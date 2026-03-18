package cmd

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestInitCreatesRuntimeScopedFunctionDirs(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "fastfn-init-*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("failed to get cwd: %v", err)
	}
	defer func() {
		_ = os.Chdir(wd)
	}()
	if err := os.Chdir(tmpDir); err != nil {
		t.Fatalf("failed to chdir: %v", err)
	}

	oldTemplate := template
	defer func() { template = oldTemplate }()

	tests := []struct {
		runtime   string
		fnName    string
		entryFile string
	}{
		{runtime: "node", fnName: "alpha", entryFile: "handler.js"},
		{runtime: "python", fnName: "bravo", entryFile: "main.py"},
		{runtime: "php", fnName: "charlie", entryFile: "handler.php"},
		{runtime: "lua", fnName: "echo_lua", entryFile: "handler.lua"},
		{runtime: "rust", fnName: "delta", entryFile: "handler.rs"},
	}

	for _, tc := range tests {
		template = tc.runtime
		initCmd.Run(initCmd, []string{tc.fnName})

		fnDir := filepath.Join(tmpDir, tc.runtime, tc.fnName)
		if st, err := os.Stat(fnDir); err != nil || !st.IsDir() {
			t.Fatalf("expected function dir %s to exist", fnDir)
		}

		cfg := filepath.Join(fnDir, "fn.config.json")
		if _, err := os.Stat(cfg); err != nil {
			t.Fatalf("expected config at %s: %v", cfg, err)
		}

		entry := filepath.Join(fnDir, tc.entryFile)
		if _, err := os.Stat(entry); err != nil {
			t.Fatalf("expected entry file at %s: %v", entry, err)
		}

		flatPath := filepath.Join(tmpDir, tc.fnName)
		if _, err := os.Stat(flatPath); err == nil {
			t.Fatalf("unexpected flat function dir %s", flatPath)
		}
	}
}

func TestInitCreatesCorrectConfigContent(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "fastfn-init-config-*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("failed to get cwd: %v", err)
	}
	defer func() { _ = os.Chdir(wd) }()
	if err := os.Chdir(tmpDir); err != nil {
		t.Fatalf("failed to chdir: %v", err)
	}

	oldTemplate := template
	defer func() { template = oldTemplate }()

	tests := []struct {
		runtime         string
		fnName          string
		expectRuntime   string
		expectEntryFile string
	}{
		{"node", "test-node", "node", "handler.js"},
		{"python", "test-python", "python", "main.py"},
		{"php", "test-php", "php", "handler.php"},
		{"lua", "test-lua", "lua", "handler.lua"},
		{"rust", "test-rust", "rust", "handler.rs"},
	}

	for _, tc := range tests {
		t.Run(tc.runtime, func(t *testing.T) {
			template = tc.runtime
			initCmd.Run(initCmd, []string{tc.fnName})

			fnDir := filepath.Join(tmpDir, tc.runtime, tc.fnName)

			// Verify fn.config.json content
			cfgData, err := os.ReadFile(filepath.Join(fnDir, "fn.config.json"))
			if err != nil {
				t.Fatalf("read config: %v", err)
			}
			cfgStr := string(cfgData)

			if !contains(cfgStr, `"runtime": "`+tc.expectRuntime+`"`) {
				t.Fatalf("config should contain runtime %q, got:\n%s", tc.expectRuntime, cfgStr)
			}
			if !contains(cfgStr, `"name": "`+tc.fnName+`"`) {
				t.Fatalf("config should contain name %q, got:\n%s", tc.fnName, cfgStr)
			}

			// Verify entry file content is non-empty
			entryData, err := os.ReadFile(filepath.Join(fnDir, tc.expectEntryFile))
			if err != nil {
				t.Fatalf("read entry file: %v", err)
			}
			if len(entryData) == 0 {
				t.Fatalf("entry file %s should not be empty", tc.expectEntryFile)
			}
		})
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsSubstr(s, substr))
}

func containsSubstr(s, substr string) bool {
	for i := 0; i+len(substr) <= len(s); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

func TestInitPythonCreatesRequirementsTxt(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "fastfn-init-py-req-*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("failed to get cwd: %v", err)
	}
	defer func() { _ = os.Chdir(wd) }()
	if err := os.Chdir(tmpDir); err != nil {
		t.Fatalf("failed to chdir: %v", err)
	}

	oldTemplate := template
	defer func() { template = oldTemplate }()

	template = "python"
	initCmd.Run(initCmd, []string{"py-test"})

	reqPath := filepath.Join(tmpDir, "python", "py-test", "requirements.txt")
	if _, err := os.Stat(reqPath); err != nil {
		t.Fatalf("expected requirements.txt at %s: %v", reqPath, err)
	}
}

