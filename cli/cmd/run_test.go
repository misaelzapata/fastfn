package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/misaelzapata/fastfn/cli/internal/process"
	"github.com/spf13/viper"
)

func TestResolveRunTargetDir_DefaultCurrentDirectory(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()

	got := resolveRunTargetDir(nil)
	if got != "." {
		t.Fatalf("resolveRunTargetDir(nil) = %q, want %q", got, ".")
	}
}

func TestResolveRunTargetDir_UsesConfigWhenNoArgs(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	viper.Set("functions-dir", "examples/functions/next-style")

	got := resolveRunTargetDir(nil)
	if got != "examples/functions/next-style" {
		t.Fatalf("resolveRunTargetDir(nil) = %q, want configured path", got)
	}
}

func TestResolveRunTargetDir_ArgWinsOverConfig(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	viper.Set("functions-dir", "examples/functions/next-style")

	got := resolveRunTargetDir([]string{"custom/path"})
	if got != "custom/path" {
		t.Fatalf("resolveRunTargetDir(arg) = %q, want arg path", got)
	}
}

func saveRunGlobals(t *testing.T) {
	t.Helper()
	origRunner := runProcessRunner
	origFatalf := runFatalf
	origFatal := runFatal
	origAbs := runAbsFn
	origNative := runNativeMode
	origForce := runForceURL
	origHotReload := runHotReload
	t.Cleanup(func() {
		runProcessRunner = origRunner
		runFatalf = origFatalf
		runFatal = origFatal
		runAbsFn = origAbs
		runNativeMode = origNative
		runForceURL = origForce
		runHotReload = origHotReload
		viper.Reset()
	})
}

func TestRunCmd_NativeMode_HappyPath(t *testing.T) {
	saveRunGlobals(t)
	viper.Reset()

	tmpDir := t.TempDir()
	runNativeMode = true
	runForceURL = false

	var captured process.RunConfig
	runProcessRunner = func(cfg process.RunConfig) error {
		captured = cfg
		return nil
	}
	runFatalf = func(format string, args ...interface{}) {
		t.Fatalf("unexpected fatalf: "+format, args...)
	}
	runFatal = func(args ...interface{}) {
		t.Fatalf("unexpected fatal: %v", args)
	}
	runAbsFn = filepath.Abs

	runCmd.Run(runCmd, []string{tmpDir})

	if !captured.VerifyTLS {
		t.Error("expected VerifyTLS=true")
	}
	if !captured.HotReload {
		t.Error("expected HotReload=true (default)")
	}
	if !captured.Watch {
		t.Error("expected Watch=true (follows HotReload)")
	}
}

func TestRunCmd_NativeMode_ProcessError(t *testing.T) {
	saveRunGlobals(t)
	viper.Reset()

	tmpDir := t.TempDir()
	runNativeMode = true
	runForceURL = false

	runProcessRunner = func(cfg process.RunConfig) error {
		return fmt.Errorf("process failed")
	}
	var fatalfCalled bool
	runFatalf = func(format string, args ...interface{}) {
		fatalfCalled = true
	}
	runFatal = func(args ...interface{}) {}
	runAbsFn = filepath.Abs

	runCmd.Run(runCmd, []string{tmpDir})

	if !fatalfCalled {
		t.Error("expected fatalf when process runner fails")
	}
}

func TestRunCmd_DockerModeNotSupported(t *testing.T) {
	saveRunGlobals(t)
	viper.Reset()

	tmpDir := t.TempDir()
	runNativeMode = false
	runForceURL = false

	var fatalMsg string
	runFatal = func(args ...interface{}) {
		fatalMsg = fmt.Sprint(args...)
	}
	runFatalf = func(format string, args ...interface{}) {}
	runAbsFn = filepath.Abs

	runCmd.Run(runCmd, []string{tmpDir})

	if !strings.Contains(fatalMsg, "Docker production mode") {
		t.Fatalf("expected Docker mode message, got %q", fatalMsg)
	}
}

func TestRunCmd_AbsPathError(t *testing.T) {
	saveRunGlobals(t)
	viper.Reset()

	runNativeMode = true
	runForceURL = false

	runAbsFn = func(path string) (string, error) {
		return "", fmt.Errorf("abs failed")
	}
	var fatalfCalled bool
	runFatalf = func(format string, args ...interface{}) {
		fatalfCalled = true
	}
	runFatal = func(args ...interface{}) {}

	runCmd.Run(runCmd, []string{"some/dir"})

	if !fatalfCalled {
		t.Error("expected fatalf when Abs fails")
	}
}

