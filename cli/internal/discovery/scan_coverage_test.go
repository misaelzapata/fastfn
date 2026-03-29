package discovery

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeDiscoveryFile(t *testing.T, path string, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0644); err != nil {
		t.Fatal(err)
	}
}

func TestDiscoveryCoverageHelpers(t *testing.T) {
	if got := toIntClamped("oops", 1, 5); got != 0 {
		t.Fatalf("toIntClamped invalid = %d, want 0", got)
	}
	if got := toIntClamped("1", 2, 5); got != 2 {
		t.Fatalf("toIntClamped min clamp = %d, want 2", got)
	}
	if got := toIntClamped("99", 2, 5); got != 5 {
		t.Fatalf("toIntClamped max clamp = %d, want 5", got)
	}
	if got := toIntClamped("3", 2, 5); got != 3 {
		t.Fatalf("toIntClamped exact = %d, want 3", got)
	}

	tmpDir := t.TempDir()
	writeDiscoveryFile(t, filepath.Join(tmpDir, "handler.js"), "module.exports = {}")

	cfgPath := filepath.Join(tmpDir, "fn.config.json")
	if err := os.WriteFile(cfgPath, []byte(`{"entrypoint":"handler.js"}`), 0644); err != nil {
		t.Fatal(err)
	}
	if !hasValidConfigEntrypoint(tmpDir) {
		t.Fatal("expected relative entrypoint to be valid")
	}

	absCfg := fmt.Sprintf(`{"entrypoint":%q}`, filepath.Join(tmpDir, "handler.js"))
	if err := os.WriteFile(cfgPath, []byte(absCfg), 0644); err != nil {
		t.Fatal(err)
	}
	if hasValidConfigEntrypoint(tmpDir) {
		t.Fatal("expected absolute entrypoint to be rejected")
	}

	if err := os.WriteFile(cfgPath, []byte(`{"entrypoint":"../handler.js"}`), 0644); err != nil {
		t.Fatal(err)
	}
	if hasValidConfigEntrypoint(tmpDir) {
		t.Fatal("expected parent-traversal entrypoint to be rejected")
	}

	if err := os.WriteFile(cfgPath, []byte(`{"entrypoint":"missing.js"}`), 0644); err != nil {
		t.Fatal(err)
	}
	if hasValidConfigEntrypoint(tmpDir) {
		t.Fatal("expected missing entrypoint to be rejected")
	}

	outsideDir := t.TempDir()
	outsideFile := filepath.Join(outsideDir, "escape.js")
	writeDiscoveryFile(t, outsideFile, "module.exports = {}")
	linkPath := filepath.Join(tmpDir, "linked.js")
	if err := os.Symlink(outsideFile, linkPath); err == nil {
		if err := os.WriteFile(cfgPath, []byte(`{"entrypoint":"linked.js"}`), 0644); err != nil {
			t.Fatal(err)
		}
		if hasValidConfigEntrypoint(tmpDir) {
			t.Fatal("expected symlinked escape entrypoint to be rejected")
		}
	}

	if !looksLikeVersionLabel("v1") {
		t.Fatal("expected v1 to be treated as a version label")
	}
	if !looksLikeVersionLabel("2026-03") {
		t.Fatal("expected numeric label to be treated as a version label")
	}
	if looksLikeVersionLabel("alpha") {
		t.Fatal("did not expect alpha to be treated as a version label")
	}

	primary := []Function{{OriginalRoute: "GET /items", Runtime: "node"}}
	fallback := []Function{
		{OriginalRoute: "GET /items", Runtime: "python"},
		{OriginalRoute: "POST /items", Runtime: "python"},
	}
	merged := mergeRouteFunctions(primary, fallback)
	if len(merged) != 2 {
		t.Fatalf("expected duplicate fallback route to be skipped, got %d entries", len(merged))
	}

	root := t.TempDir()
	manifestDir := filepath.Join(root, "manifested")
	writeDiscoveryFile(t, filepath.Join(manifestDir, "fn.routes.json"), `{"routes":{"GET /manifested":"handler.js"}}`)
	if !runtimeRootExposesRoutes(root, manifestDir, "manifested", 0) {
		t.Fatal("expected runtimeRootExposesRoutes to return true for manifest-backed routes")
	}

	sparseDir := filepath.Join(root, "sparse")
	if err := os.MkdirAll(filepath.Join(sparseDir, ".hidden"), 0755); err != nil {
		t.Fatal(err)
	}
	writeDiscoveryFile(t, filepath.Join(sparseDir, "README.txt"), "notes")
	if runtimeRootExposesRoutes(root, sparseDir, "sparse", 0) {
		t.Fatal("did not expect routes from non-handler files and hidden dirs")
	}

	if runtimeRootExposesRoutes(root, filepath.Join(root, "missing"), "missing", 0) {
		t.Fatal("did not expect routes from a missing directory")
	}
	if runtimeRootExposesRoutes(root, sparseDir, "sparse", 7) {
		t.Fatal("did not expect routes when depth is above the runtime recursion limit")
	}
}

