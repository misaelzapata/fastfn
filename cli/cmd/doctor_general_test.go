package cmd

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/misaelzapata/fastfn/cli/internal/discovery"
	"github.com/misaelzapata/fastfn/cli/internal/process"
	"github.com/spf13/viper"
)

// ---------------------------------------------------------------------------
// statusPrefix
// ---------------------------------------------------------------------------

func TestStatusPrefix(t *testing.T) {
	tests := []struct {
		in   doctorStatus
		want string
	}{
		{doctorStatusOK, "[OK]"},
		{doctorStatusWarn, "[WARN]"},
		{doctorStatusFail, "[FAIL]"},
		{doctorStatus("UNKNOWN"), "[INFO]"},
		{doctorStatus(""), "[INFO]"},
	}
	for _, tc := range tests {
		got := statusPrefix(tc.in)
		if got != tc.want {
			t.Errorf("statusPrefix(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// ---------------------------------------------------------------------------
// printDoctorReport
// ---------------------------------------------------------------------------

func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w
	fn()
	w.Close()
	os.Stdout = old
	var buf bytes.Buffer
	io.Copy(&buf, r)
	return buf.String()
}

func TestPrintDoctorReport_JSON(t *testing.T) {
	report := doctorReport{
		Scope:       "general",
		GeneratedAt: "2025-01-01T00:00:00Z",
		Checks: []doctorCheck{
			{ID: "test.check", Status: doctorStatusOK, Message: "all good"},
		},
		Summary: doctorSummary{OK: 1},
	}
	out := captureStdout(t, func() {
		if err := printDoctorReport(report, true); err != nil {
			t.Fatal(err)
		}
	})
	var parsed doctorReport
	if err := json.Unmarshal([]byte(out), &parsed); err != nil {
		t.Fatalf("invalid JSON output: %v\nraw: %s", err, out)
	}
	if parsed.Scope != "general" {
		t.Fatalf("unexpected scope: %q", parsed.Scope)
	}
	if len(parsed.Checks) != 1 {
		t.Fatalf("expected 1 check, got %d", len(parsed.Checks))
	}
}

func TestPrintDoctorReport_Text(t *testing.T) {
	report := doctorReport{
		Scope:       "general",
		GeneratedAt: "2025-01-01T00:00:00Z",
		Checks: []doctorCheck{
			{ID: "test.ok", Status: doctorStatusOK, Message: "ok check"},
			{ID: "test.warn", Status: doctorStatusWarn, Message: "warn check", Hint: "fix this"},
			{ID: "test.detail", Status: doctorStatusOK, Message: "detail check", Details: map[string]string{"key1": "val1", "key2": "val2"}},
			{Domain: "example.com", ID: "domain.check", Status: doctorStatusFail, Message: "domain fail"},
		},
		Summary: doctorSummary{OK: 2, Warn: 1, Fail: 1},
	}
	out := captureStdout(t, func() {
		if err := printDoctorReport(report, false); err != nil {
			t.Fatal(err)
		}
	})
	if !strings.Contains(out, "FastFN Doctor (general)") {
		t.Fatalf("missing header in output: %s", out)
	}
	if !strings.Contains(out, "[OK] test.ok: ok check") {
		t.Fatalf("missing OK check line: %s", out)
	}
	if !strings.Contains(out, "hint: fix this") {
		t.Fatalf("missing hint line: %s", out)
	}
	if !strings.Contains(out, "key1: val1") || !strings.Contains(out, "key2: val2") {
		t.Fatalf("missing detail lines: %s", out)
	}
	if !strings.Contains(out, "[example.com]") {
		t.Fatalf("missing domain prefix: %s", out)
	}
	if !strings.Contains(out, "Summary: OK=2 WARN=1 FAIL=1") {
		t.Fatalf("missing summary line: %s", out)
	}
}

func TestPrintDoctorReport_EmptyChecks(t *testing.T) {
	report := doctorReport{
		Scope:       "general",
		GeneratedAt: "2025-01-01T00:00:00Z",
		Checks:      []doctorCheck{},
		Summary:     doctorSummary{},
	}
	out := captureStdout(t, func() {
		if err := printDoctorReport(report, false); err != nil {
			t.Fatal(err)
		}
	})
	if !strings.Contains(out, "Summary: OK=0 WARN=0 FAIL=0") {
		t.Fatalf("unexpected summary for empty checks: %s", out)
	}
}

// ---------------------------------------------------------------------------
// checkPlatform
// ---------------------------------------------------------------------------

func TestCheckPlatform_Supported(t *testing.T) {
	oldOS, oldArch := doctorGOOS, doctorGOARCH
	t.Cleanup(func() { doctorGOOS, doctorGOARCH = oldOS, oldArch })

	doctorGOOS = "linux"
	doctorGOARCH = "amd64"
	c := checkPlatform()
	if c.Status != doctorStatusOK {
		t.Fatalf("expected OK for linux/amd64, got %s", c.Status)
	}

	doctorGOOS = "darwin"
	doctorGOARCH = "arm64"
	c = checkPlatform()
	if c.Status != doctorStatusOK {
		t.Fatalf("expected OK for darwin/arm64, got %s", c.Status)
	}
}

func TestCheckPlatform_Unsupported(t *testing.T) {
	oldOS, oldArch := doctorGOOS, doctorGOARCH
	t.Cleanup(func() { doctorGOOS, doctorGOARCH = oldOS, oldArch })

	doctorGOOS = "windows"
	doctorGOARCH = "386"
	c := checkPlatform()
	if c.Status != doctorStatusWarn {
		t.Fatalf("expected WARN for windows/386, got %s", c.Status)
	}
	if !strings.Contains(c.Hint, "amd64") {
		t.Fatalf("expected hint about preferred platforms, got: %s", c.Hint)
	}
}

// ---------------------------------------------------------------------------
// detectConfigPath
// ---------------------------------------------------------------------------

func withTempCwd(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	oldDir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chdir(oldDir) })
	return dir
}

func TestDetectConfigPath_CfgFileExplicit(t *testing.T) {
	dir := withTempCwd(t)
	oldCfg := cfgFile
	t.Cleanup(func() { cfgFile = oldCfg })

	explicit := filepath.Join(dir, "custom.json")
	os.WriteFile(explicit, []byte("{}"), 0644)
	cfgFile = explicit
	got := detectConfigPath()
	if got != explicit {
		t.Fatalf("expected %q, got %q", explicit, got)
	}
}

func TestDetectConfigPath_CfgFileExplicitMissing(t *testing.T) {
	withTempCwd(t)
	oldCfg := cfgFile
	t.Cleanup(func() { cfgFile = oldCfg })

	cfgFile = "/nonexistent/custom.json"
	got := detectConfigPath()
	if got != "" {
		t.Fatalf("expected empty, got %q", got)
	}
}

func TestDetectConfigPath_FastfnJSON(t *testing.T) {
	withTempCwd(t)
	oldCfg := cfgFile
	t.Cleanup(func() { cfgFile = oldCfg })
	cfgFile = ""

	os.WriteFile("fastfn.json", []byte("{}"), 0644)
	got := detectConfigPath()
	if got != "fastfn.json" {
		t.Fatalf("expected fastfn.json, got %q", got)
	}
}

func TestDetectConfigPath_FastfnTOML(t *testing.T) {
	withTempCwd(t)
	oldCfg := cfgFile
	t.Cleanup(func() { cfgFile = oldCfg })
	cfgFile = ""

	os.WriteFile("fastfn.toml", []byte("[server]"), 0644)
	got := detectConfigPath()
	if got != "fastfn.toml" {
		t.Fatalf("expected fastfn.toml, got %q", got)
	}
}

func TestDetectConfigPath_NoneExists(t *testing.T) {
	withTempCwd(t)
	oldCfg := cfgFile
	t.Cleanup(func() { cfgFile = oldCfg })
	cfgFile = ""

	got := detectConfigPath()
	if got != "" {
		t.Fatalf("expected empty, got %q", got)
	}
}

// ---------------------------------------------------------------------------
// checkConfigFile
// ---------------------------------------------------------------------------

func TestCheckConfigFile_NoConfigNoFix(t *testing.T) {
	withTempCwd(t)
	oldCfg := cfgFile
	t.Cleanup(func() { cfgFile = oldCfg })
	cfgFile = ""

	c, fixed := checkConfigFile(false)
	if c.Status != doctorStatusWarn {
		t.Fatalf("expected WARN, got %s", c.Status)
	}
	if fixed {
		t.Fatal("expected fixed=false")
	}
}

func TestCheckConfigFile_NoConfigApplyFix(t *testing.T) {
	withTempCwd(t)
	oldCfg := cfgFile
	t.Cleanup(func() { cfgFile = oldCfg })
	cfgFile = ""

	c, fixed := checkConfigFile(true)
	if c.Status != doctorStatusOK {
		t.Fatalf("expected OK after fix, got %s", c.Status)
	}
	if !fixed {
		t.Fatal("expected fixed=true")
	}
	data, err := os.ReadFile("fastfn.json")
	if err != nil {
		t.Fatalf("fastfn.json not created: %v", err)
	}
	if !strings.Contains(string(data), "functions-dir") {
		t.Fatalf("created config missing functions-dir: %s", data)
	}
}

func TestCheckConfigFile_ApplyFixWriteError(t *testing.T) {
	dir := withTempCwd(t)
	oldCfg := cfgFile
	t.Cleanup(func() { cfgFile = oldCfg })
	cfgFile = ""

	// Make the directory read-only so os.WriteFile fails
	if err := os.Chmod(dir, 0o555); err != nil {
		t.Skipf("chmod not supported: %v", err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o755) })

	c, fixed := checkConfigFile(true)
	if c.Status != doctorStatusFail {
		t.Fatalf("expected FAIL when write fails, got %s: %s", c.Status, c.Message)
	}
	if fixed {
		t.Fatal("expected fixed=false when write fails")
	}
	if !strings.Contains(c.Message, "Failed to auto-create") {
		t.Fatalf("expected auto-create failure message, got: %s", c.Message)
	}
}

