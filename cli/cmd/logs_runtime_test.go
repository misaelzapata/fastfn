package cmd

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/misaelzapata/fastfn/cli/internal/process"
)

func writeExecStub(t *testing.T, dir, name, body string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatalf("write stub %s: %v", name, err)
	}
	return path
}

func TestSelectedNativeLogFiles(t *testing.T) {
	s := &process.NativeSession{LogsDir: t.TempDir()}

	orig := logsFile
	t.Cleanup(func() { logsFile = orig })

	logsFile = "all"
	files, err := selectedNativeLogFiles(s)
	if err != nil || len(files) != 3 {
		t.Fatalf("all: files=%v err=%v", files, err)
	}

	logsFile = "error"
	files, err = selectedNativeLogFiles(s)
	if err != nil || len(files) != 1 || !strings.HasSuffix(files[0], "error.log") {
		t.Fatalf("error: files=%v err=%v", files, err)
	}

	logsFile = "access"
	files, err = selectedNativeLogFiles(s)
	if err != nil || len(files) != 1 || !strings.HasSuffix(files[0], "access.log") {
		t.Fatalf("access: files=%v err=%v", files, err)
	}

	logsFile = "runtime"
	files, err = selectedNativeLogFiles(s)
	if err != nil || len(files) != 1 || !strings.HasSuffix(files[0], "runtime.log") {
		t.Fatalf("runtime: files=%v err=%v", files, err)
	}

	logsFile = "bad"
	if _, err := selectedNativeLogFiles(s); err == nil {
		t.Fatal("expected invalid --file error")
	}
}

func TestRunNativeLogs(t *testing.T) {
	origFile := logsFile
	origLines := logsLines
	origFollow := logsNoFollow
	t.Cleanup(func() {
		logsFile = origFile
		logsLines = origLines
		logsNoFollow = origFollow
	})

	if err := runNativeLogs(nil); err == nil {
		t.Fatal("expected error for nil session")
	}

	logsDir := t.TempDir()
	session := &process.NativeSession{LogsDir: logsDir}
	logsFile = "all"
	logsLines = 12
	logsNoFollow = true
	if err := runNativeLogs(session); err == nil {
		t.Fatal("expected missing log files error")
	}

	errLog := session.ErrorLogPath()
	accLog := session.AccessLogPath()
	runtimeLog := session.RuntimeLogPath()
	if err := os.WriteFile(errLog, []byte("err\n"), 0o644); err != nil {
		t.Fatalf("write error log: %v", err)
	}
	if err := os.WriteFile(accLog, []byte("acc\n"), 0o644); err != nil {
		t.Fatalf("write access log: %v", err)
	}
	if err := os.WriteFile(runtimeLog, []byte("runtime\n"), 0o644); err != nil {
		t.Fatalf("write runtime log: %v", err)
	}

	stubDir := t.TempDir()
	argsFile := filepath.Join(stubDir, "tail.args")
	writeExecStub(t, stubDir, "tail", "#!/bin/sh\nprintf '%s' \"$*\" > \"$TAIL_ARGS_FILE\"\n")
	t.Setenv("TAIL_ARGS_FILE", argsFile)
	t.Setenv("PATH", stubDir+":"+os.Getenv("PATH"))

	if err := runNativeLogs(session); err != nil {
		t.Fatalf("expected native logs to run with stub tail: %v", err)
	}
	args, err := os.ReadFile(argsFile)
	if err != nil {
		t.Fatalf("read args: %v", err)
	}
	line := string(args)
	if !strings.Contains(line, "-n 12") {
		t.Fatalf("expected -n 12 in tail args, got %q", line)
	}
	if strings.Contains(line, " -F ") {
		t.Fatalf("did not expect -F when --no-follow is set, got %q", line)
	}
}

