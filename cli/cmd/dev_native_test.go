package cmd

import (
	"testing"

	"github.com/misaelzapata/fastfn/cli/internal/process"
)

func TestRunNative_UsesExpectedDefaults(t *testing.T) {
	original := runNativeRunner
	t.Cleanup(func() {
		runNativeRunner = original
	})

	var captured process.RunConfig
	runNativeRunner = func(cfg process.RunConfig) error {
		captured = cfg
		return nil
	}

	if err := runNative("/tmp/functions"); err != nil {
		t.Fatalf("runNative() error = %v", err)
	}

	if captured.FnDir != "/tmp/functions" {
		t.Fatalf("FnDir = %q, want %q", captured.FnDir, "/tmp/functions")
	}
	if !captured.HotReload {
		t.Fatalf("HotReload = false, want true")
	}
	if captured.VerifyTLS {
		t.Fatalf("VerifyTLS = true, want false")
	}
	if !captured.Watch {
		t.Fatalf("Watch = false, want true")
	}
}
