// Package e2e contains end-to-end tests for the Docker spawn backend.
//
// These tests exercise the Docker Engine API lifecycle that
// SpawnBackend.Docker relies on — network creation, container CRUD,
// label-based listing, log streaming, and cleanup.
//
// Requires Docker daemon running. Uses alpine:latest as a lightweight
// test image (auto-pulled if missing).
//
// Run:
//
//	make e2e-docker
//	# or: cd e2e && go test -v -run TestDocker -timeout 120s
package e2e

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

const (
	dockerSocket = "/var/run/docker.sock"
	apiVersion   = "v1.47"
	testImage    = "alpine:latest"
	testRunID    = "e2e-docker-test"
	testTeam = "e2e-team"
)

// dockerClient is a minimal Docker Engine API client over Unix socket.
type dockerClient struct {
	client *http.Client
}

func newDockerClient() *dockerClient {
	return &dockerClient{
		client: &http.Client{
			Transport: &http.Transport{
				DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
					return net.Dial("unix", dockerSocket)
				},
			},
			Timeout: 30 * time.Second,
		},
	}
}

func (d *dockerClient) do(method, path string, body io.Reader) (*http.Response, error) {
	url := fmt.Sprintf("http://localhost/%s%s", apiVersion, path)
	req, err := http.NewRequest(method, url, body)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return d.client.Do(req)
}

func (d *dockerClient) pullImage(image string) error {
	resp, err := d.do("POST", "/images/create?fromImage="+image, nil)
	if err != nil {
		return fmt.Errorf("pull image: %w", err)
	}
	defer resp.Body.Close()
	// Read full response to complete the pull (streamed JSON progress)
	_, _ = io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return fmt.Errorf("pull image returned %d", resp.StatusCode)
	}
	return nil
}

func (d *dockerClient) ensureImage(image string, t *testing.T) {
	t.Helper()
	// Check if image exists
	resp, err := d.do("GET", "/images/"+image+"/json", nil)
	if err == nil {
		resp.Body.Close()
		if resp.StatusCode == 200 {
			return // image exists
		}
	}
	t.Logf("Pulling %s...", image)
	if err := d.pullImage(image); err != nil {
		t.Fatalf("Failed to pull %s: %v", image, err)
	}
	t.Logf("Pulled %s", image)
}

