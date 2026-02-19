package process

import (
	"fmt"
	"io"
	"os/exec"
)

type Dependency struct {
	Name     string
	Command  string // e.g., "openresty" or "nginx"
	Optional bool
}

type dockerState int

const (
	dockerMissing dockerState = iota
	dockerInstalledDaemonDown
	dockerReady
)

func detectDockerState() dockerState {
	if _, err := exec.LookPath("docker"); err != nil {
		return dockerMissing
	}
	cmd := exec.Command("docker", "info")
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		return dockerInstalledDaemonDown
	}
	return dockerReady
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
		if len(missing) == 1 && missing[0] == "OpenResty" {
			switch detectDockerState() {
			case dockerReady:
				return fmt.Errorf("OpenResty is required for --native but was not found in PATH. Docker is available, so you can run `fastfn dev` (without --native), or install OpenResty for native mode (macOS: `brew install openresty`; Ubuntu/Debian: `sudo apt install openresty`; Fedora/RHEL: `sudo dnf install openresty`)")
			case dockerInstalledDaemonDown:
				return fmt.Errorf("OpenResty is required for --native but was not found in PATH. Docker CLI is installed but the daemon is not running; start Docker and run `fastfn dev` (without --native), or install OpenResty for native mode (macOS: `brew install openresty`; Ubuntu/Debian: `sudo apt install openresty`; Fedora/RHEL: `sudo dnf install openresty`)")
			default:
				return fmt.Errorf("OpenResty is required for --native but was not found in PATH. Install OpenResty (macOS: `brew install openresty`; Ubuntu/Debian: `sudo apt install openresty`; Fedora/RHEL: `sudo dnf install openresty`) or install/start Docker and use `fastfn dev`")
			}
		}
		return fmt.Errorf("missing required dependencies for Native mode: %v", missing)
	}

	return nil
}
