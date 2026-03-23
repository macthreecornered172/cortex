// Package main is the entrypoint for the Cortex agent worker.
//
// The agent worker polls the sidecar's HTTP API for tasks, runs
// `claude -p "prompt"` for each task, and posts the result back.
// It's the "brain" that sits alongside the sidecar in a pod.
//
// Usage:
//
//	SIDECAR_URL=http://localhost:9091 agent-worker
//
// Environment:
//
//	SIDECAR_URL       - Sidecar HTTP API URL (default: http://localhost:9091)
//	POLL_INTERVAL_MS  - Polling interval in ms (default: 500)
//	CLAUDE_COMMAND    - Command to run (default: claude)
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func main() {
	sidecarURL := envOr("SIDECAR_URL", "http://localhost:9091")
	pollInterval := envDurationMs("POLL_INTERVAL_MS", 500)
	claudeCmd := envOr("CLAUDE_COMMAND", "claude")

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	logger.Info("agent-worker starting",
		"sidecar_url", sidecarURL,
		"poll_interval", pollInterval,
		"claude_command", claudeCmd,
	)

	// Wait for sidecar to be healthy
	if err := waitForSidecar(sidecarURL, 30*time.Second, logger); err != nil {
		logger.Error("sidecar not available", "error", err)
		os.Exit(1)
	}
	logger.Info("sidecar is healthy")

	// Trap signals for graceful shutdown
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	// Poll loop
	for {
		select {
		case <-stop:
			logger.Info("shutting down")
			return
		default:
		}

		task, err := pollTask(sidecarURL)
		if err != nil {
			logger.Debug("poll failed", "error", err)
			time.Sleep(pollInterval)
			continue
		}

		if task == nil {
			time.Sleep(pollInterval)
			continue
		}

		logger.Info("received task", "task_id", task.TaskID)

		// Run claude -p with the task prompt
		start := time.Now()
		cr, err := runClaude(claudeCmd, task.Prompt, sidecarURL, logger)
		duration := time.Since(start)

		if err != nil {
			logger.Error("claude failed", "task_id", task.TaskID, "error", err, "duration", duration)
			errResult := &claudeResult{ResultText: fmt.Sprintf("claude error: %v", err)}
			submitResult(sidecarURL, task.TaskID, "failed", errResult, duration, logger)
		} else {
			logger.Info("claude completed",
				"task_id", task.TaskID,
				"duration", duration,
				"input_tokens", cr.InputTokens,
				"output_tokens", cr.OutputTokens,
				"cost_usd", cr.CostUSD,
			)
			submitResult(sidecarURL, task.TaskID, "completed", cr, duration, logger)
		}
	}
}

// --- Task polling ---

type taskResponse struct {
	Task *taskInfo `json:"task"`
}

type taskInfo struct {
	TaskID    string `json:"task_id"`
	Prompt    string `json:"prompt"`
	Tools     []string `json:"tools"`
	TimeoutMs int64  `json:"timeout_ms"`
}

func pollTask(sidecarURL string) (*taskInfo, error) {
	resp, err := http.Get(sidecarURL + "/task")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result taskResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	if result.Task == nil || result.Task.TaskID == "" {
		return nil, nil
	}

	return result.Task, nil
}

// --- Claude execution ---

// claudeResult holds the parsed output from a claude stream-json run.
type claudeResult struct {
	ResultText string
	InputTokens int
	OutputTokens int
	CacheReadTokens int
	CacheCreationTokens int
	NumTurns int
	CostUSD float64
	SessionID string
}

func runClaude(command string, prompt string, sidecarURL string, logger *slog.Logger) (*claudeResult, error) {
	cmd := exec.Command(command, "-p", prompt, "--output-format", "stream-json", "--verbose")
	cmd.Stderr = os.Stderr

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("stdout pipe failed: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("command start failed: %w", err)
	}

	result := &claudeResult{}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 256*1024), 1024*1024)

	lastReport := time.Now()
	reportInterval := 5 * time.Second

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var event map[string]any
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			continue
		}

		processEvent(event, result)

		// Report progress every ~5s
		if time.Since(lastReport) >= reportInterval && (result.InputTokens > 0 || result.OutputTokens > 0) {
			reportProgress(sidecarURL, result, logger)
			lastReport = time.Now()
		}
	}

	if err := cmd.Wait(); err != nil {
		return nil, fmt.Errorf("command failed: %w", err)
	}

	return result, nil
}

