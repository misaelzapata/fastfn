package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/viper"
)

func TestConfiguredOpenAPIIncludeInternal_DefaultUnset(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()

	got, ok := configuredOpenAPIIncludeInternal()
	if ok {
		t.Fatalf("expected unset key to return ok=false, got true with value=%v", got)
	}
}

func TestConfiguredOpenAPIIncludeInternal_TopLevelKey(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	viper.Set("openapi-include-internal", true)

	got, ok := configuredOpenAPIIncludeInternal()
	if !ok {
		t.Fatalf("expected openapi-include-internal to be detected")
	}
	if !got {
		t.Fatalf("expected openapi-include-internal=true")
	}
}

func TestConfiguredOpenAPIIncludeInternal_NestedKey(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	viper.Set("openapi.include_internal", true)

	got, ok := configuredOpenAPIIncludeInternal()
	if !ok {
		t.Fatalf("expected openapi.include_internal to be detected")
	}
	if !got {
		t.Fatalf("expected openapi.include_internal=true")
	}
}

func TestBoolEnvValue(t *testing.T) {
	if got := boolEnvValue(true); got != "1" {
		t.Fatalf("boolEnvValue(true) = %q, want %q", got, "1")
	}
	if got := boolEnvValue(false); got != "0" {
		t.Fatalf("boolEnvValue(false) = %q, want %q", got, "0")
	}
}

func TestConfiguredOpenAPIIncludeInternal_FromJSONConfigFile(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()

	tmpDir := t.TempDir()
	cfgPath := filepath.Join(tmpDir, "fastfn.json")
	if err := os.WriteFile(cfgPath, []byte("{\"openapi-include-internal\":true}"), 0644); err != nil {
		t.Fatalf("write temp config: %v", err)
	}

	oldCfgFile := cfgFile
	cfgFile = cfgPath
	t.Cleanup(func() {
		cfgFile = oldCfgFile
	})

	initConfig()
	got, ok := configuredOpenAPIIncludeInternal()
	if !ok {
		t.Fatalf("expected openapi-include-internal from JSON config to be detected")
	}
	if !got {
		t.Fatalf("expected openapi-include-internal=true from JSON config")
	}
}

func TestApplyConfiguredOpenAPIIncludeInternal_FromConfig(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	t.Setenv("FN_OPENAPI_INCLUDE_INTERNAL", "")
	viper.Set("openapi-include-internal", true)

	applied := false
	applyConfiguredOpenAPIIncludeInternal(func(value bool) {
		applied = value
	})

	if !applied {
		t.Fatalf("expected callback applied=true")
	}
	if got := os.Getenv("FN_OPENAPI_INCLUDE_INTERNAL"); got != "1" {
		t.Fatalf("expected env from config to be 1, got %q", got)
	}
}

func TestApplyConfiguredOpenAPIIncludeInternal_EnvWins(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	t.Setenv("FN_OPENAPI_INCLUDE_INTERNAL", "0")
	viper.Set("openapi-include-internal", true)

	called := false
	applyConfiguredOpenAPIIncludeInternal(func(bool) {
		called = true
	})

	if called {
		t.Fatalf("did not expect callback when env var is already set")
	}
	if got := os.Getenv("FN_OPENAPI_INCLUDE_INTERNAL"); got != "0" {
		t.Fatalf("expected existing env to win, got %q", got)
	}
}

func TestConfiguredForceURL_DefaultUnset(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()

	got, ok := configuredForceURL()
	if ok {
		t.Fatalf("expected unset key to return ok=false, got true with value=%v", got)
	}
}

func TestConfiguredForceURL_TopLevelKey(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	viper.Set("force-url", true)

	got, ok := configuredForceURL()
	if !ok {
		t.Fatalf("expected force-url to be detected")
	}
	if !got {
		t.Fatalf("expected force-url=true")
	}
}

