package templates

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"text/template"
)

func TestGenerateDockerCompose(t *testing.T) {
	// 1. Create a temporary output directory
	tempDir, err := os.MkdirTemp("", "fastfn-templates-test-*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tempDir) // cleanup

	// 2. Generate the docker-compose file
	functionsDir := "/user/functions"
	outputPath, err := GenerateDockerCompose(tempDir, functionsDir)
	if err != nil {
		t.Fatalf("Failed to generate docker-compose: %v", err)
	}

	// 3. Verify the file exists
	if outputPath != filepath.Join(tempDir, "docker-compose.yml") {
		t.Errorf("Unexpected output path: %s", outputPath)
	}

	content, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatalf("Failed to read generated docker-compose: %v", err)
	}

	// 4. Verify content substitution
	expectedMount := "- /user/functions:/app/srv/fn/functions"
	raw := string(content)
	
	if !strings.Contains(raw, expectedMount) {
		t.Errorf("Generated file missing expected mount path.\nExpected inside:\n%s\nGot:\n%s", expectedMount, raw)
	}
}

func TestGenerateDockerCompose_InvalidDestDir(t *testing.T) {
	_, err := GenerateDockerCompose("/nonexistent/path/that/does/not/exist", "/user/functions")
	if err == nil {
		t.Fatalf("expected error when dest dir does not exist")
	}
}

func TestGenerateDockerCompose_OutputFileLocation(t *testing.T) {
	tempDir := t.TempDir()
	outputPath, err := GenerateDockerCompose(tempDir, "/my/functions")
	if err != nil {
		t.Fatalf("GenerateDockerCompose() error = %v", err)
	}

	expected := filepath.Join(tempDir, "docker-compose.yml")
	if outputPath != expected {
		t.Fatalf("output path = %q, want %q", outputPath, expected)
	}

	info, err := os.Stat(outputPath)
	if err != nil {
		t.Fatalf("stat generated file: %v", err)
	}
	if info.Size() == 0 {
		t.Fatalf("generated file is empty")
	}
}

func TestGenerateDockerCompose_ContentSubstitution(t *testing.T) {
	tempDir := t.TempDir()
	functionsDir := "/custom/project/functions"
	outputPath, err := GenerateDockerCompose(tempDir, functionsDir)
	if err != nil {
		t.Fatalf("GenerateDockerCompose() error = %v", err)
	}

	content, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatalf("read output: %v", err)
	}
	raw := string(content)

	if !strings.Contains(raw, functionsDir) {
		t.Fatalf("expected function dir %q in output, got:\n%s", functionsDir, raw)
	}
}

func TestGenerateDockerCompose_EmptyFunctionDir(t *testing.T) {
	tempDir := t.TempDir()
	outputPath, err := GenerateDockerCompose(tempDir, "")
	if err != nil {
		t.Fatalf("GenerateDockerCompose() error = %v", err)
	}

	content, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatalf("read output: %v", err)
	}
	if len(content) == 0 {
		t.Fatalf("expected non-empty output even with empty function dir")
	}
}

func TestGenerateDockerCompose_ReadFileError(t *testing.T) {
	origReadFile := templateReadFileFn
	defer func() { templateReadFileFn = origReadFile }()

	templateReadFileFn = func(name string) ([]byte, error) {
		return nil, errors.New("injected read error")
	}

	_, err := GenerateDockerCompose(t.TempDir(), "/some/path")
	if err == nil {
		t.Fatal("expected error when ReadFile fails")
	}
	if !strings.Contains(err.Error(), "injected read error") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestGenerateDockerCompose_TemplateParseError(t *testing.T) {
	origParse := templateParseFn
	defer func() { templateParseFn = origParse }()

	templateParseFn = func(name, text string) (*template.Template, error) {
		return nil, errors.New("injected parse error")
	}

	_, err := GenerateDockerCompose(t.TempDir(), "/some/path")
	if err == nil {
		t.Fatal("expected error when template parse fails")
	}
	if !strings.Contains(err.Error(), "injected parse error") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestGenerateDockerCompose_ExecuteError(t *testing.T) {
	origParse := templateParseFn
	defer func() { templateParseFn = origParse }()

	// Return a template that references a missing field to cause Execute to fail.
	templateParseFn = func(name, text string) (*template.Template, error) {
		return template.New(name).Option("missingkey=error").Parse("{{ .NoSuchField }}")
	}

	_, err := GenerateDockerCompose(t.TempDir(), "/some/path")
	if err == nil {
		t.Fatal("expected error when template execute fails")
	}
}
