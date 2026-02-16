package process

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeExecutable(t *testing.T, dir, name, content string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0o755); err != nil {
		t.Fatalf("write executable %s: %v", name, err)
	}
	return path
}

func TestCheckDocker_BinaryMissing(t *testing.T) {
	t.Setenv("PATH", t.TempDir())

	err := CheckDocker()
	if err == nil {
		t.Fatalf("expected error when docker binary is missing")
	}
	if !strings.Contains(err.Error(), "Docker is not installed") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestCheckDocker_DaemonNotRunning(t *testing.T) {
	binDir := t.TempDir()
	writeExecutable(t, binDir, "docker", "#!/bin/sh\nif [ \"$1\" = \"info\" ]; then exit 1; fi\nexit 0\n")
	t.Setenv("PATH", binDir)

	err := CheckDocker()
	if err == nil {
		t.Fatalf("expected error when docker daemon is down")
	}
	if !strings.Contains(err.Error(), "Docker daemon is not running") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestCheckDocker_OK(t *testing.T) {
	binDir := t.TempDir()
	writeExecutable(t, binDir, "docker", "#!/bin/sh\nif [ \"$1\" = \"info\" ]; then exit 0; fi\nexit 0\n")
	t.Setenv("PATH", binDir)

	if err := CheckDocker(); err != nil {
		t.Fatalf("expected CheckDocker success, got %v", err)
	}
}

func TestCheckDependencies_MissingRequiredOpenResty(t *testing.T) {
	t.Setenv("PATH", t.TempDir())

	err := CheckDependencies()
	if err == nil {
		t.Fatalf("expected error when openresty is missing")
	}
	if !strings.Contains(err.Error(), "OpenResty") {
		t.Fatalf("expected OpenResty in error, got %v", err)
	}
}

func TestCheckDependencies_OnlyRequiredPresent(t *testing.T) {
	binDir := t.TempDir()
	writeExecutable(t, binDir, "openresty", "#!/bin/sh\nexit 0\n")
	t.Setenv("PATH", binDir)

	if err := CheckDependencies(); err != nil {
		t.Fatalf("expected success with required dependency present, got %v", err)
	}
}