func TestCheckExecutable_EmptyVersionOutput(t *testing.T) {
	// Test the version=="" path (line 740): when cmd outputs empty string.
	// Use a command that produces empty output.
	c := checkExecutable("true", []string{}, "test.true", "True binary")
	// "true" produces no output, so version should be "found at <path>"
	if c.Details["version"] == "" {
		t.Fatal("expected version to have fallback text")
	}
	if !strings.HasPrefix(c.Details["version"], "found at ") {
		t.Fatalf("expected 'found at' fallback, got: %s", c.Details["version"])
	}
}

func TestCheckConfiguredExecutable_VersionEmptyOutput(t *testing.T) {
	// To test the version=="" path, we need ResolveConfiguredBinary to succeed,
	// then the version command to produce empty output.
	// Use "docker" with a command that produces no output. Since docker may not
	// be installed, we override FN_DOCKER_BIN to point to "true" which exists
	// and produces no output. But ResolveConfiguredBinary for "docker" with
	// path "true" would look it up in PATH.
	if _, err := exec.LookPath("true"); err != nil {
		t.Skip("'true' binary not available")
	}
	t.Setenv("FN_DOCKER_BIN", "true")
	// "docker" has no version parser in binarySpecs, so ResolveBinary will
	// find "true" in PATH and succeed with empty version.
	c := checkConfiguredExecutable("docker", []string{}, "docker.cli", "Docker CLI")
	// "true" produces no output, so version should be "found at <path>"
	if c.Status != doctorStatusOK {
		t.Fatalf("expected OK status, got %s: %s", c.Status, c.Message)
	}
	if c.Details["version"] == "" {
		t.Fatal("expected version fallback text")
	}
	if !strings.HasPrefix(c.Details["version"], "found at ") {
		t.Fatalf("expected 'found at' fallback, got: %s", c.Details["version"])
	}
}

func TestCheckConfigFile_TOMLFallback(t *testing.T) {
	withTempCwd(t)
	oldCfg := cfgFile
	t.Cleanup(func() { cfgFile = oldCfg })
	cfgFile = ""

	os.WriteFile("fastfn.toml", []byte("[server]"), 0644)
	c, fixed := checkConfigFile(false)
	if c.Status != doctorStatusWarn {
		t.Fatalf("expected WARN for TOML fallback, got %s", c.Status)
	}
	if fixed {
		t.Fatal("expected fixed=false for TOML")
	}
	if !strings.Contains(c.Hint, "fastfn.json") {
		t.Fatalf("expected hint about preferring JSON, got: %s", c.Hint)
	}
}

