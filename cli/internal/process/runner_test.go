package process

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestSelectNativeRuntimes_DefaultSkipsUnavailableSilently(t *testing.T) {
	selected, warnings, err := selectNativeRuntimes("", map[string]bool{
		"python": true,
		"node":   true,
		"php":    false,
		"cargo":  false,
		"go":     false,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("expected no warnings for default mode, got %v", warnings)
	}
	if !reflect.DeepEqual(selected, []string{"python", "node", "lua"}) {
		t.Fatalf("unexpected runtimes: %v", selected)
	}
}

func TestSelectNativeRuntimes_DefaultKeepsLuaWithoutExternalBinaries(t *testing.T) {
	selected, warnings, err := selectNativeRuntimes("", map[string]bool{
		"python": false,
		"node":   false,
		"php":    false,
		"cargo":  false,
		"go":     false,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("expected no warnings for default mode, got %v", warnings)
	}
	if !reflect.DeepEqual(selected, []string{"lua"}) {
		t.Fatalf("unexpected runtimes: %v", selected)
	}
}

func TestSelectNativeRuntimes_ExplicitIgnoresUnknownAndUnavailableWithWarnings(t *testing.T) {
	selected, warnings, err := selectNativeRuntimes("node,unknown,go,python", map[string]bool{
		"python": true,
		"node":   true,
		"php":    false,
		"cargo":  false,
		"go":     false,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !reflect.DeepEqual(selected, []string{"node", "python"}) {
		t.Fatalf("unexpected runtimes: %v", selected)
	}
	if len(warnings) != 2 {
		t.Fatalf("expected 2 warnings, got %d (%v)", len(warnings), warnings)
	}
	if !strings.Contains(strings.Join(warnings, "\n"), "unknown") {
		t.Fatalf("expected unknown runtime warning, got %v", warnings)
	}
	if !strings.Contains(strings.Join(warnings, "\n"), "missing: go") {
		t.Fatalf("expected missing go warning, got %v", warnings)
	}
}

func TestSelectNativeRuntimes_ExplicitTrimsAndDedupes(t *testing.T) {
	selected, warnings, err := selectNativeRuntimes(" python ,node,node , python ", map[string]bool{
		"python": true,
		"node":   true,
		"php":    true,
		"cargo":  false,
		"go":     false,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("expected no warnings, got %v", warnings)
	}
	if !reflect.DeepEqual(selected, []string{"python", "node"}) {
		t.Fatalf("unexpected runtimes: %v", selected)
	}
}

func TestSelectNativeRuntimes_ExplicitExperimentalWhenAvailable(t *testing.T) {
	selected, warnings, err := selectNativeRuntimes("rust,go", map[string]bool{
		"python": true,
		"node":   false,
		"php":    false,
		"cargo":  true,
		"go":     true,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("expected no warnings, got %v", warnings)
	}
	if !reflect.DeepEqual(selected, []string{"rust", "go"}) {
		t.Fatalf("unexpected runtimes: %v", selected)
	}
}

func TestSelectNativeRuntimes_ExplicitOnlyUnavailableReturnsError(t *testing.T) {
	_, warnings, err := selectNativeRuntimes("go,rust", map[string]bool{
		"python": true,
		"node":   false,
		"php":    false,
		"cargo":  false,
		"go":     false,
	})
	if err == nil {
		t.Fatalf("expected error when explicit runtimes are unavailable")
	}
	if len(warnings) != 2 {
		t.Fatalf("expected 2 warnings, got %d (%v)", len(warnings), warnings)
	}
	if !strings.Contains(err.Error(), "no compatible runtimes enabled") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestSelectNativeRuntimes_ExplicitEmptyCSVFallsBackToDefault(t *testing.T) {
	selected, warnings, err := selectNativeRuntimes(", ,", map[string]bool{
		"python": false,
		"node":   true,
		"php":    false,
		"cargo":  false,
		"go":     false,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("expected no warnings, got %v", warnings)
	}
	if !reflect.DeepEqual(selected, []string{"node", "lua"}) {
		t.Fatalf("unexpected runtimes: %v", selected)
	}
}

func TestEnsurePortAvailable_DetectsConflict(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen failed: %v", err)
	}
	defer ln.Close()

	addr := ln.Addr().String()
	parts := strings.Split(addr, ":")
	if len(parts) < 2 {
		t.Fatalf("unexpected listener address: %s", addr)
	}
	port := parts[len(parts)-1]

	if err := ensurePortAvailable(port); err == nil {
		t.Fatalf("expected port conflict error for port %s", port)
	}
}

func TestEnsurePortAvailable_AcceptsFreePort(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen failed: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()

	if err := ensurePortAvailable(strconv.Itoa(port)); err != nil {
		t.Fatalf("expected free port %d, got error: %v", port, err)
	}
}

func TestEnsureSocketPathAvailable_AllowsMissingPath(t *testing.T) {
	socketPath := filepath.Join(t.TempDir(), "missing.sock")
	if err := ensureSocketPathAvailable(socketPath); err != nil {
		t.Fatalf("expected missing socket path to pass preflight, got: %v", err)
	}
}

func TestEnsureSocketPathAvailable_DetectsActiveSocket(t *testing.T) {
	tmpDir, err := os.MkdirTemp("/tmp", "fastfn-sock-")
	if err != nil {
		t.Fatalf("failed to create short temp dir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(tmpDir) })
	socketPath := filepath.Join(tmpDir, fmt.Sprintf("active-%d.sock", time.Now().UnixNano()))
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("failed to listen on unix socket: %v", err)
	}
	defer ln.Close()

	if err := ensureSocketPathAvailable(socketPath); err == nil {
		t.Fatalf("expected active socket preflight error for %s", socketPath)
	}
}

func TestEnsureSocketPathAvailable_RemovesStaleSocket(t *testing.T) {
	tmpDir, err := os.MkdirTemp("/tmp", "fastfn-sock-")
	if err != nil {
		t.Fatalf("failed to create short temp dir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(tmpDir) })
	socketPath := filepath.Join(tmpDir, fmt.Sprintf("stale-%d.sock", time.Now().UnixNano()))
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("failed to listen on unix socket: %v", err)
	}
	_ = ln.Close()

	if err := ensureSocketPathAvailable(socketPath); err != nil {
		t.Fatalf("expected stale socket cleanup, got: %v", err)
	}
	if _, err := os.Stat(socketPath); !os.IsNotExist(err) {
		t.Fatalf("expected stale socket to be removed, stat err=%v", err)
	}
}

func TestEnsureSocketPathAvailable_RejectsNonSocketPath(t *testing.T) {
	p := filepath.Join(t.TempDir(), "not-a-socket")
	if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
		t.Fatalf("failed to create placeholder file: %v", err)
	}
	if err := ensureSocketPathAvailable(p); err == nil {
		t.Fatalf("expected error when preflight path is not a unix socket")
	}
}
