package cmd

import (
	"testing"

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
