package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestScanForMounts(t *testing.T) {
	// 1. Create a temporary directory structure
	tmpDir, err := os.MkdirTemp("", "fastfn-test-*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	// 2. Setup mock functions
	// Structure:
	// tmpDir/
	//   ├── node-func/ (Node.js)
	//   └── py-func/   (Python)

	// Node function
	nodeDir := filepath.Join(tmpDir, "node-func")
	os.Mkdir(nodeDir, 0755)
	os.WriteFile(filepath.Join(nodeDir, "fn.config.json"), []byte(`{"runtime": "node", "name": "node-func"}`), 0644)

	// Python function
	pyDir := filepath.Join(tmpDir, "py-func")
	os.Mkdir(pyDir, 0755)
	os.WriteFile(filepath.Join(pyDir, "fn.config.json"), []byte(`{"runtime": "python", "name": "py-func"}`), 0644)

	// 3. Run scanForMounts
	mounts := scanForMounts(tmpDir)

	// 4. Assertions
	if len(mounts) != 2 {
		t.Errorf("Expected 2 mounts, got %d", len(mounts))
	}

	// Helper to check if a specific mount exists
	hasMount := func(expectedPathFragment, expectedRuntime string) bool {
		for _, m := range mounts {
			parts := strings.Split(m, ":")
			if len(parts) != 2 {
				continue
			}
			hostPath := parts[0]
			containerPath := parts[1]

			// Check host path ends correctly
			if !strings.HasSuffix(hostPath, expectedPathFragment) {
				continue
			}
			// Check container path has correct runtime structure
			// e.g. /app/srv/fn/functions/node/node-func
			if strings.Contains(containerPath, "/functions/"+expectedRuntime+"/") {
				return true
			}
		}
		return false
	}

	if !hasMount("node-func", "node") {
		t.Error("Missing or incorrect mount for node-func")
	}

	if !hasMount("py-func", "python") {
		t.Error("Missing or incorrect mount for py-func")
	}
}

func TestScanForMounts_SingleFunctionRoot(t *testing.T) {
	// Test when running 'fastfn dev .' inside the function directory itself
	tmpDir, err := os.MkdirTemp("", "fastfn-test-single-*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	os.WriteFile(filepath.Join(tmpDir, "fn.config.json"), []byte(`{"runtime": "python", "name": "my-script"}`), 0644)

	mounts := scanForMounts(tmpDir)

	if len(mounts) != 1 {
		t.Fatalf("Expected 1 mount, got %d", len(mounts))
	}

	parts := strings.Split(mounts[0], ":")
	if !strings.Contains(parts[1], "/functions/python/my-script") {
		t.Errorf("Incorrect single-function mount: %s", mounts[0])
	}
}
