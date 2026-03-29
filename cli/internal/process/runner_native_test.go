package process

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

type fakeNativeManager struct {
	services      []string
	envByName     map[string][]string
	commandByName map[string]string
	startErr      error
	done          chan struct{}
	stopped       bool
	addedCount    int
}

func newFakeNativeManager() *fakeNativeManager {
	return &fakeNativeManager{
		envByName:     map[string][]string{},
		commandByName: map[string]string{},
		done:          make(chan struct{}),
	}
}

func (m *fakeNativeManager) AddServiceWithOptions(name, command string, _ []string, env []string, _ string, _ ServiceOptions) {
	m.services = append(m.services, name)
	m.envByName[name] = append([]string{}, env...)
	m.commandByName[name] = command
	m.addedCount++
}

func (m *fakeNativeManager) StartAll() error {
	return m.startErr
}

func (m *fakeNativeManager) StopAll() {
	m.stopped = true
}

func (m *fakeNativeManager) Done() <-chan struct{} {
	return m.done
}

func reserveFreePort(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("failed to reserve free port: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()
	return strconv.Itoa(port)
}

func prepareRuntimeDir(t *testing.T) (string, string) {
	t.Helper()
	runtimeDir := t.TempDir()
	openrestyDir := filepath.Join(runtimeDir, "openresty")
	runtimesDir := filepath.Join(runtimeDir, "srv", "fn", "runtimes")
	if err := os.MkdirAll(openrestyDir, 0o755); err != nil {
		t.Fatalf("mkdir openresty: %v", err)
	}
	if err := os.MkdirAll(runtimesDir, 0o755); err != nil {
		t.Fatalf("mkdir runtimes: %v", err)
	}
	nginxConf := filepath.Join(openrestyDir, "nginx.conf")
	if err := os.WriteFile(nginxConf, []byte("events {}\nhttp {}\n"), 0o644); err != nil {
		t.Fatalf("write nginx.conf: %v", err)
	}
	return runtimeDir, nginxConf
}

func patchRunnerDeps(t *testing.T) {
	t.Helper()
	t.Setenv("FN_SOCKET_BASE_DIR", t.TempDir())

	origCheck := checkDependenciesFn
	origExtract := runtimeExtractFn
	origGenerate := generateNativeConfigFn
	origMkdir := mkdirAllFn
	origChmod := chmodFn
	origRemoveAll := removeAllFn
	origSocketStat := socketStatFn
	origSocketDial := socketDialTimeoutFn
	origSocketRemove := socketRemoveFn
	origLook := lookPathFn
	origWatcher := startHotReloadWatcherFn
	origEnsurePort := ensurePortAvailableFn
	origEnsureSocket := ensureSocketPathAvailFn
	origWriteSession := writeNativeSessionFn
	origClearSession := clearNativeSessionForPID
	origNotify := notifySignalFn
	origRuntimeSocketURIs := runtimeSocketURIsFn
	origNativeSocketFallbackRoot := nativeSocketFallbackRootFn
	origNewManager := newNativeManagerFn
	origAwait := awaitNativeStopFn
	origBinaryOutput := binaryOutputFn

	t.Cleanup(func() {
		checkDependenciesFn = origCheck
		runtimeExtractFn = origExtract
		generateNativeConfigFn = origGenerate
		mkdirAllFn = origMkdir
		chmodFn = origChmod
		removeAllFn = origRemoveAll
		socketStatFn = origSocketStat
		socketDialTimeoutFn = origSocketDial
		socketRemoveFn = origSocketRemove
		lookPathFn = origLook
		startHotReloadWatcherFn = origWatcher
		ensurePortAvailableFn = origEnsurePort
		ensureSocketPathAvailFn = origEnsureSocket
		writeNativeSessionFn = origWriteSession
		clearNativeSessionForPID = origClearSession
		notifySignalFn = origNotify
		runtimeSocketURIsFn = origRuntimeSocketURIs
		nativeSocketFallbackRootFn = origNativeSocketFallbackRoot
		newNativeManagerFn = origNewManager
		awaitNativeStopFn = origAwait
		binaryOutputFn = origBinaryOutput
	})

	binaryOutputFn = func(command string, _ ...string) (string, error) {
		switch {
		case strings.Contains(command, "python"):
			return "3.11.7", nil
		case strings.Contains(command, "node"):
			return "v18.19.0", nil
		case strings.Contains(command, "php"):
			return "8.3.2", nil
		case strings.Contains(command, "go"):
			return "go version go1.22.1 darwin/arm64", nil
		default:
			return "ok", nil
		}
	}
}

func TestRunNative_LuaOnlyHappyPath(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	functionsDir := t.TempDir()
	hostPort := reserveFreePort(t)
	t.Setenv("FN_HOST_PORT", hostPort)
	t.Setenv("FN_RUNTIMES", "")
	t.Setenv("FN_FORCE_URL", "1")

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(_ string, _ string) (string, error) { return nginxConf, nil }
	lookPathFn = func(string) (string, error) { return "", errors.New("missing") }
	startHotReloadWatcherFn = func(string, string, func(string, ...interface{})) (*HotReloadWatcher, error) {
		t.Fatal("watcher should not be started when cfg.Watch=false")
		return nil, nil
	}

	var wroteSession NativeSession
	writeNativeSessionFn = func(s NativeSession) error {
		wroteSession = s
		return nil
	}
	cleared := false
	clearNativeSessionForPID = func(int) error {
		cleared = true
		return nil
	}
	removed := ""
	removeAllFn = func(path string) error {
		removed = path
		return nil
	}

	mgr := newFakeNativeManager()
	newNativeManagerFn = func() nativeServiceManager { return mgr }
	awaitCalled := false
	awaitNativeStopFn = func(pm nativeServiceManager) error {
		awaitCalled = true
		if pm != mgr {
			t.Fatalf("await received unexpected manager")
		}
		return nil
	}

	err := RunNative(RunConfig{
		FnDir:     functionsDir,
		HotReload: false,
		VerifyTLS: true,
		Watch:     false,
	})
	if err != nil {
		t.Fatalf("RunNative() error = %v", err)
	}
	if !awaitCalled {
		t.Fatal("expected awaitNativeStopFn to be called")
	}
	if mgr.addedCount != 1 || len(mgr.services) != 1 || mgr.services[0] != "openresty" {
		t.Fatalf("expected only openresty service for lua-only host, got %v", mgr.services)
	}
	env := strings.Join(mgr.envByName["openresty"], "\n")
	if !strings.Contains(env, "FN_RUNTIMES=lua") {
		t.Fatalf("expected FN_RUNTIMES=lua in service env, got %q", env)
	}
	if !strings.Contains(env, "FN_FORCE_URL=1") {
		t.Fatalf("expected FN_FORCE_URL in service env, got %q", env)
	}
	if wroteSession.RuntimeDir != runtimeDir {
		t.Fatalf("session runtime_dir mismatch: got=%q want=%q", wroteSession.RuntimeDir, runtimeDir)
	}
	if !cleared {
		t.Fatal("expected session cleanup to run")
	}
	if removed != runtimeDir {
		t.Fatalf("expected runtime cleanup for %q, got %q", runtimeDir, removed)
	}
}

func TestRunNative_InvalidHostPort(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	t.Setenv("FN_HOST_PORT", "invalid")
	t.Setenv("FN_RUNTIMES", "")

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(_ string, _ string) (string, error) { return nginxConf, nil }
	lookPathFn = func(string) (string, error) { return "", errors.New("missing") }
	newNativeManagerFn = func() nativeServiceManager {
		t.Fatal("manager should not be created when host port is invalid")
		return nil
	}

	err := RunNative(RunConfig{FnDir: t.TempDir()})
	if err == nil || !strings.Contains(err.Error(), "invalid FN_HOST_PORT") {
		t.Fatalf("expected invalid host port error, got %v", err)
	}
}

func TestRunNative_ExplicitRuntimesUnavailable(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "python,node")

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(_ string, _ string) (string, error) { return nginxConf, nil }
	lookPathFn = func(string) (string, error) { return "", errors.New("missing") }

	err := RunNative(RunConfig{FnDir: t.TempDir()})
	if err == nil {
		t.Fatal("expected explicit runtime compatibility error")
	}
	if !strings.Contains(err.Error(), "no compatible runtimes enabled") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRunNative_StartAllFailure(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "")

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(_ string, _ string) (string, error) { return nginxConf, nil }
	lookPathFn = func(string) (string, error) { return "", errors.New("missing") }

	cleared := false
	writeNativeSessionFn = func(NativeSession) error { return nil }
	clearNativeSessionForPID = func(int) error {
		cleared = true
		return nil
	}

	mgr := newFakeNativeManager()
	mgr.startErr = errors.New("boom")
	newNativeManagerFn = func() nativeServiceManager { return mgr }
	awaitNativeStopFn = func(nativeServiceManager) error {
		t.Fatal("await should not run when StartAll fails")
		return nil
	}

	err := RunNative(RunConfig{FnDir: t.TempDir()})
	if err == nil || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("expected start failure, got %v", err)
	}
	if !cleared {
		t.Fatal("expected session cleanup when start fails")
	}
}

