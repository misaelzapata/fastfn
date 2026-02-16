package process

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWriteReadNativeSession(t *testing.T) {
	sessionPath := filepath.Join(t.TempDir(), "native-session.json")
	t.Setenv("FASTFN_NATIVE_SESSION_FILE", sessionPath)

	runtimeDir := filepath.Join(t.TempDir(), "runtime")
	logsDir := filepath.Join(runtimeDir, "openresty", "logs")
	if err := os.MkdirAll(logsDir, 0o755); err != nil {
		t.Fatalf("failed to create logs dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(logsDir, "error.log"), []byte(""), 0o644); err != nil {
		t.Fatalf("failed to create error.log: %v", err)
	}

	if err := WriteNativeSession(NativeSession{
		RuntimeDir: runtimeDir,
		LaunchPID:  os.Getpid(),
	}); err != nil {
		t.Fatalf("WriteNativeSession() error = %v", err)
	}

	got, err := ReadNativeSession()
	if err != nil {
		t.Fatalf("ReadNativeSession() error = %v", err)
	}
	if got.RuntimeDir != runtimeDir {
		t.Fatalf("runtime dir mismatch: want=%q got=%q", runtimeDir, got.RuntimeDir)
	}
	if got.LogsDir != logsDir {
		t.Fatalf("logs dir mismatch: want=%q got=%q", logsDir, got.LogsDir)
	}
	if got.LaunchPID != os.Getpid() {
		t.Fatalf("pid mismatch: want=%d got=%d", os.Getpid(), got.LaunchPID)
	}
	if got.StartedAt == "" {
		t.Fatalf("expected StartedAt to be set")
	}
	if !got.IsActive() {
		t.Fatalf("expected session to be active")
	}
}

func TestClearNativeSessionForPID(t *testing.T) {
	sessionPath := filepath.Join(t.TempDir(), "native-session.json")
	t.Setenv("FASTFN_NATIVE_SESSION_FILE", sessionPath)

	if err := WriteNativeSession(NativeSession{
		RuntimeDir: t.TempDir(),
		LaunchPID:  424242,
	}); err != nil {
		t.Fatalf("WriteNativeSession() error = %v", err)
	}

	if err := ClearNativeSessionForPID(111111); err != nil {
		t.Fatalf("ClearNativeSessionForPID(non-owner) error = %v", err)
	}
	if _, err := os.Stat(sessionPath); err != nil {
		t.Fatalf("session should remain for non-owner pid: %v", err)
	}

	if err := ClearNativeSessionForPID(424242); err != nil {
		t.Fatalf("ClearNativeSessionForPID(owner) error = %v", err)
	}
	if _, err := os.Stat(sessionPath); !os.IsNotExist(err) {
		t.Fatalf("expected session file removed, stat err=%v", err)
	}
}

func TestReadNativeSessionMissing(t *testing.T) {
	t.Setenv("FASTFN_NATIVE_SESSION_FILE", filepath.Join(t.TempDir(), "missing.json"))

	_, err := ReadNativeSession()
	if err == nil {
		t.Fatalf("expected missing session error")
	}
	if !os.IsNotExist(err) {
		t.Fatalf("expected not-exist error, got %v", err)
	}
}

func TestNativeSessionIsActiveFalseWithoutRunningPID(t *testing.T) {
	logsDir := filepath.Join(t.TempDir(), "logs")
	if err := os.MkdirAll(logsDir, 0o755); err != nil {
		t.Fatalf("failed to create logs dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(logsDir, "access.log"), []byte(""), 0o644); err != nil {
		t.Fatalf("failed to create access.log: %v", err)
	}

	s := &NativeSession{
		LogsDir:   logsDir,
		LaunchPID: -1,
	}
	if s.IsActive() {
		t.Fatalf("expected inactive session when pid is invalid")
	}
}