func TestLoadZeroConfigIgnoreDirs(t *testing.T) {
	root := t.TempDir()
	cfg := `{
  "zero_config": { "ignore_dirs": ["build", "dist"] },
  "zero_config_ignore_dirs": ["cache"]
}`
	if err := os.WriteFile(filepath.Join(root, "fn.config.json"), []byte(cfg), 0644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FN_ZERO_CONFIG_IGNORE_DIRS", "tmp, vendor")

	loaded := loadZeroConfigIgnoreDirs(root)
	for _, name := range []string{"src", "build", "dist", "cache", "tmp", "vendor"} {
		if _, ok := loaded[name]; !ok {
			t.Fatalf("expected %q in ignore dirs", name)
		}
	}
}

func TestNormalizeZeroConfigDirAndAppendStringSlice(t *testing.T) {
	if got := normalizeZeroConfigDir("nested/path"); got != "" {
		t.Fatalf("normalizeZeroConfigDir() with slash = %q, want empty", got)
	}
	if got := normalizeZeroConfigDir(`nested\path`); got != "" {
		t.Fatalf("normalizeZeroConfigDir() with backslash = %q, want empty", got)
	}

	dst := map[string]struct{}{}
	appendZeroConfigIgnoreDirs(dst, []string{"Build", "nested/path", `nested\path`, "dist"})
	if _, ok := dst["build"]; !ok {
		t.Fatal("expected build entry from []string branch")
	}
	if _, ok := dst["dist"]; !ok {
		t.Fatal("expected dist entry from []string branch")
	}
	if _, ok := dst["nested/path"]; ok {
		t.Fatal("unexpected nested/path entry to survive normalization")
	}
}

func TestScanSkipsConfiguredZeroConfigIgnoreDirs(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "fn.config.json"), []byte(`{
  "zero_config": { "ignore_dirs": ["build"] }
}`), 0644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FN_ZERO_CONFIG_IGNORE_DIRS", "tmp")
	writeDiscoveryFile(t, filepath.Join(root, "api", "handler.js"), "module.exports = {}")
	writeDiscoveryFile(t, filepath.Join(root, "build", "handler.js"), "module.exports = {}")
	writeDiscoveryFile(t, filepath.Join(root, "tmp", "handler.js"), "module.exports = {}")

	funcs, err := Scan(root, nil)
	if err != nil {
		t.Fatalf("Scan() error = %v", err)
	}

	foundAPI := false
	for _, fn := range funcs {
		if fn.OriginalRoute == "GET /api" {
			foundAPI = true
		}
		if strings.Contains(fn.OriginalRoute, "/build") || strings.Contains(fn.OriginalRoute, "/tmp") {
			t.Fatalf("ignored dir leaked into discovery: %+v", fn)
		}
	}
	if !foundAPI {
		t.Fatal("expected non-ignored API route to be discovered")
	}
}

