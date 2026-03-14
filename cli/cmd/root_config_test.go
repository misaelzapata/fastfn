package cmd

import (
	"os"
	"path/filepath"
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