func TestRunNative_WatcherStartWarningPath(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	functionsDir := t.TempDir()
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "")

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(_ string, _ string) (string, error) { return nginxConf, nil }
	lookPathFn = func(string) (string, error) { return "", errors.New("missing") }
	startHotReloadWatcherFn = func(string, string, func(string, ...interface{})) (*HotReloadWatcher, error) {
		return nil, errors.New("watcher disabled")
	}
	writeNativeSessionFn = func(NativeSession) error { return nil }
	clearNativeSessionForPID = func(int) error { return nil }

	mgr := newFakeNativeManager()
	newNativeManagerFn = func() nativeServiceManager { return mgr }
	awaitNativeStopFn = func(nativeServiceManager) error { return nil }

	if err := RunNative(RunConfig{FnDir: functionsDir, HotReload: true, Watch: true}); err != nil {
		t.Fatalf("RunNative() with watcher warning should still succeed, got %v", err)
	}
}

func TestEnsureSocketPathAvailable_StatAndRemoveErrors(t *testing.T) {
	patchRunnerDeps(t)
	socketPath := filepath.Join(t.TempDir(), "fn.sock")
	socketStatFn = func(string) (os.FileInfo, error) {
		return nil, errors.New("stat-fail")
	}
	if err := ensureSocketPathAvailable(socketPath); err == nil || !strings.Contains(err.Error(), "failed to inspect runtime socket") {
		t.Fatalf("expected stat inspection error")
	}

	socketStatFn = func(string) (os.FileInfo, error) {
		return fakeSocketFileInfo{name: "fn.sock", mode: os.ModeSocket}, nil
	}
	socketDialTimeoutFn = func(string, string, time.Duration) (net.Conn, error) {
		return nil, errors.New("stale")
	}
	socketRemoveFn = func(string) error {
		return errors.New("remove-fail")
	}
	if err := ensureSocketPathAvailable(socketPath); err == nil || !strings.Contains(err.Error(), "failed to remove stale runtime socket") {
		t.Fatalf("expected stale socket remove error, got %v", err)
	}

	socketRemoveFn = func(string) error { return nil }
	if err := ensureSocketPathAvailable(socketPath); err != nil {
		t.Fatalf("expected stale socket cleanup success, got %v", err)
	}
}

