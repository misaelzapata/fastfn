package process

import (
	"fmt"
	"io"
	"os/exec"
)

type dockerState int

const (
	dockerMissing dockerState = iota
	dockerInstalledDaemonDown
	dockerReady
)

func detectDockerState() dockerState {
	dockerBin, err := ResolveConfiguredBinary("docker")
	if err != nil {
		return dockerMissing
	}
	cmd := exec.Command(dockerBin.Path, "info")
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
	dockerBin, err := ResolveConfiguredBinary("docker")
	if err != nil {
		return fmt.Errorf("Docker is not installed or not in PATH. Install Docker Desktop/Engine (macOS/Homebrew: brew install --cask docker; Linux: apt/dnf/snap packages)")
	}

	// 2. Check daemon status
	cmd := exec.Command(dockerBin.Path, "info")
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("Docker daemon is not running. Please start Docker Desktop or the engine.")
	}

	return nil
}

// CheckDependencies verifies that required tools are in the PATH for NATIVE mode
func CheckDependencies() error {
	required := []struct {
		Key      string
		Name     string
		Optional bool
	}{
		{Key: "openresty", Name: "OpenResty", Optional: false},
		{Key: "python", Name: "Python", Optional: true},
		{Key: "node", Name: "Node.js", Optional: true},
		{Key: "php", Name: "PHP", Optional: true},
		{Key: "go", Name: "Go", Optional: true},
	}

	for _, dep := range required {
		_, err := ResolveConfiguredBinary(dep.Key)
		if err != nil && !dep.Optional {
			return renderMissingNativeDependency(dep.Name)
		}
	}
	return nil
}

func renderMissingNativeDependency(name string) error {
	switch detectDockerState() {
	case dockerReady:
		return fmt.Errorf("%s is required for --native but was not found in PATH. Docker is available, so you can run `fastfn dev` (without --native), or install it for native mode", name)
	case dockerInstalledDaemonDown:
		return fmt.Errorf("%s is required for --native but was not found in PATH. Docker CLI is installed but the daemon is not running; start Docker and run `fastfn dev` (without --native), or install it for native mode", name)
	default:
		return fmt.Errorf("%s is required for --native but was not found in PATH. Install it or install/start Docker and use `fastfn dev`", name)
	}
}
