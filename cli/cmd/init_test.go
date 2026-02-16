package cmd

import (
	"os"
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

		legacyPath := filepath.Join(tmpDir, tc.fnName)
		if _, err := os.Stat(legacyPath); err == nil {
			t.Fatalf("unexpected legacy function dir %s", legacyPath)
		}
	}
}