func TestRunCmd_MissingDirectory(t *testing.T) {
	saveRunGlobals(t)
	viper.Reset()

	runNativeMode = true
	runForceURL = false

	var fatalfMsgs []string
	runFatalf = func(format string, args ...interface{}) {
		fatalfMsgs = append(fatalfMsgs, fmt.Sprintf(format, args...))
	}
	runFatal = func(args ...interface{}) {}
	runAbsFn = filepath.Abs
	// Stub runner so it doesn't actually start services
	runProcessRunner = func(cfg process.RunConfig) error { return nil }

	runCmd.Run(runCmd, []string{"/tmp/fastfn-nonexistent-dir-" + t.Name()})

	found := false
	for _, msg := range fatalfMsgs {
		if strings.Contains(msg, "Directory not found") {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected 'Directory not found' in fatalf messages, got %v", fatalfMsgs)
	}
}

func TestRunCmd_ForceURLSetsEnv(t *testing.T) {
	saveRunGlobals(t)
	viper.Reset()

	tmpDir := t.TempDir()
	runNativeMode = true
	runForceURL = true

	runProcessRunner = func(cfg process.RunConfig) error { return nil }
	runFatalf = func(format string, args ...interface{}) {}
	runFatal = func(args ...interface{}) {}
	runAbsFn = filepath.Abs

	t.Setenv("FN_FORCE_URL", "")
	runCmd.Run(runCmd, []string{tmpDir})

	if got := os.Getenv("FN_FORCE_URL"); got != "1" {
		t.Fatalf("FN_FORCE_URL = %q, want %q", got, "1")
	}
}

func TestRunCmd_PublicBaseURLFromConfig(t *testing.T) {
	saveRunGlobals(t)
	viper.Reset()
	viper.Set("public-base-url", "https://api.example.com")

	tmpDir := t.TempDir()
	runNativeMode = true
	runForceURL = false

	runProcessRunner = func(cfg process.RunConfig) error { return nil }
	runFatalf = func(format string, args ...interface{}) {}
	runFatal = func(args ...interface{}) {}
	runAbsFn = filepath.Abs

	t.Setenv("FN_PUBLIC_BASE_URL", "")
	runCmd.Run(runCmd, []string{tmpDir})

	if got := os.Getenv("FN_PUBLIC_BASE_URL"); got != "https://api.example.com" {
		t.Fatalf("FN_PUBLIC_BASE_URL = %q, want config value", got)
	}
}

func TestRunCmd_PublicBaseURLEnvWins(t *testing.T) {
	saveRunGlobals(t)
	viper.Reset()
	viper.Set("public-base-url", "https://from-config.com")

	tmpDir := t.TempDir()
	runNativeMode = true
	runForceURL = false

	runProcessRunner = func(cfg process.RunConfig) error { return nil }
	runFatalf = func(format string, args ...interface{}) {}
	runFatal = func(args ...interface{}) {}
	runAbsFn = filepath.Abs

	t.Setenv("FN_PUBLIC_BASE_URL", "https://from-env.com")
	runCmd.Run(runCmd, []string{tmpDir})

	if got := os.Getenv("FN_PUBLIC_BASE_URL"); got != "https://from-env.com" {
		t.Fatalf("FN_PUBLIC_BASE_URL = %q, want env value", got)
	}
}

// ---------------------------------------------------------------------------
// runCmd.Run – hot reload tests
// ---------------------------------------------------------------------------

func TestRunCmd_HotReloadDefaultEnabled(t *testing.T) {
	saveRunGlobals(t)
	viper.Reset()

	tmpDir := t.TempDir()
	runNativeMode = true
	runForceURL = false
	runHotReload = false

	var captured process.RunConfig
	runProcessRunner = func(cfg process.RunConfig) error {
		captured = cfg
		return nil
	}
	runFatalf = func(format string, args ...interface{}) {}
	runFatal = func(args ...interface{}) {}
	runAbsFn = filepath.Abs

	t.Setenv("FN_HOT_RELOAD", "")
	runCmd.Run(runCmd, []string{tmpDir})

	if !captured.HotReload {
		t.Error("expected HotReload=true by default")
	}
	if !captured.Watch {
		t.Error("expected Watch=true by default")
	}
}

func TestRunCmd_HotReloadDisabledByEnv(t *testing.T) {
	saveRunGlobals(t)
	viper.Reset()

	tmpDir := t.TempDir()
	runNativeMode = true
	runForceURL = false
	runHotReload = false

	var captured process.RunConfig
	runProcessRunner = func(cfg process.RunConfig) error {
		captured = cfg
		return nil
	}
	runFatalf = func(format string, args ...interface{}) {}
	runFatal = func(args ...interface{}) {}
	runAbsFn = filepath.Abs

	t.Setenv("FN_HOT_RELOAD", "0")
	runCmd.Run(runCmd, []string{tmpDir})

	if captured.HotReload {
		t.Error("expected HotReload=false when FN_HOT_RELOAD=0")
	}
	if captured.Watch {
		t.Error("expected Watch=false when FN_HOT_RELOAD=0")
	}
}

func TestRunCmd_HotReloadDisabledByConfig(t *testing.T) {
	saveRunGlobals(t)
	viper.Reset()
	viper.Set("hot-reload", false)

	tmpDir := t.TempDir()
	runNativeMode = true
	runForceURL = false
	runHotReload = false

	var captured process.RunConfig
	runProcessRunner = func(cfg process.RunConfig) error {
		captured = cfg
		return nil
	}
	runFatalf = func(format string, args ...interface{}) {}
	runFatal = func(args ...interface{}) {}
	runAbsFn = filepath.Abs

	t.Setenv("FN_HOT_RELOAD", "")
	runCmd.Run(runCmd, []string{tmpDir})

	if captured.HotReload {
		t.Error("expected HotReload=false when config hot-reload=false")
	}
}

func TestRunCmd_HotReloadFlagOverridesEnv(t *testing.T) {
	saveRunGlobals(t)
	viper.Reset()

	tmpDir := t.TempDir()
	runNativeMode = true
	runForceURL = false
	runHotReload = true

	var captured process.RunConfig
	runProcessRunner = func(cfg process.RunConfig) error {
		captured = cfg
		return nil
	}
	runFatalf = func(format string, args ...interface{}) {}
	runFatal = func(args ...interface{}) {}
	runAbsFn = filepath.Abs

	t.Setenv("FN_HOT_RELOAD", "0")
	runCmd.Run(runCmd, []string{tmpDir})

	if !captured.HotReload {
		t.Error("expected HotReload=true when --hot-reload flag is set")
	}
}

func TestRunCmd_HotReloadEnvFalseVariants(t *testing.T) {
	saveRunGlobals(t)

	for _, val := range []string{"false", "off", "no"} {
		viper.Reset()
		tmpDir := t.TempDir()
		runNativeMode = true
		runForceURL = false
		runHotReload = false

		var captured process.RunConfig
		runProcessRunner = func(cfg process.RunConfig) error {
			captured = cfg
			return nil
		}
		runFatalf = func(format string, args ...interface{}) {}
		runFatal = func(args ...interface{}) {}
		runAbsFn = filepath.Abs

		t.Setenv("FN_HOT_RELOAD", val)
		runCmd.Run(runCmd, []string{tmpDir})

		if captured.HotReload {
			t.Errorf("expected HotReload=false for FN_HOT_RELOAD=%q", val)
		}
	}
}

// ---------------------------------------------------------------------------
// runCmd.Run – config callback coverage
// ---------------------------------------------------------------------------

func TestRunCmd_ConfigCallbacksExecuted(t *testing.T) {
	saveRunGlobals(t)
	viper.Reset()

	tmpDir := t.TempDir()
	runNativeMode = true
	runForceURL = false

	runProcessRunner = func(cfg process.RunConfig) error { return nil }
	runFatalf = func(format string, args ...interface{}) {}
	runFatal = func(args ...interface{}) {}
	runAbsFn = filepath.Abs

	// Set viper config values so the apply* callbacks fire.
	t.Setenv("FN_OPENAPI_INCLUDE_INTERNAL", "")
	t.Setenv("FN_FORCE_URL", "")
	t.Setenv("FN_RUNTIME_DAEMONS", "")
	t.Setenv("FN_PYTHON_BIN", "")
	viper.Set("openapi-include-internal", true)
	viper.Set("force-url", true)
	viper.Set("runtime-daemons", "node=3")
	viper.Set("runtime-binaries", map[string]any{"python": "python3"})

	runCmd.Run(runCmd, []string{tmpDir})

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