type fakeSocketFileInfo struct {
	name string
	mode os.FileMode
}

func (f fakeSocketFileInfo) Name() string       { return f.name }
func (f fakeSocketFileInfo) Size() int64        { return 0 }
func (f fakeSocketFileInfo) Mode() os.FileMode  { return f.mode }
func (f fakeSocketFileInfo) ModTime() time.Time { return time.Now() }
func (f fakeSocketFileInfo) IsDir() bool        { return false }
func (f fakeSocketFileInfo) Sys() interface{}   { return nil }

func TestAwaitNativeStopFn_DonePath(t *testing.T) {
	patchRunnerDeps(t)
	notifySignalFn = func(chan<- os.Signal, ...os.Signal) {}
	mgr := newFakeNativeManager()
	close(mgr.done)
	err := awaitNativeStopFn(mgr)
	if err == nil || !strings.Contains(err.Error(), "stopped unexpectedly") {
		t.Fatalf("expected done-path error, got %v", err)
	}
	if !mgr.stopped {
		t.Fatalf("expected manager StopAll on done path")
	}
}

func TestAwaitNativeStopFn_SignalPath(t *testing.T) {
	patchRunnerDeps(t)
	notifySignalFn = func(c chan<- os.Signal, _ ...os.Signal) {
		c <- os.Interrupt
	}
	mgr := newFakeNativeManager()
	err := awaitNativeStopFn(mgr)
	if err != nil {
		t.Fatalf("expected nil error on signal path, got %v", err)
	}
	if !mgr.stopped {
		t.Fatalf("expected manager StopAll on signal path")
	}
}

func TestRunNative_EarlyFailureBranches(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "")

	checkDependenciesFn = func() error { return errors.New("deps-fail") }
	if err := RunNative(RunConfig{FnDir: t.TempDir()}); err == nil || !strings.Contains(err.Error(), "deps-fail") {
		t.Fatalf("expected dependency failure, got %v", err)
	}

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return "", errors.New("extract-fail") }
	if err := RunNative(RunConfig{FnDir: t.TempDir()}); err == nil || !strings.Contains(err.Error(), "extract-fail") {
		t.Fatalf("expected runtime extract failure, got %v", err)
	}

	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(string, string) (string, error) { return "", errors.New("gen-fail") }
	if err := RunNative(RunConfig{FnDir: t.TempDir()}); err == nil || !strings.Contains(err.Error(), "gen-fail") {
		t.Fatalf("expected config generation failure, got %v", err)
	}

	generateNativeConfigFn = func(string, string) (string, error) { return nginxConf, nil }
	ensurePortAvailableFn = func(string) error { return errors.New("busy-port") }
	if err := RunNative(RunConfig{FnDir: t.TempDir()}); err == nil || !strings.Contains(err.Error(), "busy-port") {
		t.Fatalf("expected host port preflight failure, got %v", err)
	}
}

