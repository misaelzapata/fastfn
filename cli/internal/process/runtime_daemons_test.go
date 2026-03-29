package process

import (
	"fmt"
	"os"
	"path/filepath"
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

func TestCanonicalRuntimeDaemonEnvValue_Empty(t *testing.T) {
	_, ok := canonicalRuntimeDaemonEnvValue("")
	if ok {
		t.Fatalf("expected ok=false for empty string")
	}
}

func TestCanonicalRuntimeDaemonEnvValue_Invalid(t *testing.T) {
	_, ok := canonicalRuntimeDaemonEnvValue("node")
	if ok {
		t.Fatalf("expected ok=false for invalid entry")
	}
}

func TestRuntimeSupportsDaemonScaling(t *testing.T) {
	if !runtimeSupportsDaemonScaling("python") {
		t.Fatal("expected python to support daemon scaling")
	}
	if !runtimeSupportsDaemonScaling("node") {
		t.Fatal("expected node to support daemon scaling")
	}
	if runtimeSupportsDaemonScaling("lua") {
		t.Fatal("expected lua to NOT support daemon scaling")
	}
	if runtimeSupportsDaemonScaling("unknown") {
		t.Fatal("expected unknown to NOT support daemon scaling")
	}
}

func TestFirstRuntimeSocket(t *testing.T) {
	if got := firstRuntimeSocket(nil); got != "" {
		t.Fatalf("expected empty for nil, got %q", got)
	}
	if got := firstRuntimeSocket([]string{}); got != "" {
		t.Fatalf("expected empty for empty slice, got %q", got)
	}
	if got := firstRuntimeSocket([]string{"unix:/tmp/a.sock", "unix:/tmp/b.sock"}); got != "unix:/tmp/a.sock" {
		t.Fatalf("expected first socket, got %q", got)
	}
}

func TestRuntimeSocketPaths_SingleDaemon(t *testing.T) {
	paths := runtimeSocketPaths("/tmp/socks", "node", 1)
	if len(paths) != 1 {
		t.Fatalf("expected 1 path, got %d", len(paths))
	}
	if !strings.HasSuffix(paths[0], "fn-node.sock") {
		t.Fatalf("unexpected path: %s", paths[0])
	}
}

func TestRuntimeSocketPaths_MultipleDaemons(t *testing.T) {
	paths := runtimeSocketPaths("/tmp/socks", "python", 3)
	if len(paths) != 3 {
		t.Fatalf("expected 3 paths, got %d", len(paths))
	}
	for i, p := range paths {
		expected := "fn-python-" + strings.TrimSpace(strings.Split(p, "fn-python-")[1])
		if !strings.Contains(p, "fn-python-") {
			t.Fatalf("path %d missing indexed name: %s", i, p)
		}
		_ = expected
	}
}

func TestRuntimeSocketPathsTooLong(t *testing.T) {
	if runtimeSocketPathsTooLong("/tmp/fastfn/s-123", []string{"python"}, map[string]int{"python": 1}) {
		t.Fatal("expected short socket paths to be allowed")
	}

	longBase := "/tmp/" + strings.Repeat("native-socket-path-", 8)
	if !runtimeSocketPathsTooLong(longBase, []string{"python"}, map[string]int{"python": 1}) {
		t.Fatal("expected long socket paths to exceed unix socket limit")
	}
}

func TestChooseNativeSocketDir_UsesConfiguredBaseWhenSafe(t *testing.T) {
	socketDir, usedFallback := chooseNativeSocketDir("/tmp/fastfn", 4321, []string{"python"}, map[string]int{"python": 1})
	if usedFallback {
		t.Fatal("expected safe socket dir to avoid fallback")
	}
	if socketDir != "/tmp/fastfn/s-4321" {
		t.Fatalf("unexpected socket dir: %q", socketDir)
	}
}

func TestChooseNativeSocketDir_FallsBackWhenTooLong(t *testing.T) {
	origFallbackRoot := nativeSocketFallbackRootFn
	nativeSocketFallbackRootFn = func() string { return "/tmp/fallback-root" }
	t.Cleanup(func() {
		nativeSocketFallbackRootFn = origFallbackRoot
	})

	longBase := "/tmp/" + strings.Repeat("native-socket-path-", 8)
	socketDir, usedFallback := chooseNativeSocketDir(longBase, 9876, []string{"python"}, map[string]int{"python": 1})
	if !usedFallback {
		t.Fatal("expected fallback socket dir for long base path")
	}
	if !strings.HasPrefix(socketDir, "/tmp/fallback-root/ffn-sock-") {
		t.Fatalf("expected fallback root prefix, got %q", socketDir)
	}
	if !strings.HasSuffix(socketDir, "/s-9876") {
		t.Fatalf("expected pid suffix, got %q", socketDir)
	}
}

func TestDefaultNativeSocketFallbackRoot_WindowsUsesTempDir(t *testing.T) {
	origGOOS := runtimeGOOS
	t.Cleanup(func() { runtimeGOOS = origGOOS })

	runtimeGOOS = "windows"

	if got := defaultNativeSocketFallbackRoot(); got != os.TempDir() {
		t.Fatalf("defaultNativeSocketFallbackRoot() = %q, want %q", got, os.TempDir())
	}
}

func TestChooseNativeSocketDir_SkipsDuplicateFallbackCandidates(t *testing.T) {
	origGOOS := runtimeGOOS
	origFallbackRoot := nativeSocketFallbackRootFn
	origTooLongFn := runtimeSocketPathsTooLongFn
	t.Cleanup(func() {
		runtimeGOOS = origGOOS
		nativeSocketFallbackRootFn = origFallbackRoot
		runtimeSocketPathsTooLongFn = origTooLongFn
	})

	runtimeGOOS = "linux"
	nativeSocketFallbackRootFn = func() string { return "/tmp" }

	seen := []string{}
	runtimeSocketPathsTooLongFn = func(socketDir string, selected []string, counts map[string]int) bool {
		seen = append(seen, socketDir)
		return len(seen) < 3
	}

	socketDir, usedFallback := chooseNativeSocketDir("/tmp/"+strings.Repeat("socket-base-", 8), 77, []string{"python"}, map[string]int{"python": 1})
	if !usedFallback {
		t.Fatal("expected fallback to be used")
	}
	if len(seen) != 3 {
		t.Fatalf("expected duplicate fallback candidate to be skipped, got calls for %v", seen)
	}
	if !strings.Contains(socketDir, string(filepath.Separator)+"f-") || !strings.HasSuffix(socketDir, string(filepath.Separator)+"p77") {
		t.Fatalf("expected compact fallback candidate, got %q", socketDir)
	}
}

func TestChooseNativeSocketDir_ReturnsLastCandidateWhenAllAreTooLong(t *testing.T) {
	origGOOS := runtimeGOOS
	origFallbackRoot := nativeSocketFallbackRootFn
	origTooLongFn := runtimeSocketPathsTooLongFn
	t.Cleanup(func() {
		runtimeGOOS = origGOOS
		nativeSocketFallbackRootFn = origFallbackRoot
		runtimeSocketPathsTooLongFn = origTooLongFn
	})

	runtimeGOOS = "linux"
	nativeSocketFallbackRootFn = func() string { return "/tmp/custom-root" }
	runtimeSocketPathsTooLongFn = func(string, []string, map[string]int) bool { return true }

	socketDir, usedFallback := chooseNativeSocketDir("/tmp/"+strings.Repeat("socket-base-", 8), 55, []string{"python"}, map[string]int{"python": 1})
	if !usedFallback {
		t.Fatal("expected fallback result when all candidates are too long")
	}
	if !strings.Contains(socketDir, string(filepath.Separator)+"f-") || !strings.HasSuffix(socketDir, string(filepath.Separator)+"p55") {
		t.Fatalf("expected final compact fallback candidate, got %q", socketDir)
	}
}

func TestRuntimeServiceEnv(t *testing.T) {
	base := []string{"KEY=VAL"}
	env := runtimeServiceEnv(base, "python", "unix:/tmp/fn-python.sock", 1, 2)

	joined := strings.Join(env, "\n")
	if !strings.Contains(joined, "FN_PY_SOCKET=/tmp/fn-python.sock") {
		t.Fatalf("expected FN_PY_SOCKET in env, got: %s", joined)
	}
	if !strings.Contains(joined, "FN_RUNTIME_INSTANCE_INDEX=1") {
		t.Fatalf("expected instance index in env, got: %s", joined)
	}
	if !strings.Contains(joined, "FN_RUNTIME_INSTANCE_COUNT=2") {
		t.Fatalf("expected instance count in env, got: %s", joined)
	}
	if !strings.Contains(joined, "KEY=VAL") {
		t.Fatalf("expected base env preserved, got: %s", joined)
	}
}

func TestRuntimeServiceName(t *testing.T) {
	if got := runtimeServiceName("node", 1, 1); got != "node" {
		t.Fatalf("expected 'node', got %q", got)
	}
	if got := runtimeServiceName("node", 2, 3); got != "node#2" {
		t.Fatalf("expected 'node#2', got %q", got)
	}
}

func TestResolveRuntimeDaemonCounts_OverridesDefaults(t *testing.T) {
	got, warnings, err := resolveRuntimeDaemonCounts([]string{"node", "python"}, "node=4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("unexpected warnings: %v", warnings)
	}
	if got["node"] != 4 {
		t.Fatalf("expected node=4, got %d", got["node"])
	}
	if got["python"] != 1 {
		t.Fatalf("expected python=1, got %d", got["python"])
	}
}

func TestParseRuntimeDaemonCounts_EmptyFields(t *testing.T) {
	if _, _, err := parseRuntimeDaemonCounts("=3"); err == nil {
		t.Fatal("expected error for empty runtime name")
	}
	if _, _, err := parseRuntimeDaemonCounts("node="); err == nil {
		t.Fatal("expected error for empty count")
	}
}

func TestParseRuntimeDaemonCounts_ZeroCount(t *testing.T) {
	if _, _, err := parseRuntimeDaemonCounts("node=0"); err == nil {
		t.Fatal("expected error for zero count")
	}
}

func TestEncodeRuntimeSocketMap_EmptyMap(t *testing.T) {
	raw, err := encodeRuntimeSocketMap(map[string][]string{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if raw != "{}" {
		t.Fatalf("expected empty JSON object, got %s", raw)
	}
}

func TestParseRuntimeDaemonCounts_EmptyTokenInList(t *testing.T) {
	// Trailing comma produces an empty token which should be skipped.
	got, warnings, err := parseRuntimeDaemonCounts("node=3,,python=2,")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("expected no warnings, got %v", warnings)
	}
	want := map[string]int{"node": 3, "python": 2}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %#v, want %#v", got, want)
	}
}

func TestResolveRuntimeDaemonCounts_ParsedNonScalingRuntimeSkipped(t *testing.T) {
	// "lua" supports daemon counts in parseRuntimeDaemonCounts (produces a warning),
	// but unknown runtimes that pass parsing but fail runtimeSupportsDaemonScaling
	// should be skipped in resolveRuntimeDaemonCounts.
	// We need a runtime that is known to nativeRuntimeRequirements but NOT in
	// runtimeSocketEnvByRuntime. Looking at the code, "lua" is in
	// nativeRuntimeRequirements but NOT in runtimeSocketEnvByRuntime, but it gets
	// filtered out by parseRuntimeDaemonCounts. So let's test with a runtime that
	// somehow gets into parsed but doesn't support daemon scaling.
	// Actually the uncovered line is in resolveRuntimeDaemonCounts where parsed
	// runtime doesn't pass runtimeSupportsDaemonScaling. Since lua is filtered
	// by parseRuntimeDaemonCounts, we can't reach it that way.
	// Instead we directly test: pass "lua" as a selected runtime, it shouldn't
	// appear in the output (already tested). But the uncovered branch is
	// lines 89-91: when parsed has a runtime that doesn't support daemon scaling.
	// Since parseRuntimeDaemonCounts filters lua/unknown, we can't get there easily.
	// Let's verify the branch by checking the already-tested path works correctly.

	// Actually, runtimeSupportsDaemonScaling checks runtimeSocketEnvByRuntime.
	// The keys there are python, node, php, rust, go. If a runtime like "lua"
	// somehow got into parsed, it would be skipped. But parseRuntimeDaemonCounts
	// filters it first. So the only way to hit this is if nativeRuntimeRequirements
	// has a key not in runtimeSocketEnvByRuntime AND not filtered by parse.
	// Currently this can't happen, but the guard is there for safety.
	// We can still verify by testing that lua in selected list doesn't appear.
	got, _, err := resolveRuntimeDaemonCounts([]string{"lua"}, "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("expected empty map for lua-only, got %#v", got)
	}
}

func TestEncodeRuntimeSocketMap_SingleAndMulti(t *testing.T) {
	raw, err := encodeRuntimeSocketMap(map[string][]string{
		"python": {"unix:/tmp/a.sock"},
		"node":   {"unix:/tmp/b1.sock", "unix:/tmp/b2.sock"},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// Single socket should be a string, multi should be an array
	if !strings.Contains(raw, `"python":"unix:/tmp/a.sock"`) {
		t.Fatalf("expected single-socket string, got %s", raw)
	}
	if !strings.Contains(raw, `"node":[`) {
		t.Fatalf("expected multi-socket array, got %s", raw)
	}
}

func TestResolveRuntimeDaemonCounts_ParseError(t *testing.T) {
	_, _, err := resolveRuntimeDaemonCounts([]string{"node"}, "node=abc")
	if err == nil {
		t.Fatal("expected error for invalid daemon count")
	}
}

func TestEncodeRuntimeSocketMap_MarshalError(t *testing.T) {
	origMarshal := jsonMarshalFn
	t.Cleanup(func() { jsonMarshalFn = origMarshal })

	jsonMarshalFn = func(v any) ([]byte, error) {
		return nil, fmt.Errorf("marshal boom")
	}

	_, err := encodeRuntimeSocketMap(map[string][]string{
		"python": {"unix:/tmp/a.sock"},
	})
	if err == nil {
		t.Fatal("expected marshal error")
	}
	if !strings.Contains(err.Error(), "marshal boom") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestResolveRuntimeDaemonCounts_NonScalingRuntimeInParsed(t *testing.T) {
	// To exercise lines 89-91, we need a runtime that passes parseRuntimeDaemonCounts
	// but fails runtimeSupportsDaemonScaling. We temporarily add a runtime to
	// nativeRuntimeRequirements that is NOT in runtimeSocketEnvByRuntime.
	origReqs := nativeRuntimeRequirements
	t.Cleanup(func() { nativeRuntimeRequirements = origReqs })

	nativeRuntimeRequirements = map[string][]string{}
	for k, v := range origReqs {
		nativeRuntimeRequirements[k] = v
	}
	// Add a fake runtime that has no entry in runtimeSocketEnvByRuntime
	nativeRuntimeRequirements["fakert"] = []string{}

	got, warnings, err := resolveRuntimeDaemonCounts([]string{"python"}, "fakert=3")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	_ = warnings
	// fakert=3 should be silently skipped because runtimeSupportsDaemonScaling("fakert") = false
	if _, exists := got["fakert"]; exists {
		t.Fatal("expected fakert to be skipped since it doesn't support daemon scaling")
	}
	if got["python"] != 1 {
		t.Fatalf("expected python=1, got %d", got["python"])
	}
}

func TestRuntimeSocketURIsByRuntime_DaemonCountZero(t *testing.T) {
	// When daemonCount is 0 in the map, it should default to 1.
	got := runtimeSocketURIsByRuntime("/tmp/socks", []string{"node"}, map[string]int{
		"node": 0,
	})
	if len(got["node"]) != 1 {
		t.Fatalf("expected 1 socket for daemonCount=0, got %d", len(got["node"]))
	}
	if !strings.HasSuffix(got["node"][0], "fn-node.sock") {
		t.Fatalf("expected single socket name, got %s", got["node"][0])
	}
}