func TestApplyConfiguredForceURL_FromConfig(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	t.Setenv("FN_FORCE_URL", "")
	viper.Set("force-url", true)

	applied := false
	applyConfiguredForceURL(func(value bool) {
		applied = value
	})

	if !applied {
		t.Fatalf("expected callback applied=true")
	}
	if got := os.Getenv("FN_FORCE_URL"); got != "1" {
		t.Fatalf("expected env from config to be 1, got %q", got)
	}
}

func TestApplyConfiguredForceURL_EnvWins(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	t.Setenv("FN_FORCE_URL", "0")
	viper.Set("force-url", true)

	called := false
	applyConfiguredForceURL(func(bool) {
		called = true
	})

	if called {
		t.Fatalf("did not expect callback when env var is already set")
	}
	if got := os.Getenv("FN_FORCE_URL"); got != "0" {
		t.Fatalf("expected existing env to win, got %q", got)
	}
}

func TestConfiguredRuntimeDaemons_TopLevelString(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	viper.Set("runtime-daemons", "node=3,python=2")

	got, ok := configuredRuntimeDaemons()
	if !ok {
		t.Fatalf("expected runtime-daemons to be detected")
	}
	if got != "node=3,python=2" {
		t.Fatalf("configuredRuntimeDaemons = %q", got)
	}
}

func TestConfiguredRuntimeDaemons_MapCanonicalized(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	viper.Set("runtime-daemons", map[string]any{
		"python": 2,
		"node":   3,
		"lua":    1,
	})

	got, ok := configuredRuntimeDaemons()
	if !ok {
		t.Fatalf("expected runtime-daemons map to be detected")
	}
	if got != "node=3,python=2,lua=1" {
		t.Fatalf("configuredRuntimeDaemons map = %q", got)
	}
}

func TestConfiguredRuntimeDaemons_FromJSONConfigFile(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()

	tmpDir := t.TempDir()
	cfgPath := filepath.Join(tmpDir, "fastfn.json")
	if err := os.WriteFile(cfgPath, []byte(`{"runtime-daemons":{"node":3,"python":2}}`), 0o644); err != nil {
		t.Fatalf("write temp config: %v", err)
	}

	oldCfgFile := cfgFile
	cfgFile = cfgPath
	t.Cleanup(func() {
		cfgFile = oldCfgFile
	})

	initConfig()
	got, ok := configuredRuntimeDaemons()
	if !ok {
		t.Fatalf("expected runtime-daemons from JSON config to be detected")
	}
	if got != "node=3,python=2" {
		t.Fatalf("configuredRuntimeDaemons from file = %q", got)
	}
}

func TestConfiguredImageWorkloads_FromConfig(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	viper.Set("apps", map[string]any{
		"admin": map[string]any{
			"image":  "ghcr.io/acme/admin:latest",
			"port":   3000,
			"routes": []string{"/admin/*"},
		},
	})
	viper.Set("services", map[string]any{
		"mysql": map[string]any{
			"image":  "mysql:8.4",
			"port":   3306,
			"volume": "mysql-data",
		},
	})

	cfg, ok, err := configuredImageWorkloads()
	if err != nil {
		t.Fatalf("configuredImageWorkloads() error = %v", err)
	}
	if !ok {
		t.Fatalf("expected image workloads to be detected")
	}
	if len(cfg.Apps) != 1 || cfg.Apps[0].Name != "admin" {
		t.Fatalf("unexpected apps config: %+v", cfg.Apps)
	}
	if len(cfg.Services) != 1 || cfg.Services[0].Name != "mysql" {
		t.Fatalf("unexpected services config: %+v", cfg.Services)
	}
}