func TestRunNative_MkdirAndSocketPreflightFailures(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	socketBaseDir := os.Getenv("FN_SOCKET_BASE_DIR")
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "python")

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(string, string) (string, error) { return nginxConf, nil }
	ensurePortAvailableFn = func(string) error { return nil }
	lookPathFn = func(bin string) (string, error) {
		if bin == "python3" {
			return "/usr/bin/python3", nil
		}
		return "", errors.New("missing")
	}

	mkdirAllFn = func(path string, perm os.FileMode) error {
		if path == socketBaseDir {
			return errors.New("mkdir-fail")
		}
		return os.MkdirAll(path, perm)
	}
	if err := RunNative(RunConfig{FnDir: t.TempDir()}); err == nil || !strings.Contains(err.Error(), "mkdir-fail") {
		t.Fatalf("expected socket base dir mkdir failure, got %v", err)
	}

	mkdirAllFn = func(path string, perm os.FileMode) error {
		if strings.HasPrefix(path, filepath.Join(socketBaseDir, "s-")) {
			return errors.New("socket-dir-fail")
		}
		return os.MkdirAll(path, perm)
	}
	if err := RunNative(RunConfig{FnDir: t.TempDir()}); err == nil || !strings.Contains(err.Error(), "socket-dir-fail") {
		t.Fatalf("expected socket dir mkdir failure, got %v", err)
	}

	mkdirAllFn = os.MkdirAll
	ensureSocketPathAvailFn = func(string) error { return errors.New("socket-preflight-fail") }
	if err := RunNative(RunConfig{FnDir: t.TempDir()}); err == nil || !strings.Contains(err.Error(), "socket-preflight-fail") {
		t.Fatalf("expected socket preflight failure, got %v", err)
	}
}

func TestRunNative_UsesSocketBaseDirOverride(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	functionsDir := t.TempDir()
	customBase := filepath.Join(t.TempDir(), "native-sockets")
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "python")
	t.Setenv("FN_SOCKET_BASE_DIR", customBase)

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(string, string) (string, error) { return nginxConf, nil }
	ensurePortAvailableFn = func(string) error { return nil }
	lookPathFn = func(bin string) (string, error) {
		if bin == "python3" {
			return "/usr/bin/python3", nil
		}
		return "", errors.New("missing")
	}
	ensureSocketPathAvailFn = func(string) error { return nil }
	writeNativeSessionFn = func(NativeSession) error { return nil }
	clearNativeSessionForPID = func(int) error { return nil }

	mkdirPaths := []string{}
	mkdirAllFn = func(path string, perm os.FileMode) error {
		mkdirPaths = append(mkdirPaths, path)
		return os.MkdirAll(path, perm)
	}

	mgr := newFakeNativeManager()
	newNativeManagerFn = func() nativeServiceManager { return mgr }
	awaitNativeStopFn = func(nativeServiceManager) error { return nil }

	if err := RunNative(RunConfig{FnDir: functionsDir}); err != nil {
		t.Fatalf("RunNative() error = %v", err)
	}

	if len(mkdirPaths) == 0 || mkdirPaths[0] != customBase {
		t.Fatalf("expected first mkdir path to be custom base %q, got %v", customBase, mkdirPaths)
	}

	foundSocketEnv := false
	for _, env := range mgr.envByName["python"] {
		if strings.HasPrefix(env, "FN_SOCKET_BASE_DIR=") {
			foundSocketEnv = true
			socketDir := strings.TrimPrefix(env, "FN_SOCKET_BASE_DIR=")
			if !strings.HasPrefix(socketDir, customBase+string(filepath.Separator)+"s-") {
				t.Fatalf("expected socket dir under %q, got %q", customBase, socketDir)
			}
		}
	}
	if !foundSocketEnv {
		t.Fatalf("expected FN_SOCKET_BASE_DIR env for python service, got %v", mgr.envByName["python"])
	}
}

