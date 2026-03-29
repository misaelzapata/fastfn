package process

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

const nativeSessionFileName = "fastfn-native-session.json"

var (
	sessionMkdirAllFn = os.MkdirAll
	sessionWriteFileFn = os.WriteFile
	sessionRenameFn = os.Rename
	sessionReadFileFn = os.ReadFile
	sessionRemoveFn = os.Remove
	sessionKillFn = syscall.Kill
)

// NativeSession describes the active native `fastfn dev --native` process.
type NativeSession struct {
	RuntimeDir string `json:"runtime_dir"`
	LogsDir    string `json:"logs_dir"`
	LaunchPID  int    `json:"launch_pid"`
	StartedAt  string `json:"started_at"`
}

// NativeSessionPath returns where native-session metadata is persisted.
func NativeSessionPath() string {
	if custom := os.Getenv("FASTFN_NATIVE_SESSION_FILE"); custom != "" {
		return custom
	}
	return filepath.Join(os.TempDir(), nativeSessionFileName)
}

func (s *NativeSession) normalize() {
	if s == nil {
		return
	}
	if s.LogsDir == "" && s.RuntimeDir != "" {
		s.LogsDir = filepath.Join(s.RuntimeDir, "openresty", "logs")
	}
}

// ErrorLogPath returns the expected OpenResty error log path for this session.
func (s *NativeSession) ErrorLogPath() string {
	if s == nil {
		return ""
	}
	return filepath.Join(s.LogsDir, "error.log")
}

// AccessLogPath returns the expected OpenResty access log path for this session.
func (s *NativeSession) AccessLogPath() string {
	if s == nil {
		return ""
	}
	return filepath.Join(s.LogsDir, "access.log")
}

// RuntimeLogPath returns the persisted handler/runtime debug log path for this session.
func (s *NativeSession) RuntimeLogPath() string {
	if s == nil {
		return ""
	}
	return filepath.Join(s.LogsDir, "runtime.log")
}

// IsActive reports whether this session appears alive and readable.
func (s *NativeSession) IsActive() bool {
	if s == nil {
		return false
	}
	s.normalize()
	if s.LaunchPID <= 0 || !IsPIDRunning(s.LaunchPID) {
		return false
	}
	if s.LogsDir == "" {
		return false
	}
	if _, err := os.Stat(s.LogsDir); err != nil {
		return false
	}
	if _, err := os.Stat(s.ErrorLogPath()); err == nil {
		return true
	}
	if _, err := os.Stat(s.AccessLogPath()); err == nil {
		return true
	}
	if _, err := os.Stat(s.RuntimeLogPath()); err == nil {
		return true
	}
	return false
}

// WriteNativeSession stores native-session metadata atomically.
func WriteNativeSession(session NativeSession) error {
	session.normalize()
	if session.LaunchPID <= 0 {
		session.LaunchPID = os.Getpid()
	}
	if session.StartedAt == "" {
		session.StartedAt = time.Now().UTC().Format(time.RFC3339)
	}

	path := NativeSessionPath()
	if err := sessionMkdirAllFn(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("failed to create native session dir: %w", err)
	}

	payload, _ := json.MarshalIndent(session, "", "  ")

	tmpPath := path + ".tmp"
	if err := sessionWriteFileFn(tmpPath, payload, 0o600); err != nil {
		return fmt.Errorf("failed to write native session temp file: %w", err)
	}
	if err := sessionRenameFn(tmpPath, path); err != nil {
		return fmt.Errorf("failed to persist native session: %w", err)
	}
	return nil
}

// ReadNativeSession loads native-session metadata.
func ReadNativeSession() (*NativeSession, error) {
	payload, err := sessionReadFileFn(NativeSessionPath())
	if err != nil {
		return nil, err
	}
	var s NativeSession
	if err := json.Unmarshal(payload, &s); err != nil {
		return nil, fmt.Errorf("failed to parse native session metadata: %w", err)
	}
	s.normalize()
	return &s, nil
}

// ClearNativeSessionForPID removes session metadata if it belongs to pid.
func ClearNativeSessionForPID(pid int) error {
	path := NativeSessionPath()
	current, err := ReadNativeSession()
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if current.LaunchPID != pid {
		return nil
	}
	if err := sessionRemoveFn(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// IsPIDRunning checks whether a process is alive without signaling it.
func IsPIDRunning(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := sessionKillFn(pid, 0)
	if err == nil {
		return true
	}
	return errors.Is(err, syscall.EPERM)
}
