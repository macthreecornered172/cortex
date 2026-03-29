// Gate E2E tests: exercises the full HITL tier gate flow via the REST API.
//
// Flow:
//  1. Start Cortex server (mix phx.server)
//  2. POST /api/runs with a gated 2-tier config (CLI provider, mock agent)
//  3. Poll until run status = "gated"
//  4. POST /api/runs/:id/gates/approve with pivot notes
//  5. Poll until run completes
//  6. GET /api/runs/:id/gates — verify gate decisions
//  7. GET /api/runs/:id/teams/implementation — verify prompt contains gate notes
//
// Run:
//
//	make e2e-gate
//	# or: cd e2e && go test -v -run TestGate -timeout 120s
package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/itsHabib/sense"
)

// TestGateApproveAndContinue tests the full gate lifecycle:
// tier 0 completes → run gates → human approves with notes → tier 1 runs with notes injected.
func TestGateApproveAndContinue(t *testing.T) {
	mockScript := createGateMockScript(t)

	cortex, err := startCortexWithMock(t, mockScript)
	if err != nil {
		t.Fatalf("Failed to start Cortex: %v", err)
	}
	defer stopProcess(cortex, "Cortex", t)

	if err := waitForCortex(30 * time.Second); err != nil {
		t.Fatalf("Cortex not ready: %v", err)
	}
	t.Log("Cortex is up")

	// Create a gated 2-tier run
	configYAML := fmt.Sprintf(`name: "e2e-gate-test"
defaults:
  model: haiku
  max_turns: 5
  permission_mode: bypassPermissions
  timeout_minutes: 3
gates:
  after_tier: [0]
teams:
  - name: design
    lead:
      role: "API Designer"
    tasks:
      - summary: "Design the API"
    depends_on: []
  - name: implementation
    lead:
      role: "API Developer"
    tasks:
      - summary: "Implement the API"
    depends_on:
      - design
`)

	runID := createDAGRun(t, configYAML)
	t.Logf("Created gated run: %s", runID)

	// Poll until gated
	status, err := waitForRunStatus(runID, "gated", 60*time.Second)
	if err != nil {
		t.Fatalf("Run did not gate: %v", err)
	}
	t.Logf("Run gated — status: %s", status)

	// Verify gated_at_tier is 0
	run := getRunDetail(t, runID)
	gateTier, _ := run["gated_at_tier"].(float64)
	if int(gateTier) != 0 {
		t.Errorf("Expected gated_at_tier=0, got %v", run["gated_at_tier"])
	}

	// Verify gate decision is pending
	decisions := getGateDecisions(t, runID)
	if len(decisions) != 1 {
		t.Fatalf("Expected 1 gate decision, got %d", len(decisions))
	}
	if decisions[0]["decision"] != "pending" {
		t.Errorf("Expected decision=pending, got %s", decisions[0]["decision"])
	}

	// Approve with pivot notes
	approveGate(t, runID, "e2e-tester", "Pivot to REST API instead of GraphQL. Use resource-based routing.")
	t.Log("Gate approved with pivot notes")

	// Poll until completed (or gated again, or failed)
	finalStatus, err := waitForRunTerminal(runID, 60*time.Second)
	if err != nil {
		t.Fatalf("Run did not complete after approve: %v", err)
	}
	t.Logf("Final status: %s", finalStatus)

	if finalStatus != "completed" {
		t.Errorf("Expected 'completed', got '%s'", finalStatus)
	}

	// Verify gate decision was approved
	decisions = getGateDecisions(t, runID)
	approved := findDecision(decisions, "approved")
	if approved == nil {
		t.Fatal("No approved gate decision found")
	}
	if approved["decided_by"] != "e2e-tester" {
		t.Errorf("Expected decided_by=e2e-tester, got %v", approved["decided_by"])
	}
	notes, _ := approved["notes"].(string)
	if !strings.Contains(strings.ToLower(notes), "pivot to rest") {
		t.Errorf("Expected notes to contain 'pivot to rest', got: %s", notes)
	}

	// Verify the implementation team's prompt contains the gate notes
	implTeam := getTeamRun(t, runID, "implementation")
	prompt, _ := implTeam["prompt"].(string)
	if !strings.Contains(strings.ToLower(prompt), "human review notes") {
		t.Error("Implementation team prompt missing 'Human Review Notes' section")
	}
	if !strings.Contains(strings.ToLower(prompt), "pivot to rest") {
		t.Error("Implementation team prompt missing gate notes content")
	}

	// Verify the mock output reflects the pivot (substring check — mock is deterministic)
	resultSummary, _ := implTeam["result_summary"].(string)
	if !strings.Contains(strings.ToLower(resultSummary), "rest") {
		t.Errorf("Expected result to contain 'rest', got: %s", resultSummary)
	}
	if strings.Contains(strings.ToLower(resultSummary), "graphql") {
		t.Errorf("Expected result NOT to contain 'graphql', got: %s", resultSummary)
	}
	t.Log("Gate notes successfully injected into implementation team prompt")
}

