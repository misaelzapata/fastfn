package process

import (
	"regexp"
	"strings"
	"testing"
)

func patchBinaryResolvers(t *testing.T) {
	t.Helper()
	origLook := binaryLookPathFn
	origOutput := binaryOutputFn
	t.Cleanup(func() {
		binaryLookPathFn = origLook
		binaryOutputFn = origOutput
	})
}

func TestResolveConfiguredBinary_PythonFallsBackToPython(t *testing.T) {
	patchBinaryResolvers(t)
	t.Setenv("FN_PYTHON_BIN", "")

	binaryLookPathFn = func(file string) (string, error) {
		switch file {
		case "python3":
			return "", errBinaryNotFound
		case "python":
			return "/usr/local/bin/python", nil
		default:
			return "", errBinaryNotFound
		}
	}
	binaryOutputFn = func(command string, args ...string) (string, error) {
		if !strings.Contains(command, "python") {
			t.Fatalf("unexpected version probe command: %s %v", command, args)
		}
		return "3.11.7", nil
	}

	resolution, err := ResolveConfiguredBinary("python")
	if err != nil {
		t.Fatalf("ResolveConfiguredBinary(python) error = %v", err)
	}
	if resolution.Path != "/usr/local/bin/python" {
		t.Fatalf("python path = %q", resolution.Path)
	}
}

