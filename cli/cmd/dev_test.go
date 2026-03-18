package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/misaelzapata/fastfn/cli/internal/discovery"
	"github.com/misaelzapata/fastfn/cli/internal/process"
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

func TestScanForMounts_RuntimeLayoutDirsMountsProjectRoot(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "fastfn-test-runtime-layout-*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	fnDir := filepath.Join(tmpDir, "node", "alpha")
	if err := os.MkdirAll(fnDir, 0755); err != nil {
		t.Fatalf("mkdir failed: %v", err)
	}
	if err := os.WriteFile(filepath.Join(fnDir, "fn.config.json"), []byte(`{"name":"alpha","entrypoint":"handler.js"}`), 0644); err != nil {
		t.Fatalf("write fn.config.json failed: %v", err)
	}
	if err := os.WriteFile(filepath.Join(fnDir, "handler.js"), []byte("exports.handler = async () => ({ status: 200, body: '{}' });"), 0644); err != nil {
		t.Fatalf("write handler failed: %v", err)
	}

	mounts := scanForMounts(tmpDir)
	if len(mounts) != 1 {
		t.Fatalf("Expected 1 mount (project root), got %d: %v", len(mounts), mounts)
	}
	want := tmpDir + ":/app/srv/fn/functions"
	if mounts[0] != want {
		t.Fatalf("unexpected mount: got=%q want=%q", mounts[0], want)
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

func TestApplyOpenRestyDockerUser_DefaultsToHostUser(t *testing.T) {
	t.Setenv("FN_DOCKER_RUN_AS_ROOT", "")
	t.Setenv("FN_DOCKER_USER", "")

	openresty := map[string]interface{}{}
	applyOpenRestyDockerUser(openresty)

	want := strings.Join([]string{strconv.Itoa(os.Getuid()), strconv.Itoa(os.Getgid())}, ":")
	if got, _ := openresty["user"].(string); got != want {
		t.Fatalf("openresty.user = %q, want %q", got, want)
	}
}

func TestApplyOpenRestyDockerUser_ExplicitOverride(t *testing.T) {
	t.Setenv("FN_DOCKER_RUN_AS_ROOT", "")
	t.Setenv("FN_DOCKER_USER", "123:456")

	openresty := map[string]interface{}{}
	applyOpenRestyDockerUser(openresty)

	if got, _ := openresty["user"].(string); got != "123:456" {
		t.Fatalf("openresty.user = %q, want %q", got, "123:456")
	}
}

func TestApplyOpenRestyDockerUser_DoesNotOverrideExisting(t *testing.T) {
	t.Setenv("FN_DOCKER_RUN_AS_ROOT", "")
	t.Setenv("FN_DOCKER_USER", "123:456")

	openresty := map[string]interface{}{"user": "9:9"}
	applyOpenRestyDockerUser(openresty)

	if got, _ := openresty["user"].(string); got != "9:9" {
		t.Fatalf("openresty.user = %q, want %q", got, "9:9")
	}
}

func TestApplyOpenRestyDockerUser_RunAsRootSkips(t *testing.T) {
	t.Setenv("FN_DOCKER_RUN_AS_ROOT", "1")
	t.Setenv("FN_DOCKER_USER", "123:456")

	openresty := map[string]interface{}{}
	applyOpenRestyDockerUser(openresty)

	if _, ok := openresty["user"]; ok {
		t.Fatalf("openresty.user should be unset when FN_DOCKER_RUN_AS_ROOT=1, got=%v", openresty["user"])
	}
}

// ---------------------------------------------------------------------------
// checkSystemRequirements tests
// ---------------------------------------------------------------------------

func TestCheckSystemRequirements_DockerBinaryMissing(t *testing.T) {
	origLookPath := devLookPath
	origFatal := devFatal
	t.Cleanup(func() {
		devLookPath = origLookPath
		devFatal = origFatal
	})
	t.Setenv("FN_DOCKER_BIN", "")

	devLookPath = func(file string) (string, error) {
		return "", errors.New("not found")
	}

	var fatalCalled bool
	devFatal = func(v ...interface{}) {
		fatalCalled = true
	}

	checkSystemRequirements()

	if !fatalCalled {
		t.Fatal("expected devFatal to be called when docker binary is missing")
	}
}

func TestCheckSystemRequirements_DockerDaemonNotRunning(t *testing.T) {
	origLookPath := devLookPath
	origFatal := devFatal
	origRunner := devCommandRunner
	t.Cleanup(func() {
		devLookPath = origLookPath
		devFatal = origFatal
		devCommandRunner = origRunner
	})
	t.Setenv("FN_DOCKER_BIN", "")

	devLookPath = func(file string) (string, error) {
		return "/usr/bin/docker", nil
	}
	devCommandRunner = func(name string, args ...string) *exec.Cmd {
		return exec.Command("false")
	}

	var fatalCalled bool
	devFatal = func(v ...interface{}) {
		fatalCalled = true
	}

	checkSystemRequirements()

	if !fatalCalled {
		t.Fatal("expected devFatal to be called when docker daemon is not running")
	}
}

func TestCheckSystemRequirements_AllOK(t *testing.T) {
	origLookPath := devLookPath
	origFatal := devFatal
	origRunner := devCommandRunner
	t.Cleanup(func() {
		devLookPath = origLookPath
		devFatal = origFatal
		devCommandRunner = origRunner
	})
	t.Setenv("FN_DOCKER_BIN", "")

	devLookPath = func(file string) (string, error) {
		return "/usr/bin/docker", nil
	}
	devCommandRunner = func(name string, args ...string) *exec.Cmd {
		return exec.Command("true")
	}

	var fatalCalled bool
	devFatal = func(v ...interface{}) {
		fatalCalled = true
	}

	checkSystemRequirements()

	if fatalCalled {
		t.Fatal("devFatal should not be called when docker is available")
	}
}

func TestCheckSystemRequirements_CustomDockerBin(t *testing.T) {
	origLookPath := devLookPath
	origFatal := devFatal
	origRunner := devCommandRunner
	t.Cleanup(func() {
		devLookPath = origLookPath
		devFatal = origFatal
		devCommandRunner = origRunner
	})
	t.Setenv("FN_DOCKER_BIN", "podman")

	var lookedUp string
	devLookPath = func(file string) (string, error) {
		lookedUp = file
		return "/usr/bin/podman", nil
	}
	devCommandRunner = func(name string, args ...string) *exec.Cmd {
		return exec.Command("true")
	}
	devFatal = func(v ...interface{}) {
		t.Fatal("devFatal should not be called")
	}

	checkSystemRequirements()

	if lookedUp != "podman" {
		t.Fatalf("expected LookPath(podman), got LookPath(%q)", lookedUp)
	}
}

// ---------------------------------------------------------------------------
// findProjectRoot tests
// ---------------------------------------------------------------------------

func TestFindProjectRoot_FoundInCurrentDir(t *testing.T) {
	tmpDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmpDir, "docker-compose.yml"), []byte("services: {}"), 0644); err != nil {
		t.Fatal(err)
	}

	root, err := findProjectRoot(tmpDir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if root != tmpDir {
		t.Fatalf("expected %q, got %q", tmpDir, root)
	}
}

func TestFindProjectRoot_FoundInParentDir(t *testing.T) {
	tmpDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmpDir, "docker-compose.yml"), []byte("services: {}"), 0644); err != nil {
		t.Fatal(err)
	}
	child := filepath.Join(tmpDir, "sub", "deep")
	if err := os.MkdirAll(child, 0755); err != nil {
		t.Fatal(err)
	}

	root, err := findProjectRoot(child)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if root != tmpDir {
		t.Fatalf("expected %q, got %q", tmpDir, root)
	}
}