// TestGateReject tests that rejecting a gate cancels the run.
func TestGateReject(t *testing.T) {
	mockScript := createGateMockScript(t)

	cortex, err := startCortexWithMock(t, mockScript)
	if err != nil {
		t.Fatalf("Failed to start Cortex: %v", err)
	}
	defer stopProcess(cortex, "Cortex", t)

	if err := waitForCortex(30 * time.Second); err != nil {
		t.Fatalf("Cortex not ready: %v", err)
	}

	configYAML := `name: "e2e-gate-reject"
defaults:
  model: haiku
  max_turns: 5
  permission_mode: bypassPermissions
  timeout_minutes: 3
gates:
  after_tier: [0]
teams:
  - name: design
    lead:
      role: "API Designer"
    tasks:
      - summary: "Design the API"
    depends_on: []
  - name: implementation
    lead:
      role: "API Developer"
    tasks:
      - summary: "Implement the API"
    depends_on:
      - design
`

	runID := createDAGRun(t, configYAML)

	// Wait for gated
	if _, err := waitForRunStatus(runID, "gated", 60*time.Second); err != nil {
		t.Fatalf("Run did not gate: %v", err)
	}

	// Reject
	rejectGate(t, runID, "e2e-tester", "Output quality too low")

	// Run should be cancelled
	finalStatus, err := waitForRunTerminal(runID, 10*time.Second)
	if err != nil {
		t.Fatalf("Run did not reach terminal state: %v", err)
	}
	if finalStatus != "cancelled" {
		t.Errorf("Expected 'cancelled', got '%s'", finalStatus)
	}

	// Verify rejected decision
	decisions := getGateDecisions(t, runID)
	rejected := findDecision(decisions, "rejected")
	if rejected == nil {
		t.Fatal("No rejected gate decision found")
	}
	if rejected["decided_by"] != "e2e-tester" {
		t.Errorf("Expected decided_by=e2e-tester, got %v", rejected["decided_by"])
	}
}

