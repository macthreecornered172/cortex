// Package e2e contains high-level end-to-end tests for the K8s spawn backend.
//
// These tests exercise the full orchestration flow with Kubernetes pods:
//
//  1. Makefile creates a kind cluster, loads images, deploys Cortex
//  2. Go test POSTs a multi-team DAG config with backend: k8s
//  3. Cortex auto-spawns K8s Pods (sidecar + worker) per team
//  4. Workers complete tasks (mock by default)
//  5. Poll until run completes
//  6. Verify all agent pods cleaned up
//
// Run:
//
//	make e2e-k8s-simple   # mock agent (no API key needed)
//	make e2e-k8s-multi    # 3-team DAG
package e2e

import (
	"fmt"
	"testing"
	"time"
)

const (
	k8sDAGRunName = "e2e-k8s-dag"
)

// TestK8sDAGSimple runs a single-team DAG with backend: k8s.
// This is the minimal smoke test for the K8s spawn path.
//
// Prerequisite: kind cluster with Cortex deployed (make e2e-k8s-setup),
// port-forward active on localhost:4000/4001.
func TestK8sDAGSimple(t *testing.T) {
	kc := newK8sClient()
	if !kc.available() {
		t.Skipf("kind cluster %s not available (is kind installed? run make e2e-k8s-setup)", k8sContext)
	}

	cleanupK8sPods(kc, t)

	if err := waitForCortexK8s(45 * time.Second); err != nil {
		t.Fatalf("Cortex not ready (is port-forward active?): %v", err)
	}
	t.Log("Cortex is up")

	// Submit a single-team DAG with backend: k8s
	configYAML := fmt.Sprintf(`name: "%s"
defaults:
  model: haiku
  max_turns: 5
  permission_mode: bypassPermissions
  timeout_minutes: 3
  provider: external
  backend: k8s
teams:
  - name: k8s-worker-1
    lead:
      role: "Worker"
    tasks:
      - summary: "E2E k8s smoke test task"
    depends_on: []
`, k8sDAGRunName)

	runID := createDAGRun(t, configYAML)
	t.Logf("Created run: %s", runID)

	// Verify K8s pods were spawned
	time.Sleep(10 * time.Second)
	assertK8sPodsSpawned(t, kc, 1)

	// Wait for run completion
	finalStatus, err := waitForRunCompletion(runID, 120*time.Second)
	if err != nil {
		dumpK8sPodState(t, kc)
		t.Fatalf("Run did not complete: %v", err)
	}

	t.Logf("Run final status: %s", finalStatus)
	assertK8sPodsCleanedUp(t, kc)
}

// TestK8sDAGMultiTeam runs a 3-team DAG with backend: k8s.
// Teams are in two tiers to test parallel + sequential execution with K8s pods.
//
// Prerequisite: kind cluster with Cortex deployed (make e2e-k8s-setup),
// port-forward active on localhost:4000/4001.
func TestK8sDAGMultiTeam(t *testing.T) {
	kc := newK8sClient()
	if !kc.available() {
		t.Skipf("kind cluster %s not available (is kind installed? run make e2e-k8s-setup)", k8sContext)
	}

	cleanupK8sPods(kc, t)

	if err := waitForCortexK8s(45 * time.Second); err != nil {
		t.Fatalf("Cortex not ready (is port-forward active?): %v", err)
	}
	t.Log("Cortex is up")

	// 3-team DAG: researcher + analyst (tier 1, parallel), writer (tier 2, depends on both)
	configYAML := fmt.Sprintf(`name: "%s-multi"
defaults:
  model: haiku
  max_turns: 5
  permission_mode: bypassPermissions
  timeout_minutes: 5
  provider: external
  backend: k8s
teams:
  - name: researcher
    lead:
      role: "Researcher"
    tasks:
      - summary: "Research task for e2e"
    depends_on: []
  - name: analyst
    lead:
      role: "Analyst"
    tasks:
      - summary: "Analysis task for e2e"
    depends_on: []
  - name: writer
    lead:
      role: "Writer"
    tasks:
      - summary: "Writing task using research and analysis"
    depends_on: [researcher, analyst]
`, k8sDAGRunName)

	runID := createDAGRun(t, configYAML)
	t.Logf("Created 3-team DAG run: %s", runID)

	// Wait a bit and check for tier 1 pods (researcher + analyst)
	time.Sleep(15 * time.Second)
	pods, _ := kc.listPods(k8sLabelAll)
	t.Logf("Pods active during tier 1: %d", len(pods))
	for _, pod := range pods {
		metadata, _ := pod["metadata"].(map[string]any)
		labels, _ := metadata["labels"].(map[string]any)
		status, _ := pod["status"].(map[string]any)
		phase, _ := status["phase"].(string)
		t.Logf("  team=%v run-id=%v phase=%v", labels["cortex.dev/team"], labels["cortex.dev/run-id"], phase)
	}

	// Wait for run completion
	finalStatus, err := waitForRunCompletion(runID, 180*time.Second)
	if err != nil {
		dumpK8sPodState(t, kc)
		t.Fatalf("3-team DAG did not complete: %v", err)
	}

	t.Logf("3-team DAG final status: %s", finalStatus)
	assertK8sPodsCleanedUp(t, kc)
}
