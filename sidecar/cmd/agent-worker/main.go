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
		output, err := runClaude(claudeCmd, task.Prompt)
		duration := time.Since(start)

		if err != nil {
			logger.Error("claude failed", "task_id", task.TaskID, "error", err, "duration", duration)
			submitResult(sidecarURL, task.TaskID, "failed", fmt.Sprintf("claude error: %v", err), duration, logger)
		} else {
			logger.Info("claude completed", "task_id", task.TaskID, "duration", duration, "output_len", len(output))
			submitResult(sidecarURL, task.TaskID, "completed", output, duration, logger)
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

func runClaude(command string, prompt string) (string, error) {
	cmd := exec.Command(command, "-p", prompt, "--output-format", "text")
	cmd.Stderr = os.Stderr

	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("command failed: %w", err)
	}

	return strings.TrimSpace(string(output)), nil
}

// --- Result submission ---

func submitResult(sidecarURL string, taskID string, status string, resultText string, duration time.Duration, logger *slog.Logger) {
	body, _ := json.Marshal(map[string]any{
		"task_id":       taskID,
		"status":        status,
		"result_text":   resultText,
		"duration_ms":   duration.Milliseconds(),
		"input_tokens":  0,
		"output_tokens":  0,
	})

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
