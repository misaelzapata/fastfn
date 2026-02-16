package discovery

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Function represents a discoverable function in the project
type Function struct {
	Name          string
	Runtime       string
	Path          string // Absolute path to the function directory
	EntryFile     string // Optional: specific entry file (relative to Path) if detecting multi-file routes
	HasConfig     bool   // True if fn.config.json exists
	OriginalRoute string // The raw route from manifest (e.g. "GET /items") if applicable
}

type FnConfig struct {
	Runtime string `json:"runtime"`
	Name    string `json:"name"`
}

type RoutesManifest struct {
	Routes map[string]string `json:"routes"`
}

// Runtime definitions for auto-detection
var runtimeFiles = map[string][]string{
	"node":   {"handler.js", "app.js", "handler.ts", "app.ts", "index.js", "index.ts"},
	"python": {"handler.py", "app.py", "main.py"},
	"php":    {"handler.php", "app.php", "index.php"},
	"lua":    {"handler.lua", "app.lua", "main.lua", "index.lua"},
	"rust":   {"handler.rs", "app.rs", "src/lib.rs"},
	"go":     {"handler.go", "main.go"},
}

// Logger is a function type for printing debug info
type Logger func(format string, v ...interface{})

// Scan finds all functions within the given root directory
func Scan(root string, logFn Logger) ([]Function, error) {
	if logFn == nil {
		logFn = func(format string, v ...interface{}) {}
	}

	logFn("Scanning for functions in: %s", root)
	var functions []Function
	seen := map[string]struct{}{}

	appendUnique := func(scope string, fns []Function) {
		for _, fn := range fns {
			key := fn.Runtime + "|" + fn.Path + "|" + fn.EntryFile + "|" + fn.OriginalRoute + "|" + fn.Name
			if _, exists := seen[key]; exists {
				continue
			}
			seen[key] = struct{}{}
			switch scope {
			case "root":
				logFn("Found function at root: [%s] %s", fn.Runtime, fn.Name)
			case "L1":
				logFn("Found function (L1): [%s] %s", fn.Runtime, fn.Name)
			case "L2":
				logFn("Found function (L2): [%s] %s", fn.Runtime, fn.Name)
			default:
				logFn("Found function: [%s] %s", fn.Runtime, fn.Name)
			}
			functions = append(functions, fn)
		}
	}

	// 1. Check if the root itself is a function
	if fns, ok := detectFunction(root, root, logFn); ok {
		appendUnique("root", fns)
	}

	// 2. Walk the directory tree
	// We only go 2 levels deep for now (standard monorepo structure)
	// root/func1
	// root/group/func2
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		path := filepath.Join(root, entry.Name())

		// Level 1 check
		if fns, ok := detectFunction(path, root, logFn); ok {
			appendUnique("L1", fns)
			continue
		}

		// Level 2 check
		subEntries, err := os.ReadDir(path)
		if err != nil {
			continue
		}
		for _, sub := range subEntries {
			if !sub.IsDir() {
				continue
			}
			subPath := filepath.Join(path, sub.Name())
			if fns, ok := detectFunction(subPath, root, logFn); ok {
				appendUnique("L2", fns)
			}
		}
	}

	return functions, nil
}

// detectFunction checks if a directory contains a valid function
func detectFunction(path string, root string, logFn Logger) ([]Function, bool) {
	// 1. Check for fn.config.json (Highest Priority)
	configPath := filepath.Join(path, "fn.config.json")
	if _, err := os.Stat(configPath); err == nil {
		if !isNonEmptyJSONConfig(configPath) {
			logFn("  -> ignoring empty/invalid fn.config.json in: %s", filepath.Base(path))
		} else {
			rt, name := parseConfig(configPath)
			// Fallback for missing fields in config
			if rt == "" {
				rt = detectRuntimeFromFiles(path)
			}
			if name == "" {
				name = filepath.Base(path)
			}
			// If runtime is still unknown, default to node? Or fail?
			// Existing logic defaulted to node.
			if rt == "" {
				rt = "node"
			}
			logFn("  -> detected via config: %s (runtime: %s)", name, rt)
			return []Function{{
				Name:      name,
				Runtime:   rt,
				Path:      path,
				HasConfig: true,
			}}, true
		}
	}

	// 2. Check for fn.routes.json and merge safely with file-based discovery.
	manifestFns, hasManifest := detectManifestRoutes(path, logFn)
	fileBasedFns := detectFileBasedRoutes(path, root)
	if hasManifest {
		merged := mergeRouteFunctions(manifestFns, fileBasedFns)
		if len(merged) > 0 {
			logFn("  -> merged manifest + file routes: %s (%d routes)", filepath.Base(path), len(merged))
			return merged, true
		}
	}

	// 3. Zero-Config Detection
	if len(fileBasedFns) > 0 {
		logFn("  -> detected via file routes: %s (%d routes)", filepath.Base(path), len(fileBasedFns))
		return fileBasedFns, true
	}

	// 4. Legacy single-entry fallback
	// Check for standard "main" files first (existing behavior)
	rt := detectRuntimeFromFiles(path)
	if rt != "" {
		logFn("  -> detected via files: %s (runtime: %s)", filepath.Base(path), rt)
		return []Function{{
			Name:      filepath.Base(path),
			Runtime:   rt,
			Path:      path,
			HasConfig: false,
		}}, true
	}

	return nil, false
}