func TestRunNative_UsesDefaultSocketBaseDirWhenUnset(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	functionsDir := t.TempDir()
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "python")
	t.Setenv("FN_SOCKET_BASE_DIR", "")

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(string, string) (string, error) { return nginxConf, nil }
	ensurePortAvailableFn = func(string) error { return nil }
	lookPathFn = func(bin string) (string, error) {
		if bin == "python3" {
			return "/usr/bin/python3", nil
		}
		return "", errors.New("missing")
	}
	ensureSocketPathAvailFn = func(string) error { return nil }
	writeNativeSessionFn = func(NativeSession) error { return nil }
	clearNativeSessionForPID = func(int) error { return nil }

	mkdirPaths := []string{}
	mkdirAllFn = func(path string, perm os.FileMode) error {
		mkdirPaths = append(mkdirPaths, path)
		return os.MkdirAll(path, perm)
	}

	mgr := newFakeNativeManager()
	newNativeManagerFn = func() nativeServiceManager { return mgr }
	awaitNativeStopFn = func(nativeServiceManager) error { return nil }

	if err := RunNative(RunConfig{FnDir: functionsDir}); err != nil {
		t.Fatalf("RunNative() error = %v", err)
	}

	if len(mkdirPaths) == 0 || mkdirPaths[0] != "/tmp/fastfn" {
		t.Fatalf("expected default socket base dir /tmp/fastfn, got %v", mkdirPaths)
	}

	foundSocketEnv := false
	for _, env := range mgr.envByName["python"] {
		if strings.HasPrefix(env, "FN_SOCKET_BASE_DIR=") {
			foundSocketEnv = true
			socketDir := strings.TrimPrefix(env, "FN_SOCKET_BASE_DIR=")
			if !strings.HasPrefix(socketDir, "/tmp/fastfn"+string(filepath.Separator)+"s-") {
				t.Fatalf("expected default socket dir under /tmp/fastfn, got %q", socketDir)
			}
		}
	}
	if !foundSocketEnv {
		t.Fatalf("expected FN_SOCKET_BASE_DIR env for python service, got %v", mgr.envByName["python"])
	}
}

func TestRunNative_FallsBackToShortSocketDirWhenPathsTooLong(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	functionsDir := t.TempDir()
	customBase := filepath.Join(t.TempDir(), strings.Repeat("native-socket-path-", 8))
	fallbackRoot := t.TempDir()
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "python")
	t.Setenv("FN_SOCKET_BASE_DIR", customBase)

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(string, string) (string, error) { return nginxConf, nil }
	ensurePortAvailableFn = func(string) error { return nil }
	lookPathFn = func(bin string) (string, error) {
		if bin == "python3" {
			return "/usr/bin/python3", nil
		}
		return "", errors.New("missing")
	}
	writeNativeSessionFn = func(NativeSession) error { return nil }
	clearNativeSessionForPID = func(int) error { return nil }
	nativeSocketFallbackRootFn = func() string { return fallbackRoot }

	preflightSockets := []string{}
	ensureSocketPathAvailFn = func(path string) error {
		preflightSockets = append(preflightSockets, path)
		return nil
	}

	mgr := newFakeNativeManager()
	newNativeManagerFn = func() nativeServiceManager { return mgr }
	awaitNativeStopFn = func(nativeServiceManager) error { return nil }

	if err := RunNative(RunConfig{FnDir: functionsDir}); err != nil {
		t.Fatalf("RunNative() error = %v", err)
	}

	pythonEnv := strings.Join(mgr.envByName["python"], "\n")
	if strings.Contains(pythonEnv, "FN_SOCKET_BASE_DIR="+customBase) {
		t.Fatalf("expected fallback socket dir instead of long base %q, got %q", customBase, pythonEnv)
	}
	if len(preflightSockets) != 1 {
		t.Fatalf("expected one preflight socket, got %v", preflightSockets)
	}
	if !strings.Contains(pythonEnv, "FN_SOCKET_BASE_DIR=") {
		t.Fatalf("expected FN_SOCKET_BASE_DIR in env, got %q", pythonEnv)
	}
	if !strings.HasPrefix(preflightSockets[0], fallbackRoot+string(filepath.Separator)) && !strings.HasPrefix(preflightSockets[0], "/tmp/") {
		t.Fatalf("expected preflight socket under fallback root %q or /tmp, got %q", fallbackRoot, preflightSockets[0])
	}
	if len(preflightSockets[0]) > maxUnixSocketPathBytes {
		t.Fatalf("expected fallback socket path length <= %d, got %d (%q)", maxUnixSocketPathBytes, len(preflightSockets[0]), preflightSockets[0])
	}
}