func TestFindProjectRoot_NotFound(t *testing.T) {
	tmpDir := t.TempDir()

	_, err := findProjectRoot(tmpDir)
	if err == nil {
		t.Fatal("expected error when docker-compose.yml not found")
	}
}

// ---------------------------------------------------------------------------
// getFunctionDetails tests
// ---------------------------------------------------------------------------

func TestGetFunctionDetails_ValidConfig(t *testing.T) {
	tmpDir := t.TempDir()
	cfg := FnConfig{Runtime: "python", Name: "my-fn"}
	data, _ := json.Marshal(cfg)
	if err := os.WriteFile(filepath.Join(tmpDir, "fn.config.json"), data, 0644); err != nil {
		t.Fatal(err)
	}

	rt, name := getFunctionDetails(tmpDir)
	if rt != "python" {
		t.Fatalf("runtime = %q, want python", rt)
	}
	if name != "my-fn" {
		t.Fatalf("name = %q, want my-fn", name)
	}
}

func TestGetFunctionDetails_InvalidJSON(t *testing.T) {
	tmpDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmpDir, "fn.config.json"), []byte("{bad json"), 0644); err != nil {
		t.Fatal(err)
	}

	rt, name := getFunctionDetails(tmpDir)
	if rt != "node" {
		t.Fatalf("runtime = %q, want node (default)", rt)
	}
	if name != filepath.Base(tmpDir) {
		t.Fatalf("name = %q, want %q (default)", name, filepath.Base(tmpDir))
	}
}

func TestGetFunctionDetails_MissingFile(t *testing.T) {
	tmpDir := t.TempDir()

	rt, name := getFunctionDetails(tmpDir)
	if rt != "node" {
		t.Fatalf("runtime = %q, want node (default)", rt)
	}
	if name != filepath.Base(tmpDir) {
		t.Fatalf("name = %q, want %q (default)", name, filepath.Base(tmpDir))
	}
}

// ---------------------------------------------------------------------------
// scanForMounts – single function dir (isFunction path)
// ---------------------------------------------------------------------------

func TestScanForMounts_SingleFunctionDir(t *testing.T) {
	tmpDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmpDir, "fn.config.json"), []byte(`{"runtime":"go","name":"myfn"}`), 0644); err != nil {
		t.Fatal(err)
	}

	mounts := scanForMounts(tmpDir)
	if len(mounts) != 1 {
		t.Fatalf("expected 1 mount, got %d: %v", len(mounts), mounts)
	}
	want := fmt.Sprintf("%s:/app/srv/fn/functions/go/myfn", tmpDir)
	if mounts[0] != want {
		t.Fatalf("mount = %q, want %q", mounts[0], want)
	}
}

// ---------------------------------------------------------------------------
// applyOpenRestyDockerUser – nil map should not panic
// ---------------------------------------------------------------------------

func TestApplyOpenRestyDockerUser_NilMap(t *testing.T) {
	// Should not panic when called with nil.
	applyOpenRestyDockerUser(nil)
}

// ---------------------------------------------------------------------------
// Helper: create a minimal docker-compose project directory
// ---------------------------------------------------------------------------

func createComposeProject(t *testing.T) string {
	t.Helper()
	tmpDir := t.TempDir()
	composeContent := `services:
  openresty:
    image: test
    volumes:
      - /old/path:/app/srv/fn/functions
`
	if err := os.WriteFile(filepath.Join(tmpDir, "docker-compose.yml"), []byte(composeContent), 0644); err != nil {
		t.Fatal(err)
	}
	// Create a functions subdir with a file so scanForMounts returns mounts.
	fnDir := filepath.Join(tmpDir, "functions")
	if err := os.MkdirAll(fnDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fnDir, "get.hello.js"), []byte("module.exports = {};"), 0644); err != nil {
		t.Fatal(err)
	}
	return tmpDir
}