// TestGateClaudeApproveWithPivot tests the gate flow with real Claude.
// Tier 0 designs a GraphQL API, human approves with notes to pivot to REST,
// tier 1 should incorporate the pivot notes into its output.
//
// Requires ANTHROPIC_API_KEY to be set.
func TestGateClaudeApproveWithPivot(t *testing.T) {
	if os.Getenv("ANTHROPIC_API_KEY") == "" {
		t.Skip("ANTHROPIC_API_KEY not set — skipping Claude gate e2e")
	}

	cortex, err := startCortex(t)
	if err != nil {
		t.Fatalf("Failed to start Cortex: %v", err)
	}
	defer stopProcess(cortex, "Cortex", t)

	if err := waitForCortex(30 * time.Second); err != nil {
		t.Fatalf("Cortex not ready: %v", err)
	}
	t.Log("Cortex is up")

	configYAML := `name: "e2e-gate-claude"
defaults:
  model: haiku
  max_turns: 5
  permission_mode: bypassPermissions
  timeout_minutes: 5
gates:
  after_tier: [0]
teams:
  - name: api-designer
    lead:
      role: "API Designer"
    tasks:
      - summary: "Design a GraphQL API for a todo app in 5 bullet points"
        details: "Include schema types, queries, and mutations. Keep output under 15 lines."
    depends_on: []
  - name: api-implementer
    lead:
      role: "API Developer"
    tasks:
      - summary: "Outline the implementation plan for the API design from the previous team"
        details: "List 5 implementation steps. Reference the upstream design. Keep output under 15 lines."
    depends_on:
      - api-designer
`

	runID := createDAGRun(t, configYAML)
	t.Logf("Created gated Claude run: %s", runID)

	// Wait for gate
	status, err := waitForRunStatus(runID, "gated", 120*time.Second)
	if err != nil {
		t.Fatalf("Run did not gate: %v", err)
	}
	t.Logf("Run gated: %s", status)

	// Approve with pivot notes
	approveGate(t, runID, "e2e-reviewer",
		"IMPORTANT PIVOT: Discard the GraphQL design. Switch to a REST API with JSON resources instead. "+
			"Use standard HTTP methods (GET/POST/PUT/DELETE) and resource-based URLs.")
	t.Log("Gate approved with REST pivot")

	// Wait for completion
	finalStatus, err := waitForRunTerminal(runID, 180*time.Second)
	if err != nil {
		t.Fatalf("Run did not complete: %v", err)
	}
	t.Logf("Final status: %s", finalStatus)

	if finalStatus != "completed" {
		t.Errorf("Expected 'completed', got '%s'", finalStatus)
	}

	// Verify the implementer's prompt has gate notes
	implTeam := getTeamRun(t, runID, "api-implementer")
	prompt, _ := implTeam["prompt"].(string)
	if !strings.Contains(strings.ToLower(prompt), "human review notes") {
		t.Error("Implementer prompt missing Human Review Notes section")
	}

	// Sense check: the result should reflect the REST pivot, not GraphQL
	resultSummary, _ := implTeam["result_summary"].(string)
	t.Logf("Implementer result: %s", resultSummary)

	sense.Assert(t, resultSummary).
		Context("The agent was originally designing a GraphQL API, but a human reviewer approved a gate with notes instructing a pivot to REST API. This is the implementation team's output after receiving those pivot notes.").
		Expect("describes a REST API implementation, not GraphQL").
		Expect("references HTTP methods, resource URLs, or JSON endpoints").
		Expect("does not primarily describe GraphQL schemas, queries, or mutations").
		Run()

	// Gate decisions should show the approval
	decisions := getGateDecisions(t, runID)
	approved := findDecision(decisions, "approved")
	if approved == nil {
		t.Fatal("No approved decision found")
	}
	t.Logf("Gate approved by: %s", approved["decided_by"])
}

// --- Gate-specific helpers ---

func startCortexWithMock(t *testing.T, mockScript string) (*exec.Cmd, error) {
	t.Helper()
	cmd := exec.Command("mix", "phx.server")
	cmd.Dir = projectRoot()
	cmd.Env = append(os.Environ(),
		"CORTEX_GATEWAY_TOKEN="+authToken,
		"CLAUDE_COMMAND="+mockScript,
		"MIX_ENV=dev",
	)
	if testing.Verbose() {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start cortex: %w", err)
	}
	t.Logf("Cortex started with mock (PID %d)", cmd.Process.Pid)
	return cmd, nil
}

func createGateMockScript(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	script := filepath.Join(dir, "mock-claude-gate.sh")

	// The mock checks if the prompt (passed via -p) contains "pivot to REST"
	// from gate notes and outputs different results accordingly.
	content := `#!/bin/bash
ALL_ARGS="$*"
if echo "$ALL_ARGS" | grep -qi "pivot to REST"; then
  RESULT="Pivoted: Built REST API with JSON endpoints and resource routing"
else
  RESULT="Original: Built GraphQL API with schema-first design"
fi
echo '{"type":"system","subtype":"init","session_id":"sess-gate-001"}'
echo "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"$RESULT\",\"cost_usd\":0.05,\"num_turns\":2,\"duration_ms\":3000}"
`
	if err := os.WriteFile(script, []byte(content), 0o755); err != nil {
		t.Fatalf("Failed to create mock script: %v", err)
	}
	return script
}

