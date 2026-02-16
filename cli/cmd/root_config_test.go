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