// stubDevGlobals saves and restores all package-level vars used by devCmd.Run.
func stubDevGlobals(t *testing.T) {
	t.Helper()
	origDryRun := dryRun
	origDevBuild := devBuild
	origDevForceURL := devForceURL
	origDevNativeMode := devNativeMode
	origCheckSys := checkSystemRequirementsFn
	origExec := devExecCommand
	origAbs := devAbsFn
	origYAML := devYAMLMarshalFn
	origFatal := devFatal
	origFatalf := devFatalf
	origWatcher := devStartHotReloadWatcher
	origLookPath := devLookPath
	origRunner := devCommandRunner
	t.Cleanup(func() {
		dryRun = origDryRun
		devBuild = origDevBuild
		devForceURL = origDevForceURL
		devNativeMode = origDevNativeMode
		checkSystemRequirementsFn = origCheckSys
		devExecCommand = origExec
		devAbsFn = origAbs
		devYAMLMarshalFn = origYAML
		devFatal = origFatal
		devFatalf = origFatalf
		devStartHotReloadWatcher = origWatcher
		devLookPath = origLookPath
		devCommandRunner = origRunner
		viper.Reset()
	})
	viper.Reset()
	dryRun = false
	devBuild = false
	devForceURL = false
	devNativeMode = false

	// Default stubs.
	checkSystemRequirementsFn = func() {}
	devStartHotReloadWatcher = func(string, string, func(string, ...interface{})) (*process.HotReloadWatcher, error) {
		return nil, nil
	}
	devExecCommand = func(name string, args ...string) *exec.Cmd {
		return exec.Command("true")
	}
	devFatal = func(v ...interface{}) {}
	devFatalf = func(format string, v ...interface{}) {}
}

// ---------------------------------------------------------------------------
// devCmd.Run – Docker mode tests
// ---------------------------------------------------------------------------

