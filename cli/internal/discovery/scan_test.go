package discovery

import (
	"os"
	"path/filepath"
	"testing"
)

func TestScan(t *testing.T) {
	// Create temp dir structure
	tmpDir, err := os.MkdirTemp("", "fastfn-discovery-test")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	// Case 1: Root with fn.config.json (Explicit)
	// root/explicit-func/fn.config.json
	explicitDir := filepath.Join(tmpDir, "explicit-func")
	os.Mkdir(explicitDir, 0755)
	os.WriteFile(filepath.Join(explicitDir, "fn.config.json"), []byte(`{"runtime":"python", "name":"my-py"}`), 0644)

	// Case 2: Root with handler.js (Implicit Zero-Config)
	// root/implicit-node/handler.js
	implicitNodeDir := filepath.Join(tmpDir, "implicit-node")
	os.Mkdir(implicitNodeDir, 0755)
	os.WriteFile(filepath.Join(implicitNodeDir, "handler.js"), []byte(`...`), 0644)

	// Case 3: Ignored folder (no handler, no config)
	// root/ignored
	ignoredDir := filepath.Join(tmpDir, "ignored")
	os.Mkdir(ignoredDir, 0755)

	// Case 4: Deeply nested (Zero-Config)
	// root/group/nested-func/main.py
	groupDir := filepath.Join(tmpDir, "group")
	os.Mkdir(groupDir, 0755)
	nestedDir := filepath.Join(groupDir, "nested-func")
	os.Mkdir(nestedDir, 0755)
	os.WriteFile(filepath.Join(nestedDir, "main.py"), []byte(`...`), 0644)

	// Case 5: Polyglot Multi-Route
	// root/polyglot/fn.routes.json
	polyglotDir := filepath.Join(tmpDir, "polyglot")
	os.Mkdir(polyglotDir, 0755)
	os.WriteFile(filepath.Join(polyglotDir, "fn.routes.json"), []byte(`{
		"routes": {
			"GET /items": "handlers/list.js",
			"POST /items": "handlers/create.py"
		} 
	}`), 0644)
	os.Mkdir(filepath.Join(polyglotDir, "handlers"), 0755)
	os.WriteFile(filepath.Join(polyglotDir, "handlers/list.js"), []byte("..."), 0644)
	os.WriteFile(filepath.Join(polyglotDir, "handlers/create.py"), []byte("..."), 0644)

	// Run Scan
	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	// Verify results: 3 existing + 2 from polyglot = 5
	if len(funcs) != 5 {
		t.Errorf("Expected 5 functions, got %d", len(funcs))
	}

	foundExplicit := false
	foundImplicit := false
	foundNested := false
	foundPolyJS := false
	foundPolyPy := false

	for _, fn := range funcs {
		if fn.Name == "my-py" && fn.Runtime == "python" {
			foundExplicit = true
		}
		if fn.Name == "implicit-node" && fn.Runtime == "node" {
			foundImplicit = true
		}
		if fn.Name == "nested-func" && fn.Runtime == "python" {
			foundNested = true
		}
		if fn.Name == "get_items" && fn.Runtime == "node" {
			foundPolyJS = true
		}
		if fn.Name == "post_items" && fn.Runtime == "python" {
			foundPolyPy = true
		}
	}

	if !foundExplicit {
		t.Error("Did not find explicit-func")
	}
	if !foundImplicit {
		t.Error("Did not find implicit-node")
	}
	if !foundNested {
		t.Error("Did not find nested-func")
	}
	if !foundPolyJS {
		t.Error("Did not find polyglot JS route")
	}
	if !foundPolyPy {
		t.Error("Did not find polyglot Py route")
	}
}

func TestScanNextStyleRoutes(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "fastfn-discovery-next-style")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	// users/index.js -> GET /users
	usersDir := filepath.Join(tmpDir, "users")
	os.Mkdir(usersDir, 0755)
	os.WriteFile(filepath.Join(usersDir, "index.js"), []byte(`...`), 0644)

	// users/[id].js -> GET /users/:id
	os.WriteFile(filepath.Join(usersDir, "[id].js"), []byte(`...`), 0644)

	// blog/[...slug].py -> GET /blog/:slug*
	blogDir := filepath.Join(tmpDir, "blog")
	os.Mkdir(blogDir, 0755)
	os.WriteFile(filepath.Join(blogDir, "[...slug].py"), []byte(`...`), 0644)

	// admin/post.users.[id].py -> POST /admin/users/:id
	adminDir := filepath.Join(tmpDir, "admin")
	os.Mkdir(adminDir, 0755)
	os.WriteFile(filepath.Join(adminDir, "post.users.[id].py"), []byte(`...`), 0644)

	// shop/[[...opt]].js -> GET /shop and GET /shop/:opt*
	shopDir := filepath.Join(tmpDir, "shop")
	os.Mkdir(shopDir, 0755)
	os.WriteFile(filepath.Join(shopDir, "[[...opt]].js"), []byte(`...`), 0644)

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	type key struct {
		route   string
		runtime string
	}

	expected := map[key]bool{
		{route: "GET /users", runtime: "node"}:              false,
		{route: "GET /users/:id", runtime: "node"}:          false,
		{route: "GET /blog/:slug*", runtime: "python"}:      false,
		{route: "POST /admin/users/:id", runtime: "python"}: false,
		{route: "GET /shop", runtime: "node"}:               false,
		{route: "GET /shop/:opt*", runtime: "node"}:         false,
	}

	for _, fn := range funcs {
		k := key{route: fn.OriginalRoute, runtime: fn.Runtime}
		if _, ok := expected[k]; ok {
			expected[k] = true
		}
	}

	for k, found := range expected {
		if !found {
			t.Fatalf("missing discovered route %q runtime=%q", k.route, k.runtime)
		}
	}
}

