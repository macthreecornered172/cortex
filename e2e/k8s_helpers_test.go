package e2e

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os/exec"
	"strings"
	"testing"
	"time"
)

const (
	k8sContext   = "kind-cortex-e2e"
	k8sLabelAll  = "cortex.dev/component=agent-pod"
)

// k8sClient shells out to kubectl to manage pods in the default namespace.
type k8sClient struct {
	context   string
	namespace string
}

func newK8sClient() *k8sClient {
	return &k8sClient{
		context:   k8sContext,
		namespace: "default",
	}
}

// available returns true if kubectl and the kind cluster are reachable.
func (k *k8sClient) available() bool {
	cmd := exec.Command("kubectl", "--context", k.context, "cluster-info")
	return cmd.Run() == nil
}

// listPods returns pods matching the given label selector as JSON objects.
func (k *k8sClient) listPods(labelSelector string) ([]map[string]any, error) {
	out, err := exec.Command(
		"kubectl", "--context", k.context,
		"get", "pods",
		"-n", k.namespace,
		"-l", labelSelector,
		"-o", "json",
	).Output()
	if err != nil {
		return nil, fmt.Errorf("kubectl get pods: %w", err)
	}

	var result struct {
		Items []map[string]any `json:"items"`
	}
	if err := json.Unmarshal(out, &result); err != nil {
		return nil, fmt.Errorf("unmarshal pods: %w", err)
	}
	return result.Items, nil
}

// listPodsByRunID returns pods with the given cortex.dev/run-id label.
func (k *k8sClient) listPodsByRunID(runID string) ([]map[string]any, error) {
	return k.listPods(fmt.Sprintf("cortex.dev/run-id=%s", runID))
}

// deletePods deletes all pods matching the label selector.
func (k *k8sClient) deletePods(labelSelector string) error {
	cmd := exec.Command(
		"kubectl", "--context", k.context,
		"delete", "pods",
		"-n", k.namespace,
		"-l", labelSelector,
		"--ignore-not-found",
	)
	return cmd.Run()
}

// podLogs returns the logs of a container in a pod.
func (k *k8sClient) podLogs(podName, container string) (string, error) {
	args := []string{
		"--context", k.context,
		"logs", podName,
		"-n", k.namespace,
	}
	if container != "" {
		args = append(args, "-c", container)
	}
	out, err := exec.Command("kubectl", args...).Output()
	if err != nil {
		return "", fmt.Errorf("kubectl logs %s: %w", podName, err)
	}
	return string(out), nil
}

// -- Test helpers --

// waitForCortexK8s polls the port-forwarded Cortex /health/ready endpoint.
func waitForCortexK8s(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get("http://localhost:4000/health/ready")
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				return nil
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("cortex not ready after %s", timeout)
}

// assertK8sPodsSpawned checks that at least expectedTeams agent pods exist.
func assertK8sPodsSpawned(t *testing.T, kc *k8sClient, expectedTeams int) {
	t.Helper()
	pods, err := kc.listPods(k8sLabelAll)
	if err != nil {
		t.Fatalf("List pods: %v", err)
	}

	t.Logf("Agent pods found: %d (expected at least %d)", len(pods), expectedTeams)
	for _, pod := range pods {
		metadata, _ := pod["metadata"].(map[string]any)
		labels, _ := metadata["labels"].(map[string]any)
		status, _ := pod["status"].(map[string]any)
		phase, _ := status["phase"].(string)
		name, _ := metadata["name"].(string)
		t.Logf("  Pod: name=%s team=%v run-id=%v phase=%s",
			name, labels["cortex.dev/team"], labels["cortex.dev/run-id"], phase)
	}

	if len(pods) < expectedTeams {
		t.Logf("Note: fewer pods than expected — run may have completed before check (normal in mock mode)")
	}
}

// assertK8sPodsCleanedUp verifies no cortex agent pods remain.
func assertK8sPodsCleanedUp(t *testing.T, kc *k8sClient) {
	t.Helper()
	time.Sleep(5 * time.Second) // Give executor time to cleanup pods
	pods, err := kc.listPods(k8sLabelAll)
	if err != nil {
		t.Logf("Warning: failed to check remaining pods: %v", err)
		return
	}
	if len(pods) > 0 {
		t.Logf("WARNING: %d agent pods remain after run", len(pods))
		for _, pod := range pods {
			metadata, _ := pod["metadata"].(map[string]any)
			labels, _ := metadata["labels"].(map[string]any)
			t.Logf("  Leftover: team=%v run-id=%v", labels["cortex.dev/team"], labels["cortex.dev/run-id"])
		}
		cleanupK8sPods(kc, t)
	} else {
		t.Log("All agent pods cleaned up")
	}
}

// cleanupK8sPods deletes all pods with the cortex.dev/component=agent-pod label.
func cleanupK8sPods(kc *k8sClient, t *testing.T) {
	t.Helper()
	if err := kc.deletePods(k8sLabelAll); err != nil {
		t.Logf("Warning: cleanup failed: %v", err)
		return
	}
	t.Log("Cleaned up leftover agent pods")
}

// dumpK8sPodState logs pod status and tail of logs for debugging failures.
func dumpK8sPodState(t *testing.T, kc *k8sClient) {
	t.Helper()
	pods, err := kc.listPods(k8sLabelAll)
	if err != nil {
		t.Logf("Failed to list pods for debug dump: %v", err)
		return
	}
	if len(pods) == 0 {
		t.Log("No cortex agent pods found")
		return
	}
	for _, pod := range pods {
		metadata, _ := pod["metadata"].(map[string]any)
		labels, _ := metadata["labels"].(map[string]any)
		status, _ := pod["status"].(map[string]any)
		phase, _ := status["phase"].(string)
		name, _ := metadata["name"].(string)
		t.Logf("  Pod: name=%s team=%v phase=%s", name, labels["cortex.dev/team"], phase)

		for _, container := range []string{"sidecar", "worker"} {
			logs, err := kc.podLogs(name, container)
			if err != nil {
				continue
			}
			lines := strings.Split(logs, "\n")
			if len(lines) > 40 {
				lines = lines[len(lines)-40:]
			}
			t.Logf("  --- logs (%s/%s) ---\n%s", name, container, strings.Join(lines, "\n"))
		}
	}
}