func TestDevCmdRun_DockerHappyPath(t *testing.T) {
	stubDevGlobals(t)

	projDir := createComposeProject(t)
	fnDir := filepath.Join(projDir, "functions")

	origWd, _ := os.Getwd()
	os.Chdir(projDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	var mu sync.Mutex
	var capturedName string
	var capturedArgs []string
	devExecCommand = func(name string, args ...string) *exec.Cmd {
		mu.Lock()
		capturedName = name
		capturedArgs = args
		mu.Unlock()
		return exec.Command("true")
	}

	devCmd.Run(devCmd, []string{fnDir})

	mu.Lock()
	defer mu.Unlock()
	if capturedName != "docker" {
		t.Fatalf("expected docker command, got %q", capturedName)
	}
	if len(capturedArgs) < 4 {
		t.Fatalf("expected at least 4 docker args, got %v", capturedArgs)
	}
	if capturedArgs[0] != "compose" {
		t.Fatalf("expected 'compose' as first arg, got %q", capturedArgs[0])
	}
}

func TestDevCmdRun_DryRun(t *testing.T) {
	stubDevGlobals(t)
	dryRun = true

	projDir := createComposeProject(t)
	fnDir := filepath.Join(projDir, "functions")

	origWd, _ := os.Getwd()
	os.Chdir(projDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	var dockerCalled bool
	devExecCommand = func(name string, args ...string) *exec.Cmd {
		dockerCalled = true
		return exec.Command("true")
	}

	devCmd.Run(devCmd, []string{fnDir})

	if dockerCalled {
		t.Fatal("docker should not be called in dry-run mode")
	}
}

func TestDevCmdRun_BuildFlag(t *testing.T) {
	stubDevGlobals(t)
	devBuild = true

	projDir := createComposeProject(t)
	fnDir := filepath.Join(projDir, "functions")

	origWd, _ := os.Getwd()
	os.Chdir(projDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	var mu sync.Mutex
	var capturedArgs []string
	devExecCommand = func(name string, args ...string) *exec.Cmd {
		mu.Lock()
		capturedArgs = args
		mu.Unlock()
		return exec.Command("true")
	}

	devCmd.Run(devCmd, []string{fnDir})

	mu.Lock()
	defer mu.Unlock()
	found := false
	for _, a := range capturedArgs {
		if a == "--build" {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected --build in args, got %v", capturedArgs)
	}
}

func TestDevCmdRun_AbsPathError(t *testing.T) {
	stubDevGlobals(t)

	var fatalfCalled bool
	var fatalfMsg string
	devFatalf = func(format string, v ...interface{}) {
		fatalfCalled = true
		fatalfMsg = fmt.Sprintf(format, v...)
	}
	devAbsFn = func(s string) (string, error) {
		return "", errors.New("abs error")
	}

	devCmd.Run(devCmd, []string{"some-dir"})

	if !fatalfCalled {
		t.Fatalf("expected devFatalf to be called for abs path error, got msg=%q", fatalfMsg)
	}
}

func TestDevCmdRun_InvalidDir(t *testing.T) {
	stubDevGlobals(t)

	var fatalfCalled bool
	devFatalf = func(format string, v ...interface{}) {
		fatalfCalled = true
	}

	devCmd.Run(devCmd, []string{"/nonexistent/path/xxxxxx"})

	if !fatalfCalled {
		t.Fatal("expected devFatalf to be called for invalid directory")
	}
}

func TestDevCmdRun_YAMLMarshalError(t *testing.T) {
	stubDevGlobals(t)

	projDir := createComposeProject(t)
	fnDir := filepath.Join(projDir, "functions")

	origWd, _ := os.Getwd()
	os.Chdir(projDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	devYAMLMarshalFn = func(v interface{}) ([]byte, error) {
		return nil, errors.New("yaml marshal error")
	}

	var fatalfCalled bool
	devFatalf = func(format string, v ...interface{}) {
		fatalfCalled = true
		msg := fmt.Sprintf(format, v...)
		if !strings.Contains(msg, "YAML") {
			t.Fatalf("unexpected fatalf message: %s", msg)
		}
	}

	devCmd.Run(devCmd, []string{fnDir})

	if !fatalfCalled {
		t.Fatal("expected devFatalf to be called for YAML marshal error")
	}
}

func TestDevCmdRun_EnvVarPassthrough(t *testing.T) {
	stubDevGlobals(t)
	dryRun = true // dry-run so we don't need docker

	projDir := createComposeProject(t)
	fnDir := filepath.Join(projDir, "functions")

	origWd, _ := os.Getwd()
	os.Chdir(projDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	t.Setenv("FN_FORCE_URL", "1")
	t.Setenv("FN_RUNTIME_DAEMONS", "node,python")
	t.Setenv("FN_PYTHON_BIN", "/usr/bin/python3")

	devCmd.Run(devCmd, []string{fnDir})
	// If it doesn't panic/fatal, the env passthrough paths executed.
}

func TestDevCmdRun_WatcherError(t *testing.T) {
	stubDevGlobals(t)

	projDir := createComposeProject(t)
	fnDir := filepath.Join(projDir, "functions")

	origWd, _ := os.Getwd()
	os.Chdir(projDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	devStartHotReloadWatcher = func(string, string, func(string, ...interface{})) (*process.HotReloadWatcher, error) {
		return nil, errors.New("watcher error")
	}

	devExecCommand = func(name string, args ...string) *exec.Cmd {
		return exec.Command("true")
	}

	// Should warn but not fatal.
	devCmd.Run(devCmd, []string{fnDir})
}

// ---------------------------------------------------------------------------
// devCmd.Run – Native mode tests
// ---------------------------------------------------------------------------

func TestDevCmdRun_NativeWithDryRunFatals(t *testing.T) {
	stubDevGlobals(t)
	devNativeMode = true
	dryRun = true

	tmpDir := t.TempDir()

	var fatalCalled bool
	devFatal = func(v ...interface{}) {
		fatalCalled = true
		panic("devFatal called") // stop execution like real log.Fatal
	}

	func() {
		defer func() { recover() }()
		devCmd.Run(devCmd, []string{tmpDir})
	}()

	if !fatalCalled {
		t.Fatal("expected devFatal when using --dry-run with --native")
	}
}

func TestDevCmdRun_NativeWithBuildFatals(t *testing.T) {
	stubDevGlobals(t)
	devNativeMode = true
	devBuild = true

	tmpDir := t.TempDir()

	var fatalCalled bool
	devFatal = func(v ...interface{}) {
		fatalCalled = true
		panic("devFatal called") // stop execution like real log.Fatal
	}

	func() {
		defer func() { recover() }()
		devCmd.Run(devCmd, []string{tmpDir})
	}()

	if !fatalCalled {
		t.Fatal("expected devFatal when using --build with --native")
	}
}

// ---------------------------------------------------------------------------
// getFunctionDetails – empty runtime / name branches
// ---------------------------------------------------------------------------

func TestGetFunctionDetails_EmptyRuntime(t *testing.T) {
	tmpDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmpDir, "fn.config.json"), []byte(`{"name":"myfn"}`), 0644); err != nil {
		t.Fatal(err)
	}
	rt, name := getFunctionDetails(tmpDir)
	if rt != "node" {
		t.Fatalf("expected default runtime 'node', got %q", rt)
	}
	if name != "myfn" {
		t.Fatalf("expected name 'myfn', got %q", name)
	}
}

func TestGetFunctionDetails_EmptyName(t *testing.T) {
	tmpDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmpDir, "fn.config.json"), []byte(`{"runtime":"python"}`), 0644); err != nil {
		t.Fatal(err)
	}
	rt, name := getFunctionDetails(tmpDir)
	if rt != "python" {
		t.Fatalf("expected runtime 'python', got %q", rt)
	}
	if name != filepath.Base(tmpDir) {
		t.Fatalf("expected name = dir basename %q, got %q", filepath.Base(tmpDir), name)
	}
}

func TestGetFunctionDetails_BothEmpty(t *testing.T) {
	tmpDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmpDir, "fn.config.json"), []byte(`{}`), 0644); err != nil {
		t.Fatal(err)
	}
	rt, name := getFunctionDetails(tmpDir)
	if rt != "node" {
		t.Fatalf("expected default runtime 'node', got %q", rt)
	}
	if name != filepath.Base(tmpDir) {
		t.Fatalf("expected name = dir basename %q, got %q", filepath.Base(tmpDir), name)
	}
}

// ---------------------------------------------------------------------------
// scanForMounts – discovery error falls back to project root
// ---------------------------------------------------------------------------

func TestScanForMounts_DiscoveryErrorFallsBackToProjectRoot(t *testing.T) {
	tmpDir := t.TempDir()
	// Empty dir with no functions discovered -> should fall back to project root mount
	mounts := scanForMounts(tmpDir)
	if len(mounts) != 1 {
		t.Fatalf("expected 1 fallback mount, got %d: %v", len(mounts), mounts)
	}
	want := tmpDir + ":/app/srv/fn/functions"
	if mounts[0] != want {
		t.Fatalf("expected project root mount %q, got %q", want, mounts[0])
	}
}

// ---------------------------------------------------------------------------
// scanForMounts – fn.config with empty runtime/name uses defaults
// ---------------------------------------------------------------------------

func TestScanForMounts_FnConfigEmptyPathFallsBackToRoot(t *testing.T) {
	tmpDir := t.TempDir()

	// Create a fn.config.json function where the discovery will return
	// a function with HasConfig=true but Path="" (empty).
	// We do this by creating a subdirectory with fn.config.json that
	// has valid config, then use a custom discoveryScanFn to return
	// a function with empty Path.
	origScan := discoveryScanFn
	t.Cleanup(func() { discoveryScanFn = origScan })

	discoveryScanFn = func(root string, logFn discovery.Logger) ([]discovery.Function, error) {
		return []discovery.Function{
			{
				Name:      "empty-path-fn",
				Runtime:   "python",
				Path:      "", // Empty path should fall back to rootPath
				HasConfig: true,
			},
		}, nil
	}

	mounts := scanForMounts(tmpDir)
	found := false
	for _, m := range mounts {
		if strings.HasPrefix(m, tmpDir+":") && strings.Contains(m, "/app/srv/fn/functions/python/empty-path-fn") {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected mount with rootPath fallback when fn.Path is empty, got mounts: %v", mounts)
	}
}

func TestScanForMounts_FnConfigEmptyNameFallsBackToBasePath(t *testing.T) {
	tmpDir := t.TempDir()

	origScan := discoveryScanFn
	t.Cleanup(func() { discoveryScanFn = origScan })

	discoveryScanFn = func(root string, logFn discovery.Logger) ([]discovery.Function, error) {
		return []discovery.Function{
			{
				Name:      "", // Empty name should fall back to filepath.Base(fn.Path)
				Runtime:   "node",
				Path:      filepath.Join(tmpDir, "my-func"),
				HasConfig: true,
			},
		}, nil
	}

	mounts := scanForMounts(tmpDir)
	found := false
	for _, m := range mounts {
		if strings.Contains(m, "/app/srv/fn/functions/node/my-func") {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected mount with fallback name from path base, got mounts: %v", mounts)
	}
}

func TestScanForMounts_DuplicateMountSkipped(t *testing.T) {
	tmpDir := t.TempDir()

	origScan := discoveryScanFn
	t.Cleanup(func() { discoveryScanFn = origScan })

	// Return two functions that produce the same mount string.
	discoveryScanFn = func(root string, logFn discovery.Logger) ([]discovery.Function, error) {
		return []discovery.Function{
			{
				Name:      "same-fn",
				Runtime:   "node",
				Path:      filepath.Join(tmpDir, "same-fn"),
				HasConfig: true,
			},
			{
				Name:      "same-fn",
				Runtime:   "node",
				Path:      filepath.Join(tmpDir, "same-fn"),
				HasConfig: true,
			},
		}, nil
	}

	mounts := scanForMounts(tmpDir)
	count := 0
	for _, m := range mounts {
		if strings.Contains(m, "/app/srv/fn/functions/node/same-fn") {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("expected duplicate mount to be deduped (count=1), got %d; mounts=%v", count, mounts)
	}
}

func TestScanForMounts_FnConfigEmptyRuntimeDefaultsToNode(t *testing.T) {
	tmpDir := t.TempDir()
	fnDir := filepath.Join(tmpDir, "emptycfg-fn")
	if err := os.MkdirAll(fnDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fnDir, "fn.config.json"), []byte(`{"name":"emptycfg-fn"}`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fnDir, "handler.js"), []byte("exports.handler = () => {};"), 0644); err != nil {
		t.Fatal(err)
	}

	mounts := scanForMounts(tmpDir)
	found := false
	for _, m := range mounts {
		if strings.Contains(m, "/app/srv/fn/functions/node/emptycfg-fn") {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected mount with default runtime 'node', got mounts: %v", mounts)
	}
}

func TestScanForMounts_EmptyRuntimeAndNameAndPathFallbacks(t *testing.T) {
	// Test the rt="", name="", hostPath="" fallback branches in scanForMounts
	// by injecting a discoveryScanFn that returns functions with empty fields.
	tmpDir := t.TempDir()
	// Create a dir that is NOT a function leaf and NOT a runtime layout
	subDir := filepath.Join(tmpDir, "sub")
	if err := os.MkdirAll(subDir, 0755); err != nil {
		t.Fatal(err)
	}

	origScan := discoveryScanFn
	t.Cleanup(func() { discoveryScanFn = origScan })

	discoveryScanFn = func(root string, logFn discovery.Logger) ([]discovery.Function, error) {
		return []discovery.Function{
			{
				Name:      "",
				Runtime:   "",
				Path:      "",
				HasConfig: true,
			},
		}, nil
	}

	mounts := scanForMounts(tmpDir)
	// With empty runtime -> "node", empty name -> filepath.Base("") (but fn.Path is ""),
	// empty hostPath -> rootPath
	found := false
	for _, m := range mounts {
		if strings.Contains(m, tmpDir+":/app/srv/fn/functions/node/") {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected mount with fallback runtime/name/hostPath, got mounts: %v", mounts)
	}
}

func TestScanForMounts_DiscoveryScanError(t *testing.T) {
	// When discoveryScanFn returns an error, scanForMounts should fall back
	// to mountProjectRoot.
	tmpDir := t.TempDir()
	subDir := filepath.Join(tmpDir, "sub")
	if err := os.MkdirAll(subDir, 0755); err != nil {
		t.Fatal(err)
	}

	origScan := discoveryScanFn
	t.Cleanup(func() { discoveryScanFn = origScan })

	discoveryScanFn = func(root string, logFn discovery.Logger) ([]discovery.Function, error) {
		return nil, errors.New("scan error")
	}

	mounts := scanForMounts(tmpDir)
	if len(mounts) == 0 {
		t.Fatal("expected mountProjectRoot fallback")
	}
	// Should have project root mount
	if !strings.Contains(mounts[0], ":/app/srv/fn/functions") {
		t.Fatalf("unexpected mount: %v", mounts)
	}
}

func TestScanForMounts_EmptyFunctionsResult(t *testing.T) {
	// When discoveryScanFn returns empty functions, scanForMounts should
	// fall back to mountProjectRoot.
	tmpDir := t.TempDir()
	subDir := filepath.Join(tmpDir, "sub")
	if err := os.MkdirAll(subDir, 0755); err != nil {
		t.Fatal(err)
	}

	origScan := discoveryScanFn
	t.Cleanup(func() { discoveryScanFn = origScan })

	discoveryScanFn = func(root string, logFn discovery.Logger) ([]discovery.Function, error) {
		return []discovery.Function{}, nil
	}

	mounts := scanForMounts(tmpDir)
	if len(mounts) == 0 {
		t.Fatal("expected mountProjectRoot fallback for empty functions")
	}
}

func TestScanForMounts_NonExistentPath(t *testing.T) {
	mounts := scanForMounts("/nonexistent/path/that/does/not/exist")
	if mounts != nil {
		t.Fatalf("expected nil for nonexistent path, got %v", mounts)
	}
}

// ---------------------------------------------------------------------------
// devCmd.Run – config callback coverage
// ---------------------------------------------------------------------------

func TestDevCmdRun_ConfigCallbacksExecuted(t *testing.T) {
	stubDevGlobals(t)
	dryRun = true

	projDir := createComposeProject(t)
	fnDir := filepath.Join(projDir, "functions")

	origWd, _ := os.Getwd()
	os.Chdir(projDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	// Set viper config values so the apply* callbacks fire.
	t.Setenv("FN_OPENAPI_INCLUDE_INTERNAL", "")
	t.Setenv("FN_FORCE_URL", "")
	t.Setenv("FN_RUNTIME_DAEMONS", "")
	t.Setenv("FN_PYTHON_BIN", "")
	viper.Set("openapi-include-internal", true)
	viper.Set("force-url", true)
	viper.Set("runtime-daemons", "node=3")
	viper.Set("runtime-binaries", map[string]any{"python": "python3"})

	devCmd.Run(devCmd, []string{fnDir})

	if got := os.Getenv("FN_OPENAPI_INCLUDE_INTERNAL"); got != "1" {
		t.Fatalf("expected FN_OPENAPI_INCLUDE_INTERNAL=1, got %q", got)
	}
	if got := os.Getenv("FN_RUNTIME_DAEMONS"); got != "node=3" {
		t.Fatalf("expected FN_RUNTIME_DAEMONS=node=3, got %q", got)
	}
	if got := os.Getenv("FN_PYTHON_BIN"); got != "python3" {
		t.Fatalf("expected FN_PYTHON_BIN=python3, got %q", got)
	}
}

// ---------------------------------------------------------------------------
// devCmd.Run – native mode happy path
// ---------------------------------------------------------------------------

func TestDevCmdRun_NativeHappyPath(t *testing.T) {
	stubDevGlobals(t)
	devNativeMode = true

	tmpDir := t.TempDir()

	origRunner := runNativeRunner
	t.Cleanup(func() { runNativeRunner = origRunner })

	var called bool
	runNativeRunner = func(cfg process.RunConfig) error {
		called = true
		return nil
	}

	t.Setenv("FN_PUBLIC_BASE_URL", "")
	viper.Set("public-base-url", "https://api.example.com")

	devCmd.Run(devCmd, []string{tmpDir})

	if !called {
		t.Fatal("expected runNativeRunner to be called")
	}
	if got := os.Getenv("FN_PUBLIC_BASE_URL"); got != "https://api.example.com" {
		t.Fatalf("expected FN_PUBLIC_BASE_URL from config, got %q", got)
	}
}

func TestDevCmdRun_NativeRunnerError(t *testing.T) {
	stubDevGlobals(t)
	devNativeMode = true

	tmpDir := t.TempDir()

	origRunner := runNativeRunner
	t.Cleanup(func() { runNativeRunner = origRunner })

	runNativeRunner = func(cfg process.RunConfig) error {
		return errors.New("native failed")
	}

	var fatalfCalled bool
	devFatalf = func(format string, v ...interface{}) {
		fatalfCalled = true
	}

	devCmd.Run(devCmd, []string{tmpDir})

	if !fatalfCalled {
		t.Fatal("expected devFatalf when native runner fails")
	}
}

func TestDevCmdRun_NativePublicBaseURLEnvAlreadySet(t *testing.T) {
	stubDevGlobals(t)
	devNativeMode = true

	tmpDir := t.TempDir()

	origRunner := runNativeRunner
	t.Cleanup(func() { runNativeRunner = origRunner })

	runNativeRunner = func(cfg process.RunConfig) error {
		return nil
	}

	t.Setenv("FN_PUBLIC_BASE_URL", "https://from-env.com")
	viper.Set("public-base-url", "https://from-config.com")

	devCmd.Run(devCmd, []string{tmpDir})

	if got := os.Getenv("FN_PUBLIC_BASE_URL"); got != "https://from-env.com" {
		t.Fatalf("expected env to win, got %q", got)
	}
}

// ---------------------------------------------------------------------------
// devCmd.Run – Docker compose error paths
// ---------------------------------------------------------------------------

func TestDevCmdRun_InvalidComposeYAML(t *testing.T) {
	stubDevGlobals(t)

	tmpDir := t.TempDir()
	// Write invalid YAML that cannot be parsed
	os.WriteFile(filepath.Join(tmpDir, "docker-compose.yml"), []byte("\t\t invalid:\n  - :\n  [broken"), 0644)
	fnDir := filepath.Join(tmpDir, "functions")
	os.MkdirAll(fnDir, 0755)
	os.WriteFile(filepath.Join(fnDir, "get.hello.js"), []byte("module.exports = {};"), 0644)

	origWd, _ := os.Getwd()
	os.Chdir(tmpDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	var fatalfCalled bool
	devFatalf = func(format string, v ...interface{}) {
		fatalfCalled = true
		panic("devFatalf") // stop execution like real log.Fatalf
	}

	func() {
		defer func() { recover() }()
		devCmd.Run(devCmd, []string{fnDir})
	}()

	if !fatalfCalled {
		t.Fatal("expected devFatalf for invalid YAML")
	}
}

func TestDevCmdRun_ComposeNoServices(t *testing.T) {
	stubDevGlobals(t)

	tmpDir := t.TempDir()
	os.WriteFile(filepath.Join(tmpDir, "docker-compose.yml"), []byte("version: '3'\n"), 0644)
	fnDir := filepath.Join(tmpDir, "functions")
	os.MkdirAll(fnDir, 0755)
	os.WriteFile(filepath.Join(fnDir, "get.hello.js"), []byte("module.exports = {};"), 0644)

	origWd, _ := os.Getwd()
	os.Chdir(tmpDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	var fatalCalled bool
	devFatal = func(v ...interface{}) {
		fatalCalled = true
		panic("devFatal")
	}

	func() {
		defer func() { recover() }()
		devCmd.Run(devCmd, []string{fnDir})
	}()

	if !fatalCalled {
		t.Fatal("expected devFatal for missing services")
	}
}

func TestDevCmdRun_ComposeNoOpenresty(t *testing.T) {
	stubDevGlobals(t)

	tmpDir := t.TempDir()
	os.WriteFile(filepath.Join(tmpDir, "docker-compose.yml"), []byte("services:\n  web:\n    image: test\n"), 0644)
	fnDir := filepath.Join(tmpDir, "functions")
	os.MkdirAll(fnDir, 0755)
	os.WriteFile(filepath.Join(fnDir, "get.hello.js"), []byte("module.exports = {};"), 0644)

	origWd, _ := os.Getwd()
	os.Chdir(tmpDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	var fatalCalled bool
	devFatal = func(v ...interface{}) {
		fatalCalled = true
		panic("devFatal")
	}

	func() {
		defer func() { recover() }()
		devCmd.Run(devCmd, []string{fnDir})
	}()

	if !fatalCalled {
		t.Fatal("expected devFatal for missing openresty service")
	}
}

func TestDevCmdRun_DockerRunError(t *testing.T) {
	stubDevGlobals(t)

	projDir := createComposeProject(t)
	fnDir := filepath.Join(projDir, "functions")

	origWd, _ := os.Getwd()
	os.Chdir(projDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	devExecCommand = func(name string, args ...string) *exec.Cmd {
		return exec.Command("false")
	}

	var fatalfCalled bool
	devFatalf = func(format string, v ...interface{}) {
		fatalfCalled = true
	}

	devCmd.Run(devCmd, []string{fnDir})

	if !fatalfCalled {
		t.Fatal("expected devFatalf when docker run fails")
	}
}

func TestDevCmdRun_EnvMapNilBranch_ForceURL(t *testing.T) {
	stubDevGlobals(t)
	dryRun = true

	tmpDir := t.TempDir()
	// Compose with no environment key at all on openresty
	composeContent := `services:
  openresty:
    image: test
    volumes:
      - /old/path:/app/srv/fn/functions
`
	os.WriteFile(filepath.Join(tmpDir, "docker-compose.yml"), []byte(composeContent), 0644)
	fnDir := filepath.Join(tmpDir, "functions")
	os.MkdirAll(fnDir, 0755)
	os.WriteFile(filepath.Join(fnDir, "get.hello.js"), []byte("module.exports = {};"), 0644)

	origWd, _ := os.Getwd()
	os.Chdir(tmpDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	// Only FN_FORCE_URL triggers the first nil env map branch
	t.Setenv("FN_FORCE_URL", "1")
	t.Setenv("FN_RUNTIME_DAEMONS", "")
	t.Setenv("FN_NODE_BIN", "")

	devCmd.Run(devCmd, []string{fnDir})
}

func TestDevCmdRun_EnvMapNilBranch_RuntimeDaemons(t *testing.T) {
	stubDevGlobals(t)
	dryRun = true

	tmpDir := t.TempDir()
	// Compose with environment key that has an integer value (not a map)
	// to ensure the nil branch is hit for FN_RUNTIME_DAEMONS
	composeContent := `services:
  openresty:
    image: test
    environment: null
    volumes:
      - /old/path:/app/srv/fn/functions
`
	os.WriteFile(filepath.Join(tmpDir, "docker-compose.yml"), []byte(composeContent), 0644)
	fnDir := filepath.Join(tmpDir, "functions")
	os.MkdirAll(fnDir, 0755)
	os.WriteFile(filepath.Join(fnDir, "get.hello.js"), []byte("module.exports = {};"), 0644)

	origWd, _ := os.Getwd()
	os.Chdir(tmpDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	t.Setenv("FN_FORCE_URL", "")
	t.Setenv("FN_RUNTIME_DAEMONS", "node")
	t.Setenv("FN_NODE_BIN", "")

	devCmd.Run(devCmd, []string{fnDir})
}

func TestDevCmdRun_EnvMapNilBranch_BinaryEnv(t *testing.T) {
	stubDevGlobals(t)
	dryRun = true

	tmpDir := t.TempDir()
	composeContent := `services:
  openresty:
    image: test
    environment: null
    volumes:
      - /old/path:/app/srv/fn/functions
`
	os.WriteFile(filepath.Join(tmpDir, "docker-compose.yml"), []byte(composeContent), 0644)
	fnDir := filepath.Join(tmpDir, "functions")
	os.MkdirAll(fnDir, 0755)
	os.WriteFile(filepath.Join(fnDir, "get.hello.js"), []byte("module.exports = {};"), 0644)

	origWd, _ := os.Getwd()
	os.Chdir(tmpDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	t.Setenv("FN_FORCE_URL", "")
	t.Setenv("FN_RUNTIME_DAEMONS", "")
	t.Setenv("FN_NODE_BIN", "/usr/bin/node")

	devCmd.Run(devCmd, []string{fnDir})
}

func TestDevCmdRun_ComposeProjectRootFromAbsPath(t *testing.T) {
	stubDevGlobals(t)
	dryRun = true

	// Create a project with compose in the functions parent
	projDir := createComposeProject(t)
	fnDir := filepath.Join(projDir, "functions")

	// chdir to a directory WITHOUT docker-compose.yml so findProjectRoot from cwd fails
	// but findProjectRoot from absPath succeeds
	noDockDir := t.TempDir()
	origWd, _ := os.Getwd()
	os.Chdir(noDockDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	devCmd.Run(devCmd, []string{fnDir})
	// This exercises the projectRoot == "" branch (line 144-145)
}

func TestDevCmdRun_ComposeProjectRootElseBranch(t *testing.T) {
	stubDevGlobals(t)
	dryRun = true

	// Create a project root with compose and chdir there.
	// The else branch (projectRoot != "") triggers err = nil.
	projDir := createComposeProject(t)
	fnDir := filepath.Join(projDir, "functions")

	origWd, _ := os.Getwd()
	os.Chdir(projDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	devCmd.Run(devCmd, []string{fnDir})
}

func TestDevCmdRun_ForceURLSetsEnv(t *testing.T) {
	stubDevGlobals(t)
	dryRun = true
	devForceURL = true

	projDir := createComposeProject(t)
	fnDir := filepath.Join(projDir, "functions")

	origWd, _ := os.Getwd()
	os.Chdir(projDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	t.Setenv("FN_FORCE_URL", "")

	devCmd.Run(devCmd, []string{fnDir})

	if got := os.Getenv("FN_FORCE_URL"); got != "1" {
		t.Fatalf("expected FN_FORCE_URL=1, got %q", got)
	}
}

// Note: Compose read error is difficult to test reliably due to file ownership
// and the findProjectRoot fallback. The error path is covered by the
// invalid YAML test instead.

func TestDevCmdRun_ComposeNoVolumesKey(t *testing.T) {
	stubDevGlobals(t)
	dryRun = true

	tmpDir := t.TempDir()
	// Compose with openresty but no volumes key
	composeContent := `services:
  openresty:
    image: test
`
	os.WriteFile(filepath.Join(tmpDir, "docker-compose.yml"), []byte(composeContent), 0644)
	fnDir := filepath.Join(tmpDir, "functions")
	os.MkdirAll(fnDir, 0755)
	os.WriteFile(filepath.Join(fnDir, "get.hello.js"), []byte("module.exports = {};"), 0644)

	origWd, _ := os.Getwd()
	os.Chdir(tmpDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	devCmd.Run(devCmd, []string{fnDir})
	// Exercises the volumes !ok branch (line 204-206)
}

func TestDevCmdRun_WatcherCallbackInvoked(t *testing.T) {
	stubDevGlobals(t)

	projDir := createComposeProject(t)
	fnDir := filepath.Join(projDir, "functions")

	origWd, _ := os.Getwd()
	os.Chdir(projDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	// Override watcher to capture and invoke the logFn callback
	devStartHotReloadWatcher = func(dir, url string, logFn func(string, ...interface{})) (*process.HotReloadWatcher, error) {
		// Invoke the callback to cover the anonymous function on line 289-291
		logFn("test %s", "message")
		return nil, nil
	}

	devExecCommand = func(name string, args ...string) *exec.Cmd {
		return exec.Command("true")
	}

	devCmd.Run(devCmd, []string{fnDir})
}

// TestDevCmdRun_PortableMode covers the portable mode branch (lines 155-176)
// when no docker-compose.yml is found anywhere.
func TestDevCmdRun_PortableMode(t *testing.T) {
	stubDevGlobals(t)

	// Create a temp dir with functions but NO docker-compose.yml
	tmpDir := t.TempDir()
	fnDir := filepath.Join(tmpDir, "functions")
	os.MkdirAll(fnDir, 0755)
	os.WriteFile(filepath.Join(fnDir, "get.hello.js"), []byte("module.exports = {};"), 0644)

	// Change wd to a dir without compose file
	origWd, _ := os.Getwd()
	os.Chdir(tmpDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	var fatalMsg string
	devFatal = func(v ...interface{}) {
		fatalMsg = fmt.Sprint(v...)
		panic("devFatal called")
	}

	func() {
		defer func() { recover() }()
		devCmd.Run(devCmd, []string{fnDir})
	}()

	if fatalMsg == "" {
		t.Fatal("expected devFatal to be called for portable mode")
	}
	if !strings.Contains(fatalMsg, "Portable mode") {
		t.Fatalf("expected portable mode message, got %q", fatalMsg)
	}
}

// TestDevCmdRun_ComposeReadError covers line 182-184 when docker-compose.yml
// exists but cannot be read.
func TestDevCmdRun_ComposeReadError(t *testing.T) {
	stubDevGlobals(t)

	projDir := createComposeProject(t)
	fnDir := filepath.Join(projDir, "functions")

	origWd, _ := os.Getwd()
	os.Chdir(projDir)
	t.Cleanup(func() { os.Chdir(origWd) })

	// Make docker-compose.yml unreadable
	composePath := filepath.Join(projDir, "docker-compose.yml")
	os.Chmod(composePath, 0000)
	t.Cleanup(func() { os.Chmod(composePath, 0644) })

	var fatalfCalled bool
	devFatalf = func(format string, v ...interface{}) {
		fatalfCalled = true
		panic("devFatalf called")
	}

	func() {
		defer func() { recover() }()
		devCmd.Run(devCmd, []string{fnDir})
	}()

	if !fatalfCalled {
		t.Fatal("expected devFatalf to be called for compose read error")
	}
}
