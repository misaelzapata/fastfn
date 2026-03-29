package runtime

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	goruntime "runtime"
	"sort"
	"strings"
	"testing"
	"testing/fstest"
	"time"
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

func listRuntimeFiles(t *testing.T, root string) map[string][]byte {
	t.Helper()
	out := map[string][]byte{}
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		name := d.Name()
		if d.IsDir() {
			if name == "__pycache__" || name == ".pytest_cache" || name == ".git" {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasPrefix(name, ".") || strings.HasSuffix(name, ".pyc") {
			return nil
		}

		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		out[rel] = mustReadFile(t, path)
		return nil
	})
	if err != nil {
		t.Fatalf("failed to walk %s: %v", root, err)
	}
	return out
}

func assertTreeParity(t *testing.T, mainRoot, embedRoot string) {
	t.Helper()
	mainFiles := listRuntimeFiles(t, mainRoot)
	embedFiles := listRuntimeFiles(t, embedRoot)

	mainKeys := make([]string, 0, len(mainFiles))
	for k := range mainFiles {
		mainKeys = append(mainKeys, k)
	}
	embedKeys := make([]string, 0, len(embedFiles))
	for k := range embedFiles {
		embedKeys = append(embedKeys, k)
	}
	sort.Strings(mainKeys)
	sort.Strings(embedKeys)

	if len(mainKeys) != len(embedKeys) {
		t.Fatalf("runtime file set drift:\nmain=%v\nembed=%v", mainKeys, embedKeys)
	}
	for i := range mainKeys {
		if mainKeys[i] != embedKeys[i] {
			t.Fatalf("runtime file set drift:\nmain=%v\nembed=%v", mainKeys, embedKeys)
		}
	}

	for _, rel := range mainKeys {
		if !bytes.Equal(mainFiles[rel], embedFiles[rel]) {
			t.Fatalf("runtime content drift for %s", rel)
		}
	}
}

func normalizeDockerfileForParity(data string) string {
	lines := strings.Split(data, "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "#") {
			continue
		}
		if trimmed == "COPY srv/fn/functions /app/srv/fn/functions" {
			continue
		}
		if strings.HasPrefix(trimmed, "# COPY srv/fn/functions ") {
			continue
		}
		out = append(out, trimmed)
	}
	return strings.Join(out, "\n")
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
		"openresty/lua/fastfn/console/dashboard_endpoint.lua",
		"openresty/lua/fastfn/console/data.lua",
		"openresty/lua/fastfn/console/functions_endpoint.lua",
		"openresty/lua/fastfn/console/secrets_endpoint.lua",
		"openresty/lua/fastfn/http/home.lua",
		"srv/fn/runtimes/node-daemon.js",
		"srv/fn/runtimes/node-function-worker.js",
		"srv/fn/runtimes/python-daemon.py",
		"srv/fn/runtimes/python-function-worker.py",
		"srv/fn/runtimes/php-daemon.php",
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

	mainDockerfile := string(mustReadFile(t, filepath.Join(root, "docker", "openresty", "Dockerfile")))
	embeddedDockerfile := string(mustReadFile(t, filepath.Join(root, "cli", "embed", "runtime", "Dockerfile")))
	requiredDockerSnippets := []string{
		"luarocks5.1",
		"luarocks-5.1 install luacov 0.17.0-1",
	}
	for _, snippet := range requiredDockerSnippets {
		if !strings.Contains(mainDockerfile, snippet) {
			t.Fatalf("main docker/openresty/Dockerfile missing required snippet: %s", snippet)
		}
		if !strings.Contains(embeddedDockerfile, snippet) {
			t.Fatalf("embedded runtime Dockerfile missing required snippet: %s", snippet)
		}
	}
}