func TestRunNative_SessionWarningsAndAllRuntimeRegistration(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	functionsDir := t.TempDir()
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "python,node,php,rust,go,unknown")
	t.Setenv("FN_FORCE_URL", "1")

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(string, string) (string, error) { return nginxConf, nil }
	ensurePortAvailableFn = func(string) error { return nil }
	ensureSocketPathAvailFn = func(string) error { return nil }
	lookPathFn = func(bin string) (string, error) {
		switch bin {
		case "python3":
			return "/usr/bin/python3", nil
		case "node":
			return "/usr/bin/node", nil
		case "php":
			return "/usr/bin/php", nil
		case "go":
			return "/usr/bin/go", nil
		case "cargo":
			return "/usr/bin/cargo", nil
		default:
			return "", errors.New("missing")
		}
	}

	writeNativeSessionFn = func(NativeSession) error { return errors.New("write-session-fail") }
	clearNativeSessionForPID = func(int) error { return errors.New("clear-session-fail") }

	watcherStarted := false
	startHotReloadWatcherFn = func(_ string, _ string, logf func(string, ...interface{})) (*HotReloadWatcher, error) {
		watcherStarted = true
		logf("watcher warmup")
		return &HotReloadWatcher{}, nil
	}

	mgr := newFakeNativeManager()
	newNativeManagerFn = func() nativeServiceManager { return mgr }
	awaitNativeStopFn = func(nativeServiceManager) error { return nil }

	if err := RunNative(RunConfig{FnDir: functionsDir, HotReload: true, VerifyTLS: true, Watch: true}); err != nil {
		t.Fatalf("RunNative() error = %v", err)
	}
	if !watcherStarted {
		t.Fatalf("expected watcher start path")
	}

	gotServices := strings.Join(mgr.services, ",")
	for _, required := range []string{"openresty", "python", "node", "php", "rust", "go"} {
		if !strings.Contains(gotServices, required) {
			t.Fatalf("expected service %q, got %v", required, mgr.services)
		}
	}
	goEnv := strings.Join(mgr.envByName["go"], "\n")
	if !strings.Contains(goEnv, "FN_GO_BIN=/usr/bin/go") {
		t.Fatalf("expected FN_GO_BIN in go env, got %q", goEnv)
	}
	if got := mgr.commandByName["php"]; got != "/usr/bin/php" {
		t.Fatalf("expected php daemon to launch with php, got %q", got)
	}
	openrestyEnv := strings.Join(mgr.envByName["openresty"], "\n")
	if !strings.Contains(openrestyEnv, "FN_FORCE_URL=1") {
		t.Fatalf("expected FN_FORCE_URL in openresty env, got %q", openrestyEnv)
	}
	if !strings.Contains(openrestyEnv, "FN_HTTP_VERIFY_TLS=true") {
		t.Fatalf("expected verify tls flag in env, got %q", openrestyEnv)
	}
}

func TestRunNative_RuntimeDaemonCountsCreateIndexedServicesAndSockets(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	functionsDir := t.TempDir()
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "node,python,lua")
	t.Setenv("FN_RUNTIME_DAEMONS", "node=3,python=2,lua=2")

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(string, string) (string, error) { return nginxConf, nil }
	ensurePortAvailableFn = func(string) error { return nil }
	lookPathFn = func(bin string) (string, error) {
		switch bin {
		case "python3":
			return "/usr/bin/python3", nil
		case "node":
			return "/usr/bin/node", nil
		default:
			return "", errors.New("missing")
		}
	}
	writeNativeSessionFn = func(NativeSession) error { return nil }
	clearNativeSessionForPID = func(int) error { return nil }

	preflightSockets := make([]string, 0)
	ensureSocketPathAvailFn = func(path string) error {
		preflightSockets = append(preflightSockets, path)
		return nil
	}

	mgr := newFakeNativeManager()
	newNativeManagerFn = func() nativeServiceManager { return mgr }
	awaitNativeStopFn = func(nativeServiceManager) error { return nil }

	if err := RunNative(RunConfig{FnDir: functionsDir}); err != nil {
		t.Fatalf("RunNative() error = %v", err)
	}

	wantServices := []string{"openresty", "python#1", "python#2", "node#1", "node#2", "node#3"}
	if !reflect.DeepEqual(mgr.services, wantServices) {
		t.Fatalf("services = %v, want %v", mgr.services, wantServices)
	}

	if len(preflightSockets) != 5 {
		t.Fatalf("expected 5 socket preflights, got %v", preflightSockets)
	}

	openrestyEnv := strings.Join(mgr.envByName["openresty"], "\n")
	if !strings.Contains(openrestyEnv, `FN_RUNTIME_SOCKETS={"node":["unix:`) {
		t.Fatalf("expected FN_RUNTIME_SOCKETS arrays in env, got %q", openrestyEnv)
	}
	if !strings.Contains(openrestyEnv, `"python":["unix:`) {
		t.Fatalf("expected python sockets array in env, got %q", openrestyEnv)
	}
	nodeEnv := strings.Join(mgr.envByName["node#2"], "\n")
	if !strings.Contains(nodeEnv, "FN_NODE_SOCKET=") || !strings.Contains(nodeEnv, "fn-node-2.sock") {
		t.Fatalf("expected node#2 socket env, got %q", nodeEnv)
	}
	if !strings.Contains(nodeEnv, "FN_RUNTIME_INSTANCE_INDEX=2") {
		t.Fatalf("expected node instance index env, got %q", nodeEnv)
	}
	pythonEnv := strings.Join(mgr.envByName["python#2"], "\n")
	if !strings.Contains(pythonEnv, "fn-python-2.sock") {
		t.Fatalf("expected python#2 socket env, got %q", pythonEnv)
	}
}