func TestRunNativeLogs_FollowAddsTailF(t *testing.T) {
	origFile := logsFile
	origLines := logsLines
	origFollow := logsNoFollow
	t.Cleanup(func() {
		logsFile = origFile
		logsLines = origLines
		logsNoFollow = origFollow
	})

	logsDir := t.TempDir()
	session := &process.NativeSession{LogsDir: logsDir}
	logsFile = "error"
	logsLines = 7
	logsNoFollow = false

	if err := os.WriteFile(session.ErrorLogPath(), []byte("err\n"), 0o644); err != nil {
		t.Fatalf("write error log: %v", err)
	}

	stubDir := t.TempDir()
	argsFile := filepath.Join(stubDir, "tail.args")
	writeExecStub(t, stubDir, "tail", "#!/bin/sh\nprintf '%s' \"$*\" > \"$TAIL_ARGS_FILE\"\n")
	t.Setenv("TAIL_ARGS_FILE", argsFile)
	t.Setenv("PATH", stubDir+":"+os.Getenv("PATH"))

	if err := runNativeLogs(session); err != nil {
		t.Fatalf("runNativeLogs() error = %v", err)
	}
	args, err := os.ReadFile(argsFile)
	if err != nil {
		t.Fatalf("read args: %v", err)
	}
	line := string(args)
	if !strings.Contains(line, "-n 7 -F") {
		t.Fatalf("expected -F when following logs, got %q", line)
	}
}

func TestRunDockerLogs(t *testing.T) {
	composeDir := t.TempDir()
	composePath := filepath.Join(composeDir, "docker-compose.yml")
	if err := os.WriteFile(composePath, []byte("services:\n"), 0o644); err != nil {
		t.Fatalf("write compose: %v", err)
	}

	stubDir := t.TempDir()
	argsFile := filepath.Join(stubDir, "docker.args")
	writeExecStub(t, stubDir, "docker", "#!/bin/sh\nprintf '%s' \"$*\" > \"$DOCKER_ARGS_FILE\"\nexit 0\n")
	t.Setenv("DOCKER_ARGS_FILE", argsFile)
	t.Setenv("PATH", stubDir+":"+os.Getenv("PATH"))

	if err := runDockerLogs(composePath); err != nil {
		t.Fatalf("expected docker logs to succeed with stub: %v", err)
	}
	args, err := os.ReadFile(argsFile)
	if err != nil {
		t.Fatalf("read docker args: %v", err)
	}
	if !strings.Contains(string(args), "compose -f "+composePath+" logs -f") {
		t.Fatalf("unexpected docker args: %q", string(args))
	}

	writeExecStub(t, stubDir, "docker", "#!/bin/sh\nexit 1\n")
	if err := runDockerLogs(composePath); err == nil {
		t.Fatal("expected docker logs error on non-zero exit")
	}
}