func TestCheckConfigFile_ValidJSON(t *testing.T) {
	withTempCwd(t)
	oldCfg := cfgFile
	t.Cleanup(func() { cfgFile = oldCfg })
	cfgFile = ""

	os.WriteFile("fastfn.json", []byte(`{"functions-dir": "."}`), 0644)
	c, fixed := checkConfigFile(false)
	if c.Status != doctorStatusOK {
		t.Fatalf("expected OK, got %s: %s", c.Status, c.Message)
	}
	if fixed {
		t.Fatal("expected fixed=false")
	}
}

func TestCheckConfigFile_InvalidJSON(t *testing.T) {
	withTempCwd(t)
	oldCfg := cfgFile
	t.Cleanup(func() { cfgFile = oldCfg })
	cfgFile = ""

	os.WriteFile("fastfn.json", []byte(`{invalid json`), 0644)
	c, fixed := checkConfigFile(false)
	if c.Status != doctorStatusFail {
		t.Fatalf("expected FAIL for invalid JSON, got %s", c.Status)
	}
	if fixed {
		t.Fatal("expected fixed=false")
	}
}

func TestCheckConfigFile_UnreadableFile(t *testing.T) {
	dir := withTempCwd(t)
	oldCfg := cfgFile
	t.Cleanup(func() { cfgFile = oldCfg })

	// Point cfgFile to a file inside a directory we can't read.
	unreadableDir := filepath.Join(dir, "noperm")
	os.Mkdir(unreadableDir, 0755)
	filePath := filepath.Join(unreadableDir, "fastfn.json")
	os.WriteFile(filePath, []byte(`{}`), 0644)
	os.Chmod(filePath, 0000)
	t.Cleanup(func() { os.Chmod(filePath, 0644) })

	cfgFile = filePath
	c, fixed := checkConfigFile(false)
	if c.Status != doctorStatusFail {
		t.Fatalf("expected FAIL for unreadable file, got %s: %s", c.Status, c.Message)
	}
	if fixed {
		t.Fatal("expected fixed=false")
	}
}

func TestCheckConfigFile_ValidJSONBadDomains(t *testing.T) {
	withTempCwd(t)
	oldCfg := cfgFile
	t.Cleanup(func() { cfgFile = oldCfg })
	cfgFile = ""

	// domains is an integer, which parseDomainTargets rejects.
	os.WriteFile("fastfn.json", []byte(`{"functions-dir": ".", "domains": 42}`), 0644)
	c, fixed := checkConfigFile(false)
	if c.Status != doctorStatusWarn {
		t.Fatalf("expected WARN for bad domains block, got %s: %s", c.Status, c.Message)
	}
	if !strings.Contains(c.Message, "domains block has issues") {
		t.Fatalf("expected domains issue message, got: %s", c.Message)
	}
	if fixed {
		t.Fatal("expected fixed=false")
	}
}

// ---------------------------------------------------------------------------
// checkFunctionsDir
// ---------------------------------------------------------------------------

func TestCheckFunctionsDir_Exists(t *testing.T) {
	withTempCwd(t)
	// "." always exists so default works
	c := checkFunctionsDir()
	if c.Status != doctorStatusOK {
		t.Fatalf("expected OK, got %s", c.Status)
	}
}

func TestCheckFunctionsDir_Missing(t *testing.T) {
	withTempCwd(t)

	viper.Set("functions-dir", "nonexistent_funcs_dir_12345")
	t.Cleanup(func() { viper.Set("functions-dir", nil) })

	c := checkFunctionsDir()
	if c.Status != doctorStatusFail {
		t.Fatalf("expected FAIL for missing functions dir, got %s: %s", c.Status, c.Message)
	}
	if !strings.Contains(c.Message, "nonexistent_funcs_dir_12345") {
		t.Fatalf("expected missing dir name in message, got: %s", c.Message)
	}
}

func TestCheckFunctionDiscovery_OK(t *testing.T) {
	withTempCwd(t)
	origScan := doctorDiscoveryScanFn
	t.Cleanup(func() { doctorDiscoveryScanFn = origScan })

	doctorDiscoveryScanFn = func(root string, logFn discovery.Logger) ([]discovery.Function, error) {
		if logFn != nil {
			logFn("scanned ok")
		}
		return nil, nil
	}

	c := checkFunctionDiscovery()
	if c.Status != doctorStatusOK {
		t.Fatalf("expected OK, got %s: %s", c.Status, c.Message)
	}
}

func TestCheckFunctionDiscovery_WarnsOnRouteConflicts(t *testing.T) {
	withTempCwd(t)
	origScan := doctorDiscoveryScanFn
	t.Cleanup(func() { doctorDiscoveryScanFn = origScan })

	doctorDiscoveryScanFn = func(root string, logFn discovery.Logger) ([]discovery.Function, error) {
		if logFn != nil {
			logFn("WARNING: route conflict GET /users resolves to multiple targets")
		}
		return []discovery.Function{{OriginalRoute: "GET /users"}}, nil
	}

	c := checkFunctionDiscovery()
	if c.Status != doctorStatusWarn {
		t.Fatalf("expected WARN, got %s: %s", c.Status, c.Message)
	}
	if c.Details == nil || !strings.Contains(c.Details["conflicts"], "route conflict") {
		t.Fatalf("expected conflict details, got %#v", c.Details)
	}
}

func TestCheckFunctionDiscovery_FailsWhenScanErrors(t *testing.T) {
	withTempCwd(t)
	origScan := doctorDiscoveryScanFn
	t.Cleanup(func() { doctorDiscoveryScanFn = origScan })

	doctorDiscoveryScanFn = func(root string, logFn discovery.Logger) ([]discovery.Function, error) {
		return nil, fmt.Errorf("scan failed")
	}

	c := checkFunctionDiscovery()
	if c.Status != doctorStatusFail {
		t.Fatalf("expected FAIL, got %s: %s", c.Status, c.Message)
	}
}

func TestCheckFunctionDiscovery_WarnsWhenFunctionsDirIsMissing(t *testing.T) {
	withTempCwd(t)
	t.Cleanup(viper.Reset)
	viper.Reset()
	viper.Set("functions-dir", "missing-functions-dir")

	c := checkFunctionDiscovery()
	if c.Status != doctorStatusWarn {
		t.Fatalf("expected WARN, got %s: %s", c.Status, c.Message)
	}
	if !strings.Contains(c.Message, "missing-functions-dir") {
		t.Fatalf("expected missing dir in message, got %s", c.Message)
	}
}