func TestDetectFunction_InvalidConfigAndOverlayFileRoutes(t *testing.T) {
	tmpDir := t.TempDir()

	invalidDir := filepath.Join(tmpDir, "invalid")
	if err := os.MkdirAll(invalidDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(invalidDir, "fn.config.json"), []byte(`{bad`), 0644); err != nil {
		t.Fatal(err)
	}

	var logs []string
	logger := func(format string, v ...interface{}) {
		logs = append(logs, fmt.Sprintf(format, v...))
	}
	if fns, ok := detectFunction(invalidDir, tmpDir, logger); ok || len(fns) != 0 {
		t.Fatalf("expected invalid config without handlers to be ignored, got ok=%v fns=%v", ok, fns)
	}
	if len(logs) == 0 {
		t.Fatal("expected invalid config branch to log the ignore message")
	}

	overlayDir := filepath.Join(tmpDir, "overlay")
	if err := os.MkdirAll(overlayDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(overlayDir, "fn.config.json"), []byte(`{"timeout_ms":1200}`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(overlayDir, "get.js"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}

	fns, ok := detectFunction(overlayDir, tmpDir, func(string, ...interface{}) {})
	if !ok || len(fns) != 1 {
		t.Fatalf("expected overlay config + file route to be detected, got ok=%v len=%d", ok, len(fns))
	}
	if !fns[0].HasConfig {
		t.Fatal("expected overlay file route to be marked HasConfig=true")
	}
	if fns[0].OriginalRoute != "GET /overlay" {
		t.Fatalf("unexpected overlay route: %q", fns[0].OriginalRoute)
	}
}

func TestScanHybridBranchCoverage(t *testing.T) {
	t.Setenv("FN_NAMESPACE_DEPTH", "2")

	tmpDir := t.TempDir()

	writeDiscoveryFile(t, filepath.Join(tmpDir, "visible", "index.js"), `...`)
	writeDiscoveryFile(t, filepath.Join(tmpDir, ".hidden", "index.js"), `...`)
	writeDiscoveryFile(t, filepath.Join(tmpDir, "a", "b", "c", "d", "e", "f", "g", "index.js"), `...`)

	nodeRoot := filepath.Join(tmpDir, "node")
	writeDiscoveryFile(t, filepath.Join(nodeRoot, "README.txt"), "notes")
	if err := os.MkdirAll(filepath.Join(nodeRoot, ".skip"), 0755); err != nil {
		t.Fatal(err)
	}

	writeDiscoveryFile(t, filepath.Join(nodeRoot, "whatsapp", "handler.js"), `...`)
	writeDiscoveryFile(t, filepath.Join(nodeRoot, "whatsapp", "admin", "index.js"), `...`)
	writeDiscoveryFile(t, filepath.Join(nodeRoot, "whatsapp", ".private", "index.js"), `...`)
	writeDiscoveryFile(t, filepath.Join(nodeRoot, "whatsapp", "a", "b", "c", "d", "e", "f", "g", "index.js"), `...`)

	lockedMixedDir := filepath.Join(nodeRoot, "whatsapp", "locked")
	if err := os.MkdirAll(lockedMixedDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(lockedMixedDir, 0000); err != nil {
		t.Skipf("chmod not supported: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(lockedMixedDir, 0755) })

	writeDiscoveryFile(t, filepath.Join(nodeRoot, "api", "users", "handler.js"), `...`)
	writeDiscoveryFile(t, filepath.Join(nodeRoot, "group", "alpha", "handler.js"), `...`)
	writeDiscoveryFile(t, filepath.Join(nodeRoot, "a", "b", "c", "handler.js"), `...`)
	writeDiscoveryFile(t, filepath.Join(nodeRoot, "bad.name", "handler.js"), `...`)
	writeDiscoveryFile(t, filepath.Join(nodeRoot, "versioned", "v1", "handler.js"), `...`)
	writeDiscoveryFile(t, filepath.Join(nodeRoot, "versioned", "v2", "handler.js"), `...`)

	blockedRuntimeDir := filepath.Join(nodeRoot, "blocked")
	writeDiscoveryFile(t, filepath.Join(blockedRuntimeDir, "inner", "handler.js"), `...`)
	if err := os.Chmod(blockedRuntimeDir, 0000); err != nil {
		t.Skipf("chmod not supported: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(blockedRuntimeDir, 0755) })

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	foundVisible := false
	foundMixedAdmin := false
	foundRuntimeNamespace := false
	foundVersioned := false
	foundGroupAlpha := false

	for _, fn := range funcs {
		switch {
		case fn.OriginalRoute == "GET /visible":
			foundVisible = true
		case fn.OriginalRoute == "GET /whatsapp/admin":
			foundMixedAdmin = true
		case fn.Runtime == "node" && fn.Name == "api/users":
			foundRuntimeNamespace = true
		case fn.Runtime == "node" && fn.Name == "versioned":
			foundVersioned = true
		case fn.Runtime == "node" && fn.Name == "group/alpha":
			foundGroupAlpha = true
		}

		if fn.OriginalRoute == "GET /hidden" {
			t.Fatalf("hidden zero-config dir should not be discovered: %+v", fn)
		}
		if fn.OriginalRoute == "GET /a/b/c/d/e/f/g" {
			t.Fatalf("zero-config route deeper than 6 levels should not be discovered: %+v", fn)
		}
		if fn.OriginalRoute == "GET /whatsapp/private" || fn.OriginalRoute == "GET /whatsapp/a/b/c/d/e/f/g" {
			t.Fatalf("mixed helper/deep route should not be discovered: %+v", fn)
		}
		if fn.Runtime == "node" && (fn.Name == "a/b/c" || fn.Path == filepath.Join(nodeRoot, "bad.name")) {
			t.Fatalf("unexpected runtime namespace discovery leak: %+v", fn)
		}
	}

	if !foundVisible {
		t.Fatal("expected visible zero-config route to be discovered")
	}
	if !foundMixedAdmin {
		t.Fatal("expected mixed subtree route /whatsapp/admin to be discovered")
	}
	if !foundRuntimeNamespace {
		t.Fatal("expected runtime namespace function api/users to be discovered")
	}
	if !foundVersioned {
		t.Fatal("expected versioned runtime group to be discovered")
	}
	if !foundGroupAlpha {
		t.Fatal("expected non-version nested runtime function group/alpha to be discovered")
	}
}

func TestDetectFileBasedRoutesInDir_RootIndexDoesNotMintSlashRoute(t *testing.T) {
	root := t.TempDir()
	writeDiscoveryFile(t, filepath.Join(root, "index.js"), "module.exports = {}")

	fns := detectFileBasedRoutesInDir(root, root, "", false, func(string, ...interface{}) {})
	if len(fns) != 0 {
		t.Fatalf("expected root index.js to avoid minting GET /, got %+v", fns)
	}
}

func TestDetectFileBasedRoutesInDir_SkipsReservedPaths(t *testing.T) {
	root := t.TempDir()
	reservedDir := filepath.Join(root, "_fn")
	if err := os.MkdirAll(reservedDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeDiscoveryFile(t, filepath.Join(reservedDir, "get.js"), "module.exports = {}")

	var logs []string
	logger := func(format string, v ...interface{}) {
		logs = append(logs, fmt.Sprintf(format, v...))
	}

	fns := detectFileBasedRoutesInDir(reservedDir, root, "_fn", false, logger)
	if len(fns) != 0 {
		t.Fatalf("expected reserved file route to be ignored, got %+v", fns)
	}
	if len(logs) == 0 || !strings.Contains(logs[0], "reserved path /_fn") {
		t.Fatalf("expected reserved route warning, got %v", logs)
	}
}

func TestDiscoveryAssetsHelpersAndValidation(t *testing.T) {
	tests := []struct {
		path string
		want bool
	}{
		{path: "public", want: true},
		{path: "public/nested", want: true},
		{path: "", want: false},
		{path: "/absolute", want: false},
		{path: `public\\nested`, want: false},
		{path: ".", want: false},
		{path: "../public", want: false},
		{path: "public/./nested", want: false},
		{path: "public//nested", want: false},
	}

	for _, tc := range tests {
		if got := isSafeRootRelativePath(tc.path); got != tc.want {
			t.Fatalf("isSafeRootRelativePath(%q) = %v, want %v", tc.path, got, tc.want)
		}
	}

	if !relativePathHasPrefix("public/images", "public") {
		t.Fatal("expected relativePathHasPrefix to match nested path")
	}
	if !relativePathHasPrefix("public", "public") {
		t.Fatal("expected relativePathHasPrefix to match exact path")
	}
	if relativePathHasPrefix("", "public") {
		t.Fatal("expected empty path to be rejected")
	}
	if relativePathHasPrefix("public/images", "") {
		t.Fatal("expected empty prefix to be rejected")
	}
	if !relativePathIntersectsPrefix("public", "public/images") {
		t.Fatal("expected prefix intersection for parent/child paths")
	}

	tmpDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmpDir, "fn.config.json"), []byte(`{"assets":{"directory":"public"}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := loadAssetsDirectory(tmpDir); got != "public" {
		t.Fatalf("loadAssetsDirectory() = %q, want public", got)
	}
	if got := loadRootAssetsDirectory(tmpDir); got != "public" {
		t.Fatalf("loadRootAssetsDirectory() = %q, want public", got)
	}

	invalidDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(invalidDir, "fn.config.json"), []byte(`{"assets":{"directory":"../public"}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := loadAssetsDirectory(invalidDir); got != "" {
		t.Fatalf("expected invalid assets directory to be ignored, got %q", got)
	}
}

func TestScan_IgnoresConfiguredAssetsDirectoriesInMixedFunctionRoots(t *testing.T) {
	root := t.TempDir()
	functionDir := filepath.Join(root, "node", "site")
	writeDiscoveryFile(t, filepath.Join(functionDir, "handler.js"), `exports.handler = () => ({ status: 200, body: "ok" })`)
	writeDiscoveryFile(t, filepath.Join(functionDir, "public", "get.secret.js"), `exports.handler = () => ({ status: 200, body: "secret" })`)
	writeDiscoveryFile(t, filepath.Join(functionDir, "admin", "get.dashboard.js"), `exports.handler = () => ({ status: 200, body: "dashboard" })`)
	writeDiscoveryFile(t, filepath.Join(functionDir, "fn.config.json"), `{"assets":{"directory":"public"}}`)

	funcs, err := Scan(root, nil)
	if err != nil {
		t.Fatalf("Scan() error = %v", err)
	}

	foundDashboard := false
	for _, fn := range funcs {
		if fn.OriginalRoute == "GET /site/admin/dashboard" {
			foundDashboard = true
		}
		if fn.OriginalRoute == "GET /site/public/secret" {
			t.Fatalf("assets directory leaked into route discovery: %+v", fn)
		}
	}
	if !foundDashboard {
		t.Fatal("expected non-assets mixed route to remain discoverable")
	}
}

func TestRuntimeRootExposesRoutes_IgnoresConfiguredAssetsDirectories(t *testing.T) {
	root := t.TempDir()
	runtimeDir := filepath.Join(root, "node")
	writeDiscoveryFile(t, filepath.Join(runtimeDir, "fn.config.json"), `{"assets":{"directory":"public"}}`)
	writeDiscoveryFile(t, filepath.Join(runtimeDir, "public", "get.secret.js"), `exports.handler = () => ({ status: 200, body: "secret" })`)

	if runtimeRootExposesRoutes(root, runtimeDir, "node", 0) {
		t.Fatal("expected assets-only runtime root to be ignored")
	}
}

func TestResolveConfigEntrypointPath_FallsBackToAbsWhenRootEvalFails(t *testing.T) {
	dir := t.TempDir()
	writeDiscoveryFile(t, filepath.Join(dir, "fn.config.json"), `{"entrypoint":"handler.js"}`)
	writeDiscoveryFile(t, filepath.Join(dir, "handler.js"), `exports.handler = () => ({ status: 200, body: "ok" })`)

	origEval := filepathEvalSymlinks
	origAbs := filepathAbs
	t.Cleanup(func() {
		filepathEvalSymlinks = origEval
		filepathAbs = origAbs
	})

	filepathEvalSymlinks = func(path string) (string, error) {
		if path == dir {
			return "", fmt.Errorf("forced eval failure")
		}
		return origEval(path)
	}
	filepathAbs = filepath.Abs

	got, ok := resolveConfigEntrypointPath(dir)
	if !ok {
		t.Fatal("expected fallback to filepath.Abs to succeed")
	}
	want := filepath.Join(dir, "handler.js")
	if got != want {
		t.Fatalf("resolveConfigEntrypointPath() = %q, want %q", got, want)
	}
}

func TestResolveConfigEntrypointPath_RejectsWhenRootEvalAndAbsFail(t *testing.T) {
	dir := t.TempDir()
	writeDiscoveryFile(t, filepath.Join(dir, "fn.config.json"), `{"entrypoint":"handler.js"}`)
	writeDiscoveryFile(t, filepath.Join(dir, "handler.js"), `exports.handler = () => ({ status: 200, body: "ok" })`)

	origEval := filepathEvalSymlinks
	origAbs := filepathAbs
	t.Cleanup(func() {
		filepathEvalSymlinks = origEval
		filepathAbs = origAbs
	})

	filepathEvalSymlinks = func(path string) (string, error) {
		if path == dir {
			return "", fmt.Errorf("forced eval failure")
		}
		return origEval(path)
	}
	filepathAbs = func(string) (string, error) {
		return "", fmt.Errorf("forced abs failure")
	}

	if got, ok := resolveConfigEntrypointPath(dir); ok || got != "" {
		t.Fatalf("expected double fallback failure to reject entrypoint, got %q ok=%v", got, ok)
	}
}

func TestResolveConfigEntrypointPath_RejectsDirectoryEntrypoint(t *testing.T) {
	dir := t.TempDir()
	writeDiscoveryFile(t, filepath.Join(dir, "fn.config.json"), `{"entrypoint":"worker"}`)
	if err := os.MkdirAll(filepath.Join(dir, "worker"), 0o755); err != nil {
		t.Fatal(err)
	}

	if got, ok := resolveConfigEntrypointPath(dir); ok || got != "" {
		t.Fatalf("expected directory entrypoint to be rejected, got %q ok=%v", got, ok)
	}
}