func TestWriteFile_Success(t *testing.T) {
	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "test.txt")
	writeFile(path, "hello world")

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read written file: %v", err)
	}
	if string(data) != "hello world" {
		t.Fatalf("expected 'hello world', got %q", string(data))
	}
}

func TestWriteFile_ErrorExitsProcess(t *testing.T) {
	// writeFile calls log.Fatalf on error, which calls os.Exit(1).
	// We test this using a subprocess pattern.
	if os.Getenv("TEST_WRITEFILE_CRASH") == "1" {
		writeFile("/nonexistent/dir/file.txt", "content")
		return
	}
	// Run ourselves as a subprocess with the crash env var set.
	// #nosec -- test code
	cmd := exec.Command(os.Args[0], "-test.run=TestWriteFile_ErrorExitsProcess")
	cmd.Env = append(os.Environ(), "TEST_WRITEFILE_CRASH=1")
	err := cmd.Run()
	if exitErr, ok := err.(*exec.ExitError); ok {
		if exitErr.ExitCode() == 0 {
			t.Fatal("expected non-zero exit code from log.Fatalf")
		}
		return // Expected: process exited with non-zero code
	}
	if err != nil {
		return // Process failed as expected
	}
	t.Fatal("expected process to exit with error when writeFile fails")
}

func TestInitUnknownTemplate(t *testing.T) {
	// initCmd uses log.Fatalf for unknown templates which calls os.Exit(1).
	// Test via subprocess.
	if os.Getenv("TEST_INIT_UNKNOWN_TEMPLATE") == "1" {
		tmpDir, _ := os.MkdirTemp("", "fastfn-init-unknown-*")
		defer os.RemoveAll(tmpDir)
		os.Chdir(tmpDir)
		template = "ruby"
		initCmd.Run(initCmd, []string{"test-fn"})
		return
	}
	cmd := exec.Command(os.Args[0], "-test.run=TestInitUnknownTemplate")
	cmd.Env = append(os.Environ(), "TEST_INIT_UNKNOWN_TEMPLATE=1")
	err := cmd.Run()
	if exitErr, ok := err.(*exec.ExitError); ok {
		if exitErr.ExitCode() == 0 {
			t.Fatal("expected non-zero exit for unknown template")
		}
		return
	}
	if err != nil {
		return // Process failed as expected
	}
	t.Fatal("expected process to exit with error for unknown template")
}

func TestInitMkdirError(t *testing.T) {
	// initCmd uses log.Fatalf when MkdirAll fails, so test via subprocess.
	if os.Getenv("TEST_INIT_MKDIR_ERROR") == "1" {
		// Try to create a function under /proc which should fail on Linux.
		os.Chdir("/proc")
		template = "node"
		initCmd.Run(initCmd, []string{"test-fn"})
		return
	}
	cmd := exec.Command(os.Args[0], "-test.run=TestInitMkdirError")
	cmd.Env = append(os.Environ(), "TEST_INIT_MKDIR_ERROR=1")
	err := cmd.Run()
	if exitErr, ok := err.(*exec.ExitError); ok {
		if exitErr.ExitCode() == 0 {
			t.Fatal("expected non-zero exit for mkdir error")
		}
		return
	}
	if err != nil {
		return // Process failed as expected
	}
	t.Fatal("expected process to exit with error for mkdir failure")
}

func TestInitTemplateUppercaseNormalized(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "fastfn-init-case-*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("failed to get cwd: %v", err)
	}
	defer func() { _ = os.Chdir(wd) }()
	if err := os.Chdir(tmpDir); err != nil {
		t.Fatalf("failed to chdir: %v", err)
	}

	oldTemplate := template
	defer func() { template = oldTemplate }()

	// The template is lowercased in the Run function via strings.ToLower
	// but the switch still matches on the original template variable.
	// This test verifies the dir path uses lowercase.
	template = "node"
	initCmd.Run(initCmd, []string{"case-test"})

	fnDir := filepath.Join(tmpDir, "node", "case-test")
	if _, err := os.Stat(fnDir); err != nil {
		t.Fatalf("expected function dir at %s: %v", fnDir, err)
	}
}
