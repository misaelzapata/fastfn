package runtime

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func failCmd() *exec.Cmd {
	return exec.Command("sh", "-c", "exit 1")
}

func okCmd() *exec.Cmd {
	return exec.Command("sh", "-c", "exit 0")
}

func TestEnsureImageSkipsBuildWhenImageExists(t *testing.T) {
	origRunner := commandRunner
	origExtractor := runtimeExtractor
	origRemoveAll := removeAll
	t.Cleanup(func() {
		commandRunner = origRunner
		runtimeExtractor = origExtractor
		removeAll = origRemoveAll
	})

	var calls [][]string
	commandRunner = func(name string, args ...string) *exec.Cmd {
		cmd := append([]string{name}, args...)
		calls = append(calls, cmd)
		if name == "docker" && len(args) >= 2 && args[0] == "image" && args[1] == "inspect" {
			return okCmd()
		}
		return failCmd()
	}

	extractorCalled := false
	runtimeExtractor = func() (string, error) {
		extractorCalled = true
		return "", nil
	}

	if err := EnsureImage(); err != nil {
		t.Fatalf("EnsureImage() error = %v", err)
	}
	if extractorCalled {
		t.Fatalf("expected extractor not to run when image already exists")
	}
	if len(calls) != 1 {
		t.Fatalf("expected one docker inspect call, got %d", len(calls))
	}
}

func TestEnsureImageBuildsWhenImageMissing(t *testing.T) {
	origRunner := commandRunner
	origExtractor := runtimeExtractor
	origRemoveAll := removeAll
	t.Cleanup(func() {
		commandRunner = origRunner
		runtimeExtractor = origExtractor
		removeAll = origRemoveAll
	})

	buildContext := t.TempDir()
	dockerfile := filepath.Join(buildContext, "Dockerfile")
	if err := os.WriteFile(dockerfile, []byte("FROM scratch\n"), 0o644); err != nil {
		t.Fatalf("failed to create dockerfile: %v", err)
	}

	var calls [][]string
	commandRunner = func(name string, args ...string) *exec.Cmd {
		cmd := append([]string{name}, args...)
		calls = append(calls, cmd)
		if name == "docker" && len(args) >= 2 && args[0] == "image" && args[1] == "inspect" {
			return failCmd()
		}
		if name == "docker" && len(args) >= 1 && args[0] == "build" {
			if !strings.Contains(strings.Join(args, " "), dockerfile) {
				t.Fatalf("build args missing dockerfile path: %v", args)
			}
			if args[len(args)-1] != buildContext {
				t.Fatalf("expected build context %q, got %q", buildContext, args[len(args)-1])
			}
			return okCmd()
		}
		return failCmd()
	}

	runtimeExtractor = func() (string, error) {
		return buildContext, nil
	}

	removed := ""
	removeAll = func(path string) error {
		removed = path
		return nil
	}

	if err := EnsureImage(); err != nil {
		t.Fatalf("EnsureImage() error = %v", err)
	}
	if removed != buildContext {
		t.Fatalf("expected removeAll on %q, got %q", buildContext, removed)
	}
	if len(calls) < 2 {
		t.Fatalf("expected inspect + build calls, got %d", len(calls))
	}
}

func TestEnsureImageReturnsBuildError(t *testing.T) {
	origRunner := commandRunner
	origExtractor := runtimeExtractor
	origRemoveAll := removeAll
	t.Cleanup(func() {
		commandRunner = origRunner
		runtimeExtractor = origExtractor
		removeAll = origRemoveAll
	})

	buildContext := t.TempDir()
	if err := os.WriteFile(filepath.Join(buildContext, "Dockerfile"), []byte("FROM scratch\n"), 0o644); err != nil {
		t.Fatalf("failed to create dockerfile: %v", err)
	}

	commandRunner = func(name string, args ...string) *exec.Cmd {
		if name == "docker" && len(args) >= 2 && args[0] == "image" && args[1] == "inspect" {
			return failCmd()
		}
		if name == "docker" && len(args) >= 1 && args[0] == "build" {
			return failCmd()
		}
		return failCmd()
	}
	runtimeExtractor = func() (string, error) {
		return buildContext, nil
	}
	removeAll = func(string) error { return nil }

	err := EnsureImage()
	if err == nil {
		t.Fatalf("expected build error")
	}
	if !strings.Contains(err.Error(), "failed to build docker image") {
		t.Fatalf("unexpected error: %v", err)
	}
}