func TestResolveConfiguredBinary_PythonRejectsExplicitPython2(t *testing.T) {
	patchBinaryResolvers(t)
	t.Setenv("FN_PYTHON_BIN", "python2.7")

	binaryLookPathFn = func(file string) (string, error) {
		if file == "python2.7" {
			return "/usr/bin/python2.7", nil
		}
		return "", errBinaryNotFound
	}
	binaryOutputFn = func(command string, args ...string) (string, error) {
		return "2.7.18", nil
	}

	_, err := ResolveConfiguredBinary("python")
	if err == nil {
		t.Fatalf("expected explicit python2 override to fail")
	}
	if !strings.Contains(err.Error(), "requires >=") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestParseBinaryAssignments(t *testing.T) {
	got, err := ParseBinaryAssignments("python=python,node=node18,php=php8.3")
	if err != nil {
		t.Fatalf("ParseBinaryAssignments error = %v", err)
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

// ---------------------------------------------------------------------------
// BinarySpecKeys
// ---------------------------------------------------------------------------

func TestBinarySpecKeys(t *testing.T) {
	keys := BinarySpecKeys()
	if len(keys) == 0 {
		t.Fatal("expected non-empty keys")
	}
	// Should follow binaryConfigOrder
	expected := []string{"openresty", "docker", "python", "node", "npm", "php", "composer", "cargo", "go"}
	if len(keys) != len(expected) {
		t.Fatalf("BinarySpecKeys() length = %d, want %d", len(keys), len(expected))
	}
	for i, k := range keys {
		if k != expected[i] {
			t.Fatalf("BinarySpecKeys()[%d] = %q, want %q", i, k, expected[i])
		}
	}
}

// ---------------------------------------------------------------------------
// BinaryEnvVarName
// ---------------------------------------------------------------------------

func TestBinaryEnvVarName_Known(t *testing.T) {
	envVar, ok := BinaryEnvVarName("python")
	if !ok || envVar != "FN_PYTHON_BIN" {
		t.Fatalf("BinaryEnvVarName(python) = (%q, %v)", envVar, ok)
	}
}

func TestBinaryEnvVarName_Unknown(t *testing.T) {
	_, ok := BinaryEnvVarName("unknown_binary")
	if ok {
		t.Fatalf("expected ok=false for unknown binary")
	}
}

func TestBinaryEnvVarName_Whitespace(t *testing.T) {
	envVar, ok := BinaryEnvVarName("  Python  ")
	if !ok || envVar != "FN_PYTHON_BIN" {
		t.Fatalf("BinaryEnvVarName with whitespace = (%q, %v)", envVar, ok)
	}
}

// ---------------------------------------------------------------------------
// NormalizeBinaryConfigValue
// ---------------------------------------------------------------------------

func TestNormalizeBinaryConfigValue_Nil(t *testing.T) {
	_, ok := NormalizeBinaryConfigValue(nil)
	if ok {
		t.Fatal("expected nil to return ok=false")
	}
}

func TestNormalizeBinaryConfigValue_String(t *testing.T) {
	got, ok := NormalizeBinaryConfigValue("python=python3,node=node18")
	if !ok {
		t.Fatal("expected string to be parsed")
	}
	if got["FN_PYTHON_BIN"] != "python3" {
		t.Fatalf("FN_PYTHON_BIN = %q", got["FN_PYTHON_BIN"])
	}
}

func TestNormalizeBinaryConfigValue_InvalidString(t *testing.T) {
	_, ok := NormalizeBinaryConfigValue("invalid")
	if ok {
		t.Fatal("expected invalid string to return ok=false")
	}
}

func TestNormalizeBinaryConfigValue_EmptyString(t *testing.T) {
	_, ok := NormalizeBinaryConfigValue("")
	if ok {
		t.Fatal("expected empty string to return ok=false")
	}
}

func TestNormalizeBinaryConfigValue_MapStringAny(t *testing.T) {
	got, ok := NormalizeBinaryConfigValue(map[string]any{
		"python": "python3",
		"node":   "node18",
	})
	if !ok {
		t.Fatal("expected map[string]any to be parsed")
	}
	if got["FN_PYTHON_BIN"] != "python3" || got["FN_NODE_BIN"] != "node18" {
		t.Fatalf("result = %#v", got)
	}
}

func TestNormalizeBinaryConfigValue_MapAnyAny(t *testing.T) {
	got, ok := NormalizeBinaryConfigValue(map[any]any{
		"python": "python3",
	})
	if !ok {
		t.Fatal("expected map[any]any to be parsed")
	}
	if got["FN_PYTHON_BIN"] != "python3" {
		t.Fatalf("FN_PYTHON_BIN = %q", got["FN_PYTHON_BIN"])
	}
}

func TestNormalizeBinaryConfigValue_EmptyMap(t *testing.T) {
	_, ok := NormalizeBinaryConfigValue(map[string]any{})
	if ok {
		t.Fatal("expected empty map to return ok=false")
	}
}

func TestNormalizeBinaryConfigValue_UnknownKeys(t *testing.T) {
	_, ok := NormalizeBinaryConfigValue(map[string]any{
		"unknown_binary": "foo",
	})
	if ok {
		t.Fatal("expected unknown keys to return ok=false")
	}
}

func TestNormalizeBinaryConfigValue_EmptyValues(t *testing.T) {
	_, ok := NormalizeBinaryConfigValue(map[string]any{
		"python": "",
	})
	if ok {
		t.Fatal("expected empty value to return ok=false")
	}
}

func TestNormalizeBinaryConfigValue_InvalidType(t *testing.T) {
	_, ok := NormalizeBinaryConfigValue(42)
	if ok {
		t.Fatal("expected int to return ok=false")
	}
}

// ---------------------------------------------------------------------------
// ParseBinaryAssignments – error cases
// ---------------------------------------------------------------------------

func TestParseBinaryAssignments_EmptyString(t *testing.T) {
	got, err := ParseBinaryAssignments("")
	if err != nil {
		t.Fatalf("expected no error for empty string, got %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("expected empty result, got %#v", got)
	}
}

func TestParseBinaryAssignments_NoEqualsSign(t *testing.T) {
	_, err := ParseBinaryAssignments("python")
	if err == nil {
		t.Fatal("expected error for missing = sign")
	}
}

func TestParseBinaryAssignments_UnknownKey(t *testing.T) {
	_, err := ParseBinaryAssignments("unknown=foo")
	if err == nil {
		t.Fatal("expected error for unknown key")
	}
}

func TestParseBinaryAssignments_EmptyCommand(t *testing.T) {
	_, err := ParseBinaryAssignments("python=")
	if err == nil {
		t.Fatal("expected error for empty command")
	}
}

// ---------------------------------------------------------------------------
// BinaryConfiguredCommand
// ---------------------------------------------------------------------------

func TestBinaryConfiguredCommand_KnownNoEnv(t *testing.T) {
	patchBinaryResolvers(t)
	t.Setenv("FN_PYTHON_BIN", "")
	got := BinaryConfiguredCommand("python")
	if got != "python3" {
		t.Fatalf("BinaryConfiguredCommand(python) = %q, want first default candidate", got)
	}
}

func TestBinaryConfiguredCommand_KnownWithEnv(t *testing.T) {
	patchBinaryResolvers(t)
	t.Setenv("FN_PYTHON_BIN", "custom-python")
	got := BinaryConfiguredCommand("python")
	if got != "custom-python" {
		t.Fatalf("BinaryConfiguredCommand(python) = %q, want env override", got)
	}
}

func TestBinaryConfiguredCommand_Unknown(t *testing.T) {
	got := BinaryConfiguredCommand("unknown_binary")
	if got != "" {
		t.Fatalf("expected empty for unknown key, got %q", got)
	}
}

// ---------------------------------------------------------------------------
// BinaryKeysSummary
// ---------------------------------------------------------------------------

func TestBinaryKeysSummary(t *testing.T) {
	summary := BinaryKeysSummary()
	if summary == "" {
		t.Fatal("expected non-empty summary")
	}
	if !strings.Contains(summary, "python=FN_PYTHON_BIN") {
		t.Fatalf("expected python in summary, got: %s", summary)
	}
	if !strings.Contains(summary, "node=FN_NODE_BIN") {
		t.Fatalf("expected node in summary, got: %s", summary)
	}
}

// ---------------------------------------------------------------------------
// sortedBinaryEnvVars
// ---------------------------------------------------------------------------

func TestSortedBinaryEnvVars(t *testing.T) {
	vars := sortedBinaryEnvVars()
	if len(vars) == 0 {
		t.Fatal("expected non-empty sorted env vars")
	}
	for i := 1; i < len(vars); i++ {
		if vars[i] < vars[i-1] {
			t.Fatalf("env vars not sorted: %v", vars)
		}
	}
}

// ---------------------------------------------------------------------------
// ResolveConfiguredBinary – additional branches
// ---------------------------------------------------------------------------

func TestResolveConfiguredBinary_UnknownKey(t *testing.T) {
	_, err := ResolveConfiguredBinary("unknown_key")
	if err == nil {
		t.Fatal("expected error for unknown key")
	}
}

func TestResolveConfiguredBinary_NotFoundNoEnvVar(t *testing.T) {
	patchBinaryResolvers(t)
	t.Setenv("FN_DOCKER_BIN", "")

	binaryLookPathFn = func(file string) (string, error) {
		return "", errBinaryNotFound
	}

	_, err := ResolveConfiguredBinary("docker")
	if err == nil {
		t.Fatal("expected error when binary not found")
	}
	if !strings.Contains(err.Error(), "not found or incompatible") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestResolveConfiguredBinary_EnvOverrideNotFound(t *testing.T) {
	patchBinaryResolvers(t)
	t.Setenv("FN_DOCKER_BIN", "custom-docker")

	binaryLookPathFn = func(file string) (string, error) {
		return "", errBinaryNotFound
	}

	_, err := ResolveConfiguredBinary("docker")
	if err == nil {
		t.Fatal("expected error when env override binary not found")
	}
	if !strings.Contains(err.Error(), "override") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestResolveConfiguredBinary_VersionParseFailed(t *testing.T) {
	patchBinaryResolvers(t)
	t.Setenv("FN_NODE_BIN", "")

	binaryLookPathFn = func(file string) (string, error) {
		return "/usr/bin/node", nil
	}
	binaryOutputFn = func(command string, args ...string) (string, error) {
		return "not-a-version", nil
	}

	_, err := ResolveConfiguredBinary("node")
	if err == nil {
		t.Fatal("expected error when version parse fails")
	}
}

func TestResolveConfiguredBinary_VersionProbeFailed(t *testing.T) {
	patchBinaryResolvers(t)
	// Use the env var override path so the error propagates directly
	// instead of being swallowed by the candidate loop
	t.Setenv("FN_NODE_BIN", "/usr/bin/node")

	binaryLookPathFn = func(file string) (string, error) {
		return "/usr/bin/node", nil
	}
	binaryOutputFn = func(command string, args ...string) (string, error) {
		return "", errBinaryNotFound
	}

	_, err := ResolveConfiguredBinary("node")
	if err == nil {
		t.Fatal("expected error when version probe fails")
	}
	if !strings.Contains(err.Error(), "version probe failed") {
		t.Fatalf("unexpected error: %v", err)
	}
}

// ---------------------------------------------------------------------------
// compareBinaryVersion
// ---------------------------------------------------------------------------

func TestCompareBinaryVersion(t *testing.T) {
	tests := []struct {
		left, right binaryVersion
		want        int
	}{
		{binaryVersion{1, 0, 0}, binaryVersion{1, 0, 0}, 0},
		{binaryVersion{2, 0, 0}, binaryVersion{1, 0, 0}, 1},
		{binaryVersion{1, 0, 0}, binaryVersion{2, 0, 0}, -1},
		{binaryVersion{1, 2, 0}, binaryVersion{1, 1, 0}, 1},
		{binaryVersion{1, 1, 0}, binaryVersion{1, 2, 0}, -1},
		{binaryVersion{1, 1, 2}, binaryVersion{1, 1, 1}, 1},
		{binaryVersion{1, 1, 1}, binaryVersion{1, 1, 2}, -1},
	}
	for _, tc := range tests {
		got := compareBinaryVersion(tc.left, tc.right)
		if (tc.want > 0 && got <= 0) || (tc.want < 0 && got >= 0) || (tc.want == 0 && got != 0) {
			t.Fatalf("compareBinaryVersion(%v, %v) = %d, want sign %d", tc.left, tc.right, got, tc.want)
		}
	}
}

// ---------------------------------------------------------------------------
// parseVersionWithPattern
// ---------------------------------------------------------------------------

func TestParseVersionWithPattern_NoMatch(t *testing.T) {
	_, err := parseSimpleVersion("no version here")
	if err == nil {
		t.Fatal("expected error for no match")
	}
}

func TestParseVersionWithPattern_TwoParts(t *testing.T) {
	v, err := parseSimpleVersion("3.11")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if v.Major != 3 || v.Minor != 11 || v.Patch != 0 {
		t.Fatalf("parsed = %+v", v)
	}
}

func TestParseVersionWithPattern_ThreeParts(t *testing.T) {
	v, err := parseSimpleVersion("3.11.7")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if v.Major != 3 || v.Minor != 11 || v.Patch != 7 {
		t.Fatalf("parsed = %+v", v)
	}
}

func TestParseGoVersion(t *testing.T) {
	v, err := parseGoVersion("go version go1.21.5 linux/amd64")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if v.Major != 1 || v.Minor != 21 || v.Patch != 5 {
		t.Fatalf("parsed = %+v", v)
	}
}

func TestParseNodeVersion(t *testing.T) {
	v, err := parseNodeVersion("v18.17.0")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if v.Major != 18 || v.Minor != 17 || v.Patch != 0 {
		t.Fatalf("parsed = %+v", v)
	}
}

// ---------------------------------------------------------------------------
// resolveBinaryCandidate – no version parser
// ---------------------------------------------------------------------------

func TestResolveConfiguredBinary_EnvOverrideSuccess(t *testing.T) {
	patchBinaryResolvers(t)
	t.Setenv("FN_DOCKER_BIN", "custom-docker")

	binaryLookPathFn = func(file string) (string, error) {
		if file == "custom-docker" {
			return "/usr/local/bin/custom-docker", nil
		}
		return "", errBinaryNotFound
	}

	resolution, err := ResolveConfiguredBinary("docker")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resolution.Path != "/usr/local/bin/custom-docker" {
		t.Fatalf("expected /usr/local/bin/custom-docker, got %q", resolution.Path)
	}
	if resolution.Command != "custom-docker" {
		t.Fatalf("expected command=custom-docker, got %q", resolution.Command)
	}
}

func TestBinaryConfiguredCommand_NoCandidates(t *testing.T) {
	// Test the len(spec.DefaultCandidates) == 0 path.
	// We can't easily create a spec with no candidates without modifying binarySpecs,
	// but we can verify the existing "unknown" key returns empty.
	got := BinaryConfiguredCommand("unknown_binary_that_does_not_exist")
	if got != "" {
		t.Fatalf("expected empty for unknown key, got %q", got)
	}
}

func TestParseVersionWithPattern_AtoiError(t *testing.T) {
	// The regex matches digits, so strconv.Atoi shouldn't normally fail.
	// But the code guards against it. To trigger this, we'd need a regex
	// that captures non-digit groups. Since all version patterns only
	// capture \d+, this branch is essentially unreachable in practice.
	// We verify that normal parsing works correctly instead, and test
	// that the error path returns an error for malformed input.
	_, err := parseSimpleVersion("no version here at all")
	if err == nil {
		t.Fatal("expected error for no match")
	}
}

func TestBinaryConfiguredCommand_EmptyCandidates(t *testing.T) {
	// Temporarily register a spec with no DefaultCandidates to exercise lines 250-251.
	patchBinaryResolvers(t)

	origSpecs := binarySpecs
	t.Cleanup(func() { binarySpecs = origSpecs })

	binarySpecs = map[string]binarySpec{}
	for k, v := range origSpecs {
		binarySpecs[k] = v
	}
	binarySpecs["nocandidates"] = binarySpec{
		Key:               "nocandidates",
		Label:             "NoCandidates",
		EnvVar:            "FN_NOCANDIDATES_BIN",
		DefaultCandidates: nil,
	}
	t.Setenv("FN_NOCANDIDATES_BIN", "")

	got := BinaryConfiguredCommand("nocandidates")
	if got != "" {
		t.Fatalf("expected empty for spec with no candidates, got %q", got)
	}
}

func TestParseVersionWithPattern_AtoiErrorPath(t *testing.T) {
	// Use a custom regex that captures a non-digit group to trigger the Atoi error.
	pattern := regexp.MustCompile(`(\d+)\.(\w+)\.(\d+)`)
	_, err := parseVersionWithPattern("1.abc.3", pattern)
	if err == nil {
		t.Fatal("expected Atoi error for non-numeric capture group")
	}
}

func TestResolveBinaryCandidate_NoVersionParser(t *testing.T) {
	patchBinaryResolvers(t)
	binaryLookPathFn = func(file string) (string, error) {
		return "/usr/bin/" + file, nil
	}
	// docker has no VersionParser, so it should resolve without version check
	resolution, err := resolveBinaryCandidate(binarySpecs["docker"], "docker")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resolution.Version != "" {
		t.Fatalf("expected empty version for binary without version parser, got %q", resolution.Version)
	}
	if resolution.Key != "docker" {
		t.Fatalf("expected key=docker, got %q", resolution.Key)
	}
}

// ---------------------------------------------------------------------------
// binaryOutputFn default implementation
// ---------------------------------------------------------------------------

func TestBinaryOutputFn_DefaultImpl(t *testing.T) {
	// Save and restore the default binaryOutputFn.
	origOutput := binaryOutputFn
	origLook := binaryLookPathFn
	t.Cleanup(func() {
		binaryOutputFn = origOutput
		binaryLookPathFn = origLook
	})

	// Reset to the real default implementation (exec.Command + CombinedOutput).
	binaryOutputFn = origOutput

	out, err := binaryOutputFn("echo", "hello")
	if err != nil {
		t.Fatalf("binaryOutputFn(echo, hello) error = %v", err)
	}
	if !strings.Contains(out, "hello") {
		t.Fatalf("expected output to contain 'hello', got %q", out)
	}
}