func TestRunNative_LogsDirMkdirFailure(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "")

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(string, string) (string, error) { return nginxConf, nil }
	ensurePortAvailableFn = func(string) error { return nil }
	lookPathFn = func(string) (string, error) { return "", errors.New("missing") }

	mkdirAllFn = func(path string, perm os.FileMode) error {
		if strings.HasSuffix(path, filepath.Join("openresty", "logs")) {
			return errors.New("logs-dir-fail")
		}
		return os.MkdirAll(path, perm)
	}
	if err := RunNative(RunConfig{FnDir: t.TempDir()}); err == nil || !strings.Contains(err.Error(), "logs-dir-fail") {
		t.Fatalf("expected logs dir mkdir failure, got %v", err)
	}
}

func TestRunNative_DefaultHostPortAndClearSessionWarning(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	functionsDir := t.TempDir()
	t.Setenv("FN_HOST_PORT", "")
	t.Setenv("FN_RUNTIMES", "")

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(string, string) (string, error) { return nginxConf, nil }
	lookPathFn = func(string) (string, error) { return "", errors.New("missing") }
	ensureSocketPathAvailFn = func(string) error { return nil }

	capturedPort := ""
	ensurePortAvailableFn = func(port string) error {
		capturedPort = port
		return nil
	}
	writeNativeSessionFn = func(NativeSession) error { return nil }
	clearNativeSessionForPID = func(int) error { return errors.New("clear-fail") }
	mgr := newFakeNativeManager()
	newNativeManagerFn = func() nativeServiceManager { return mgr }
	awaitNativeStopFn = func(nativeServiceManager) error { return nil }

	if err := RunNative(RunConfig{FnDir: functionsDir}); err != nil {
		t.Fatalf("RunNative() error = %v", err)
	}
	if capturedPort != "8080" {
		t.Fatalf("expected default host port 8080, got %q", capturedPort)
	}
}

func TestRunNative_RemoveAllWarningInDefer(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	functionsDir := t.TempDir()
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "")

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(string, string) (string, error) { return nginxConf, nil }
	lookPathFn = func(string) (string, error) { return "", errors.New("missing") }
	ensureSocketPathAvailFn = func(string) error { return nil }
	writeNativeSessionFn = func(NativeSession) error { return nil }
	clearNativeSessionForPID = func(int) error { return nil }

	// Track calls. The socketDir removeAll is called at two points:
	// 1. Initial cleanup (line 216) - must succeed
	// 2. Deferred cleanup (line 223) - we want this to fail to trigger warning
	socketDirCallCount := 0
	removeAllFn = func(path string) error {
		if strings.Contains(path, "s-") {
			socketDirCallCount++
			if socketDirCallCount >= 2 {
				// Second call is the deferred cleanup - return error to trigger warning
				return errors.New("remove-socket-dir-fail")
			}
		}
		return nil
	}

	mgr := newFakeNativeManager()
	newNativeManagerFn = func() nativeServiceManager { return mgr }
	awaitNativeStopFn = func(nativeServiceManager) error { return nil }

	// This should not fail even though socketDir removal fails (it's just a warning)
	if err := RunNative(RunConfig{FnDir: functionsDir}); err != nil {
		t.Fatalf("RunNative() error = %v", err)
	}
}

func TestRunNative_SocketDirRemoveAllError(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "")

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(string, string) (string, error) { return nginxConf, nil }
	lookPathFn = func(string) (string, error) { return "", errors.New("missing") }
	ensurePortAvailableFn = func(string) error { return nil }

	callCount := 0
	removeAllFn = func(path string) error {
		callCount++
		if strings.Contains(path, "s-") && callCount == 1 {
			// First call to remove socketDir (initial cleanup) returns a non-ErrNotExist error
			return errors.New("remove-fail")
		}
		return nil
	}

	err := RunNative(RunConfig{FnDir: t.TempDir()})
	if err == nil || !strings.Contains(err.Error(), "failed to clear native socket dir") {
		t.Fatalf("expected socket dir clear error, got %v", err)
	}
}

func TestRunNative_EnvVarOverrideError(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "")
	// Set an explicit env var override that is invalid
	t.Setenv("FN_OPENRESTY_BIN", "/nonexistent/openresty")

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(string, string) (string, error) { return nginxConf, nil }
	ensurePortAvailableFn = func(string) error { return nil }
	lookPathFn = func(bin string) (string, error) {
		return "", errors.New("missing")
	}

	err := RunNative(RunConfig{FnDir: t.TempDir()})
	if err == nil {
		t.Fatal("expected error when env var override points to invalid binary")
	}
}

