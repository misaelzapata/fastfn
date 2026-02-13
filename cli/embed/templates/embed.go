package templates

import (
	"embed"
	"os"
	"path/filepath"
	"text/template"
)

//go:embed docker-compose.yml
var Content embed.FS

// Config for the template
type Config struct {
	FunctionDir string
}

// GenerateDockerCompose creates a temporary docker-compose.yml
func GenerateDockerCompose(destDir, functionDir string) (string, error) {
	tmplData := Config{
		FunctionDir: functionDir,
	}

	raw, err := Content.ReadFile("docker-compose.yml")
	if err != nil {
		return "", err
	}

	t, err := template.New("docker-compose").Parse(string(raw))
	if err != nil {
		return "", err
	}

	destFile := filepath.Join(destDir, "docker-compose.yml")
	f, err := os.Create(destFile)
	if err != nil {
		return "", err
	}
	defer f.Close()

	if err := t.Execute(f, tmplData); err != nil {
		return "", err
	}

	return destFile, nil
}
