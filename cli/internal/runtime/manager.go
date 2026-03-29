package runtime

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/misaelzapata/fastfn/cli/embed/runtime"
	"github.com/misaelzapata/fastfn/cli/embed/templates"
)

var commandRunner = exec.Command
var runtimeExtractor = runtime.Extract
var removeAll = os.RemoveAll
var ensureImageFn = EnsureImage

// EnsureImage ensures the fastfn runtime image exists.
// If not, it builds it from embedded sources or pulls it.
func EnsureImage() error {
	imageName := "fastfn/runtime:local"

	// Check if image exists
	cmd := commandRunner("docker", "image", "inspect", imageName)
	if err := cmd.Run(); err == nil {
		// Image exists
		return nil
	}

	log.Printf("Image '%s' not found. Building from embedded sources...\n", imageName)

	// Extract embedded files
	buildContext, err := runtimeExtractor()
	if err != nil {
		return fmt.Errorf("failed to extract build context: %w", err)
	}
	defer removeAll(buildContext) // Clean up after build

	// Build the image
	// docker build -t fastfn/runtime:local -f Dockerfile .
	buildCmd := commandRunner("docker", "build", "-t", imageName, "-f", filepath.Join(buildContext, "Dockerfile"), buildContext)
	buildCmd.Stdout = os.Stdout
	buildCmd.Stderr = os.Stderr

	if err := buildCmd.Run(); err != nil {
		return fmt.Errorf("failed to build docker image: %w", err)
	}

	log.Println("Runtime image built successfully.")
	return nil
}

// GenerateComposeFile creates a docker-compose.yml that uses the local image
func GenerateComposeFile(workDir, functionsDir string) (string, error) {
	// 1. Ensure the image exists
	if err := ensureImageFn(); err != nil {
		return "", err
	}

	// 2. Generate the compose file using template
	// We need to modify the template to point to the local image we just built
	// This would require updating the template to accept ImageName variable

	return templates.GenerateDockerCompose(workDir, functionsDir)
}
