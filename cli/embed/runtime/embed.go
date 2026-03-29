package runtime

import (
	"embed"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

//go:embed *
var Content embed.FS

// Injectable for testing
var mkdirTempFn = os.MkdirTemp
var walkDirFS fs.FS = Content
var readFileFn = func(path string) ([]byte, error) { return Content.ReadFile(path) }

// Extract extracts the embedded runtime files to a temporary directory
// Returns the path to the directory containing Dockerfile
func Extract() (string, error) {
	tempDir, err := mkdirTempFn("", "fastfn-runtime-build-*")
	if err != nil {
		return "", fmt.Errorf("failed to create temp dir: %w", err)
	}

	// Copy all embedded files to the temp dir
	err = fs.WalkDir(walkDirFS, ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return os.MkdirAll(filepath.Join(tempDir, path), 0755)
		}

		data, err := readFileFn(path)
		if err != nil {
			return err
		}

		destPath := filepath.Join(tempDir, path)
		// For executables like start.sh, set execute bit
		perm := os.FileMode(0644)
		if filepath.Base(path) == "start.sh" {
			perm = 0755
		}
		
		return os.WriteFile(destPath, data, perm)
	})

	if err != nil {
		os.RemoveAll(tempDir) // cleanup on error
		return "", fmt.Errorf("failed to extract runtime files: %w", err)
	}

	return tempDir, nil
}