// ---------------------------------------------------------------------------
// checkPortAvailability
// ---------------------------------------------------------------------------

func TestCheckPortAvailability_Available(t *testing.T) {
	// Find a free port.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close()

	t.Setenv("FN_HOST_PORT", fmt.Sprintf("%d", port))
	c := checkPortAvailability()
	if c.Status != doctorStatusOK {
		t.Fatalf("expected OK for free port, got %s: %s", c.Status, c.Message)
	}
}

func TestCheckPortAvailability_InUse(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port

	t.Setenv("FN_HOST_PORT", fmt.Sprintf("%d", port))
	c := checkPortAvailability()
	if c.Status != doctorStatusWarn {
		t.Fatalf("expected WARN for port in use, got %s: %s", c.Status, c.Message)
	}
}

func TestCheckPortAvailability_InvalidPort(t *testing.T) {
	t.Setenv("FN_HOST_PORT", "notanumber")
	c := checkPortAvailability()
	if c.Status != doctorStatusFail {
		t.Fatalf("expected FAIL for invalid port, got %s: %s", c.Status, c.Message)
	}
}

func TestCheckPortAvailability_OutOfRange(t *testing.T) {
	t.Setenv("FN_HOST_PORT", "99999")
	c := checkPortAvailability()
	if c.Status != doctorStatusFail {
		t.Fatalf("expected FAIL for out-of-range port, got %s: %s", c.Status, c.Message)
	}
}

func TestCheckPortAvailability_Default8080(t *testing.T) {
	t.Setenv("FN_HOST_PORT", "")
	c := checkPortAvailability()
	// Port 8080 may or may not be available; just ensure no crash.
	if c.Status != doctorStatusOK && c.Status != doctorStatusWarn {
		t.Fatalf("expected OK or WARN for default port, got %s", c.Status)
	}
}

// ---------------------------------------------------------------------------
// checkDockerDaemon (limited: depends on system state)
// ---------------------------------------------------------------------------

func TestCheckDockerDaemon_Runs(t *testing.T) {
	// This is a smoke test. We can't control whether Docker is present.
	c := checkDockerDaemon()
	// Just verify a valid status is returned.
	switch c.Status {
	case doctorStatusOK, doctorStatusWarn, doctorStatusFail:
		// OK
	default:
		t.Fatalf("unexpected status: %s", c.Status)
	}
	if c.ID != "docker.daemon" {
		t.Fatalf("unexpected ID: %s", c.ID)
	}
}

// ---------------------------------------------------------------------------
// checkExecutable
// ---------------------------------------------------------------------------

func TestCheckExecutable_NotFound(t *testing.T) {
	c := checkExecutable("__fastfn_test_nonexistent_binary__", []string{"--version"}, "test.bin", "Test Binary")
	if c.Status != doctorStatusWarn {
		t.Fatalf("expected WARN for missing binary, got %s", c.Status)
	}
	if !strings.Contains(c.Message, "not found") {
		t.Fatalf("expected 'not found' message, got: %s", c.Message)
	}
}

func TestCheckExecutable_Found(t *testing.T) {
	// "go" should be available in test environments.
	c := checkExecutable("go", []string{"version"}, "test.go", "Go runtime")
	if c.Status != doctorStatusOK {
		t.Fatalf("expected OK for go binary, got %s: %s", c.Status, c.Message)
	}
	if !strings.Contains(c.Message, "available") {
		t.Fatalf("expected 'available' message, got: %s", c.Message)
	}
	if c.Details["path"] == "" {
		t.Fatal("expected path in details")
	}
}

func TestCheckExecutable_FoundVersionFailed(t *testing.T) {
	// Use "go" with an invalid subcommand to trigger version probe failure.
	c := checkExecutable("go", []string{"__invalid_cmd__"}, "test.go", "Go runtime")
	if c.Status != doctorStatusWarn {
		t.Fatalf("expected WARN for version probe failure, got %s", c.Status)
	}
	if !strings.Contains(c.Message, "version probe failed") {
		t.Fatalf("expected 'version probe failed' message, got: %s", c.Message)
	}
}

// ---------------------------------------------------------------------------
// checkConfiguredExecutable
// ---------------------------------------------------------------------------

func TestCheckConfiguredExecutable_NotFound(t *testing.T) {
	c := checkConfiguredExecutable("__nonexistent__", []string{"--version"}, "test.bin", "Test Binary")
	if c.Status != doctorStatusWarn {
		t.Fatalf("expected WARN, got %s", c.Status)
	}
	if !strings.Contains(c.Message, "not found") {
		t.Fatalf("expected 'not found' message, got: %s", c.Message)
	}
}

func TestCheckConfiguredExecutable_NotFoundWithEnvOverride(t *testing.T) {
	// Set the env var for the docker binary to an invalid path.
	t.Setenv("FN_DOCKER_BIN", "/nonexistent/docker")
	c := checkConfiguredExecutable("docker", []string{"--version"}, "docker.cli", "Docker CLI")
	if c.Status != doctorStatusWarn {
		t.Fatalf("expected WARN, got %s", c.Status)
	}
	if !strings.Contains(c.Message, "override") || !strings.Contains(c.Message, "invalid") {
		t.Fatalf("expected override-invalid message, got: %s", c.Message)
	}
}

func TestCheckConfiguredExecutable_Found(t *testing.T) {
	// "go" should be present.
	c := checkConfiguredExecutable("go", []string{"version"}, "runtime.go", "Go runtime")
	if c.Status != doctorStatusOK {
		t.Fatalf("expected OK, got %s: %s", c.Status, c.Message)
	}
}

func TestCheckConfiguredExecutable_VersionProbeFailed(t *testing.T) {
	c := checkConfiguredExecutable("go", []string{"__invalid_cmd__"}, "runtime.go", "Go runtime")
	if c.Status != doctorStatusWarn {
		t.Fatalf("expected WARN for version probe failure, got %s", c.Status)
	}
	if !strings.Contains(c.Message, "version probe failed") {
		t.Fatalf("expected 'version probe failed' message, got: %s", c.Message)
	}
}

// ---------------------------------------------------------------------------
// runGeneralDoctorChecks
// ---------------------------------------------------------------------------

