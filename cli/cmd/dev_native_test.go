package cmd

import (
	"testing"

	"github.com/misaelzapata/fastfn/cli/internal/process"
	"github.com/misaelzapata/fastfn/cli/internal/workloads"
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

	if err := runNative("/tmp/project", "/tmp/functions", workloads.Config{}); err != nil {
		t.Fatalf("runNative() error = %v", err)
	}

	if captured.ProjectDir != "/tmp/project" {
		t.Fatalf("ProjectDir = %q, want %q", captured.ProjectDir, "/tmp/project")
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
