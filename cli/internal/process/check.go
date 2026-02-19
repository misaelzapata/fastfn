package process

import (
	"fmt"
	"os/exec"
)

type Dependency struct {
	Name     string
	Command  string // e.g., "openresty" or "nginx"
	Optional bool
}

// CheckDocker verifies that Docker is installed AND the daemon is running
func CheckDocker() error {
	// 1. Check binary
	if _, err := exec.LookPath("docker"); err != nil {
		return fmt.Errorf("Docker is not installed or not in PATH. Install Docker Desktop/Engine (macOS/Homebrew: brew install --cask docker; Linux: apt/dnf/snap packages)")
	}

	// 2. Check daemon status
	cmd := exec.Command("docker", "info")
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("Docker daemon is not running. Please start Docker Desktop or the engine.")
	}

	return nil
}

// CheckDependencies verifies that required tools are in the PATH for NATIVE mode
func CheckDependencies() error {
	var missing []string

	// Define required deps for Native mode
	required := []Dependency{
		{Name: "OpenResty", Command: "openresty", Optional: false},
		{Name: "Python 3", Command: "python3", Optional: true},
		{Name: "Node.js", Command: "node", Optional: true},
		{Name: "PHP", Command: "php", Optional: true},
		{Name: "Go", Command: "go", Optional: true},
	}

	for _, dep := range required {
		_, err := exec.LookPath(dep.Command)
		if err != nil {
			if !dep.Optional {
				missing = append(missing, dep.Name)
			}
		}
	}

	if len(missing) > 0 {
		return fmt.Errorf("missing required dependencies for Native mode: %v. Install required runtimes (OpenResty via Homebrew or distro package) or use Docker mode", missing)
	}

	return nil
}