func waitForRunStatus(runID, targetStatus string, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(fmt.Sprintf("%s/runs/%s", cortexAPI, runID))
		if err != nil {
			time.Sleep(time.Second)
			continue
		}

		var result struct {
			Data struct {
				Status string `json:"status"`
			} `json:"data"`
		}
		if json.NewDecoder(resp.Body).Decode(&result) == nil {
			if result.Data.Status == targetStatus {
				resp.Body.Close()
				return targetStatus, nil
			}
			// Bail early on terminal states if we're waiting for something else
			if result.Data.Status == "failed" || result.Data.Status == "cancelled" {
				resp.Body.Close()
				return result.Data.Status, fmt.Errorf("run reached terminal status %q while waiting for %q", result.Data.Status, targetStatus)
			}
		}
		resp.Body.Close()
		time.Sleep(time.Second)
	}
	return "", fmt.Errorf("run %s did not reach status %q within %s", runID, targetStatus, timeout)
}

func waitForRunTerminal(runID string, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(fmt.Sprintf("%s/runs/%s", cortexAPI, runID))
		if err != nil {
			time.Sleep(time.Second)
			continue
		}

		var result struct {
			Data struct {
				Status string `json:"status"`
			} `json:"data"`
		}
		if json.NewDecoder(resp.Body).Decode(&result) == nil {
			s := result.Data.Status
			if s == "completed" || s == "failed" || s == "cancelled" || s == "stopped" {
				resp.Body.Close()
				return s, nil
			}
		}
		resp.Body.Close()
		time.Sleep(time.Second)
	}
	return "", fmt.Errorf("run %s did not reach terminal state within %s", runID, timeout)
}

func getRunDetail(t *testing.T, runID string) map[string]any {
	t.Helper()
	resp, err := http.Get(fmt.Sprintf("%s/runs/%s", cortexAPI, runID))
	if err != nil {
		t.Fatalf("GET run: %v", err)
	}
	defer resp.Body.Close()

	var result struct {
		Data map[string]any `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		t.Fatalf("Decode run: %v", err)
	}
	return result.Data
}

func getGateDecisions(t *testing.T, runID string) []map[string]any {
	t.Helper()
	resp, err := http.Get(fmt.Sprintf("%s/runs/%s/gates", cortexAPI, runID))
	if err != nil {
		t.Fatalf("GET gates: %v", err)
	}
	defer resp.Body.Close()

	var result struct {
		Data []map[string]any `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		t.Fatalf("Decode gates: %v", err)
	}
	return result.Data
}

func getTeamRun(t *testing.T, runID, teamName string) map[string]any {
	t.Helper()
	resp, err := http.Get(fmt.Sprintf("%s/runs/%s/teams/%s", cortexAPI, runID, teamName))
	if err != nil {
		t.Fatalf("GET team run: %v", err)
	}
	defer resp.Body.Close()

	var result struct {
		Data map[string]any `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		t.Fatalf("Decode team run: %v", err)
	}
	return result.Data
}

func approveGate(t *testing.T, runID, decidedBy, notes string) {
	t.Helper()
	payload, _ := json.Marshal(map[string]string{
		"decided_by": decidedBy,
		"notes":      notes,
	})

	resp, err := http.Post(
		fmt.Sprintf("%s/runs/%s/gates/approve", cortexAPI, runID),
		"application/json",
		bytes.NewReader(payload),
	)
	if err != nil {
		t.Fatalf("POST gates/approve: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("Approve returned %d: %s", resp.StatusCode, string(body))
	}
}

func rejectGate(t *testing.T, runID, decidedBy, notes string) {
	t.Helper()
	payload, _ := json.Marshal(map[string]string{
		"decided_by": decidedBy,
		"notes":      notes,
	})

	resp, err := http.Post(
		fmt.Sprintf("%s/runs/%s/gates/reject", cortexAPI, runID),
		"application/json",
		bytes.NewReader(payload),
	)
	if err != nil {
		t.Fatalf("POST gates/reject: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("Reject returned %d: %s", resp.StatusCode, string(body))
	}
}

func findDecision(decisions []map[string]any, targetDecision string) map[string]any {
	for _, d := range decisions {
		if d["decision"] == targetDecision {
			return d
		}
	}
	return nil
}