func detectManifestRoutes(path string, logFn Logger) ([]Function, bool) {
	routesPath := filepath.Join(path, "fn.routes.json")
	data, err := os.ReadFile(routesPath)
	if err != nil {
		return nil, false
	}
	var manifest RoutesManifest
	if err := json.Unmarshal(data, &manifest); err != nil || len(manifest.Routes) == 0 {
		return nil, true
	}

	var fns []Function
	logFn("  -> detected manifest: %s (%d routes)", filepath.Base(path), len(manifest.Routes))
	for route, file := range manifest.Routes {
		rt := detectRuntimeFromFile(file)
		if rt == "" {
			rt = "node"
		}
		safeName := sanitizeName(route)
		fns = append(fns, Function{
			Name:          safeName,
			OriginalRoute: route,
			Runtime:       rt,
			Path:          path,
			EntryFile:     file,
			HasConfig:     true,
		})
	}
	return fns, true
}

func routeKey(route string) string {
	parts := strings.SplitN(strings.TrimSpace(route), " ", 2)
	if len(parts) == 2 {
		m := strings.ToUpper(strings.TrimSpace(parts[0]))
		if m == "GET" || m == "POST" || m == "PUT" || m == "PATCH" || m == "DELETE" {
			return m + " " + strings.TrimSpace(parts[1])
		}
	}
	return "GET " + strings.TrimSpace(route)
}

func mergeRouteFunctions(primary []Function, fallback []Function) []Function {
	seen := map[string]struct{}{}
	out := make([]Function, 0, len(primary)+len(fallback))

	for _, fn := range primary {
		key := routeKey(fn.OriginalRoute)
		seen[key] = struct{}{}
		out = append(out, fn)
	}
	for _, fn := range fallback {
		key := routeKey(fn.OriginalRoute)
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}
		out = append(out, fn)
	}
	return out
}

type fileRoute struct {
	method       string
	path         string
	runtime      string
	entryFile    string
	defaultEntry bool
}

var httpMethodPrefix = map[string]string{
	"get":    "GET",
	"post":   "POST",
	"put":    "PUT",
	"patch":  "PATCH",
	"delete": "DELETE",
}

func detectFileBasedRoutes(path string, root string) []Function {
	files, err := os.ReadDir(path)
	if err != nil {
		return nil
	}

	relPath, err := filepath.Rel(root, path)
	if err != nil {
		relPath = filepath.Base(path)
	}
	relPath = filepath.ToSlash(relPath)

	var out []fileRoute
	for _, entry := range files {
		if entry.IsDir() {
			continue
		}

		filename := entry.Name()
		baseNoExt := strings.TrimSuffix(filename, filepath.Ext(filename))
		if shouldIgnoreFile(baseNoExt) {
			continue
		}

		runtime := detectRuntimeFromFile(filename)
		if runtime == "" {
			continue
		}

		method, routeTokens := parseMethodAndRouteTokens(baseNoExt)
		routePath, isDefault := buildRoutePath(relPath, routeTokens)
		if routePath != "" && routePath != "/" {
			out = append(out, fileRoute{
				method:       method,
				path:         routePath,
				runtime:      runtime,
				entryFile:    filename,
				defaultEntry: isDefault,
			})
		}

		// Next.js optional catch-all: [[...opt]] maps both "/base" and "/base/:opt*".
		if len(routeTokens) > 0 && isOptionalCatchAllToken(routeTokens[len(routeTokens)-1]) {
			baseTokens := routeTokens[:len(routeTokens)-1]
			basePath, baseDefault := buildRoutePath(relPath, baseTokens)
			if basePath != "" && basePath != "/" {
				out = append(out, fileRoute{
					method:       method,
					path:         basePath,
					runtime:      runtime,
					entryFile:    filename,
					defaultEntry: baseDefault,
				})
			}
		}
	}

	if len(out) == 0 {
		return nil
	}

	sort.Slice(out, func(i, j int) bool {
		if out[i].path == out[j].path {
			return out[i].entryFile < out[j].entryFile
		}
		return out[i].path < out[j].path
	})

	var fns []Function
	for _, r := range out {
		routeDef := r.method + " " + r.path
		name := sanitizeName(routeDef)
		if r.defaultEntry {
			name = filepath.Base(path)
		}
		fns = append(fns, Function{
			Name:          name,
			Runtime:       r.runtime,
			Path:          path,
			EntryFile:     r.entryFile,
			HasConfig:     false,
			OriginalRoute: routeDef,
		})
	}

	return fns
}

func shouldIgnoreFile(base string) bool {
	lower := strings.ToLower(base)
	if strings.HasSuffix(lower, ".test") || strings.HasSuffix(lower, ".spec") {
		return true
	}
	return strings.HasPrefix(lower, "_")
}