func TestLogsCommandRun_BackendsAndFailures(t *testing.T) {
	origNativeMode := logsNativeMode
	origDockerMode := logsDockerMode
	origReadSession := readNativeSessionFn
	origRunNativeLogs := runNativeLogsFn
	origRunDockerLogs := runDockerLogsFn
	origChoose := chooseLogsBackendFn
	origFatal := logsFatal
	origFatalf := logsFatalf
	t.Cleanup(func() {
		logsNativeMode = origNativeMode
		logsDockerMode = origDockerMode
		readNativeSessionFn = origReadSession
		runNativeLogsFn = origRunNativeLogs
		runDockerLogsFn = origRunDockerLogs
		chooseLogsBackendFn = origChoose
		logsFatal = origFatal
		logsFatalf = origFatalf
	})

	logsFatal = func(v ...interface{}) {}
	logsFatalf = func(string, ...interface{}) {}
	logsNativeMode = false
	logsDockerMode = false

	parent := t.TempDir()
	child := filepath.Join(parent, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("mkdir child: %v", err)
	}
	composePath := filepath.Join(parent, "docker-compose.yml")
	if err := os.WriteFile(composePath, []byte("services:\n"), 0o644); err != nil {
		t.Fatalf("write compose: %v", err)
	}
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if err := os.Chdir(child); err != nil {
		t.Fatalf("chdir child: %v", err)
	}
	t.Cleanup(func() { _ = os.Chdir(wd) })

	readNativeSessionFn = func() (*process.NativeSession, error) {
		return nil, errors.New("missing")
	}

	gotCompose := ""
	runDockerLogsFn = func(path string) error {
		gotCompose = path
		return nil
	}
	runNativeLogsFn = func(*process.NativeSession) error {
		t.Fatal("native logs should not run in docker fallback path")
		return nil
	}
	chooseLogsBackendFn = chooseLogsBackend
	logsCmd.Run(logsCmd, nil)
	if gotCompose != filepath.Join("..", "docker-compose.yml") {
		t.Fatalf("expected ../docker-compose.yml path, got %q", gotCompose)
	}

	nativeCalled := false
	runNativeLogsFn = func(s *process.NativeSession) error {
		nativeCalled = s != nil
		return nil
	}
	readNativeSessionFn = func() (*process.NativeSession, error) {
		logsDir := t.TempDir()
		if err := os.WriteFile(filepath.Join(logsDir, "error.log"), []byte("ok\n"), 0o644); err != nil {
			t.Fatalf("write native error log: %v", err)
		}
		return &process.NativeSession{LogsDir: logsDir, LaunchPID: os.Getpid()}, nil
	}
	runDockerLogsFn = func(string) error {
		t.Fatal("docker logs should not run when native is active")
		return nil
	}
	logsCmd.Run(logsCmd, nil)
	if !nativeCalled {
		t.Fatal("expected native backend path to run")
	}

	fatalCalled := false
	logsFatal = func(v ...interface{}) { fatalCalled = true }
	chooseLogsBackendFn = func(bool, bool, bool, bool) (logsBackend, error) {
		return "", errors.New("choose-fail")
	}
	logsCmd.Run(logsCmd, nil)
	if !fatalCalled {
		t.Fatal("expected logsFatal call when backend selection fails")
	}

	fatalfCalled := false
	logsFatalf = func(string, ...interface{}) { fatalfCalled = true }
	logsFatal = func(v ...interface{}) {}
	chooseLogsBackendFn = func(bool, bool, bool, bool) (logsBackend, error) {
		return logsBackend("weird"), nil
	}
	logsCmd.Run(logsCmd, nil)
	if !fatalfCalled {
		t.Fatal("expected logsFatalf call for unknown backend")
	}

	// direct compose path branch + docker backend fatalf
	if err := os.Chdir(parent); err != nil {
		t.Fatalf("chdir parent: %v", err)
	}
	fatalfCalled = false
	chooseLogsBackendFn = chooseLogsBackend
	readNativeSessionFn = func() (*process.NativeSession, error) {
		return nil, errors.New("missing")
	}
	runDockerLogsFn = func(string) error { return errors.New("docker-log-fail") }
	logsFatalf = func(string, ...interface{}) { fatalfCalled = true }
	logsCmd.Run(logsCmd, nil)
	if !fatalfCalled {
		t.Fatal("expected logsFatalf for docker backend failure")
	}

	// native backend fatalf path
	if err := os.Chdir(child); err != nil {
		t.Fatalf("chdir child: %v", err)
	}
	fatalfCalled = false
	readNativeSessionFn = func() (*process.NativeSession, error) {
		logsDir := t.TempDir()
		if err := os.WriteFile(filepath.Join(logsDir, "error.log"), []byte("x\n"), 0o644); err != nil {
			t.Fatalf("write native error.log: %v", err)
		}
		return &process.NativeSession{LogsDir: logsDir, LaunchPID: os.Getpid()}, nil
	}
	chooseLogsBackendFn = chooseLogsBackend
	runNativeLogsFn = func(*process.NativeSession) error { return errors.New("native-log-fail") }
	logsFatalf = func(string, ...interface{}) { fatalfCalled = true }
	runDockerLogsFn = func(string) error { t.Fatal("docker backend should not run"); return nil }
	logsCmd.Run(logsCmd, nil)
	if !fatalfCalled {
		t.Fatal("expected logsFatalf for native backend failure")
	}
}