func TestRunGeneralDoctorChecks_Smoke(t *testing.T) {
	dir := withTempCwd(t)
	oldCfg := cfgFile
	t.Cleanup(func() { cfgFile = oldCfg })
	cfgFile = ""

	// Create a minimal config so the config check passes.
	os.WriteFile(filepath.Join(dir, "fastfn.json"), []byte(`{"functions-dir": "."}`), 0644)

	report := runGeneralDoctorChecks(false)
	if report.Scope != "general" {
		t.Fatalf("unexpected scope: %q", report.Scope)
	}
	if len(report.Checks) == 0 {
		t.Fatal("expected checks to be populated")
	}
	if report.GeneratedAt == "" {
		t.Fatal("expected GeneratedAt to be set")
	}
}

func TestRunGeneralDoctorChecks_ApplyFix(t *testing.T) {
	withTempCwd(t)
	oldCfg := cfgFile
	t.Cleanup(func() { cfgFile = oldCfg })
	cfgFile = ""

	report := runGeneralDoctorChecks(true)
	// Look for the fix-applied check.
	var foundFix bool
	for _, c := range report.Checks {
		if c.ID == "project.config.fix" {
			foundFix = true
			if c.Status != doctorStatusOK {
				t.Fatalf("expected OK for fix check, got %s", c.Status)
			}
		}
	}
	if !foundFix {
		t.Fatal("expected project.config.fix check when applyFix=true and no config exists")
	}
	if _, err := os.Stat("fastfn.json"); err != nil {
		t.Fatalf("expected fastfn.json to be created: %v", err)
	}
}

// ---------------------------------------------------------------------------
// doctorCmd.RunE
// ---------------------------------------------------------------------------

func TestDoctorCmd_RunE_NoFailures(t *testing.T) {
	oldGeneral := runGeneralDoctorChecksFn
	oldPrint := printDoctorReportFn
	t.Cleanup(func() {
		runGeneralDoctorChecksFn = oldGeneral
		printDoctorReportFn = oldPrint
	})

	runGeneralDoctorChecksFn = func(applyFix bool) doctorReport {
		return doctorReport{
			Scope:   "general",
			Checks:  []doctorCheck{{ID: "test", Status: doctorStatusOK, Message: "ok"}},
			Summary: doctorSummary{OK: 1},
		}
	}
	printDoctorReportFn = func(report doctorReport, asJSON bool) error {
		return nil
	}

	err := doctorCmd.RunE(doctorCmd, nil)
	if err != nil {
		t.Fatalf("expected no error, got: %v", err)
	}
}

func TestDoctorCmd_RunE_WithFailures(t *testing.T) {
	oldGeneral := runGeneralDoctorChecksFn
	oldPrint := printDoctorReportFn
	t.Cleanup(func() {
		runGeneralDoctorChecksFn = oldGeneral
		printDoctorReportFn = oldPrint
	})

	runGeneralDoctorChecksFn = func(applyFix bool) doctorReport {
		return doctorReport{
			Scope:   "general",
			Checks:  []doctorCheck{{ID: "test", Status: doctorStatusFail, Message: "bad"}},
			Summary: doctorSummary{Fail: 1},
		}
	}
	printDoctorReportFn = func(report doctorReport, asJSON bool) error {
		return nil
	}

	err := doctorCmd.RunE(doctorCmd, nil)
	if err == nil {
		t.Fatal("expected error when failures present")
	}
	if !strings.Contains(err.Error(), "1 failing check") {
		t.Fatalf("unexpected error message: %v", err)
	}
}