func parseMethodAndRouteTokens(base string) (string, []string) {
	method := "GET"
	parts := splitFileTokens(base)
	if len(parts) > 1 {
		if m, ok := httpMethodPrefix[strings.ToLower(parts[0])]; ok {
			method = m
			parts = parts[1:]
		}
	}
	return method, parts
}

func splitFileTokens(base string) []string {
	var out []string
	var cur strings.Builder
	bracketDepth := 0

	for _, r := range base {
		switch r {
		case '[':
			bracketDepth++
			cur.WriteRune(r)
		case ']':
			if bracketDepth > 0 {
				bracketDepth--
			}
			cur.WriteRune(r)
		case '.':
			if bracketDepth == 0 {
				token := strings.TrimSpace(cur.String())
				if token != "" {
					out = append(out, token)
				}
				cur.Reset()
			} else {
				cur.WriteRune(r)
			}
		default:
			cur.WriteRune(r)
		}
	}

	last := strings.TrimSpace(cur.String())
	if last != "" {
		out = append(out, last)
	}

	if len(out) == 0 {
		return []string{base}
	}
	return out
}

func buildRoutePath(relPath string, fileTokens []string) (string, bool) {
	var segments []string
	if relPath != "." && relPath != "" {
		segments = append(segments, splitAndSanitize(relPath)...)
	}

	isDefault := true
	for _, token := range fileTokens {
		s := normalizeRouteToken(token)
		if s == "" {
			continue
		}
		isDefault = false
		segments = append(segments, s)
	}

	if len(segments) == 0 {
		return "/", isDefault
	}
	return "/" + strings.Join(segments, "/"), isDefault
}

func splitAndSanitize(path string) []string {
	raw := strings.Split(filepath.ToSlash(path), "/")
	out := make([]string, 0, len(raw))
	for _, segment := range raw {
		s := normalizeRouteToken(segment)
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}

func normalizeRouteToken(s string) string {
	lower := strings.ToLower(strings.TrimSpace(s))
	if lower == "" || lower == "index" || lower == "handler" || lower == "app" || lower == "main" {
		return ""
	}

	optionalCatchAll := regexp.MustCompile(`^\[\[\.\.\.([a-zA-Z0-9_]+)\]\]$`)
	if m := optionalCatchAll.FindStringSubmatch(s); len(m) == 2 {
		return ":" + strings.ToLower(m[1]) + "*"
	}

	catchAll := regexp.MustCompile(`^\[\.\.\.([a-zA-Z0-9_]+)\]$`)
	if m := catchAll.FindStringSubmatch(s); len(m) == 2 {
		return ":" + strings.ToLower(m[1]) + "*"
	}

	dynamic := regexp.MustCompile(`^\[([a-zA-Z0-9_]+)\]$`)
	if m := dynamic.FindStringSubmatch(s); len(m) == 2 {
		return ":" + strings.ToLower(m[1])
	}

	reg := regexp.MustCompile(`[^a-z0-9_-]+`)
	clean := reg.ReplaceAllString(lower, "-")
	clean = strings.Trim(clean, "-")
	return clean
}

func isOptionalCatchAllToken(s string) bool {
	optionalCatchAll := regexp.MustCompile(`^\[\[\.\.\.([a-zA-Z0-9_]+)\]\]$`)
	return optionalCatchAll.MatchString(s)
}

func sanitizeName(s string) string {
	// Lowercase
	s = strings.ToLower(s)
	// Replace non-alphanumeric with underscore
	reg := regexp.MustCompile(`[^a-z0-9]+`)
	s = reg.ReplaceAllString(s, "_")
	// Trim underscores
	s = strings.Trim(s, "_")
	return s
}

func detectRuntimeFromFile(file string) string {
	lower := strings.ToLower(file)
	if strings.HasSuffix(lower, ".d.ts") {
		return ""
	}
	ext := filepath.Ext(file)
	switch ext {
	case ".js", ".ts":
		return "node"
	case ".py":
		return "python"
	case ".php":
		return "php"
	case ".lua":
		return "lua"
	case ".rs":
		return "rust"
	case ".go":
		return "go"
	}
	// Fallback/Unknown
	return ""
}

// NOTE: Future "Next.js Style" multi-file detection would go here or in a separate pass.
// For now, we stick to the 1-folder = 1-function model for stability.

func parseConfig(path string) (string, string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", ""
	}
	var cfg FnConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return "", ""
	}
	return cfg.Runtime, cfg.Name
}

func isNonEmptyJSONConfig(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var raw map[string]interface{}
	if err := json.Unmarshal(data, &raw); err != nil {
		return false
	}
	return len(raw) > 0
}

func detectRuntimeFromFiles(dir string) string {
	for rt, files := range runtimeFiles {
		for _, f := range files {
			if _, err := os.Stat(filepath.Join(dir, f)); err == nil {
				return rt
			}
		}
	}
	return ""
}
