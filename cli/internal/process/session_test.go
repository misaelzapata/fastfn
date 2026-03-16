package process

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
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

func TestNativeSessionPathAndLogHelpers(t *testing.T) {
	customPath := filepath.Join(t.TempDir(), "custom-session.json")
	t.Setenv("FASTFN_NATIVE_SESSION_FILE", customPath)

	if got := NativeSessionPath(); got != customPath {
		t.Fatalf("NativeSessionPath() = %q, want %q", got, customPath)
	}

	var nilSession *NativeSession
	if nilSession.ErrorLogPath() != "" || nilSession.AccessLogPath() != "" || nilSession.RuntimeLogPath() != "" {
		t.Fatalf("expected nil session log helpers to return empty paths")
	}

	s := &NativeSession{LogsDir: "/tmp/runtime/logs"}
	if got := s.ErrorLogPath(); got != "/tmp/runtime/logs/error.log" {
		t.Fatalf("ErrorLogPath() = %q", got)
	}
	if got := s.AccessLogPath(); got != "/tmp/runtime/logs/access.log" {
		t.Fatalf("AccessLogPath() = %q", got)
	}
	if got := s.RuntimeLogPath(); got != "/tmp/runtime/logs/runtime.log" {
		t.Fatalf("RuntimeLogPath() = %q", got)
	}
}

func TestNativeSessionIsActiveWithAccessAndRuntimeLogs(t *testing.T) {
	for _, logName := range []string{"access.log", "runtime.log"} {
		t.Run(logName, func(t *testing.T) {
			logsDir := filepath.Join(t.TempDir(), "logs")
			if err := os.MkdirAll(logsDir, 0o755); err != nil {
				t.Fatalf("failed to create logs dir: %v", err)
			}
			if err := os.WriteFile(filepath.Join(logsDir, logName), []byte("ok"), 0o644); err != nil {
				t.Fatalf("failed to create %s: %v", logName, err)
			}

			s := &NativeSession{
				LogsDir:   logsDir,
				LaunchPID: os.Getpid(),
			}
			if !s.IsActive() {
				t.Fatalf("expected session to be active when %s exists", logName)
			}
		})
	}
}

func TestWriteNativeSession_ErrorPaths(t *testing.T) {
	sessionPath := filepath.Join(t.TempDir(), "native-session.json")
	t.Setenv("FASTFN_NATIVE_SESSION_FILE", sessionPath)

	origMkdirAll := sessionMkdirAllFn
	origWriteFile := sessionWriteFileFn
	origRename := sessionRenameFn
	t.Cleanup(func() {
		sessionMkdirAllFn = origMkdirAll
		sessionWriteFileFn = origWriteFile
		sessionRenameFn = origRename
	})

	sessionMkdirAllFn = func(string, os.FileMode) error {
		return errors.New("mkdir boom")
	}
	if err := WriteNativeSession(NativeSession{}); err == nil || !strings.Contains(err.Error(), "failed to create native session dir") {
		t.Fatalf("expected mkdir failure, got %v", err)
	}

	sessionMkdirAllFn = origMkdirAll
	sessionWriteFileFn = func(string, []byte, os.FileMode) error {
		return errors.New("write boom")
	}
	if err := WriteNativeSession(NativeSession{}); err == nil || !strings.Contains(err.Error(), "failed to write native session temp file") {
		t.Fatalf("expected write failure, got %v", err)
	}

	sessionWriteFileFn = origWriteFile
	sessionRenameFn = func(string, string) error {
		return errors.New("rename boom")
	}
	if err := WriteNativeSession(NativeSession{}); err == nil || !strings.Contains(err.Error(), "failed to persist native session") {
		t.Fatalf("expected rename failure, got %v", err)
	}
}

func TestReadNativeSession_InvalidJSON(t *testing.T) {
	origReadFile := sessionReadFileFn
	t.Cleanup(func() {
		sessionReadFileFn = origReadFile
	})

	sessionReadFileFn = func(string) ([]byte, error) {
		return []byte("{"), nil
	}

	if _, err := ReadNativeSession(); err == nil || !strings.Contains(err.Error(), "failed to parse native session metadata") {
		t.Fatalf("expected parse failure, got %v", err)
	}
}

func TestClearNativeSessionForPID_IgnoresMissingSession(t *testing.T) {
	t.Setenv("FASTFN_NATIVE_SESSION_FILE", filepath.Join(t.TempDir(), "missing.json"))

	if err := ClearNativeSessionForPID(os.Getpid()); err != nil {
		t.Fatalf("expected missing session to be ignored, got %v", err)
	}
}

func TestClearNativeSessionForPID_RemoveError(t *testing.T) {
	origReadFile := sessionReadFileFn
	origRemove := sessionRemoveFn
	t.Cleanup(func() {
		sessionReadFileFn = origReadFile
		sessionRemoveFn = origRemove
	})

	sessionReadFileFn = func(string) ([]byte, error) {
		return []byte(`{"launch_pid":123,"logs_dir":"/tmp/logs"}`), nil
	}
	sessionRemoveFn = func(string) error {
		return errors.New("remove boom")
	}

	if err := ClearNativeSessionForPID(123); err == nil || !strings.Contains(err.Error(), "remove boom") {
		t.Fatalf("expected remove failure, got %v", err)
	}
}

func TestIsPIDRunning_SpecialCases(t *testing.T) {
	origKill := sessionKillFn
	t.Cleanup(func() {
		sessionKillFn = origKill
	})

	if IsPIDRunning(0) {
		t.Fatalf("expected pid 0 to be treated as not running")
	}

	sessionKillFn = func(int, syscall.Signal) error {
		return nil
	}
	if !IsPIDRunning(123) {
		t.Fatalf("expected nil kill error to report running")
	}

	sessionKillFn = func(int, syscall.Signal) error {
		return syscall.EPERM
	}
	if !IsPIDRunning(123) {
		t.Fatalf("expected EPERM to report running")
	}

	sessionKillFn = func(int, syscall.Signal) error {
		return syscall.ESRCH
	}
	if IsPIDRunning(123) {
		t.Fatalf("expected ESRCH to report not running")
	}
}