func processEvent(event map[string]any, result *claudeResult) {
	eventType, _ := event["type"].(string)

	switch eventType {
	case "result":
		if r, ok := event["result"].(string); ok {
			result.ResultText = r
		}
		if v, ok := event["cost_usd"].(float64); ok {
			result.CostUSD = v
		}
		if v, ok := event["num_turns"].(float64); ok {
			result.NumTurns = int(v)
		}
		if v, ok := event["session_id"].(string); ok {
			result.SessionID = v
		}
		if usage, ok := event["usage"].(map[string]any); ok {
			extractUsage(usage, result)
		}

	case "system":
		if sid, ok := event["session_id"].(string); ok {
			result.SessionID = sid
		}

	case "assistant":
		if msg, ok := event["message"].(map[string]any); ok {
			if usage, ok := msg["usage"].(map[string]any); ok {
				extractUsage(usage, result)
			}
		}
	}
}

func reportProgress(sidecarURL string, result *claudeResult, logger *slog.Logger) {
	detail, _ := json.Marshal(map[string]any{
		"input_tokens":          result.InputTokens,
		"output_tokens":         result.OutputTokens,
		"cache_read_tokens":     result.CacheReadTokens,
		"cache_creation_tokens": result.CacheCreationTokens,
	})

	body, _ := json.Marshal(map[string]any{
		"status": "working",
		"detail": string(detail),
	})

	resp, err := http.Post(sidecarURL+"/status", "application/json", bytes.NewReader(body))
	if err != nil {
		logger.Debug("progress report failed", "error", err)
		return
	}
	resp.Body.Close()
}


func extractUsage(usage map[string]any, result *claudeResult) {
	if v, ok := usage["input_tokens"].(float64); ok {
		result.InputTokens = int(v)
	}
	if v, ok := usage["output_tokens"].(float64); ok {
		result.OutputTokens = int(v)
	}
	if v, ok := usage["cache_read_input_tokens"].(float64); ok {
		result.CacheReadTokens = int(v)
	}
	if v, ok := usage["cache_creation_input_tokens"].(float64); ok {
		result.CacheCreationTokens = int(v)
	}
}

// --- Result submission ---

type resultPayload struct {
	TaskID              string  `json:"task_id"`
	Status              string  `json:"status"`
	ResultText          string  `json:"result_text"`
	DurationMs          int64   `json:"duration_ms"`
	InputTokens         int     `json:"input_tokens"`
	OutputTokens        int     `json:"output_tokens"`
	CacheReadTokens     int     `json:"cache_read_tokens"`
	CacheCreationTokens int     `json:"cache_creation_tokens"`
	NumTurns            int     `json:"num_turns"`
	CostUSD             float64 `json:"cost_usd"`
	SessionID           string  `json:"session_id,omitempty"`
}

func submitResult(sidecarURL string, taskID string, status string, cr *claudeResult, duration time.Duration, logger *slog.Logger) {
	payload := resultPayload{
		TaskID:              taskID,
		Status:              status,
		ResultText:          cr.ResultText,
		DurationMs:          duration.Milliseconds(),
		InputTokens:         cr.InputTokens,
		OutputTokens:        cr.OutputTokens,
		CacheReadTokens:     cr.CacheReadTokens,
		CacheCreationTokens: cr.CacheCreationTokens,
		NumTurns:            cr.NumTurns,
		CostUSD:             cr.CostUSD,
		SessionID:           cr.SessionID,
	}
	body, _ := json.Marshal(payload)

	resp, err := http.Post(sidecarURL+"/task/result", "application/json", bytes.NewReader(body))
	if err != nil {
		logger.Error("failed to submit result", "task_id", taskID, "error", err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		respBody, _ := io.ReadAll(resp.Body)
		logger.Error("submit result failed", "task_id", taskID, "status", resp.StatusCode, "body", string(respBody))
	} else {
		logger.Info("result submitted", "task_id", taskID, "status", status)
	}
}

// --- Sidecar health ---

func waitForSidecar(sidecarURL string, timeout time.Duration, logger *slog.Logger) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(sidecarURL + "/health")
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				return nil
			}
		}
		logger.Debug("waiting for sidecar...")
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("sidecar not healthy after %s", timeout)
}

// --- Env helpers ---

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envDurationMs(key string, fallbackMs int) time.Duration {
	if v := os.Getenv(key); v != "" {
		if ms, err := strconv.Atoi(v); err == nil {
			return time.Duration(ms) * time.Millisecond
		}
	}
	return time.Duration(fallbackMs) * time.Millisecond
}
