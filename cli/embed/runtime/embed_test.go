package runtime

import (
	"bytes"
	"os"
	"path/filepath"
	goruntime "runtime"
	"strings"
	"testing"
)

func TestExtract(t *testing.T) {
	// 1. Run the extraction
	tempDir, err := Extract()
	if err != nil {
		t.Fatalf("Failed to extract runtime: %v", err)
	}
	defer os.RemoveAll(tempDir) // cleanup

	// 2. Verify key files exist
	expectedFiles := []string{
		"Dockerfile",
		"docker/openresty/start.sh",
		"openresty/nginx.conf",
		"openresty/lua/fastfn/core/client.lua", // deep file check
	}

	for _, relPath := range expectedFiles {
		fullPath := filepath.Join(tempDir, relPath)
		info, err := os.Stat(fullPath)
		if os.IsNotExist(err) {
			t.Errorf("Expected file %s not found in extraction directory", relPath)
			continue
		}
		if err != nil {
			t.Errorf("Error checking file %s: %v", relPath, err)
			continue
		}
		if info.IsDir() {
			t.Errorf("Expected %s to be a file, but it is a directory", relPath)
		}
	}

	// 3. Verify permissions (start.sh should be executable)
	startShPath := filepath.Join(tempDir, "docker/openresty/start.sh")
	info, err := os.Stat(startShPath)
	if err == nil {
		mode := info.Mode()
		// Check if executable bit is set for user (0100)
		if mode&0100 == 0 {
			t.Errorf("start.sh should be executable, got mode %v", mode)
		}
	}
}

func repoRoot(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := goruntime.Caller(0)
	if !ok {
		t.Fatal("failed to resolve test file path")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(thisFile), "..", "..", ".."))
}

func mustReadFile(t *testing.T, p string) []byte {
	t.Helper()
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("failed to read %s: %v", p, err)
	}
	return data
}

func TestEmbeddedOpenRestyParityPortableMode(t *testing.T) {
	root := repoRoot(t)

	parityFiles := []string{
		"openresty/nginx.conf",
		"openresty/console/console.js",
		"openresty/console/index.html",
		"openresty/console/style.css",
		"openresty/lua/fastfn/core/openapi.lua",
		"openresty/lua/fastfn/core/routes.lua",
		"openresty/lua/fastfn/core/lua_runtime.lua",
		"openresty/lua/fastfn/core/assistant.lua",
		"openresty/lua/fastfn/console/assistant_status_endpoint.lua",
		"openresty/lua/fastfn/console/dashboard_endpoint.lua",
		"openresty/lua/fastfn/console/data.lua",
		"openresty/lua/fastfn/console/functions_endpoint.lua",
		"openresty/lua/fastfn/console/secrets_endpoint.lua",
		"openresty/lua/fastfn/http/home.lua",
		"srv/fn/runtimes/node-daemon.js",
		"srv/fn/runtimes/node-function-worker.js",
		"srv/fn/runtimes/python-daemon.py",
		"srv/fn/runtimes/python-function-worker.py",
		"srv/fn/runtimes/php-daemon.py",
		"srv/fn/runtimes/php-worker.php",
		"srv/fn/runtimes/rust-daemon.py",
		"srv/fn/runtimes/go-daemon.py",
	}

	for _, rel := range parityFiles {
		mainPath := filepath.Join(root, rel)
		embedPath := filepath.Join(root, "cli", "embed", "runtime", rel)
		mainData := mustReadFile(t, mainPath)
		embedData := mustReadFile(t, embedPath)
		if !bytes.Equal(mainData, embedData) {
			t.Fatalf("embedded runtime drift detected for %s", rel)
		}
	}

	nginxData := string(mustReadFile(t, filepath.Join(root, "cli", "embed", "runtime", "openresty", "nginx.conf")))
	requiredRoutes := []string{
		"location = /_fn/assistant/status",
		"location = /_fn/dashboard",
		"location = /_fn/api/functions",
	}
	for _, route := range requiredRoutes {
		if !strings.Contains(nginxData, route) {
			t.Fatalf("embedded nginx missing route: %s", route)
		}
	}

	composeData := string(mustReadFile(t, filepath.Join(root, "cli", "embed", "runtime", "docker-compose.yml")))
	if !strings.Contains(composeData, "dockerfile: Dockerfile") {
		t.Fatal("embedded docker-compose must point to local Dockerfile for portable mode")
	}
	if strings.Contains(composeData, "docker/openresty/Dockerfile") {
		t.Fatal("embedded docker-compose should not reference docker/openresty/Dockerfile")
	}

	routesData := string(mustReadFile(t, filepath.Join(root, "cli", "embed", "runtime", "openresty", "lua", "fastfn", "core", "routes.lua")))
	if !strings.Contains(routesData, `socket = "inprocess:lua"`) {
		t.Fatal("embedded routes.lua must keep lua runtime in-process socket marker")
	}
	if !strings.Contains(routesData, `if runtime == "lua" then`) {
		t.Fatal("embedded routes.lua must keep lua in-process branch")
	}
	if strings.Contains(routesData, "fn-lua.sock") {
		t.Fatal("embedded routes.lua should not reference fn-lua.sock")
	}
}