func TestApplyConfiguredRuntimeDaemons_FromConfig(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	t.Setenv("FN_RUNTIME_DAEMONS", "")
	viper.Set("runtime-daemons", map[string]any{
		"node":   3,
		"python": 2,
	})

	applied := ""
	applyConfiguredRuntimeDaemons(func(value string) {
		applied = value
	})

	if applied != "node=3,python=2" {
		t.Fatalf("callback value = %q", applied)
	}
	if got := os.Getenv("FN_RUNTIME_DAEMONS"); got != "node=3,python=2" {
		t.Fatalf("expected env from config to be node=3,python=2, got %q", got)
	}
}

func TestApplyConfiguredRuntimeDaemons_EnvWins(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	t.Setenv("FN_RUNTIME_DAEMONS", "node=4")
	viper.Set("runtime-daemons", "node=3,python=2")

	called := false
	applyConfiguredRuntimeDaemons(func(string) {
		called = true
	})

	if called {
		t.Fatalf("did not expect callback when env var is already set")
	}
	if got := os.Getenv("FN_RUNTIME_DAEMONS"); got != "node=4" {
		t.Fatalf("expected existing env to win, got %q", got)
	}
}

func TestConfiguredRuntimeBinaries_Map(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	viper.Set("runtime-binaries", map[string]any{
		"python": "python",
		"node":   "node18",
		"php":    "php8.3",
	})

	got, ok := configuredRuntimeBinaries()
	if !ok {
		t.Fatalf("expected runtime-binaries to be detected")
	}
	if got["FN_PYTHON_BIN"] != "python" {
		t.Fatalf("FN_PYTHON_BIN = %q", got["FN_PYTHON_BIN"])
	}
	if got["FN_NODE_BIN"] != "node18" {
		t.Fatalf("FN_NODE_BIN = %q", got["FN_NODE_BIN"])
	}
	if got["FN_PHP_BIN"] != "php8.3" {
		t.Fatalf("FN_PHP_BIN = %q", got["FN_PHP_BIN"])
	}
}

func TestConfiguredRuntimeBinaries_FromJSONConfigFile(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()

	tmpDir := t.TempDir()
	cfgPath := filepath.Join(tmpDir, "fastfn.json")
	if err := os.WriteFile(cfgPath, []byte(`{"runtime-binaries":{"python":"python","node":"node18"}}`), 0o644); err != nil {
		t.Fatalf("write temp config: %v", err)
	}

	oldCfgFile := cfgFile
	cfgFile = cfgPath
	t.Cleanup(func() {
		cfgFile = oldCfgFile
	})

	initConfig()
	got, ok := configuredRuntimeBinaries()
	if !ok {
		t.Fatalf("expected runtime-binaries from JSON config to be detected")
	}
	if got["FN_PYTHON_BIN"] != "python" || got["FN_NODE_BIN"] != "node18" {
		t.Fatalf("configuredRuntimeBinaries from file = %#v", got)
	}
}

func TestApplyConfiguredRuntimeBinaries_FromConfig(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	for _, envVar := range []string{"FN_PYTHON_BIN", "FN_NODE_BIN", "FN_PHP_BIN"} {
		t.Setenv(envVar, "")
	}
	viper.Set("runtime-binaries", map[string]any{
		"python": "python",
		"node":   "node18",
		"php":    "php8.3",
	})

	applied := map[string]string{}
	applyConfiguredRuntimeBinaries(func(envVar, value string) {
		applied[envVar] = value
	})

	if applied["FN_PYTHON_BIN"] != "python" {
		t.Fatalf("callback FN_PYTHON_BIN = %q", applied["FN_PYTHON_BIN"])
	}
	if got := os.Getenv("FN_NODE_BIN"); got != "node18" {
		t.Fatalf("FN_NODE_BIN = %q", got)
	}
	if got := os.Getenv("FN_PHP_BIN"); got != "php8.3" {
		t.Fatalf("FN_PHP_BIN = %q", got)
	}
}

