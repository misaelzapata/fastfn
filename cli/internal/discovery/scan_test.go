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
