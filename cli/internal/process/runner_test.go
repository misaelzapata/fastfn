package process

import (
	"reflect"
	"strings"
	"testing"
)

func TestSelectNativeRuntimes_DefaultSkipsUnavailableSilently(t *testing.T) {
	selected, warnings, err := selectNativeRuntimes("", map[string]bool{
		"python3": true,
		"node":    true,
		"php":     false,
		"cargo":   false,
		"go":      false,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("expected no warnings for default mode, got %v", warnings)
	}
	if !reflect.DeepEqual(selected, []string{"python", "node", "lua"}) {
		t.Fatalf("unexpected runtimes: %v", selected)
	}
}

func TestSelectNativeRuntimes_DefaultKeepsLuaWithoutExternalBinaries(t *testing.T) {
	selected, warnings, err := selectNativeRuntimes("", map[string]bool{
		"python3": false,
		"node":    false,
		"php":     false,
		"cargo":   false,
		"go":      false,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("expected no warnings for default mode, got %v", warnings)
	}
	if !reflect.DeepEqual(selected, []string{"lua"}) {
		t.Fatalf("unexpected runtimes: %v", selected)
	}
}

func TestSelectNativeRuntimes_ExplicitIgnoresUnknownAndUnavailableWithWarnings(t *testing.T) {
	selected, warnings, err := selectNativeRuntimes("node,unknown,go,python", map[string]bool{
		"python3": true,
		"node":    true,
		"php":     false,
		"cargo":   false,
		"go":      false,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !reflect.DeepEqual(selected, []string{"node", "python"}) {
		t.Fatalf("unexpected runtimes: %v", selected)
	}
	if len(warnings) != 2 {
		t.Fatalf("expected 2 warnings, got %d (%v)", len(warnings), warnings)
	}
	if !strings.Contains(strings.Join(warnings, "\n"), "unknown") {
		t.Fatalf("expected unknown runtime warning, got %v", warnings)
	}
	if !strings.Contains(strings.Join(warnings, "\n"), "missing: go") {
		t.Fatalf("expected missing go warning, got %v", warnings)
	}
}

func TestSelectNativeRuntimes_ExplicitTrimsAndDedupes(t *testing.T) {
	selected, warnings, err := selectNativeRuntimes(" python ,node,node , python ", map[string]bool{
		"python3": true,
		"node":    true,
		"php":     true,
		"cargo":   false,
		"go":      false,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("expected no warnings, got %v", warnings)
	}
	if !reflect.DeepEqual(selected, []string{"python", "node"}) {
		t.Fatalf("unexpected runtimes: %v", selected)
	}
}

func TestSelectNativeRuntimes_ExplicitExperimentalWhenAvailable(t *testing.T) {
	selected, warnings, err := selectNativeRuntimes("rust,go", map[string]bool{
		"python3": true,
		"node":    false,
		"php":     false,
		"cargo":   true,
		"go":      true,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("expected no warnings, got %v", warnings)
	}
	if !reflect.DeepEqual(selected, []string{"rust", "go"}) {
		t.Fatalf("unexpected runtimes: %v", selected)
	}
}

func TestSelectNativeRuntimes_ExplicitOnlyUnavailableReturnsError(t *testing.T) {
	_, warnings, err := selectNativeRuntimes("go,rust", map[string]bool{
		"python3": true,
		"node":    false,
		"php":     false,
		"cargo":   false,
		"go":      false,
	})
	if err == nil {
		t.Fatalf("expected error when explicit runtimes are unavailable")
	}
	if len(warnings) != 2 {
		t.Fatalf("expected 2 warnings, got %d (%v)", len(warnings), warnings)
	}
	if !strings.Contains(err.Error(), "no compatible runtimes enabled") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestSelectNativeRuntimes_ExplicitEmptyCSVFallsBackToDefault(t *testing.T) {
	selected, warnings, err := selectNativeRuntimes(", ,", map[string]bool{
		"python3": false,
		"node":    true,
		"php":     false,
		"cargo":   false,
		"go":      false,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("expected no warnings, got %v", warnings)
	}
	if !reflect.DeepEqual(selected, []string{"node", "lua"}) {
		t.Fatalf("unexpected runtimes: %v", selected)
	}
}