func TestScanMethodOnlyFilesMapToDirRoot(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "fastfn-discovery-method-only")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	helloDir := filepath.Join(tmpDir, "hello")
	if err := os.Mkdir(helloDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(helloDir, "get.py"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(helloDir, "post.js"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	type key struct {
		route   string
		runtime string
	}
	expected := map[key]bool{
		{route: "GET /hello", runtime: "python"}:  false,
		{route: "POST /hello", runtime: "node"}:  false,
		{route: "GET /hello/get", runtime: "python"}: false,
	}

	for _, fn := range funcs {
		k := key{route: fn.OriginalRoute, runtime: fn.Runtime}
		if _, ok := expected[k]; ok {
			expected[k] = true
		}
	}

	if !expected[key{route: "GET /hello", runtime: "python"}] {
		t.Fatal("expected GET /hello from hello/get.py")
	}
	if !expected[key{route: "POST /hello", runtime: "node"}] {
		t.Fatal("expected POST /hello from hello/post.js")
	}
	if expected[key{route: "GET /hello/get", runtime: "python"}] {
		t.Fatal("did not expect GET /hello/get for hello/get.py (method-only should map to dir root)")
	}
}

func TestScanConfigOverlayDoesNotSuppressFileRoutes(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "fastfn-discovery-config-overlay")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	dir := filepath.Join(tmpDir, "overlay")
	if err := os.Mkdir(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "fn.config.json"), []byte(`{
  "group": "demo",
  "timeout_ms": 1200,
  "invoke": { "methods": ["GET"] }
}`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "get.js"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}
	// Nested route directory should still be discovered.
	nested := filepath.Join(dir, "[id]")
	if err := os.Mkdir(nested, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(nested, "get.py"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	foundRoot := false
	foundNested := false
	for _, fn := range funcs {
		if fn.OriginalRoute == "GET /overlay" && fn.Runtime == "node" && fn.HasConfig {
			foundRoot = true
		}
		if fn.OriginalRoute == "GET /overlay/:id" && fn.Runtime == "python" {
			foundNested = true
		}
	}

	if !foundRoot {
		t.Fatal("expected overlay get.js route to be discovered and marked HasConfig=true")
	}
	if !foundNested {
		t.Fatal("expected overlay/[id]/get.py route to be discovered")
	}
}

func TestScanRootAndNestedRoutesTogether(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "fastfn-discovery-root-and-nested")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	// Root file route: hello.js -> GET /hello
	if err := os.WriteFile(filepath.Join(tmpDir, "hello.js"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}

	// Nested routes under users/
	usersDir := filepath.Join(tmpDir, "users")
	if err := os.Mkdir(usersDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(usersDir, "index.js"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(usersDir, "[id].js"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	expected := map[string]bool{
		"GET /hello":     false,
		"GET /users":     false,
		"GET /users/:id": false,
	}

	for _, fn := range funcs {
		if _, ok := expected[fn.OriginalRoute]; ok {
			expected[fn.OriginalRoute] = true
		}
	}

	for route, found := range expected {
		if !found {
			t.Fatalf("missing discovered route %q", route)
		}
	}
}

func TestScanRuntimeIsInferredFromExtensionNotFromURLPrefix(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "fastfn-discovery-runtime-vs-url")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	// Runtime must come from extension, while URL comes from file tokens.
	if err := os.WriteFile(filepath.Join(tmpDir, "get.health.rs"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tmpDir, "get.profile.[id].php"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	type key struct {
		route   string
		runtime string
	}
	expected := map[key]bool{
		{route: "GET /health", runtime: "rust"}:     false,
		{route: "GET /profile/:id", runtime: "php"}: false,
	}

	for _, fn := range funcs {
		k := key{route: fn.OriginalRoute, runtime: fn.Runtime}
		if _, ok := expected[k]; ok {
			expected[k] = true
		}
		// URL should not auto-prefix runtime names.
		if fn.Runtime == "rust" && fn.OriginalRoute == "GET /rust/health" {
			t.Fatalf("unexpected runtime-prefixed route for rust file: %q", fn.OriginalRoute)
		}
		if fn.Runtime == "php" && fn.OriginalRoute == "GET /php/profile/:id" {
			t.Fatalf("unexpected runtime-prefixed route for php file: %q", fn.OriginalRoute)
		}
	}

	for k, found := range expected {
		if !found {
			t.Fatalf("missing discovered route %q runtime=%q", k.route, k.runtime)
		}
	}
}

func TestScanIgnoresEmptyOrInvalidConfigAndFallsBackToFileRoutes(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "fastfn-discovery-empty-config")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	emptyCfgDir := filepath.Join(tmpDir, "empty-cfg")
	if err := os.Mkdir(emptyCfgDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(emptyCfgDir, "fn.config.json"), []byte(`{}`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(emptyCfgDir, "index.js"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}

	invalidCfgDir := filepath.Join(tmpDir, "invalid-cfg")
	if err := os.Mkdir(invalidCfgDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(invalidCfgDir, "fn.config.json"), []byte(`{invalid`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(invalidCfgDir, "index.py"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	foundEmptyCfg := false
	foundInvalidCfg := false
	for _, fn := range funcs {
		if fn.OriginalRoute == "GET /empty-cfg" && fn.Runtime == "node" && !fn.HasConfig {
			foundEmptyCfg = true
		}
		if fn.OriginalRoute == "GET /invalid-cfg" && fn.Runtime == "python" && !fn.HasConfig {
			foundInvalidCfg = true
		}
	}

	if !foundEmptyCfg {
		t.Fatal("expected fallback file route for empty fn.config.json")
	}
	if !foundInvalidCfg {
		t.Fatal("expected fallback file route for invalid fn.config.json")
	}
}

func TestScanManifestSelectiveOverride(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "fastfn-discovery-manifest-override")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	apiDir := filepath.Join(tmpDir, "api")
	if err := os.Mkdir(apiDir, 0755); err != nil {
		t.Fatal(err)
	}

	if err := os.WriteFile(filepath.Join(apiDir, "get.items.js"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(apiDir, "post.items.py"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(apiDir, "delete.items.[id].rs"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(apiDir, "fn.routes.json"), []byte(`{
		"routes": {
			"GET /api/items": "handlers/list.php",
			"PATCH /api/items/:id": "handlers/patch.py"
		}
	}`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(apiDir, "handlers"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(apiDir, "handlers/list.php"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(apiDir, "handlers/patch.py"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	type key struct {
		route   string
		runtime string
	}
	got := map[key]bool{}
	for _, fn := range funcs {
		got[key{route: fn.OriginalRoute, runtime: fn.Runtime}] = true
	}

	expected := []key{
		{route: "GET /api/items", runtime: "php"},          // manifest overrides file-based GET /api/items.js
		{route: "PATCH /api/items/:id", runtime: "python"}, // manifest-only route kept
		{route: "POST /api/items", runtime: "python"},      // non-overlapping file route kept
		{route: "DELETE /api/items/:id", runtime: "rust"},  // non-overlapping file route kept
	}

	for _, k := range expected {
		if !got[k] {
			t.Fatalf("missing route=%q runtime=%q in merged manifest+file discovery", k.route, k.runtime)
		}
	}
}

func TestScanIgnoresHelperAndTestFiles(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "fastfn-discovery-ignore-files")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	docsDir := filepath.Join(tmpDir, "docs")
	if err := os.Mkdir(docsDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(docsDir, "_helper.js"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(docsDir, "page.test.js"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(docsDir, "page.spec.js"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(docsDir, "types.d.ts"), []byte(`export type A = string;`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(docsDir, "index.js"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	hasDocs := false
	for _, fn := range funcs {
		if fn.OriginalRoute == "GET /docs" && fn.Runtime == "node" {
			hasDocs = true
		}
		if fn.EntryFile == "_helper.js" || fn.EntryFile == "page.test.js" || fn.EntryFile == "page.spec.js" || fn.EntryFile == "types.d.ts" {
			t.Fatalf("ignored file should not be discovered: %s", fn.EntryFile)
		}
	}

	if !hasDocs {
		t.Fatal("expected docs/index.js route to be discovered")
	}
}

func TestScanDetectsLuaFileRoutes(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "fastfn-discovery-lua-routes")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	luaDir := filepath.Join(tmpDir, "lua-routes")
	if err := os.Mkdir(luaDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(luaDir, "get.health.lua"), []byte(`...`), 0644); err != nil {
		t.Fatal(err)
	}

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	found := false
	for _, fn := range funcs {
		if fn.OriginalRoute == "GET /lua-routes/health" {
			found = true
			if fn.Runtime != "lua" {
				t.Fatalf("expected lua runtime, got %s", fn.Runtime)
			}
		}
	}
	if !found {
		t.Fatal("expected lua file route to be discovered")
	}
}

func TestScanDetectsGoAndRustFromFiles(t *testing.T) {
	tmpDir := t.TempDir()

	goDir := filepath.Join(tmpDir, "go-fn")
	if err := os.Mkdir(goDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(goDir, "main.go"), []byte("package main"), 0644); err != nil {
		t.Fatal(err)
	}

	rustDir := filepath.Join(tmpDir, "rust-fn")
	if err := os.Mkdir(rustDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(rustDir, "handler.rs"), []byte("fn handler(){}"), 0644); err != nil {
		t.Fatal(err)
	}

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	foundGo := false
	foundRust := false
	for _, fn := range funcs {
		if fn.Name == "go-fn" && fn.Runtime == "go" {
			foundGo = true
		}
		if fn.Name == "rust-fn" && fn.Runtime == "rust" {
			foundRust = true
		}
	}

	if !foundGo {
		t.Fatal("expected go function from main.go")
	}
	if !foundRust {
		t.Fatal("expected rust function from handler.rs")
	}
}

func TestScanConfigNoRuntime_FallbackToFileDetect(t *testing.T) {
	tmpDir := t.TempDir()

	fnDir := filepath.Join(tmpDir, "my-fn")
	if err := os.Mkdir(fnDir, 0755); err != nil {
		t.Fatal(err)
	}
	// Config with name but no runtime
	if err := os.WriteFile(filepath.Join(fnDir, "fn.config.json"), []byte(`{"name":"my-fn"}`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fnDir, "handler.py"), []byte("def handler():pass"), 0644); err != nil {
		t.Fatal(err)
	}

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	found := false
	for _, fn := range funcs {
		if fn.Name == "my-fn" && fn.Runtime == "python" && fn.HasConfig {
			found = true
		}
	}
	if !found {
		t.Fatal("expected config with no runtime to fallback to file detection")
	}
}

func TestScanConfigNoRuntimeNoFiles_DefaultsToNode(t *testing.T) {
	tmpDir := t.TempDir()

	fnDir := filepath.Join(tmpDir, "bare-fn")
	if err := os.Mkdir(fnDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fnDir, "fn.config.json"), []byte(`{"name":"bare-fn"}`), 0644); err != nil {
		t.Fatal(err)
	}

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	found := false
	for _, fn := range funcs {
		if fn.Name == "bare-fn" && fn.Runtime == "node" {
			found = true
		}
	}
	if !found {
		t.Fatal("expected bare config with no runtime files to default to node")
	}
}

func TestScanInvalidRoot(t *testing.T) {
	_, err := Scan("/nonexistent/path/that/does/not/exist", nil)
	if err == nil {
		t.Fatal("expected error for invalid root")
	}
}

func TestScanRootIsFunctionItself(t *testing.T) {
	tmpDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmpDir, "handler.js"), []byte("module.exports={}"), 0644); err != nil {
		t.Fatal(err)
	}

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	found := false
	for _, fn := range funcs {
		if fn.Runtime == "node" && fn.Path == tmpDir {
			found = true
		}
	}
	if !found {
		t.Fatal("expected root itself to be detected as a function")
	}
}

func TestScanDuplicateDetectionDedup(t *testing.T) {
	tmpDir := t.TempDir()
	// Create a function that would match both config and file detection
	fnDir := filepath.Join(tmpDir, "dedup-fn")
	if err := os.Mkdir(fnDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fnDir, "fn.config.json"), []byte(`{"runtime":"node","name":"dedup-fn"}`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fnDir, "handler.js"), []byte("module.exports={}"), 0644); err != nil {
		t.Fatal(err)
	}

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	count := 0
	for _, fn := range funcs {
		if fn.Name == "dedup-fn" && fn.Runtime == "node" {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("expected exactly 1 dedup-fn entry, got %d", count)
	}
}

func TestScanManifestEmptyRoutes(t *testing.T) {
	tmpDir := t.TempDir()
	fnDir := filepath.Join(tmpDir, "empty-manifest")
	if err := os.Mkdir(fnDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fnDir, "fn.routes.json"), []byte(`{"routes":{}}`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fnDir, "handler.js"), []byte("..."), 0644); err != nil {
		t.Fatal(err)
	}

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	found := false
	for _, fn := range funcs {
		if fn.Name == "empty-manifest" && fn.Runtime == "node" {
			found = true
		}
	}
	if !found {
		t.Fatal("expected fallback to file detection when manifest routes are empty")
	}
}

func TestScanWithLogger(t *testing.T) {
	tmpDir := t.TempDir()
	fnDir := filepath.Join(tmpDir, "logged-fn")
	if err := os.Mkdir(fnDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fnDir, "handler.js"), []byte("..."), 0644); err != nil {
		t.Fatal(err)
	}

	var logs []string
	logger := func(format string, v ...interface{}) {
		logs = append(logs, format)
	}

	funcs, err := Scan(tmpDir, logger)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	if len(funcs) == 0 {
		t.Fatal("expected at least one function")
	}
	if len(logs) == 0 {
		t.Fatal("expected logger to be called")
	}
}

func TestDetectRuntimeFromFile_AllExtensions(t *testing.T) {
	tests := []struct {
		file    string
		runtime string
	}{
		{"handler.js", "node"},
		{"handler.ts", "node"},
		{"handler.py", "python"},
		{"handler.php", "php"},
		{"handler.lua", "lua"},
		{"handler.rs", "rust"},
		{"handler.go", "go"},
		{"handler.txt", ""},
		{"types.d.ts", ""},
	}

	for _, tc := range tests {
		t.Run(tc.file, func(t *testing.T) {
			got := detectRuntimeFromFile(tc.file)
			if got != tc.runtime {
				t.Fatalf("detectRuntimeFromFile(%q) = %q, want %q", tc.file, got, tc.runtime)
			}
		})
	}
}

func TestIsLeafFunctionDir_WithManifest(t *testing.T) {
	tmpDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmpDir, "fn.routes.json"), []byte(`{"routes":{"GET /x":"handler.js"}}`), 0644); err != nil {
		t.Fatal(err)
	}

	if !isLeafFunctionDir(tmpDir) {
		t.Fatal("expected leaf function dir with non-empty manifest")
	}
}

func TestIsLeafFunctionDir_WithExplicitConfig(t *testing.T) {
	tmpDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmpDir, "fn.config.json"), []byte(`{"runtime":"node","name":"leaf"}`), 0644); err != nil {
		t.Fatal(err)
	}

	if !isLeafFunctionDir(tmpDir) {
		t.Fatal("expected leaf function dir with explicit config")
	}
}

func TestIsLeafFunctionDir_NeitherManifestNorConfig(t *testing.T) {
	tmpDir := t.TempDir()

	if isLeafFunctionDir(tmpDir) {
		t.Fatal("expected non-leaf when neither manifest nor config exists")
	}
}

// ---------------------------------------------------------------------------
// parseConfig
// ---------------------------------------------------------------------------

func TestParseConfig_Valid(t *testing.T) {
	tmpDir := t.TempDir()
	cfgPath := filepath.Join(tmpDir, "fn.config.json")
	os.WriteFile(cfgPath, []byte(`{"runtime":"python","name":"my-fn"}`), 0644)

	rt, name := parseConfig(cfgPath)
	if rt != "python" {
		t.Fatalf("parseConfig runtime = %q, want python", rt)
	}
	if name != "my-fn" {
		t.Fatalf("parseConfig name = %q, want my-fn", name)
	}
}

func TestParseConfig_MissingFile(t *testing.T) {
	rt, name := parseConfig("/nonexistent/fn.config.json")
	if rt != "" || name != "" {
		t.Fatalf("expected empty values for missing file, got (%q, %q)", rt, name)
	}
}

func TestParseConfig_InvalidJSON(t *testing.T) {
	tmpDir := t.TempDir()
	cfgPath := filepath.Join(tmpDir, "fn.config.json")
	os.WriteFile(cfgPath, []byte(`{invalid`), 0644)

	rt, name := parseConfig(cfgPath)
	if rt != "" || name != "" {
		t.Fatalf("expected empty values for invalid JSON, got (%q, %q)", rt, name)
	}
}

func TestParseConfig_EmptyFields(t *testing.T) {
	tmpDir := t.TempDir()
	cfgPath := filepath.Join(tmpDir, "fn.config.json")
	os.WriteFile(cfgPath, []byte(`{"runtime":"","name":""}`), 0644)

	rt, name := parseConfig(cfgPath)
	if rt != "" || name != "" {
		t.Fatalf("expected empty values for empty fields, got (%q, %q)", rt, name)
	}
}

// ---------------------------------------------------------------------------
// isNonEmptyJSONConfig
// ---------------------------------------------------------------------------

func TestIsNonEmptyJSONConfig_Valid(t *testing.T) {
	tmpDir := t.TempDir()
	cfgPath := filepath.Join(tmpDir, "fn.config.json")
	os.WriteFile(cfgPath, []byte(`{"runtime":"node"}`), 0644)

	if !isNonEmptyJSONConfig(cfgPath) {
		t.Fatal("expected true for non-empty JSON config")
	}
}

func TestIsNonEmptyJSONConfig_Empty(t *testing.T) {
	tmpDir := t.TempDir()
	cfgPath := filepath.Join(tmpDir, "fn.config.json")
	os.WriteFile(cfgPath, []byte(`{}`), 0644)

	if isNonEmptyJSONConfig(cfgPath) {
		t.Fatal("expected false for empty JSON config")
	}
}

func TestIsNonEmptyJSONConfig_MissingFile(t *testing.T) {
	if isNonEmptyJSONConfig("/nonexistent/fn.config.json") {
		t.Fatal("expected false for missing file")
	}
}

func TestIsNonEmptyJSONConfig_InvalidJSON(t *testing.T) {
	tmpDir := t.TempDir()
	cfgPath := filepath.Join(tmpDir, "fn.config.json")
	os.WriteFile(cfgPath, []byte(`{bad`), 0644)

	if isNonEmptyJSONConfig(cfgPath) {
		t.Fatal("expected false for invalid JSON")
	}
}

// ---------------------------------------------------------------------------
// isExplicitFunctionConfig
// ---------------------------------------------------------------------------

func TestIsExplicitFunctionConfig_EmptyMap(t *testing.T) {
	if isExplicitFunctionConfig(map[string]interface{}{}) {
		t.Fatal("expected false for empty map")
	}
}

func TestIsExplicitFunctionConfig_RuntimeOnly(t *testing.T) {
	raw := map[string]interface{}{"runtime": "python"}
	if !isExplicitFunctionConfig(raw) {
		t.Fatal("expected true when runtime is set")
	}
}

func TestIsExplicitFunctionConfig_NameOnly(t *testing.T) {
	raw := map[string]interface{}{"name": "my-fn"}
	if !isExplicitFunctionConfig(raw) {
		t.Fatal("expected true when name is set")
	}
}

func TestIsExplicitFunctionConfig_EntrypointOnly(t *testing.T) {
	raw := map[string]interface{}{"entrypoint": "handler.js"}
	if !isExplicitFunctionConfig(raw) {
		t.Fatal("expected true when entrypoint is set")
	}
}

func TestIsExplicitFunctionConfig_InvokeRoutes(t *testing.T) {
	raw := map[string]interface{}{
		"invoke": map[string]interface{}{
			"routes": []interface{}{"GET /hello"},
		},
	}
	if !isExplicitFunctionConfig(raw) {
		t.Fatal("expected true when invoke.routes is non-empty")
	}
}

func TestIsExplicitFunctionConfig_InvokeEmptyRoutes(t *testing.T) {
	raw := map[string]interface{}{
		"invoke": map[string]interface{}{
			"routes": []interface{}{},
		},
	}
	if isExplicitFunctionConfig(raw) {
		t.Fatal("expected false when invoke.routes is empty")
	}
}

func TestIsExplicitFunctionConfig_InvokeNotMap(t *testing.T) {
	raw := map[string]interface{}{
		"invoke": "not a map",
	}
	if isExplicitFunctionConfig(raw) {
		t.Fatal("expected false when invoke is not a map")
	}
}

func TestIsExplicitFunctionConfig_InvokeRoutesNotSlice(t *testing.T) {
	raw := map[string]interface{}{
		"invoke": map[string]interface{}{
			"routes": "not a slice",
		},
	}
	if isExplicitFunctionConfig(raw) {
		t.Fatal("expected false when invoke.routes is not a slice")
	}
}

func TestIsExplicitFunctionConfig_WhitespaceRuntime(t *testing.T) {
	raw := map[string]interface{}{"runtime": "  "}
	if isExplicitFunctionConfig(raw) {
		t.Fatal("expected false when runtime is whitespace-only")
	}
}

func TestIsExplicitFunctionConfig_NonStringRuntime(t *testing.T) {
	raw := map[string]interface{}{"runtime": 42, "timeout_ms": 1000}
	if isExplicitFunctionConfig(raw) {
		t.Fatal("expected false when runtime is not a string and no other identity fields")
	}
}

// ---------------------------------------------------------------------------
// routeKey
// ---------------------------------------------------------------------------

func TestRouteKey_MethodAndPath(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"GET /items", "GET /items"},
		{"post /items", "POST /items"},
		{"PUT /items", "PUT /items"},
		{"PATCH /items", "PATCH /items"},
		{"DELETE /items", "DELETE /items"},
		{"/items", "GET /items"},
		{"  GET  /items  ", "GET /items"},
		{"UNKNOWN /items", "GET UNKNOWN /items"},
	}
	for _, tc := range tests {
		got := routeKey(tc.input)
		if got != tc.want {
			t.Fatalf("routeKey(%q) = %q, want %q", tc.input, got, tc.want)
		}
	}
}

// ---------------------------------------------------------------------------
// splitFileTokens
// ---------------------------------------------------------------------------

func TestSplitFileTokens_EmptyString(t *testing.T) {
	got := splitFileTokens("")
	if len(got) != 1 || got[0] != "" {
		t.Fatalf("splitFileTokens(\"\") = %v", got)
	}
}

func TestSplitFileTokens_NoBrackets(t *testing.T) {
	got := splitFileTokens("get.users")
	if len(got) != 2 || got[0] != "get" || got[1] != "users" {
		t.Fatalf("splitFileTokens(\"get.users\") = %v", got)
	}
}

func TestSplitFileTokens_WithBrackets(t *testing.T) {
	got := splitFileTokens("get.users.[id]")
	if len(got) != 3 || got[0] != "get" || got[1] != "users" || got[2] != "[id]" {
		t.Fatalf("splitFileTokens(\"get.users.[id]\") = %v", got)
	}
}

// ---------------------------------------------------------------------------
// detectManifestRoutes – unknown extension fallback to rt="node"
// ---------------------------------------------------------------------------

func TestDetectManifestRoutes_UnknownExtensionFallsBackToNode(t *testing.T) {
	tmpDir := t.TempDir()
	// Create a manifest that maps a route to a file with an unknown extension.
	if err := os.WriteFile(filepath.Join(tmpDir, "fn.routes.json"), []byte(`{
		"routes": {
			"GET /data": "handlers/export.xyz"
		}
	}`), 0644); err != nil {
		t.Fatal(err)
	}

	fns, hasManifest := detectManifestRoutes(tmpDir, func(format string, v ...interface{}) {})
	if !hasManifest {
		t.Fatal("expected hasManifest=true")
	}
	if len(fns) != 1 {
		t.Fatalf("expected 1 function, got %d", len(fns))
	}
	if fns[0].Runtime != "node" {
		t.Fatalf("expected runtime fallback to 'node', got %q", fns[0].Runtime)
	}
}

// ---------------------------------------------------------------------------
// detectFileBasedRoutes – filepath.Rel error path
// ---------------------------------------------------------------------------

func TestDetectFileBasedRoutes_RelError(t *testing.T) {
	// When filepath.Rel fails, relPath falls back to filepath.Base(path).
	// This is hard to trigger on most OSes, but we can test the normal case
	// and verify the function handles edge cases gracefully.
	tmpDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmpDir, "get.health.js"), []byte("..."), 0644); err != nil {
		t.Fatal(err)
	}

	// Pass an unrelated root to make Rel produce a relative path with ".." prefixes
	unrelatedRoot := "/unlikely/root/path/that/does/not/match"
	fns := detectFileBasedRoutes(tmpDir, unrelatedRoot)
	// Should still produce routes even when root doesn't match
	if len(fns) == 0 {
		t.Fatal("expected at least one file-based route even with mismatched root")
	}
}

// ---------------------------------------------------------------------------
// Scan – L2 os.ReadDir error, appendUnique default scope
// ---------------------------------------------------------------------------

func TestScan_L2ReadDirErrorSkipped(t *testing.T) {
	tmpDir := t.TempDir()

	// Create a L1 directory that is not a leaf and contains a non-readable L2 dir
	l1Dir := filepath.Join(tmpDir, "group")
	if err := os.Mkdir(l1Dir, 0755); err != nil {
		t.Fatal(err)
	}
	// Create an unreadable L2 dir
	l2Dir := filepath.Join(l1Dir, "broken")
	if err := os.Mkdir(l2Dir, 0755); err != nil {
		t.Fatal(err)
	}
	// Make it unreadable
	if err := os.Chmod(l2Dir, 0000); err != nil {
		t.Skipf("chmod not supported: %v", err)
	}
	t.Cleanup(func() { os.Chmod(l2Dir, 0755) })

	// Also add a working L2 dir with a function
	l2Good := filepath.Join(l1Dir, "good-fn")
	if err := os.Mkdir(l2Good, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(l2Good, "handler.js"), []byte("..."), 0644); err != nil {
		t.Fatal(err)
	}

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}
	// Should find good-fn despite broken L2 dir
	found := false
	for _, fn := range funcs {
		if fn.Name == "good-fn" {
			found = true
		}
	}
	if !found {
		t.Fatal("expected good-fn to be discovered despite broken sibling")
	}
}

// ---------------------------------------------------------------------------
// detectFunction – hasManifest=true but merged is empty
// ---------------------------------------------------------------------------

func TestDetectFunction_ManifestEmptyRoutesAndNoFileRoutes(t *testing.T) {
	tmpDir := t.TempDir()
	fnDir := filepath.Join(tmpDir, "empty-merge")
	if err := os.Mkdir(fnDir, 0755); err != nil {
		t.Fatal(err)
	}
	// Empty manifest routes
	if err := os.WriteFile(filepath.Join(fnDir, "fn.routes.json"), []byte(`{"routes":{}}`), 0644); err != nil {
		t.Fatal(err)
	}
	// No handler files, so file-based routes are empty too
	// But add a handler.js so the single-entry fallback path hits
	if err := os.WriteFile(filepath.Join(fnDir, "handler.js"), []byte("..."), 0644); err != nil {
		t.Fatal(err)
	}

	fns, ok := detectFunction(fnDir, tmpDir, func(format string, v ...interface{}) {})
	if !ok {
		t.Fatal("expected function to be detected via single-entry fallback")
	}
	if len(fns) == 0 {
		t.Fatal("expected at least one function")
	}
	if fns[0].Runtime != "node" {
		t.Fatalf("expected runtime=node, got %q", fns[0].Runtime)
	}
}

// ---------------------------------------------------------------------------
// detectFunction – overlay config with manifest producing merged
// ---------------------------------------------------------------------------

func TestDetectFunction_OverlayConfigWithManifest(t *testing.T) {
	tmpDir := t.TempDir()
	fnDir := filepath.Join(tmpDir, "overlay-manifest")
	if err := os.Mkdir(fnDir, 0755); err != nil {
		t.Fatal(err)
	}
	// Non-identity config (overlay)
	if err := os.WriteFile(filepath.Join(fnDir, "fn.config.json"), []byte(`{"timeout_ms": 1200}`), 0644); err != nil {
		t.Fatal(err)
	}
	// Manifest with routes
	if err := os.WriteFile(filepath.Join(fnDir, "fn.routes.json"), []byte(`{
		"routes": {
			"GET /items": "list.js"
		}
	}`), 0644); err != nil {
		t.Fatal(err)
	}

	fns, ok := detectFunction(fnDir, tmpDir, func(format string, v ...interface{}) {})
	if !ok {
		t.Fatal("expected function to be detected")
	}
	// Overlay config should mark HasConfig=true on merged routes
	for _, fn := range fns {
		if !fn.HasConfig {
			t.Fatalf("expected HasConfig=true for overlay config + manifest merge, got false for %s", fn.Name)
		}
	}
}

func TestDetectFunction_ConfigWithRuntimeButNoName(t *testing.T) {
	// When fn.config.json has "runtime" but no "name", the name should
	// fall back to filepath.Base(path).
	tmpDir := t.TempDir()
	fnDir := filepath.Join(tmpDir, "my-func-dir")
	if err := os.Mkdir(fnDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fnDir, "fn.config.json"), []byte(`{"runtime":"python"}`), 0644); err != nil {
		t.Fatal(err)
	}

	fns, ok := detectFunction(fnDir, tmpDir, func(format string, v ...interface{}) {})
	if !ok {
		t.Fatal("expected function to be detected")
	}
	if len(fns) != 1 {
		t.Fatalf("expected 1 function, got %d", len(fns))
	}
	if fns[0].Name != "my-func-dir" {
		t.Fatalf("expected name to fallback to dir base name 'my-func-dir', got %q", fns[0].Name)
	}
	if fns[0].Runtime != "python" {
		t.Fatalf("expected runtime 'python', got %q", fns[0].Runtime)
	}
}

func TestScan_DuplicateFunctionDedup(t *testing.T) {
	// When the same function is detected at both L1 and root level,
	// the appendUnique seen map should deduplicate them.
	// This happens when the root itself IS a function and also appears
	// in the L1 scan. We create a dir that is itself a function.
	tmpDir := t.TempDir()

	// Root itself is a function (has handler.js)
	if err := os.WriteFile(filepath.Join(tmpDir, "handler.js"), []byte("exports.handler = () => {};"), 0644); err != nil {
		t.Fatal(err)
	}

	fns, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan() error = %v", err)
	}
	// Should have exactly 1 function even if root was detected
	count := 0
	for _, fn := range fns {
		if fn.Runtime == "node" {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("expected exactly 1 deduped function, got %d (total fns=%d)", count, len(fns))
	}
}

func TestSplitFileTokens_DotInsideBrackets(t *testing.T) {
	got := splitFileTokens("get.[[...opt]]")
	if len(got) != 2 || got[0] != "get" || got[1] != "[[...opt]]" {
		t.Fatalf("splitFileTokens(\"get.[[...opt]]\") = %v", got)
	}
}

func TestScan_L2ReadDirErrorContinues(t *testing.T) {
	// When an L1 directory is not readable, os.ReadDir at L2 level
	// should fail and be skipped gracefully.
	tmpDir := t.TempDir()

	// Create L1 dir that is NOT a leaf (no manifest, no explicit config)
	// and is not itself a function, but cannot be listed for L2 scanning.
	l1Dir := filepath.Join(tmpDir, "unreadable-group")
	if err := os.Mkdir(l1Dir, 0755); err != nil {
		t.Fatal(err)
	}
	// Create a subdir so it looks like a group dir, then make it unreadable
	l2Dir := filepath.Join(l1Dir, "sub-fn")
	if err := os.Mkdir(l2Dir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(l2Dir, "handler.js"), []byte("..."), 0644); err != nil {
		t.Fatal(err)
	}
	// Make L1 dir unreadable so os.ReadDir(l1Dir) fails at the L2 stage
	if err := os.Chmod(l1Dir, 0111); err != nil {
		t.Skipf("chmod not supported: %v", err)
	}
	t.Cleanup(func() { os.Chmod(l1Dir, 0755) })

	// Also add a working L1 function so we verify scan still succeeds
	workingDir := filepath.Join(tmpDir, "working-fn")
	if err := os.Mkdir(workingDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workingDir, "handler.py"), []byte("..."), 0644); err != nil {
		t.Fatal(err)
	}

	funcs, err := Scan(tmpDir, nil)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	found := false
	for _, fn := range funcs {
		if fn.Name == "working-fn" && fn.Runtime == "python" {
			found = true
		}
	}
	if !found {
		t.Fatal("expected working-fn to be discovered despite unreadable sibling group dir")
	}
}

func TestDetectFileBasedRoutes_RelativeRootCausesRelError(t *testing.T) {
	// When root is a relative path and path is absolute, filepath.Rel
	// returns an error, causing the fallback to filepath.Base(path).
	tmpDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmpDir, "get.health.js"), []byte("..."), 0644); err != nil {
		t.Fatal(err)
	}

	// Pass a relative root with an absolute path to trigger filepath.Rel error
	fns := detectFileBasedRoutes(tmpDir, "relative-root")
	if len(fns) == 0 {
		t.Fatal("expected file-based routes despite Rel error")
	}
	// The route should use filepath.Base(tmpDir) as the prefix
	baseName := filepath.Base(tmpDir)
	foundHealth := false
	for _, fn := range fns {
		if fn.OriginalRoute == "GET /"+baseName+"/health" {
			foundHealth = true
		}
	}
	if !foundHealth {
		t.Fatalf("expected route with base dir prefix, got routes: %v", fns)
	}
}
