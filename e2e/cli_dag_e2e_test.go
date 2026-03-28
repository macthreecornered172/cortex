// Package e2e contains end-to-end tests for the CLI provider pipeline.
//
// These tests exercise the full orchestration flow with the CLI provider:
//
//  1. Go test starts Cortex via mix phx.server
//  2. Go test POSTs a multi-team DAG config with provider: cli
//  3. Cortex shells out to `claude -p` for each team (real Claude)
//  4. Poll until run completes
//  5. Verify run status
//
// Run:
//
//	make e2e-cli        # single-team smoke test
//	make e2e-cli-multi  # 5-team 3-tier DAG
package e2e

import (
	"os"
	"testing"
	"time"
)

// TestCLIDAGSimple runs a single-team DAG with provider: cli (real Claude).
// This is the minimal smoke test for the CLI provider path — no sidecar,
// no Docker, no K8s. Cortex shells out to `claude -p` directly.
//
// Requires ANTHROPIC_API_KEY to be set.
func TestCLIDAGSimple(t *testing.T) {
	if os.Getenv("ANTHROPIC_API_KEY") == "" {
		t.Skip("ANTHROPIC_API_KEY not set — skipping CLI provider e2e (requires real Claude)")
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

	configYAML := `name: "e2e-cli-simple"
defaults:
  model: haiku
  max_turns: 5
  permission_mode: bypassPermissions
  timeout_minutes: 3
teams:
  - name: backend
    lead:
      role: "Backend Engineer"
    tasks:
      - summary: "List 3 best practices for REST API design in one sentence each"
    depends_on: []
`

	runID := createDAGRun(t, configYAML)
	t.Logf("Created CLI DAG run: %s", runID)

	finalStatus, err := waitForRunCompletion(runID, 120*time.Second)
	if err != nil {
		t.Fatalf("Run did not complete: %v", err)
	}

	t.Logf("CLI DAG simple — final status: %s", finalStatus)
	if finalStatus != "completed" {
		t.Errorf("Expected 'completed', got '%s'", finalStatus)
	}
}

// TestCLIDAGMultiTeam runs a 5-team, 3-tier DAG with provider: cli.
// Same topology as Docker/K8s e2e tests: 3 parallel research teams (tier 0),
// 1 architecture synthesis (tier 1), 1 final review (tier 2).
//
// Requires ANTHROPIC_API_KEY to be set.
func TestCLIDAGMultiTeam(t *testing.T) {
	if os.Getenv("ANTHROPIC_API_KEY") == "" {
		t.Skip("ANTHROPIC_API_KEY not set — skipping CLI provider e2e (requires real Claude)")
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

	configYAML := `name: "e2e-cli-multi"
defaults:
  model: haiku
  max_turns: 5
  permission_mode: bypassPermissions
  timeout_minutes: 5
teams:
  # --- Tier 0: Three parallel research teams ---
  - name: api-researcher
    lead:
      role: "API Design Researcher"
    tasks:
      - summary: "List 3 REST API design patterns for a task management system"
        details: |
          Cover resource naming, pagination, and error response format.
          Keep the output to ~10 lines.
    depends_on: []

  - name: data-modeler
    lead:
      role: "Data Architect"
    tasks:
      - summary: "Sketch a 4-table database schema for a task management system"
        details: |
          Include projects, tasks, users, and comments tables.
          List columns and primary/foreign keys. Keep it to ~15 lines.
    depends_on: []

  - name: security-reviewer
    lead:
      role: "Security Engineer"
    tasks:
      - summary: "List the top 3 security requirements for a task management API"
        details: |
          Cover authentication, authorization, and input validation.
          Keep it to ~10 lines.
    depends_on: []

  # --- Tier 1: Architecture synthesis ---
  - name: architect
    lead:
      role: "Software Architect"
    tasks:
      - summary: "Summarize upstream findings into a 5-point architecture proposal"
        details: |
          Reference the API patterns, data model, and security requirements
          from upstream teams. Keep it to ~15 lines.
    depends_on: [api-researcher, data-modeler, security-reviewer]

  # --- Tier 2: Final review ---
  - name: tech-lead
    lead:
      role: "Tech Lead"
    tasks:
      - summary: "Produce a 5-item implementation checklist based on the architecture proposal"
        details: |
          Reference specific decisions from upstream. Keep it to ~10 lines.
    depends_on: [architect]
`

	runID := createDAGRun(t, configYAML)
	t.Logf("Created 5-team CLI DAG run: %s", runID)

	finalStatus, err := waitForRunCompletion(runID, 300*time.Second)
	if err != nil {
		t.Fatalf("5-team CLI DAG did not complete: %v", err)
	}

	t.Logf("CLI DAG multi-team — final status: %s", finalStatus)
	if finalStatus != "completed" {
		t.Errorf("Expected 'completed', got '%s'", finalStatus)
	}
}