func TestDoctorCmd_RunE_JSONMode(t *testing.T) {
	oldGeneral := runGeneralDoctorChecksFn
	oldPrint := printDoctorReportFn
	oldJSON := doctorJSON
	t.Cleanup(func() {
		runGeneralDoctorChecksFn = oldGeneral
		printDoctorReportFn = oldPrint
		doctorJSON = oldJSON
	})

	doctorJSON = true
	var capturedJSON bool
	runGeneralDoctorChecksFn = func(applyFix bool) doctorReport {
		return doctorReport{
			Scope:   "general",
			Checks:  []doctorCheck{{ID: "test", Status: doctorStatusOK, Message: "ok"}},
			Summary: doctorSummary{OK: 1},
		}
	}
	printDoctorReportFn = func(report doctorReport, asJSON bool) error {
		capturedJSON = asJSON
		return nil
	}

	err := doctorCmd.RunE(doctorCmd, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !capturedJSON {
		t.Fatal("expected JSON flag to be passed to printDoctorReport")
	}
}

// ---------------------------------------------------------------------------
// doctorDomainsCmd.RunE
// ---------------------------------------------------------------------------

func TestDoctorDomainsCmd_RunE_ResolveError(t *testing.T) {
	oldResolve := resolveDomainTargetsFn
	oldPrint := printDoctorReportFn
	t.Cleanup(func() {
		resolveDomainTargetsFn = oldResolve
		printDoctorReportFn = oldPrint
	})

	resolveDomainTargetsFn = func(flagDomains []string, expectedTarget string, enforceHTTPS bool) ([]domainTarget, error) {
		return nil, fmt.Errorf("no valid domains")
	}

	err := doctorDomainsCmd.RunE(doctorDomainsCmd, nil)
	if err == nil {
		t.Fatal("expected error on resolve failure")
	}
	if !strings.Contains(err.Error(), "no valid domains") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestDoctorDomainsCmd_RunE_Success(t *testing.T) {
	oldResolve := resolveDomainTargetsFn
	oldRun := runDomainDoctorChecksFn
	oldPrint := printDoctorReportFn
	oldNewProber := newNetDomainProberFn
	t.Cleanup(func() {
		resolveDomainTargetsFn = oldResolve
		runDomainDoctorChecksFn = oldRun
		printDoctorReportFn = oldPrint
		newNetDomainProberFn = oldNewProber
	})

	resolveDomainTargetsFn = func(flagDomains []string, expectedTarget string, enforceHTTPS bool) ([]domainTarget, error) {
		return []domainTarget{{Domain: "api.example.com"}}, nil
	}
	runDomainDoctorChecksFn = func(ctx context.Context, targets []domainTarget, prober domainProber) doctorReport {
		return doctorReport{
			Scope:   "domains",
			Checks:  []doctorCheck{{ID: "test", Status: doctorStatusOK, Message: "ok"}},
			Summary: doctorSummary{OK: 1},
		}
	}
	printDoctorReportFn = func(report doctorReport, asJSON bool) error {
		return nil
	}
	newNetDomainProberFn = func(timeout time.Duration) *netDomainProber {
		return &netDomainProber{}
	}

	err := doctorDomainsCmd.RunE(doctorDomainsCmd, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestDoctorDomainsCmd_RunE_WithFailures(t *testing.T) {
	oldResolve := resolveDomainTargetsFn
	oldRun := runDomainDoctorChecksFn
	oldPrint := printDoctorReportFn
	oldNewProber := newNetDomainProberFn
	t.Cleanup(func() {
		resolveDomainTargetsFn = oldResolve
		runDomainDoctorChecksFn = oldRun
		printDoctorReportFn = oldPrint
		newNetDomainProberFn = oldNewProber
	})

	resolveDomainTargetsFn = func(flagDomains []string, expectedTarget string, enforceHTTPS bool) ([]domainTarget, error) {
		return []domainTarget{{Domain: "bad.example.com"}}, nil
	}
	runDomainDoctorChecksFn = func(ctx context.Context, targets []domainTarget, prober domainProber) doctorReport {
		return doctorReport{
			Scope:   "domains",
			Checks:  []doctorCheck{{ID: "test", Status: doctorStatusFail, Message: "bad"}},
			Summary: doctorSummary{Fail: 1},
		}
	}
	printDoctorReportFn = func(report doctorReport, asJSON bool) error {
		return nil
	}
	newNetDomainProberFn = func(timeout time.Duration) *netDomainProber {
		return &netDomainProber{}
	}

	err := doctorDomainsCmd.RunE(doctorDomainsCmd, nil)
	if err == nil {
		t.Fatal("expected error when failures present")
	}
	if !strings.Contains(err.Error(), "1 failing check") {
		t.Fatalf("unexpected error: %v", err)
	}
}

// ---------------------------------------------------------------------------
// netDomainProber.TLSInfo (with mock tlsProbeConn)
// ---------------------------------------------------------------------------

type fakeTLSProbeConn struct {
	setDeadlineErr error
	handshakeErr   error
	state          tls.ConnectionState
	closed         bool
}

func (f *fakeTLSProbeConn) SetDeadline(t time.Time) error {
	return f.setDeadlineErr
}

func (f *fakeTLSProbeConn) HandshakeContext(ctx context.Context) error {
	return f.handshakeErr
}

func (f *fakeTLSProbeConn) ConnectionState() tls.ConnectionState {
	return f.state
}

func (f *fakeTLSProbeConn) Close() error {
	f.closed = true
	return nil
}

func TestNetDomainProber_TLSInfo_Success(t *testing.T) {
	oldDial := dialTLSProbeConnFn
	t.Cleanup(func() { dialTLSProbeConnFn = oldDial })

	fakeConn := &fakeTLSProbeConn{
		state: tls.ConnectionState{
			PeerCertificates: []*x509.Certificate{
				{
					NotAfter: time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC),
					DNSNames: []string{"example.com", "*.example.com"},
				},
			},
		},
	}

	dialTLSProbeConnFn = func(host string) (tlsProbeConn, error) {
		return fakeConn, nil
	}

	prober := &netDomainProber{}
	result, err := prober.TLSInfo(context.Background(), "example.com")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.NotAfter.IsZero() {
		t.Fatal("expected NotAfter to be set")
	}
	if !fakeConn.closed {
		t.Fatal("expected connection to be closed")
	}
}

func TestNetDomainProber_TLSInfo_DialError(t *testing.T) {
	oldDial := dialTLSProbeConnFn
	t.Cleanup(func() { dialTLSProbeConnFn = oldDial })

	dialTLSProbeConnFn = func(host string) (tlsProbeConn, error) {
		return nil, fmt.Errorf("connection refused")
	}

	prober := &netDomainProber{}
	_, err := prober.TLSInfo(context.Background(), "example.com")
	if err == nil {
		t.Fatal("expected error on dial failure")
	}
}

func TestNetDomainProber_TLSInfo_SetDeadlineError(t *testing.T) {
	oldDial := dialTLSProbeConnFn
	t.Cleanup(func() { dialTLSProbeConnFn = oldDial })

	fakeConn := &fakeTLSProbeConn{
		setDeadlineErr: fmt.Errorf("deadline error"),
	}
	dialTLSProbeConnFn = func(host string) (tlsProbeConn, error) {
		return fakeConn, nil
	}

	prober := &netDomainProber{}
	_, err := prober.TLSInfo(context.Background(), "example.com")
	if err == nil {
		t.Fatal("expected error on SetDeadline failure")
	}
}

func TestNetDomainProber_TLSInfo_HandshakeError(t *testing.T) {
	oldDial := dialTLSProbeConnFn
	t.Cleanup(func() { dialTLSProbeConnFn = oldDial })

	fakeConn := &fakeTLSProbeConn{
		handshakeErr: fmt.Errorf("handshake failed"),
	}
	dialTLSProbeConnFn = func(host string) (tlsProbeConn, error) {
		return fakeConn, nil
	}

	prober := &netDomainProber{}
	_, err := prober.TLSInfo(context.Background(), "example.com")
	if err == nil {
		t.Fatal("expected error on handshake failure")
	}
}

func TestNetDomainProber_TLSInfo_NoCert(t *testing.T) {
	oldDial := dialTLSProbeConnFn
	t.Cleanup(func() { dialTLSProbeConnFn = oldDial })

	fakeConn := &fakeTLSProbeConn{
		state: tls.ConnectionState{
			PeerCertificates: []*x509.Certificate{},
		},
	}
	dialTLSProbeConnFn = func(host string) (tlsProbeConn, error) {
		return fakeConn, nil
	}

	prober := &netDomainProber{}
	_, err := prober.TLSInfo(context.Background(), "example.com")
	if err == nil {
		t.Fatal("expected error when no peer certificates")
	}
	if !strings.Contains(err.Error(), "no peer certificate") {
		t.Fatalf("unexpected error: %v", err)
	}
}

// ---------------------------------------------------------------------------
// netDomainProber.HTTPInfo
// ---------------------------------------------------------------------------

func TestNetDomainProber_HTTPInfo_Success(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	}))
	defer srv.Close()

	prober := newNetDomainProber(5 * time.Second)
	result, err := prober.HTTPInfo(context.Background(), srv.URL)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.StatusCode != 200 {
		t.Fatalf("expected 200, got %d", result.StatusCode)
	}
	if result.FinalURL != srv.URL {
		t.Fatalf("unexpected final URL: %q", result.FinalURL)
	}
}

