package templates

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
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