func TestRunNative_InvalidRuntimeDaemons(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "")
	t.Setenv("FN_RUNTIME_DAEMONS", "node=abc") // invalid count

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(string, string) (string, error) { return nginxConf, nil }
	lookPathFn = func(string) (string, error) { return "", errors.New("missing") }
	ensurePortAvailableFn = func(string) error { return nil }
	ensureSocketPathAvailFn = func(string) error { return nil }
	removeAllFn = func(string) error { return nil }

	err := RunNative(RunConfig{FnDir: t.TempDir()})
	if err == nil {
		t.Fatal("expected error for invalid FN_RUNTIME_DAEMONS")
	}
}

func TestRunNative_OpenrestyBinaryResolved(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	functionsDir := t.TempDir()
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "")

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(string, string) (string, error) { return nginxConf, nil }
	ensurePortAvailableFn = func(string) error { return nil }
	ensureSocketPathAvailFn = func(string) error { return nil }
	writeNativeSessionFn = func(NativeSession) error { return nil }
	clearNativeSessionForPID = func(int) error { return nil }

	// Make openresty resolvable so the openrestyCommand uses the resolved path
	lookPathFn = func(bin string) (string, error) {
		if bin == "openresty" {
			return "/usr/local/bin/openresty", nil
		}
		return "", errors.New("missing")
	}

	mgr := newFakeNativeManager()
	newNativeManagerFn = func() nativeServiceManager { return mgr }
	awaitNativeStopFn = func(nativeServiceManager) error { return nil }

	if err := RunNative(RunConfig{FnDir: functionsDir}); err != nil {
		t.Fatalf("RunNative() error = %v", err)
	}

	// Verify openresty service uses the resolved path
	if cmd, ok := mgr.commandByName["openresty"]; ok {
		if cmd != "/usr/local/bin/openresty" {
			t.Fatalf("expected openresty command to be resolved path, got %q", cmd)
		}
	}
}

func TestRunNative_SocketPreflightSkipsUnselectedRuntime(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	functionsDir := t.TempDir()
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "")

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(string, string) (string, error) { return nginxConf, nil }
	ensurePortAvailableFn = func(string) error { return nil }
	lookPathFn = func(string) (string, error) { return "", errors.New("missing") }
	writeNativeSessionFn = func(NativeSession) error { return nil }
	clearNativeSessionForPID = func(int) error { return nil }

	// Inject runtimeSocketURIsFn to return an extra runtime not in selected
	runtimeSocketURIsFn = func(socketDir string, selected []string, counts map[string]int) map[string][]string {
		result := runtimeSocketURIsByRuntime(socketDir, selected, counts)
		// Add an extra runtime that is NOT in the selected list
		result["phantom"] = []string{"unix:/tmp/phantom.sock"}
		return result
	}

	preflightSockets := make([]string, 0)
	ensureSocketPathAvailFn = func(path string) error {
		preflightSockets = append(preflightSockets, path)
		return nil
	}

	mgr := newFakeNativeManager()
	newNativeManagerFn = func() nativeServiceManager { return mgr }
	awaitNativeStopFn = func(nativeServiceManager) error { return nil }

	if err := RunNative(RunConfig{FnDir: functionsDir}); err != nil {
		t.Fatalf("RunNative() error = %v", err)
	}

	// Verify that "phantom" socket was NOT preflighted (skipped by !selected check)
	for _, sock := range preflightSockets {
		if strings.Contains(sock, "phantom") {
			t.Fatal("expected phantom runtime sockets to be skipped in preflight")
		}
	}
}

func TestRunNative_EncodeRuntimeSocketMapError(t *testing.T) {
	patchRunnerDeps(t)
	runtimeDir, nginxConf := prepareRuntimeDir(t)
	t.Setenv("FN_HOST_PORT", reserveFreePort(t))
	t.Setenv("FN_RUNTIMES", "")

	checkDependenciesFn = func() error { return nil }
	runtimeExtractFn = func() (string, error) { return runtimeDir, nil }
	generateNativeConfigFn = func(string, string) (string, error) { return nginxConf, nil }
	ensurePortAvailableFn = func(string) error { return nil }
	lookPathFn = func(string) (string, error) { return "", errors.New("missing") }
	ensureSocketPathAvailFn = func(string) error { return nil }

	origMarshal := jsonMarshalFn
	t.Cleanup(func() { jsonMarshalFn = origMarshal })
	jsonMarshalFn = func(v any) ([]byte, error) {
		return nil, errors.New("encode-fail")
	}

	err := RunNative(RunConfig{FnDir: t.TempDir()})
	if err == nil || !strings.Contains(err.Error(), "failed to encode runtime socket map") {
		t.Fatalf("expected encode error, got %v", err)
	}
}

func TestNewNativeManagerFn_DefaultFactory(t *testing.T) {
	patchRunnerDeps(t)
	pm := newNativeManagerFn()
	if pm == nil {
		t.Fatalf("expected default native manager factory to return value")
	}
	pm.StopAll()
}