func TestNetDomainProber_HTTPInfo_Error(t *testing.T) {
	prober := newNetDomainProber(5 * time.Second)
	_, err := prober.HTTPInfo(context.Background(), "http://[::1]:0/invalid")
	if err == nil {
		t.Fatal("expected error for unreachable URL")
	}
}

func TestNetDomainProber_HTTPInfo_InvalidURL(t *testing.T) {
	prober := newNetDomainProber(5 * time.Second)
	_, err := prober.HTTPInfo(context.Background(), "://bad-url")
	if err == nil {
		t.Fatal("expected error for invalid URL")
	}
}

// ---------------------------------------------------------------------------
// firstMapString
// ---------------------------------------------------------------------------

func TestFirstMapString_StringValue(t *testing.T) {
	m := map[string]any{"name": "hello"}
	got := firstMapString(m, "name")
	if got != "hello" {
		t.Fatalf("expected 'hello', got %q", got)
	}
}

func TestFirstMapString_NonStringValue(t *testing.T) {
	m := map[string]any{"count": 42}
	got := firstMapString(m, "count")
	if got != "42" {
		t.Fatalf("expected '42' via fmt.Sprint, got %q", got)
	}
}

func TestFirstMapString_NilValue(t *testing.T) {
	m := map[string]any{"key": nil}
	got := firstMapString(m, "key")
	if got != "" {
		t.Fatalf("expected empty for nil value, got %q", got)
	}
}

func TestFirstMapString_EmptyString(t *testing.T) {
	m := map[string]any{"key": "  "}
	got := firstMapString(m, "key")
	if got != "" {
		t.Fatalf("expected empty for whitespace-only string, got %q", got)
	}
}

func TestFirstMapString_MissingKey(t *testing.T) {
	m := map[string]any{"other": "val"}
	got := firstMapString(m, "missing")
	if got != "" {
		t.Fatalf("expected empty for missing key, got %q", got)
	}
}

func TestFirstMapString_FallbackKeys(t *testing.T) {
	m := map[string]any{"alt": "found"}
	got := firstMapString(m, "primary", "alt")
	if got != "found" {
		t.Fatalf("expected 'found' from fallback key, got %q", got)
	}
}

// ---------------------------------------------------------------------------
// firstMapBoolDefault
// ---------------------------------------------------------------------------

func TestFirstMapBoolDefault_BoolValue(t *testing.T) {
	m := map[string]any{"flag": true}
	got := firstMapBoolDefault(m, false, "flag")
	if !got {
		t.Fatal("expected true")
	}
}

func TestFirstMapBoolDefault_StringFalse(t *testing.T) {
	m := map[string]any{"flag": "false"}
	got := firstMapBoolDefault(m, true, "flag")
	if got {
		t.Fatal("expected false from string 'false'")
	}
}

func TestFirstMapBoolDefault_StringTrue(t *testing.T) {
	m := map[string]any{"flag": "true"}
	got := firstMapBoolDefault(m, false, "flag")
	if !got {
		t.Fatal("expected true from string 'true'")
	}
}

func TestFirstMapBoolDefault_MissingKeyReturnsDefault(t *testing.T) {
	m := map[string]any{"other": true}
	got := firstMapBoolDefault(m, false, "missing")
	if got {
		t.Fatal("expected default false for missing key")
	}
	got = firstMapBoolDefault(m, true, "missing")
	if !got {
		t.Fatal("expected default true for missing key")
	}
}

func TestFirstMapBoolDefault_InvalidStringReturnsDefault(t *testing.T) {
	m := map[string]any{"flag": "notabool"}
	got := firstMapBoolDefault(m, true, "flag")
	// "notabool" can't be parsed, so it continues to next key, then returns default.
	if !got {
		t.Fatal("expected default true for unparseable string")
	}
}

// ---------------------------------------------------------------------------
// newNetDomainProber
// ---------------------------------------------------------------------------

func TestCheckDockerDaemon_DockerNotFound(t *testing.T) {
	origResolve := doctorResolveDockerBinaryFn
	t.Cleanup(func() { doctorResolveDockerBinaryFn = origResolve })

	doctorResolveDockerBinaryFn = func() (process.BinaryResolution, error) {
		return process.BinaryResolution{}, fmt.Errorf("not found")
	}

	check := checkDockerDaemon()
	if check.Status != doctorStatusWarn {
		t.Fatalf("expected warn status, got %s", check.Status)
	}
	if !strings.Contains(check.Message, "skipped") {
		t.Fatalf("expected 'skipped' in message, got %q", check.Message)
	}
}

func TestCheckDockerDaemon_DaemonNotReachable(t *testing.T) {
	origResolve := doctorResolveDockerBinaryFn
	origInfo := doctorDockerInfoFn
	t.Cleanup(func() {
		doctorResolveDockerBinaryFn = origResolve
		doctorDockerInfoFn = origInfo
	})

	doctorResolveDockerBinaryFn = func() (process.BinaryResolution, error) {
		return process.BinaryResolution{Path: "/usr/bin/docker"}, nil
	}
	doctorDockerInfoFn = func(dockerPath string) (string, error) {
		return "Cannot connect to the Docker daemon", fmt.Errorf("exit status 1")
	}

	check := checkDockerDaemon()
	if check.Status != doctorStatusFail {
		t.Fatalf("expected fail status, got %s", check.Status)
	}
	if !strings.Contains(check.Message, "not reachable") {
		t.Fatalf("expected 'not reachable' in message, got %q", check.Message)
	}
}

func TestCheckDockerDaemon_Success(t *testing.T) {
	origResolve := doctorResolveDockerBinaryFn
	origInfo := doctorDockerInfoFn
	t.Cleanup(func() {
		doctorResolveDockerBinaryFn = origResolve
		doctorDockerInfoFn = origInfo
	})

	doctorResolveDockerBinaryFn = func() (process.BinaryResolution, error) {
		return process.BinaryResolution{Path: "/usr/bin/docker"}, nil
	}
	doctorDockerInfoFn = func(dockerPath string) (string, error) {
		return "24.0.7", nil
	}

	check := checkDockerDaemon()
	if check.Status != doctorStatusOK {
		t.Fatalf("expected ok status, got %s", check.Status)
	}
	if check.Details["server_version"] != "24.0.7" {
		t.Fatalf("expected server_version='24.0.7', got %q", check.Details["server_version"])
	}
}