func TestApplyConfiguredRuntimeBinaries_EnvWinsPerKey(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	t.Setenv("FN_PYTHON_BIN", "python3.12")
	t.Setenv("FN_NODE_BIN", "")
	viper.Set("runtime-binaries", map[string]any{
		"python": "python",
		"node":   "node18",
	})

	applied := map[string]string{}
	applyConfiguredRuntimeBinaries(func(envVar, value string) {
		applied[envVar] = value
	})

	if _, ok := applied["FN_PYTHON_BIN"]; ok {
		t.Fatalf("did not expect FN_PYTHON_BIN callback when env already set")
	}
	if got := os.Getenv("FN_PYTHON_BIN"); got != "python3.12" {
		t.Fatalf("FN_PYTHON_BIN = %q", got)
	}
	if got := os.Getenv("FN_NODE_BIN"); got != "node18" {
		t.Fatalf("FN_NODE_BIN = %q", got)
	}
}

func TestInitConfig_ExplicitFileError(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()

	oldCfgFile := cfgFile
	oldExitFn := exitFn
	t.Cleanup(func() {
		cfgFile = oldCfgFile
		exitFn = oldExitFn
	})

	cfgFile = "/nonexistent/path/fastfn.json"
	exitCalled := false
	exitFn = func(code int) {
		exitCalled = true
	}

	initConfig()
	if !exitCalled {
		t.Fatalf("expected exit to be called when explicit config file is missing")
	}
}

func TestInitConfig_TOMLFallback(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()

	tmpDir := t.TempDir()
	oldWd, _ := os.Getwd()
	defer os.Chdir(oldWd)
	os.Chdir(tmpDir)

	oldCfgFile := cfgFile
	t.Cleanup(func() {
		cfgFile = oldCfgFile
	})
	cfgFile = ""

	// Create only a TOML file
	if err := os.WriteFile(filepath.Join(tmpDir, "fastfn.toml"), []byte("[test]\nkey = \"value\"\n"), 0o644); err != nil {
		t.Fatalf("write toml: %v", err)
	}

	initConfig()

	if viper.GetString("test.key") != "value" {
		t.Fatalf("expected TOML fallback to read test.key, got %q", viper.GetString("test.key"))
	}
}

func TestNormalizeRuntimeDaemonConfigValue_Nil(t *testing.T) {
	_, ok := normalizeRuntimeDaemonConfigValue(nil)
	if ok {
		t.Fatalf("expected nil to return ok=false")
	}
}

func TestNormalizeRuntimeDaemonConfigValue_EmptyString(t *testing.T) {
	_, ok := normalizeRuntimeDaemonConfigValue("")
	if ok {
		t.Fatalf("expected empty string to return ok=false")
	}
}

func TestNormalizeRuntimeDaemonConfigValue_EmptyMap(t *testing.T) {
	_, ok := normalizeRuntimeDaemonConfigValue(map[string]any{})
	if ok {
		t.Fatalf("expected empty map to return ok=false")
	}
}

func TestNormalizeRuntimeDaemonConfigValue_MapAnyAny(t *testing.T) {
	raw := map[any]any{
		"node":   3,
		"python": 2,
	}
	got, ok := normalizeRuntimeDaemonConfigValue(raw)
	if !ok {
		t.Fatalf("expected map[any]any to be handled")
	}
	if got != "node=3,python=2" {
		t.Fatalf("normalizeRuntimeDaemonConfigValue(map[any]any) = %q", got)
	}
}

func TestNormalizeRuntimeDaemonConfigValue_InvalidType(t *testing.T) {
	_, ok := normalizeRuntimeDaemonConfigValue(42)
	if ok {
		t.Fatalf("expected int to return ok=false")
	}
}

func TestNormalizeRuntimeDaemonConfigValue_StringCount(t *testing.T) {
	raw := map[string]any{
		"node": "3",
	}
	got, ok := normalizeRuntimeDaemonConfigValue(raw)
	if !ok {
		t.Fatalf("expected string count to be parsed")
	}
	if got != "node=3" {
		t.Fatalf("normalizeRuntimeDaemonConfigValue(string count) = %q", got)
	}
}