func TestEmbeddedRuntimeTreeParity(t *testing.T) {
	root := repoRoot(t)

	assertTreeParity(
		t,
		filepath.Join(root, "openresty", "lua", "fastfn"),
		filepath.Join(root, "cli", "embed", "runtime", "openresty", "lua", "fastfn"),
	)
	assertTreeParity(
		t,
		filepath.Join(root, "srv", "fn", "runtimes"),
		filepath.Join(root, "cli", "embed", "runtime", "srv", "fn", "runtimes"),
	)
	assertTreeParity(
		t,
		filepath.Join(root, "openresty", "console"),
		filepath.Join(root, "cli", "embed", "runtime", "openresty", "console"),
	)

	mainStart := mustReadFile(t, filepath.Join(root, "docker", "openresty", "start.sh"))
	embedStart := mustReadFile(t, filepath.Join(root, "cli", "embed", "runtime", "docker", "openresty", "start.sh"))
	if !bytes.Equal(mainStart, embedStart) {
		t.Fatal("runtime drift detected for docker/openresty/start.sh")
	}

	mainDocker := string(mustReadFile(t, filepath.Join(root, "docker", "openresty", "Dockerfile")))
	embedDocker := string(mustReadFile(t, filepath.Join(root, "cli", "embed", "runtime", "Dockerfile")))
	if normalizeDockerfileForParity(mainDocker) != normalizeDockerfileForParity(embedDocker) {
		t.Fatal("runtime drift detected for Dockerfile (normalized parity)")
	}
}

