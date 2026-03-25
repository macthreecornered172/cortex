package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// TestMain runs before and after all tests in the e2e package.
// It ensures cortex containers and stale BEAM processes are cleaned up
// even if a test panics (e.g. from Go's -timeout flag).
func TestMain(m *testing.M) {
	cleanupAll()
	code := m.Run()
	cleanupAll()
	os.Exit(code)
}

// cleanupAll removes orphan cortex containers, networks, and stale BEAM processes.
func cleanupAll() {
	d := newDockerClient()
	if d.ping() != nil {
		return // Docker not available, skip cleanup
	}

	// Remove cortex-managed containers
	containers, err := d.listContainers("cortex.managed=true")
	if err == nil {
		for _, c := range containers {
			if id, ok := c["Id"].(string); ok {
				_ = d.stopContainer(id)
				_ = d.removeContainer(id)
			}
		}
		if len(containers) > 0 {
			fmt.Fprintf(os.Stderr, "TestMain: cleaned up %d orphan containers\n", len(containers))
		}
	}

	// Remove cortex-* networks (not cortex-net from compose)
	resp, err := d.do("GET", "/networks", nil)
	if err == nil {
		defer resp.Body.Close()
		var networks []map[string]any
		if decodeErr := json.NewDecoder(resp.Body).Decode(&networks); decodeErr == nil {
			for _, net := range networks {
				name, _ := net["Name"].(string)
				id, _ := net["Id"].(string)
				if strings.HasPrefix(name, "cortex-") && name != "cortex-net" {
					_ = d.removeNetwork(id)
				}
			}
		}
	}

	// Kill stale Cortex BEAM processes (started via mix phx.server)
	_ = exec.Command("pkill", "-f", "beam.*phx.server").Run()

	// Wait for ports to be released after process kill
	for i := 0; i < 10; i++ {
		out, _ := exec.Command("lsof", "-ti:4001").Output()
		if len(strings.TrimSpace(string(out))) == 0 {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
}