func TestNormalizeRuntimeDaemonConfigValue_InvalidStringCount(t *testing.T) {
	raw := map[string]any{
		"node": "abc",
	}
	_, ok := normalizeRuntimeDaemonConfigValue(raw)
	if ok {
		t.Fatalf("expected invalid string count to return ok=false")
	}
}

func TestNormalizeRuntimeDaemonConfigValue_ZeroCount(t *testing.T) {
	raw := map[string]any{
		"node": 0,
	}
	_, ok := normalizeRuntimeDaemonConfigValue(raw)
	if ok {
		t.Fatalf("expected zero count to return ok=false")
	}
}

func TestNormalizeRuntimeDaemonConfigValue_Float64Count(t *testing.T) {
	raw := map[string]any{
		"python": float64(2),
	}
	got, ok := normalizeRuntimeDaemonConfigValue(raw)
	if !ok {
		t.Fatalf("expected float64 count to be handled")
	}
	if got != "python=2" {
		t.Fatalf("normalizeRuntimeDaemonConfigValue(float64) = %q", got)
	}
}

func TestNormalizeRuntimeDaemonConfigValue_Int64Count(t *testing.T) {
	raw := map[string]any{
		"python": int64(4),
	}
	got, ok := normalizeRuntimeDaemonConfigValue(raw)
	if !ok {
		t.Fatalf("expected int64 count to be handled")
	}
	if got != "python=4" {
		t.Fatalf("normalizeRuntimeDaemonConfigValue(int64) = %q", got)
	}
}

func TestNormalizeRuntimeDaemonConfigValue_InvalidCountType(t *testing.T) {
	raw := map[string]any{
		"node": true,
	}
	_, ok := normalizeRuntimeDaemonConfigValue(raw)
	if ok {
		t.Fatalf("expected bool count to return ok=false")
	}
}

func TestNormalizeRuntimeDaemonConfigValue_ExtraRuntimesSorted(t *testing.T) {
	raw := map[string]any{
		"custom_b": 1,
		"custom_a": 2,
	}
	got, ok := normalizeRuntimeDaemonConfigValue(raw)
	if !ok {
		t.Fatalf("expected extra runtimes to be handled")
	}
	if got != "custom_a=2,custom_b=1" {
		t.Fatalf("normalizeRuntimeDaemonConfigValue(extras) = %q", got)
	}
}

func TestConfiguredRuntimeDaemons_NestedKey(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	viper.Set("runtime.daemons", map[string]any{
		"node": 2,
	})

	got, ok := configuredRuntimeDaemons()
	if !ok {
		t.Fatalf("expected runtime.daemons nested key to be detected")
	}
	if got != "node=2" {
		t.Fatalf("configuredRuntimeDaemons() nested = %q", got)
	}
}

func TestConfiguredString_MultipleKeys(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	viper.Set("functions_dir", "my-functions")

	got := configuredFunctionsDir()
	if got != "my-functions" {
		t.Fatalf("configuredFunctionsDir() = %q, want %q", got, "my-functions")
	}
}

func TestConfiguredString_AllKeysEmpty(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()

	got := configuredFunctionsDir()
	if got != "" {
		t.Fatalf("configuredFunctionsDir() = %q, want empty", got)
	}
}

func TestConfiguredPublicBaseURL(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	viper.Set("public-base-url", "https://api.example.com")

	got := configuredPublicBaseURL()
	if got != "https://api.example.com" {
		t.Fatalf("configuredPublicBaseURL() = %q", got)
	}
}

func TestExecute_SuccessfulCommand(t *testing.T) {
	oldExitFn := exitFn
	t.Cleanup(func() { exitFn = oldExitFn })

	exitCalled := false
	exitFn = func(code int) {
		exitCalled = true
	}

	// Execute with no args should succeed (rootCmd prints help)
	Execute()
	if exitCalled {
		t.Fatal("did not expect exit to be called for successful execution")
	}
}