func TestCheckDockerDaemon_SuccessEmptyOutput(t *testing.T) {
	origResolve := doctorResolveDockerBinaryFn
	origInfo := doctorDockerInfoFn
	t.Cleanup(func() {
		doctorResolveDockerBinaryFn = origResolve
		doctorDockerInfoFn = origInfo
	})

	doctorResolveDockerBinaryFn = func() (process.BinaryResolution, error) {
		return process.BinaryResolution{Path: "/usr/bin/docker"}, nil
	}
	doctorDockerInfoFn = func(dockerPath string) (string, error) {
		return "", nil
	}

	check := checkDockerDaemon()
	if check.Status != doctorStatusOK {
		t.Fatalf("expected ok status, got %s", check.Status)
	}
	if check.Details["server_version"] != "reachable" {
		t.Fatalf("expected server_version='reachable' for empty output, got %q", check.Details["server_version"])
	}
}

func TestCheckDockerDaemon_PermissionDenied(t *testing.T) {
	origResolve := doctorResolveDockerBinaryFn
	origInfo := doctorDockerInfoFn
	t.Cleanup(func() {
		doctorResolveDockerBinaryFn = origResolve
		doctorDockerInfoFn = origInfo
	})

	doctorResolveDockerBinaryFn = func() (process.BinaryResolution, error) {
		return process.BinaryResolution{Path: "/usr/bin/docker"}, nil
	}
	doctorDockerInfoFn = func(dockerPath string) (string, error) {
		return "permission denied", nil
	}

	check := checkDockerDaemon()
	if check.Status != doctorStatusFail {
		t.Fatalf("expected fail status for permission denied, got %s", check.Status)
	}
}

// ---------------------------------------------------------------------------
// doctorCmd.RunE – printDoctorReportFn error
// ---------------------------------------------------------------------------

func TestDoctorCmd_RunE_PrintReportError(t *testing.T) {
	oldGeneral := runGeneralDoctorChecksFn
	oldPrint := printDoctorReportFn
	t.Cleanup(func() {
		runGeneralDoctorChecksFn = oldGeneral
		printDoctorReportFn = oldPrint
	})

	runGeneralDoctorChecksFn = func(applyFix bool) doctorReport {
		return doctorReport{
			Scope:   "general",
			Checks:  []doctorCheck{{ID: "test", Status: doctorStatusOK, Message: "ok"}},
			Summary: doctorSummary{OK: 1},
		}
	}
	printDoctorReportFn = func(report doctorReport, asJSON bool) error {
		return fmt.Errorf("print failed")
	}

	err := doctorCmd.RunE(doctorCmd, nil)
	if err == nil {
		t.Fatal("expected error when printDoctorReportFn fails")
	}
	if !strings.Contains(err.Error(), "print failed") {
		t.Fatalf("unexpected error: %v", err)
	}
}

// ---------------------------------------------------------------------------
// doctorDomainsCmd.RunE – printDoctorReportFn error
// ---------------------------------------------------------------------------

func TestDoctorDomainsCmd_RunE_PrintReportError(t *testing.T) {
	oldResolve := resolveDomainTargetsFn
	oldRun := runDomainDoctorChecksFn
	oldPrint := printDoctorReportFn
	oldNewProber := newNetDomainProberFn
	t.Cleanup(func() {
		resolveDomainTargetsFn = oldResolve
		runDomainDoctorChecksFn = oldRun
		printDoctorReportFn = oldPrint
		newNetDomainProberFn = oldNewProber
	})

	resolveDomainTargetsFn = func(flagDomains []string, expectedTarget string, enforceHTTPS bool) ([]domainTarget, error) {
		return []domainTarget{{Domain: "api.example.com"}}, nil
	}
	runDomainDoctorChecksFn = func(ctx context.Context, targets []domainTarget, prober domainProber) doctorReport {
		return doctorReport{
			Scope:   "domains",
			Checks:  []doctorCheck{{ID: "test", Status: doctorStatusOK, Message: "ok"}},
			Summary: doctorSummary{OK: 1},
		}
	}
	printDoctorReportFn = func(report doctorReport, asJSON bool) error {
		return fmt.Errorf("domains print failed")
	}
	newNetDomainProberFn = func(timeout time.Duration) *netDomainProber {
		return &netDomainProber{}
	}

	err := doctorDomainsCmd.RunE(doctorDomainsCmd, nil)
	if err == nil {
		t.Fatal("expected error when printDoctorReportFn fails")
	}
	if !strings.Contains(err.Error(), "domains print failed") {
		t.Fatalf("unexpected error: %v", err)
	}
}

// ---------------------------------------------------------------------------
// dialTLSProbeConnFn default implementation
// ---------------------------------------------------------------------------

func TestDialTLSProbeConnFn_DefaultImpl(t *testing.T) {
	// Exercise the default dialTLSProbeConnFn with a host that will fail to connect.
	// We just need to invoke the default implementation to cover those lines.
	oldTLSPort := doctorTLSPort
	t.Cleanup(func() { doctorTLSPort = oldTLSPort })

	// Use a port that should not be listening
	doctorTLSPort = "1"
	_, err := dialTLSProbeConnFn("127.0.0.1")
	if err == nil {
		t.Fatal("expected error connecting to non-listening port")
	}
}

func TestNewNetDomainProber(t *testing.T) {
	prober := newNetDomainProber(10 * time.Second)
	if prober == nil {
		t.Fatal("expected non-nil prober")
	}
	if prober.client == nil {
		t.Fatal("expected non-nil http client")
	}
	if prober.client.Timeout != 10*time.Second {
		t.Fatalf("expected 10s timeout, got %v", prober.client.Timeout)
	}
	// Test redirect policy: create fake via slice to trigger limit.
	checkRedirect := prober.client.CheckRedirect
	if checkRedirect == nil {
		t.Fatal("expected CheckRedirect to be set")
	}
	// Under 10 redirects should return nil.
	via := make([]*http.Request, 5)
	if err := checkRedirect(nil, via); err != nil {
		t.Fatalf("expected nil for under-limit redirects, got: %v", err)
	}
	// At 10 redirects should return ErrUseLastResponse.
	via = make([]*http.Request, 10)
	if err := checkRedirect(nil, via); err != http.ErrUseLastResponse {
		t.Fatalf("expected ErrUseLastResponse at limit, got: %v", err)
	}
}