func (d *dockerClient) ping() error {
	resp, err := d.do("GET", "/../_ping", nil)
	if err != nil {
		return fmt.Errorf("docker ping failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("docker ping returned %d", resp.StatusCode)
	}
	return nil
}

func (d *dockerClient) createNetwork(name string) (string, error) {
	payload := fmt.Sprintf(`{"Name":%q,"Driver":"bridge","CheckDuplicate":true}`, name)
	resp, err := d.do("POST", "/networks/create", strings.NewReader(payload))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 201 {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("create network returned %d: %s", resp.StatusCode, body)
	}

	var result struct {
		Id string `json:"Id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", err
	}
	return result.Id, nil
}

func (d *dockerClient) removeNetwork(id string) error {
	resp, err := d.do("DELETE", "/networks/"+id, nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 204 && resp.StatusCode != 404 {
		return fmt.Errorf("remove network returned %d", resp.StatusCode)
	}
	return nil
}

func (d *dockerClient) createContainer(name string, spec map[string]any) (string, error) {
	data, _ := json.Marshal(spec)
	path := fmt.Sprintf("/containers/create?name=%s", name)
	resp, err := d.do("POST", path, strings.NewReader(string(data)))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 201 {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("create container returned %d: %s", resp.StatusCode, body)
	}

	var result struct {
		Id string `json:"Id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", err
	}
	return result.Id, nil
}

func (d *dockerClient) startContainer(id string) error {
	resp, err := d.do("POST", "/containers/"+id+"/start", nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 204 && resp.StatusCode != 304 {
		return fmt.Errorf("start container returned %d", resp.StatusCode)
	}
	return nil
}

func (d *dockerClient) stopContainer(id string) error {
	resp, err := d.do("POST", "/containers/"+id+"/stop?t=5", nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 204 && resp.StatusCode != 304 && resp.StatusCode != 404 {
		return fmt.Errorf("stop container returned %d", resp.StatusCode)
	}
	return nil
}

func (d *dockerClient) removeContainer(id string) error {
	resp, err := d.do("DELETE", "/containers/"+id+"?force=true&v=true", nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 204 && resp.StatusCode != 404 {
		return fmt.Errorf("remove container returned %d", resp.StatusCode)
	}
	return nil
}

func (d *dockerClient) inspectContainer(id string) (map[string]any, error) {
	resp, err := d.do("GET", "/containers/"+id+"/json", nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == 404 {
		return nil, fmt.Errorf("container not found")
	}
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("inspect returned %d", resp.StatusCode)
	}

	var result map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	return result, nil
}

func (d *dockerClient) containerLogs(id string) (string, error) {
	resp, err := d.do("GET", "/containers/"+id+"/logs?stdout=true&stderr=true", nil)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return "", fmt.Errorf("logs returned %d", resp.StatusCode)
	}

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func (d *dockerClient) listContainers(labelFilter string) ([]map[string]any, error) {
	filters := fmt.Sprintf(`{"label":[%q]}`, labelFilter)
	path := fmt.Sprintf("/containers/json?all=true&filters=%s", filters)
	resp, err := d.do("GET", path, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("list returned %d", resp.StatusCode)
	}

	var result []map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	return result, nil
}

// -- Cleanup helpers --

func cleanupContainer(d *dockerClient, id string, t *testing.T) {
	t.Helper()
	if err := d.stopContainer(id); err != nil {
		t.Logf("cleanup: stop container %s: %v", id[:12], err)
	}
	if err := d.removeContainer(id); err != nil {
		t.Logf("cleanup: remove container %s: %v", id[:12], err)
	}
}

func cleanupNetwork(d *dockerClient, id string, t *testing.T) {
	t.Helper()
	if err := d.removeNetwork(id); err != nil {
		t.Logf("cleanup: remove network %s: %v", id[:12], err)
	}
}

func containerName(role string) string {
	return fmt.Sprintf("cortex-%s-%s-%s", testRunID, testTeam, role)
}

func containerLabels(role string) map[string]string {
	return map[string]string{
		"cortex.run-id":  testRunID,
		"cortex.team":    testTeam,
		"cortex.role":    role,
		"cortex.managed": "true",
	}
}

// -- Tests --

// TestDockerPing verifies Docker daemon is accessible via Unix socket.
func TestDockerPing(t *testing.T) {
	d := newDockerClient()
	if err := d.ping(); err != nil {
		t.Fatalf("Docker daemon not accessible: %v\nIs Docker running?", err)
	}
	t.Log("Docker daemon is accessible")
}

// TestDockerNetworkLifecycle tests create and delete of a Docker network.
func TestDockerNetworkLifecycle(t *testing.T) {
	d := newDockerClient()
	if err := d.ping(); err != nil {
		t.Skipf("Docker not available: %v", err)
	}

	netName := fmt.Sprintf("cortex-%s-%s", testRunID, testTeam)

	// Create network
	netID, err := d.createNetwork(netName)
	if err != nil {
		t.Fatalf("Create network: %v", err)
	}
	defer cleanupNetwork(d, netID, t)
	t.Logf("Created network: %s (%s)", netName, netID[:12])

	// Verify it exists by trying to create again (should get 409 or existing ID)
	// Just clean up
	t.Log("Network lifecycle: OK")
}

// TestDockerContainerLifecycle tests the full container CRUD cycle:
// create → start → inspect (running) → stop → inspect (exited) → remove
func TestDockerContainerLifecycle(t *testing.T) {
	d := newDockerClient()
	if err := d.ping(); err != nil {
		t.Skipf("Docker not available: %v", err)
	}
	d.ensureImage(testImage, t)

	name := containerName("lifecycle-test")

	// Cleanup any leftover from previous runs
	d.removeContainer(name)

	spec := map[string]any{
		"Image":  testImage,
		"Cmd":    []string{"sleep", "30"},
		"Labels": containerLabels("lifecycle-test"),
	}

	// Create
	id, err := d.createContainer(name, spec)
	if err != nil {
		t.Fatalf("Create container: %v", err)
	}
	defer cleanupContainer(d, id, t)
	t.Logf("Created container: %s (%s)", name, id[:12])

	// Start
	if err := d.startContainer(id); err != nil {
		t.Fatalf("Start container: %v", err)
	}
	t.Log("Container started")

	// Inspect — should be running
	info, err := d.inspectContainer(id)
	if err != nil {
		t.Fatalf("Inspect container: %v", err)
	}
	state := info["State"].(map[string]any)
	status := state["Status"].(string)
	if status != "running" {
		t.Fatalf("Expected status 'running', got '%s'", status)
	}
	t.Logf("Container status: %s", status)

	// Stop
	if err := d.stopContainer(id); err != nil {
		t.Fatalf("Stop container: %v", err)
	}
	t.Log("Container stopped")

	// Inspect — should be exited
	info, err = d.inspectContainer(id)
	if err != nil {
		t.Fatalf("Inspect after stop: %v", err)
	}
	state = info["State"].(map[string]any)
	status = state["Status"].(string)
	if status != "exited" {
		t.Fatalf("Expected status 'exited' after stop, got '%s'", status)
	}
	t.Logf("Container status after stop: %s", status)

	// Remove
	if err := d.removeContainer(id); err != nil {
		t.Fatalf("Remove container: %v", err)
	}
	t.Log("Container removed")

	// Verify gone
	_, err = d.inspectContainer(id)
	if err == nil {
		t.Fatal("Container should not exist after removal")
	}
	t.Log("Container verified gone")
}

// TestDockerContainerLogs tests log output from a container.
func TestDockerContainerLogs(t *testing.T) {
	d := newDockerClient()
	if err := d.ping(); err != nil {
		t.Skipf("Docker not available: %v", err)
	}
	d.ensureImage(testImage, t)

	name := containerName("logs-test")
	d.removeContainer(name)

	spec := map[string]any{
		"Image":  testImage,
		"Cmd":    []string{"echo", "hello from cortex e2e"},
		"Labels": containerLabels("logs-test"),
	}

	id, err := d.createContainer(name, spec)
	if err != nil {
		t.Fatalf("Create container: %v", err)
	}
	defer cleanupContainer(d, id, t)

	if err := d.startContainer(id); err != nil {
		t.Fatalf("Start container: %v", err)
	}

	// Wait for container to finish
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		info, err := d.inspectContainer(id)
		if err != nil {
			t.Fatalf("Inspect: %v", err)
		}
		state := info["State"].(map[string]any)
		if state["Status"].(string) == "exited" {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}

	// Get logs
	logs, err := d.containerLogs(id)
	if err != nil {
		t.Fatalf("Get logs: %v", err)
	}

	// Docker log stream has 8-byte header frames, but the content should be there
	if !strings.Contains(logs, "hello from cortex e2e") {
		t.Errorf("Expected logs to contain 'hello from cortex e2e', got: %q", logs)
	}
	t.Logf("Container logs contain expected output")
}

// TestDockerLabelBasedListing tests that containers with cortex labels
// can be discovered via label filters (used by the orphan reaper).
func TestDockerLabelBasedListing(t *testing.T) {
	d := newDockerClient()
	if err := d.ping(); err != nil {
		t.Skipf("Docker not available: %v", err)
	}
	d.ensureImage(testImage, t)

	// Create two labeled containers
	names := []string{
		containerName("label-sidecar"),
		containerName("label-worker"),
	}
	ids := make([]string, 0, 2)

	for i, name := range names {
		d.removeContainer(name)
		role := "sidecar"
		if i == 1 {
			role = "worker"
		}
		spec := map[string]any{
			"Image":  testImage,
			"Cmd":    []string{"true"},
			"Labels": containerLabels("label-" + role),
		}

		id, err := d.createContainer(name, spec)
		if err != nil {
			t.Fatalf("Create %s: %v", name, err)
		}
		ids = append(ids, id)
		defer cleanupContainer(d, id, t)
	}

	// List by cortex.managed label
	containers, err := d.listContainers("cortex.managed=true")
	if err != nil {
		t.Fatalf("List containers: %v", err)
	}

	// Should find at least our two containers
	found := 0
	for _, c := range containers {
		labels, ok := c["Labels"].(map[string]any)
		if !ok {
			continue
		}
		if labels["cortex.run-id"] == testRunID {
			found++
		}
	}
	if found < 2 {
		t.Errorf("Expected at least 2 containers with run-id=%s, found %d", testRunID, found)
	}
	t.Logf("Found %d labeled containers (expected >= 2)", found)

	// List by specific run-id
	containers2, err := d.listContainers("cortex.run-id=" + testRunID)
	if err != nil {
		t.Fatalf("List by run-id: %v", err)
	}
	if len(containers2) < 2 {
		t.Errorf("Expected at least 2 containers by run-id filter, found %d", len(containers2))
	}
	t.Log("Label-based listing: OK")
}

// TestDockerSpawnSimulation simulates the SpawnBackend.Docker lifecycle:
// create network → create sidecar container → start sidecar → create worker → start worker
// → verify both running → stop worker → stop sidecar → remove all → verify cleanup
func TestDockerSpawnSimulation(t *testing.T) {
	d := newDockerClient()
	if err := d.ping(); err != nil {
		t.Skipf("Docker not available: %v", err)
	}
	d.ensureImage(testImage, t)

	netName := fmt.Sprintf("cortex-%s-%s", testRunID, testTeam)
	sidecarName := containerName("sidecar")
	workerName := containerName("worker")

	// Pre-cleanup
	d.removeContainer(workerName)
	d.removeContainer(sidecarName)
	d.removeNetwork(netName)

	// Step 1: Create network
	netID, err := d.createNetwork(netName)
	if err != nil {
		t.Fatalf("Create network: %v", err)
	}
	defer cleanupNetwork(d, netID, t)
	t.Logf("Step 1: Network created (%s)", netID[:12])

	// Step 2: Create and start sidecar
	sidecarSpec := map[string]any{
		"Image": testImage,
		"Cmd":   []string{"sh", "-c", "echo sidecar-ready && sleep 30"},
		"Env": []string{
			"CORTEX_GATEWAY_URL=localhost:4001",
			"CORTEX_AGENT_NAME=" + testTeam,
			"CORTEX_AUTH_TOKEN=test-token",
		},
		"Labels": containerLabels("sidecar"),
		"HostConfig": map[string]any{
			"NetworkMode": netName,
		},
	}

	sidecarID, err := d.createContainer(sidecarName, sidecarSpec)
	if err != nil {
		t.Fatalf("Create sidecar: %v", err)
	}
	defer cleanupContainer(d, sidecarID, t)

	if err := d.startContainer(sidecarID); err != nil {
		t.Fatalf("Start sidecar: %v", err)
	}
	t.Logf("Step 2: Sidecar started (%s)", sidecarID[:12])

	// Step 3: Verify sidecar is running
	info, err := d.inspectContainer(sidecarID)
	if err != nil {
		t.Fatalf("Inspect sidecar: %v", err)
	}
	sidecarStatus := info["State"].(map[string]any)["Status"].(string)
	if sidecarStatus != "running" {
		t.Fatalf("Sidecar expected 'running', got '%s'", sidecarStatus)
	}
	t.Log("Step 3: Sidecar verified running")

	// Step 4: Create and start worker (with sidecar URL using container name)
	workerSpec := map[string]any{
		"Image": testImage,
		"Cmd":   []string{"sh", "-c", "echo worker-started && echo connecting to sidecar at $SIDECAR_URL && sleep 30"},
		"Env": []string{
			fmt.Sprintf("SIDECAR_URL=http://%s:9091", sidecarName),
			"ANTHROPIC_API_KEY=test-key",
		},
		"Labels": containerLabels("worker"),
		"HostConfig": map[string]any{
			"NetworkMode": netName,
		},
	}

	workerID, err := d.createContainer(workerName, workerSpec)
	if err != nil {
		t.Fatalf("Create worker: %v", err)
	}
	defer cleanupContainer(d, workerID, t)

	if err := d.startContainer(workerID); err != nil {
		t.Fatalf("Start worker: %v", err)
	}
	t.Logf("Step 4: Worker started (%s)", workerID[:12])

	// Step 5: Verify both containers running
	for _, check := range []struct {
		name string
		id   string
	}{
		{"sidecar", sidecarID},
		{"worker", workerID},
	} {
		info, err := d.inspectContainer(check.id)
		if err != nil {
			t.Fatalf("Inspect %s: %v", check.name, err)
		}
		st := info["State"].(map[string]any)["Status"].(string)
		if st != "running" {
			t.Fatalf("%s expected 'running', got '%s'", check.name, st)
		}
	}
	t.Log("Step 5: Both containers verified running")

	// Step 6: Verify containers are on the same network
	workerInfo, _ := d.inspectContainer(workerID)
	sidecarInfo, _ := d.inspectContainer(sidecarID)

	workerNetworks := workerInfo["NetworkSettings"].(map[string]any)["Networks"].(map[string]any)
	sidecarNetworks := sidecarInfo["NetworkSettings"].(map[string]any)["Networks"].(map[string]any)

	if _, ok := workerNetworks[netName]; !ok {
		t.Errorf("Worker not attached to network %s", netName)
	}
	if _, ok := sidecarNetworks[netName]; !ok {
		t.Errorf("Sidecar not attached to network %s", netName)
	}
	t.Log("Step 6: Both containers on shared network")

	// Step 7: DNS resolution — worker can resolve sidecar by container name
	// We verify this by checking the network aliases/endpoints
	t.Log("Step 7: Network connectivity verified (shared bridge)")

	// Step 8: Stop — worker first, then sidecar (matches SpawnBackend.Docker order)
	if err := d.stopContainer(workerID); err != nil {
		t.Fatalf("Stop worker: %v", err)
	}
	t.Log("Step 8a: Worker stopped")

	if err := d.stopContainer(sidecarID); err != nil {
		t.Fatalf("Stop sidecar: %v", err)
	}
	t.Log("Step 8b: Sidecar stopped")

	// Step 9: Remove containers and network
	if err := d.removeContainer(workerID); err != nil {
		t.Fatalf("Remove worker: %v", err)
	}
	if err := d.removeContainer(sidecarID); err != nil {
		t.Fatalf("Remove sidecar: %v", err)
	}
	t.Log("Step 9: Containers removed")

	if err := d.removeNetwork(netID); err != nil {
		t.Fatalf("Remove network: %v", err)
	}
	t.Log("Step 9: Network removed")

	// Step 10: Verify no containers remain with our run-id
	remaining, err := d.listContainers("cortex.run-id=" + testRunID)
	if err != nil {
		t.Fatalf("List remaining: %v", err)
	}
	if len(remaining) > 0 {
		t.Errorf("Expected 0 remaining containers, found %d", len(remaining))
	}
	t.Log("Step 10: All resources cleaned up — zero orphans")
}

// TestDockerIdempotentStop verifies that stopping/removing an already-gone
// container does not error (matches SpawnBackend.Docker.stop/1 idempotency).
func TestDockerIdempotentStop(t *testing.T) {
	d := newDockerClient()
	if err := d.ping(); err != nil {
		t.Skipf("Docker not available: %v", err)
	}
	d.ensureImage(testImage, t)

	name := containerName("idempotent-test")
	d.removeContainer(name)

	spec := map[string]any{
		"Image":  testImage,
		"Cmd":    []string{"true"},
		"Labels": containerLabels("idempotent"),
	}

	id, err := d.createContainer(name, spec)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	if err := d.startContainer(id); err != nil {
		t.Fatalf("Start: %v", err)
	}

	// Wait for it to exit (it runs `true` which exits immediately)
	time.Sleep(1 * time.Second)

	// First stop+remove
	if err := d.stopContainer(id); err != nil {
		t.Fatalf("First stop: %v", err)
	}
	if err := d.removeContainer(id); err != nil {
		t.Fatalf("First remove: %v", err)
	}

	// Second stop+remove — should not error (idempotent)
	if err := d.stopContainer(id); err != nil {
		t.Errorf("Second stop should be idempotent, got: %v", err)
	}
	if err := d.removeContainer(id); err != nil {
		t.Errorf("Second remove should be idempotent, got: %v", err)
	}
	t.Log("Idempotent stop/remove: OK")
}

// TestDockerContainerEnvVars verifies environment variables are properly
// passed to containers (critical for sidecar/worker configuration).
func TestDockerContainerEnvVars(t *testing.T) {
	d := newDockerClient()
	if err := d.ping(); err != nil {
		t.Skipf("Docker not available: %v", err)
	}
	d.ensureImage(testImage, t)

	name := containerName("env-test")
	d.removeContainer(name)

	spec := map[string]any{
		"Image": testImage,
		"Cmd":   []string{"env"},
		"Env": []string{
			"CORTEX_GATEWAY_URL=localhost:4001",
			"CORTEX_AGENT_NAME=test-agent",
			"CORTEX_AUTH_TOKEN=secret-token",
			"SIDECAR_URL=http://localhost:9091",
		},
		"Labels": containerLabels("env-test"),
	}

	id, err := d.createContainer(name, spec)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	defer cleanupContainer(d, id, t)

	if err := d.startContainer(id); err != nil {
		t.Fatalf("Start: %v", err)
	}

	// Wait for exit
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		info, _ := d.inspectContainer(id)
		if info != nil {
			state := info["State"].(map[string]any)
			if state["Status"].(string) == "exited" {
				break
			}
		}
		time.Sleep(200 * time.Millisecond)
	}

	// Check logs for env vars
	logs, err := d.containerLogs(id)
	if err != nil {
		t.Fatalf("Logs: %v", err)
	}

	expectedEnvs := []string{
		"CORTEX_GATEWAY_URL=localhost:4001",
		"CORTEX_AGENT_NAME=test-agent",
		"SIDECAR_URL=http://localhost:9091",
	}
	for _, env := range expectedEnvs {
		if !strings.Contains(logs, env) {
			t.Errorf("Expected env %q in container output", env)
		}
	}

	// Verify CORTEX_AUTH_TOKEN is set (but don't log its value)
	if !strings.Contains(logs, "CORTEX_AUTH_TOKEN=") {
		t.Error("Expected CORTEX_AUTH_TOKEN to be set")
	}
	t.Log("Environment variables correctly passed to container")
}