func TestExtract_CreatesReadableFiles(t *testing.T) {
	tempDir, err := Extract()
	if err != nil {
		t.Fatalf("Extract() error = %v", err)
	}
	defer os.RemoveAll(tempDir)

	// Walk all extracted files and verify they are readable
	fileCount := 0
	err = filepath.WalkDir(tempDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		fileCount++
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			t.Errorf("failed to read extracted file %s: %v", path, readErr)
		}
		if len(data) == 0 {
			// Some files may legitimately be empty, but key files should not be
			rel, _ := filepath.Rel(tempDir, path)
			if rel == "Dockerfile" || rel == "openresty/nginx.conf" {
				t.Errorf("key file %s should not be empty", rel)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk extracted dir: %v", err)
	}
	if fileCount == 0 {
		t.Fatalf("expected at least one extracted file")
	}
}

func TestExtract_StartShPermissions(t *testing.T) {
	tempDir, err := Extract()
	if err != nil {
		t.Fatalf("Extract() error = %v", err)
	}
	defer os.RemoveAll(tempDir)

	startShPath := filepath.Join(tempDir, "docker/openresty/start.sh")
	info, err := os.Stat(startShPath)
	if err != nil {
		t.Skipf("start.sh not found (may not exist in embed): %v", err)
	}
	mode := info.Mode()
	if mode&0111 == 0 {
		t.Fatalf("start.sh should have executable bits, got mode %v", mode)
	}
}

func TestExtract_NonStartShPermissions(t *testing.T) {
	tempDir, err := Extract()
	if err != nil {
		t.Fatalf("Extract() error = %v", err)
	}
	defer os.RemoveAll(tempDir)

	dockerfilePath := filepath.Join(tempDir, "Dockerfile")
	info, err := os.Stat(dockerfilePath)
	if err != nil {
		t.Skipf("Dockerfile not found: %v", err)
	}
	mode := info.Mode()
	// Non-executable files should have 0644 permissions
	if mode&0111 != 0 {
		t.Fatalf("Dockerfile should not have executable bits, got mode %v", mode)
	}
}

func TestExtract_ContainsDockerfile(t *testing.T) {
	tempDir, err := Extract()
	if err != nil {
		t.Fatalf("Extract() error = %v", err)
	}
	defer os.RemoveAll(tempDir)

	dockerfilePath := filepath.Join(tempDir, "Dockerfile")
	data, err := os.ReadFile(dockerfilePath)
	if err != nil {
		t.Fatalf("failed to read Dockerfile: %v", err)
	}
	if !strings.Contains(string(data), "FROM") {
		t.Fatalf("Dockerfile should contain FROM directive")
	}
}

func TestExtract_ReadFileError(t *testing.T) {
	// Inject a readFileFn that fails to trigger lines 37-38 and the
	// cleanup-on-error path at lines 51-53.
	origReadFile := readFileFn
	origWalkDirFS := walkDirFS
	defer func() {
		readFileFn = origReadFile
		walkDirFS = origWalkDirFS
	}()

	// Use a minimal in-memory FS so WalkDir finds a file to read.
	walkDirFS = fstest.MapFS{
		"dummy.txt": &fstest.MapFile{Data: []byte("hello")},
	}
	readFileFn = func(path string) ([]byte, error) {
		return nil, errors.New("injected read error")
	}

	_, err := Extract()
	if err == nil {
		t.Fatal("expected error from Extract when readFileFn fails")
	}
	if !strings.Contains(err.Error(), "failed to extract runtime files") {
		t.Fatalf("unexpected error message: %v", err)
	}
}

func TestExtract_MkdirTempError(t *testing.T) {
	origMkdirTemp := mkdirTempFn
	defer func() { mkdirTempFn = origMkdirTemp }()

	mkdirTempFn = func(dir, pattern string) (string, error) {
		return "", errors.New("injected mkdirtemp error")
	}

	_, err := Extract()
	if err == nil {
		t.Fatal("expected error from Extract when mkdirTempFn fails")
	}
	if !strings.Contains(err.Error(), "failed to create temp dir") {
		t.Fatalf("unexpected error message: %v", err)
	}
}

// brokenDirEntry implements fs.DirEntry but returns an error from Info.
type brokenDirEntry struct {
	name string
}

func (b brokenDirEntry) Name() string               { return b.name }
func (b brokenDirEntry) IsDir() bool                 { return false }
func (b brokenDirEntry) Type() fs.FileMode           { return 0 }
func (b brokenDirEntry) Info() (fs.FileInfo, error)  { return nil, errors.New("broken info") }

// brokenFS implements fs.FS and fs.ReadDirFile to produce a walk error
// on the second entry, which causes WalkDir to pass a non-nil err to
// the callback (line 29-30).
type brokenFS struct{}

type brokenDir struct{}

func (brokenDir) Read([]byte) (int, error)   { return 0, errors.New("not a regular file") }
func (brokenDir) Stat() (fs.FileInfo, error) { return brokenDirInfo{}, nil }
func (brokenDir) Close() error               { return nil }
func (brokenDir) ReadDir(n int) ([]fs.DirEntry, error) {
	// Return a good entry followed by a broken one
	return nil, errors.New("injected readdir error")
}

type brokenDirInfo struct{}

func (brokenDirInfo) Name() string      { return "." }
func (brokenDirInfo) Size() int64       { return 0 }
func (brokenDirInfo) Mode() fs.FileMode { return fs.ModeDir | 0755 }
func (brokenDirInfo) ModTime() time.Time { return time.Time{} }
func (brokenDirInfo) IsDir() bool       { return true }
func (brokenDirInfo) Sys() interface{}  { return nil }

func (brokenFS) Open(name string) (fs.File, error) {
	if name == "." {
		return brokenDir{}, nil
	}
	return nil, errors.New("not found")
}

func TestExtract_WalkDirCallbackError(t *testing.T) {
	origWalkDirFS := walkDirFS
	origReadFile := readFileFn
	defer func() {
		walkDirFS = origWalkDirFS
		readFileFn = origReadFile
	}()

	// Use a MapFS with a subdirectory, but make readFileFn fail so that
	// we also cover the write-error cleanup path. The key thing is that
	// the walk itself succeeds but the callback returns an error.
	walkDirFS = fstest.MapFS{
		"subdir/file.txt": &fstest.MapFile{Data: []byte("data")},
	}
	readFileFn = func(path string) ([]byte, error) {
		return nil, errors.New("injected read error in walk")
	}

	_, err := Extract()
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "failed to extract runtime files") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestExtract_WalkDirErrCallback(t *testing.T) {
	// Test the err != nil branch in the WalkDir callback (line 29-30).
	// brokenFS causes WalkDir to pass a non-nil err to the callback.
	origWalkDirFS := walkDirFS
	defer func() { walkDirFS = origWalkDirFS }()

	walkDirFS = brokenFS{}

	_, err := Extract()
	if err == nil {
		t.Fatal("expected error from broken FS walk")
	}
	if !strings.Contains(err.Error(), "failed to extract runtime files") {
		t.Fatalf("unexpected error: %v", err)
	}
}