func TestConfiguredRuntimeBinaries_NestedKey(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()
	viper.Set("runtime.binaries", map[string]any{
		"python": "python3",
	})

	got, ok := configuredRuntimeBinaries()
	if !ok {
		t.Fatalf("expected runtime.binaries nested key to be detected")
	}
	if got["FN_PYTHON_BIN"] != "python3" {
		t.Fatalf("FN_PYTHON_BIN = %q", got["FN_PYTHON_BIN"])
	}
}

func TestConfiguredRuntimeBinaries_NoKeys(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()

	_, ok := configuredRuntimeBinaries()
	if ok {
		t.Fatalf("expected no runtime binaries when none configured")
	}
}

func TestConfiguredBool_Unset(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()

	_, ok := configuredBool("nonexistent-key")
	if ok {
		t.Fatal("expected ok=false for unset key")
	}
}

func TestExecute_ErrorPath(t *testing.T) {
	oldExitFn := exitFn
	t.Cleanup(func() { exitFn = oldExitFn })

	exitCode := -1
	exitFn = func(code int) {
		exitCode = code
	}

	// Run with an unknown subcommand to trigger an error
	rootCmd.SetArgs([]string{"__nonexistent_subcommand__"})
	t.Cleanup(func() { rootCmd.SetArgs(nil) })
	Execute()

	if exitCode != 1 {
		t.Fatalf("expected exit code 1, got %d", exitCode)
	}
}

func TestNormalizeRuntimeDaemonConfigValue_DuplicateInOrder(t *testing.T) {
	// Test that the seen map prevents duplicate entries.
	// When the same runtime appears in both the `order` list and the source map,
	// it should only be included once.
	raw := map[string]any{
		"node": 3,
	}
	got, ok := normalizeRuntimeDaemonConfigValue(raw)
	if !ok {
		t.Fatalf("expected ok=true")
	}
	if got != "node=3" {
		t.Fatalf("expected 'node=3', got %q", got)
	}
	// Verify no duplicate by counting occurrences
	if strings.Count(got, "node") != 1 {
		t.Fatalf("expected node to appear exactly once, got %q", got)
	}
}

func TestInitConfig_JSONFallback(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()

	tmpDir := t.TempDir()
	oldWd, _ := os.Getwd()
	defer os.Chdir(oldWd)
	os.Chdir(tmpDir)

	oldCfgFile := cfgFile
	t.Cleanup(func() {
		cfgFile = oldCfgFile
	})
	cfgFile = ""

	// Create a JSON config file (preferred over TOML)
	if err := os.WriteFile(filepath.Join(tmpDir, "fastfn.json"), []byte(`{"json_test_key":"json_value"}`), 0o644); err != nil {
		t.Fatalf("write json: %v", err)
	}

	initConfig()

	if viper.GetString("json_test_key") != "json_value" {
		t.Fatalf("expected JSON fallback to read json_test_key, got %q", viper.GetString("json_test_key"))
	}
}

func TestInitConfig_NoConfigFileNoError(t *testing.T) {
	t.Cleanup(viper.Reset)
	viper.Reset()

	tmpDir := t.TempDir()
	oldWd, _ := os.Getwd()
	defer os.Chdir(oldWd)
	os.Chdir(tmpDir)

	oldCfgFile := cfgFile
	oldExitFn := exitFn
	t.Cleanup(func() {
		cfgFile = oldCfgFile
		exitFn = oldExitFn
	})
	cfgFile = ""
	exitCalled := false
	exitFn = func(code int) {
		exitCalled = true
	}

	// Should not error or exit when no config file exists and no explicit file set
	initConfig()
	if exitCalled {
		t.Fatal("did not expect exit when no config file exists and cfgFile is empty")
	}
}
