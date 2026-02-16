package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/viper"
)

func TestResolveDevTargetDir_DefaultCurrentDirectory(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()

	got := resolveDevTargetDir(nil)
	if got != "." {
		t.Fatalf("resolveDevTargetDir(nil) = %q, want %q", got, ".")
	}
}

func TestResolveDevTargetDir_UsesConfigWhenNoArgs(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	viper.Set("functions-dir", "examples/functions/next-style")

	got := resolveDevTargetDir(nil)
	if got != "examples/functions/next-style" {
		t.Fatalf("resolveDevTargetDir(nil) = %q, want configured path", got)
	}
}

func TestResolveDevTargetDir_ArgWinsOverConfig(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	viper.Set("functions-dir", "examples/functions/next-style")

	got := resolveDevTargetDir([]string{"custom/path"})
	if got != "custom/path" {
		t.Fatalf("resolveDevTargetDir(arg) = %q, want arg path", got)
	}
}

func TestScanForMounts_FileRoutesMountProjectRoot(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "fastfn-test-file-routes-*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	// Next-style file route: GET /users
	if err := os.WriteFile(filepath.Join(tmpDir, "get.users.js"), []byte("module.exports = { handler: async () => ({ status: 200, body: '{}' }) };"), 0644); err != nil {
		t.Fatalf("write route file failed: %v", err)
	}

	mounts := scanForMounts(tmpDir)
	if len(mounts) != 1 {
		t.Fatalf("Expected 1 mount, got %d: %v", len(mounts), mounts)
	}

	parts := strings.Split(mounts[0], ":")
	if len(parts) != 2 {
		t.Fatalf("invalid mount format: %s", mounts[0])
	}
	if parts[0] != tmpDir {
		t.Fatalf("unexpected host mount path: got=%s want=%s", parts[0], tmpDir)
	}
	if parts[1] != "/app/srv/fn/functions" {
		t.Fatalf("unexpected container mount path: got=%s", parts[1])
	}
}

func TestScanForMounts_FnConfigSubdirMountsRuntimeFunctionPath(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "fastfn-test-fnconfig-subdir-*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	fnDir := filepath.Join(tmpDir, "hello-fn")
	if err := os.MkdirAll(fnDir, 0755); err != nil {
		t.Fatalf("mkdir failed: %v", err)
	}
	if err := os.WriteFile(filepath.Join(fnDir, "fn.config.json"), []byte(`{"runtime":"node","name":"hello-fn"}`), 0644); err != nil {
		t.Fatalf("write fn.config.json failed: %v", err)
	}
	if err := os.WriteFile(filepath.Join(fnDir, "handler.js"), []byte("exports.handler = async () => ({ status: 200, body: '{}' });"), 0644); err != nil {
		t.Fatalf("write handler failed: %v", err)
	}

	mounts := scanForMounts(tmpDir)
	if len(mounts) != 1 {
		t.Fatalf("Expected 1 mount, got %d: %v", len(mounts), mounts)
	}
	if !strings.HasPrefix(mounts[0], fnDir+":") {
		t.Fatalf("expected host path to be function dir, got %s", mounts[0])
	}
	if !strings.HasSuffix(mounts[0], "/app/srv/fn/functions/node/hello-fn") {
		t.Fatalf("expected node/hello-fn mount target, got %s", mounts[0])
	}
}

func TestScanForMounts_InvalidDirectoryReturnsNil(t *testing.T) {
	mounts := scanForMounts(filepath.Join(os.TempDir(), "fastfn-missing-dir"))
	if mounts != nil {
		t.Fatalf("expected nil mounts for missing directory, got: %v", mounts)
	}
}

func TestScanForMounts_HybridProjectIncludesRootAndFnConfigMounts(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "fastfn-test-hybrid-*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	// File-based route (non-config)
	if err := os.WriteFile(filepath.Join(tmpDir, "get.users.js"), []byte("module.exports = { handler: async () => ({ status: 200, body: '{}' }) };"), 0644); err != nil {
		t.Fatalf("write route file failed: %v", err)
	}

	// fn.config function (config-based)
	fnDir := filepath.Join(tmpDir, "hello-fn")
	if err := os.MkdirAll(fnDir, 0755); err != nil {
		t.Fatalf("mkdir failed: %v", err)
	}
	if err := os.WriteFile(filepath.Join(fnDir, "fn.config.json"), []byte(`{"runtime":"node","name":"hello-fn"}`), 0644); err != nil {
		t.Fatalf("write fn.config.json failed: %v", err)
	}
	if err := os.WriteFile(filepath.Join(fnDir, "handler.js"), []byte("exports.handler = async () => ({ status: 200, body: '{}' });"), 0644); err != nil {
		t.Fatalf("write handler failed: %v", err)
	}

	mounts := scanForMounts(tmpDir)
	if len(mounts) != 2 {
		t.Fatalf("Expected 2 mounts (root + config), got %d: %v", len(mounts), mounts)
	}

	rootExpected := tmpDir + ":/app/srv/fn/functions"
	configExpected := fnDir + ":/app/srv/fn/functions/node/hello-fn"
	joined := strings.Join(mounts, "\n")
	if !strings.Contains(joined, rootExpected) {
		t.Fatalf("missing root mount: %s\nall mounts:\n%s", rootExpected, joined)
	}
	if !strings.Contains(joined, configExpected) {
		t.Fatalf("missing config mount: %s\nall mounts:\n%s", configExpected, joined)
	}
}
