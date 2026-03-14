package process

import (
	"reflect"
	"strings"
	"testing"
)

func TestParseRuntimeDaemonCounts(t *testing.T) {
	got, warnings, err := parseRuntimeDaemonCounts("node=3,python=2,php=4")
	if err != nil {
		t.Fatalf("parseRuntimeDaemonCounts() error = %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("expected no warnings, got %v", warnings)
	}
	want := map[string]int{"node": 3, "python": 2, "php": 4}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parseRuntimeDaemonCounts() = %#v, want %#v", got, want)
	}
}

func TestParseRuntimeDaemonCounts_IgnoresLuaAndUnknown(t *testing.T) {
	got, warnings, err := parseRuntimeDaemonCounts("lua=3,unknown=2,node=2")
	if err != nil {
		t.Fatalf("parseRuntimeDaemonCounts() error = %v", err)
	}
	if len(warnings) != 2 {
		t.Fatalf("expected 2 warnings, got %v", warnings)
	}
	if !strings.Contains(strings.Join(warnings, "\n"), "lua") {
		t.Fatalf("expected lua warning, got %v", warnings)
	}
	if !reflect.DeepEqual(got, map[string]int{"node": 2}) {
		t.Fatalf("parseRuntimeDaemonCounts() = %#v", got)
	}
}

func TestParseRuntimeDaemonCounts_InvalidEntry(t *testing.T) {
	if _, _, err := parseRuntimeDaemonCounts("node=two"); err == nil {
		t.Fatalf("expected invalid count error")
	}
	if _, _, err := parseRuntimeDaemonCounts("node"); err == nil {
		t.Fatalf("expected invalid token error")
	}
}

func TestResolveRuntimeDaemonCounts_DefaultsToOne(t *testing.T) {
	got, warnings, err := resolveRuntimeDaemonCounts([]string{"lua", "node", "python"}, "")
	if err != nil {
		t.Fatalf("resolveRuntimeDaemonCounts() error = %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("expected no warnings, got %v", warnings)
	}
	want := map[string]int{"node": 1, "python": 1}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("resolveRuntimeDaemonCounts() = %#v, want %#v", got, want)
	}
}

func TestRuntimeSocketURIsByRuntime_UsesIndexedSockets(t *testing.T) {
	got := runtimeSocketURIsByRuntime("/tmp/fastfn", []string{"node", "python", "lua"}, map[string]int{
		"node":   3,
		"python": 1,
	})
	want := map[string][]string{
		"node": []string{
			"unix:/tmp/fastfn/fn-node-1.sock",
			"unix:/tmp/fastfn/fn-node-2.sock",
			"unix:/tmp/fastfn/fn-node-3.sock",
		},
		"python": []string{
			"unix:/tmp/fastfn/fn-python.sock",
		},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("runtimeSocketURIsByRuntime() = %#v, want %#v", got, want)
	}
}

func TestEncodeRuntimeSocketMap_PreservesLegacySingleSocketShape(t *testing.T) {
	raw, err := encodeRuntimeSocketMap(map[string][]string{
		"node":   []string{"unix:/tmp/fn-node.sock"},
		"python": []string{"unix:/tmp/fn-python-1.sock", "unix:/tmp/fn-python-2.sock"},
	})
	if err != nil {
		t.Fatalf("encodeRuntimeSocketMap() error = %v", err)
	}
	if !strings.Contains(raw, `"node":"unix:/tmp/fn-node.sock"`) {
		t.Fatalf("expected single-socket legacy shape, got %s", raw)
	}
	if !strings.Contains(raw, `"python":["unix:/tmp/fn-python-1.sock","unix:/tmp/fn-python-2.sock"]`) {
		t.Fatalf("expected multi-socket array shape, got %s", raw)
	}
}

func TestCanonicalRuntimeDaemonEnvValue_SortsRuntimes(t *testing.T) {
	got, ok := canonicalRuntimeDaemonEnvValue("python=2,node=3")
	if !ok {
		t.Fatalf("expected canonical value")
	}
	if got != "node=3,python=2" {
		t.Fatalf("canonicalRuntimeDaemonEnvValue() = %q", got)
	}
}
