package discovery

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
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
	SourceRank    int    // Discovery priority for route conflict parity (higher wins)
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
	"node":   {"handler.js", "handler.ts", "index.js", "index.ts"},
	"python": {"handler.py", "main.py"},
	"php":    {"handler.php", "index.php"},
	"lua":    {"handler.lua", "main.lua", "index.lua"},
	"rust":   {"handler.rs"},
	"go":     {"handler.go", "main.go"},
}

var defaultRouteTokens = map[string]struct{}{
	"handler": {},
	"index":   {},
	"main":    {},
}

var defaultZeroConfigIgnoreDirs = []string{
	"node_modules",
	"vendor",
	"__pycache__",
	".fastfn",
	".deps",
	".rust-build",
	"target",
	"src",
}

var filepathEvalSymlinks = filepath.EvalSymlinks
var filepathAbs = filepath.Abs

// Logger is a function type for printing debug info
type Logger func(format string, v ...interface{})

func normalizeZeroConfigDir(raw string) string {
	value := strings.ToLower(strings.TrimSpace(raw))
	if value == "" || value == "." || value == ".." {
		return ""
	}
	if strings.Contains(value, "/") || strings.Contains(value, "\\") {
		return ""
	}
	return value
}

func appendZeroConfigIgnoreDirs(dst map[string]struct{}, value any) {
	add := func(raw string) {
		if normalized := normalizeZeroConfigDir(raw); normalized != "" {
			dst[normalized] = struct{}{}
		}
	}

	switch v := value.(type) {
	case string:
		for _, token := range strings.Split(v, ",") {
			add(token)
		}
	case []string:
		for _, item := range v {
			add(item)
		}
	case []interface{}:
		for _, item := range v {
			if raw, ok := item.(string); ok {
				add(raw)
			}
		}
	}
}

func loadZeroConfigIgnoreDirs(root string) map[string]struct{} {
	out := map[string]struct{}{}
	for _, item := range defaultZeroConfigIgnoreDirs {
		out[item] = struct{}{}
	}

	rawCfg, ok := readRawJSONConfig(filepath.Join(root, "fn.config.json"))
	if ok {
		discoveryRaw := rawCfg["zero_config"]
		if _, valid := discoveryRaw.(map[string]interface{}); !valid {
			discoveryRaw = rawCfg["discovery"]
		}
		if _, valid := discoveryRaw.(map[string]interface{}); !valid {
			discoveryRaw = rawCfg["routing"]
		}
		if discovery, valid := discoveryRaw.(map[string]interface{}); valid {
			appendZeroConfigIgnoreDirs(out, discovery["ignore_dirs"])
		}
		appendZeroConfigIgnoreDirs(out, rawCfg["zero_config_ignore_dirs"])
	}

	appendZeroConfigIgnoreDirs(out, os.Getenv("FN_ZERO_CONFIG_IGNORE_DIRS"))
	return out
}

// Scan finds all functions within the given root directory
func Scan(root string, logFn Logger) ([]Function, error) {
	if logFn == nil {
		logFn = func(format string, v ...interface{}) {}
	}

	logFn("Scanning for functions in: %s", root)
	if _, err := os.ReadDir(root); err != nil {
		return nil, err
	}

	var functions []Function
	seen := map[string]struct{}{}
	routeTargets := map[string]Function{}
	blockedRouteConflicts := map[string]struct{}{}
	warnedRouteConflicts := map[string]struct{}{}
	zeroConfigIgnoreDirs := loadZeroConfigIgnoreDirs(root)
	appendFunctions := func(scope string, fns []Function) {
		for _, fn := range fns {
			if strings.TrimSpace(fn.OriginalRoute) != "" && fn.SourceRank > 0 {
				conflictKey := routeConflictKey(fn)
				if _, blocked := blockedRouteConflicts[conflictKey]; blocked {
					continue
				}
				if existing, ok := routeTargets[conflictKey]; ok {
					if routeTargetKey(existing) != routeTargetKey(fn) {
						if _, warned := warnedRouteConflicts[conflictKey]; !warned {
							warnedRouteConflicts[conflictKey] = struct{}{}
							logFn(
								"WARNING: route conflict %s resolves to multiple targets at the same discovery priority: %s <> %s",
								routeKey(fn.OriginalRoute),
								describeRouteTarget(existing),
								describeRouteTarget(fn),
							)
						}
						blockedRouteConflicts[conflictKey] = struct{}{}
						delete(routeTargets, conflictKey)
						filtered := functions[:0]
						for _, existingFn := range functions {
							if routeConflictKey(existingFn) == conflictKey {
								continue
							}
							filtered = append(filtered, existingFn)
						}
						functions = filtered
						continue
					}
				} else {
					routeTargets[conflictKey] = fn
				}
			}

			key := discoveryKey(fn)
			if _, ok := seen[key]; ok {
				continue
			}
			seen[key] = struct{}{}
			switch scope {
			case "root":
				logFn("Found function at root: [%s] %s", fn.Runtime, fn.Name)
			case "zero-config":
				logFn("Found file route: [%s] %s (%s)", fn.Runtime, fn.Name, fn.OriginalRoute)
			case "runtime":
				logFn("Found runtime-scoped function: [%s] %s", fn.Runtime, fn.Name)
			}
			functions = append(functions, fn)
		}
	}

	runtimeRoots := map[string]bool{}
	for _, rt := range sortedRuntimeNames() {
		runtimeRoots[rt] = true
	}
	if fns, ok := detectFunction(root, root, logFn); ok {
		appendFunctions("root", fns)
	}

	var scanZeroConfigDir func(absDir, relDir string, depth int, inheritedMixed bool, withinRuntimeNamespace bool)
	scanZeroConfigDir = func(absDir, relDir string, depth int, inheritedMixed bool, withinRuntimeNamespace bool) {
		if depth > 6 {
			if relDir != "." && relDir != "" {
				logFn("WARNING: ignoring zero-config subtree deeper than 6 levels: %s", relDir)
			}
			return
		}

		currentSingleEntryRoot := hasSingleEntryRoot(absDir)
		if withinRuntimeNamespace && currentSingleEntryRoot {
			return
		}
		currentMixed := inheritedMixed || currentSingleEntryRoot

		manifestFns, manifestFound := detectManifestRoutes(absDir, logFn)
		appendFunctions("zero-config", manifestFns)

		fileFns := detectFileBasedRoutesInDir(absDir, root, relDir, currentMixed, logFn)
		appendFunctions("zero-config", fileFns)

		rawCfg, cfgOK := readRawJSONConfig(filepath.Join(absDir, "fn.config.json"))
		hasExplicitCfg := cfgOK && isExplicitFunctionConfig(rawCfg)
		hasDetectedRoutes := (manifestFound && len(manifestFns) > 0) || len(fileFns) > 0
		if hasExplicitCfg && currentSingleEntryRoot {
			if fns, ok := detectFunction(absDir, root, logFn); ok {
				appendFunctions("root", fns)
			}
		} else if hasExplicitCfg && !hasDetectedRoutes {
			if fns, ok := detectFunction(absDir, root, logFn); ok {
				appendFunctions("root", fns)
			}
		}

		isLeaf := (manifestFound && len(manifestFns) > 0) || (hasExplicitCfg && !currentSingleEntryRoot)
		if isLeaf && relDir != "." {
			return
		}

		entries, err := os.ReadDir(absDir)
		if err != nil {
			return
		}
		localAssetsDir := loadAssetsDirectory(absDir)
		for _, entry := range entries {
			if !entry.IsDir() {
				continue
			}
			name := entry.Name()
			if shouldSkipDir(name, zeroConfigIgnoreDirs) {
				continue
			}
			if localAssetsDir != "" && relativePathIntersectsPrefix(name, localAssetsDir) {
				continue
			}
			childAbs := filepath.Join(absDir, name)
			if depth == 0 && runtimeRoots[name] && !runtimeRootExposesRoutes(root, childAbs, name, 0) {
				continue
			}
			childRel := name
			if relDir != "." && relDir != "" {
				childRel = filepath.ToSlash(filepath.Join(relDir, name))
			}
			childRuntimeNamespace := withinRuntimeNamespace || (depth == 0 && runtimeRoots[name])
			scanZeroConfigDir(childAbs, childRel, depth+1, currentMixed, childRuntimeNamespace)
		}
	}

	scanZeroConfigDir(root, ".", 0, false, false)

	maxNsDepth := 3
	if raw := strings.TrimSpace(os.Getenv("FN_NAMESPACE_DEPTH")); raw != "" {
		if n := toIntClamped(raw, 1, 5); n > 0 {
			maxNsDepth = n
		}
	}

	var scanRuntimeMixedDir func(dir, routePrefix string, depth int)
	scanRuntimeMixedDir = func(dir, routePrefix string, depth int) {
		if depth > 6 {
			if routePrefix != "" {
				logFn("WARNING: ignoring zero-config subtree deeper than 6 levels: %s", routePrefix)
			}
			return
		}

		fileFns := detectFileBasedRoutesInDir(dir, root, routePrefix, true, logFn)
		filtered := make([]Function, 0, len(fileFns))
		for _, fn := range fileFns {
			baseNoExt := strings.TrimSuffix(filepath.Base(fn.EntryFile), filepath.Ext(fn.EntryFile))
			_, _, methodExplicit, _ := parseMethodAndRouteTokens(baseNoExt)
			skipRootDefault := depth == 0 && !methodExplicit && isDefaultRouteToken(baseNoExt)
			if skipRootDefault && !methodExplicit && isDefaultRouteToken(baseNoExt) {
				continue
			}
			filtered = append(filtered, fn)
		}
		appendFunctions("zero-config", filtered)

		entries, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		localAssetsDir := loadAssetsDirectory(dir)
		for _, entry := range entries {
			if !entry.IsDir() {
				continue
			}
			name := entry.Name()
			if shouldSkipDir(name, zeroConfigIgnoreDirs) {
				continue
			}
			if localAssetsDir != "" && relativePathIntersectsPrefix(name, localAssetsDir) {
				continue
			}
			childAbs := filepath.Join(dir, name)
			childRoutePrefix := filepath.ToSlash(filepath.Join(routePrefix, name))
			scanRuntimeMixedDir(childAbs, childRoutePrefix, depth+1)
		}
	}

	var hasVersionedRuntimeChildren func(string) bool
	hasVersionedRuntimeChildren = func(dir string) bool {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return false
		}
		seenVersion := false
		for _, entry := range entries {
			if !entry.IsDir() {
				continue
			}
			name := entry.Name()
			if hasSingleEntryRoot(filepath.Join(dir, name)) {
				if looksLikeVersionLabel(name) {
					seenVersion = true
					continue
				}
				return false
			}
		}
		return seenVersion
	}

	var discoverRuntimeDir func(runtime, dir, prefix string, depth int)
	discoverRuntimeDir = func(runtime, dir, prefix string, depth int) {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, entry := range entries {
			if !entry.IsDir() {
				continue
			}
			name := entry.Name()
			if !validNamespaceSegment(name) {
				logFn("WARNING: ignoring runtime namespace segment with unsupported characters: %s", filepath.ToSlash(filepath.Join(prefix, name)))
				continue
			}
			childAbs := filepath.Join(dir, name)
			fnName := name
			if prefix != "" {
				fnName = filepath.ToSlash(filepath.Join(prefix, name))
			}
			if routePathReserved("/" + filepath.ToSlash(fnName)) {
				logFn("WARNING: ignoring runtime-scoped function that resolves to reserved path: /%s", filepath.ToSlash(fnName))
				continue
			}

			if hasSingleEntryRoot(childAbs) || hasVersionedRuntimeChildren(childAbs) {
				hasConfig := false
				if rawCfg, ok := readRawJSONConfig(filepath.Join(childAbs, "fn.config.json")); ok && len(rawCfg) > 0 {
					hasConfig = true
				}
				appendFunctions("runtime", []Function{{
					Name:      fnName,
					Runtime:   runtime,
					Path:      childAbs,
					HasConfig: hasConfig,
				}})
				if hasSingleEntryRoot(childAbs) {
					scanRuntimeMixedDir(childAbs, fnName, 0)
				}
				continue
			}

			if depth < maxNsDepth {
				discoverRuntimeDir(runtime, childAbs, fnName, depth+1)
			}
		}
	}

	for _, runtime := range sortedRuntimeNames() {
		runtimeDir := filepath.Join(root, runtime)
		info, err := os.Stat(runtimeDir)
		if err != nil || !info.IsDir() {
			continue
		}
		discoverRuntimeDir(runtime, runtimeDir, "", 1)
	}

	return functions, nil
}

func isLeafFunctionDir(path string) bool {
	manifestPath := filepath.Join(path, "fn.routes.json")
	if raw, err := os.ReadFile(manifestPath); err == nil {
		var manifest RoutesManifest
		if json.Unmarshal(raw, &manifest) == nil && len(manifest.Routes) > 0 {
			return true
		}
	}

	configPath := filepath.Join(path, "fn.config.json")
	rawCfg, ok := readRawJSONConfig(configPath)
	if ok && isExplicitFunctionConfig(rawCfg) {
		return true
	}

	return false
}

// detectFunction checks if a directory contains a valid function
func detectFunction(path string, root string, logFn Logger) ([]Function, bool) {
	// 1. Check for fn.config.json (Highest Priority)
	configPath := filepath.Join(path, "fn.config.json")
	hasOverlayConfig := false
	if _, err := os.Stat(configPath); err == nil {
		rawCfg, ok := readRawJSONConfig(configPath)
		if !ok || len(rawCfg) == 0 {
			logFn("  -> ignoring empty/invalid fn.config.json in: %s", filepath.Base(path))
		} else {
			if isExplicitFunctionConfig(rawCfg) {
				rt, name := parseConfig(configPath)
				// Fallback for missing fields in config
				if rt == "" {
					logMultipleEntryFileWarning(path, root, detectRuntimeMatches(path), logFn)
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
			// Non-empty config without identity fields is treated as an overlay for file-based routes.
			hasOverlayConfig = true
		}
	}

	// 2. Check for fn.routes.json and merge safely with file-based discovery.
	manifestFns, hasManifest := detectManifestRoutes(path, logFn)
	fileBasedFns := detectFileBasedRoutes(path, root, logFn)
	if hasManifest {
		merged := mergeRouteFunctions(manifestFns, fileBasedFns)
		if len(merged) > 0 {
			if hasOverlayConfig {
				for i := range merged {
					merged[i].HasConfig = true
				}
			}
			logFn("  -> merged manifest + file routes: %s (%d routes)", filepath.Base(path), len(merged))
			return merged, true
		}
	}

	// 3. Zero-Config Detection
	if len(fileBasedFns) > 0 {
		if hasOverlayConfig {
			for i := range fileBasedFns {
				fileBasedFns[i].HasConfig = true
			}
		}
		logFn("  -> detected via file routes: %s (%d routes)", filepath.Base(path), len(fileBasedFns))
		return fileBasedFns, true
	}

	// 4. Single-entry fallback
	// Check for standard "main" files first (existing behavior)
	logMultipleEntryFileWarning(path, root, detectRuntimeMatches(path), logFn)
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
	if logFn == nil {
		logFn = func(format string, v ...interface{}) {}
	}
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
			SourceRank:    2,
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

func discoveryKey(fn Function) string {
	if strings.TrimSpace(fn.OriginalRoute) != "" {
		return "route|" + fn.Runtime + "|" + routeKey(fn.OriginalRoute) + "|" + fn.Path + "|" + fn.EntryFile
	}
	return "fn|" + fn.Runtime + "|" + fn.Name + "|" + fn.Path + "|" + fn.EntryFile
}

func routeConflictKey(fn Function) string {
	return routeKey(fn.OriginalRoute) + "|rank|" + strconv.Itoa(fn.SourceRank)
}

func routeTargetKey(fn Function) string {
	return fn.Runtime + "|" + fn.Path + "|" + fn.EntryFile + "|" + fn.Name
}

func describeRouteTarget(fn Function) string {
	target := fn.Path
	if fn.EntryFile != "" {
		target = filepath.ToSlash(filepath.Join(fn.Path, fn.EntryFile))
	}
	return fn.Runtime + ":" + target
}

type runtimeMatch struct {
	runtime string
	file    string
}

func sortedRuntimeNames() []string {
	out := make([]string, 0, len(runtimeFiles))
	for rt := range runtimeFiles {
		out = append(out, rt)
	}
	sort.Strings(out)
	return out
}

func detectRuntimeMatches(dir string) []runtimeMatch {
	matches := []runtimeMatch{}
	for _, rt := range sortedRuntimeNames() {
		for _, file := range runtimeFiles[rt] {
			if _, err := os.Stat(filepath.Join(dir, file)); err == nil {
				matches = append(matches, runtimeMatch{
					runtime: rt,
					file:    file,
				})
			}
		}
	}
	return matches
}

func logMultipleEntryFileWarning(path string, root string, matches []runtimeMatch, logFn Logger) {
	if logFn == nil || len(matches) < 2 {
		return
	}
	relPath := filepath.Base(path)
	if rel, err := filepath.Rel(root, path); err == nil && rel != "" {
		relPath = filepath.ToSlash(rel)
	}
	selected := matches[0].runtime + ":" + matches[0].file
	ignored := make([]string, 0, len(matches)-1)
	for _, match := range matches[1:] {
		ignored = append(ignored, match.runtime+":"+match.file)
	}
	logFn(
		"WARNING: multiple compatible entry files in %s; selected %s and ignored %s",
		relPath,
		selected,
		strings.Join(ignored, ", "),
	)
}

func toIntClamped(raw string, min, max int) int {
	n := 0
	for _, r := range strings.TrimSpace(raw) {
		if r < '0' || r > '9' {
			return 0
		}
		n = (n * 10) + int(r-'0')
	}
	if n < min {
		return min
	}
	if n > max {
		return max
	}
	return n
}

func shouldSkipDir(name string, ignoreDirs map[string]struct{}) bool {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" || strings.HasPrefix(trimmed, ".") {
		return true
	}
	_, ok := ignoreDirs[strings.ToLower(trimmed)]
	return ok
}

func validNamespaceSegment(name string) bool {
	matched, _ := regexp.MatchString(`^[a-zA-Z0-9_-]+$`, name)
	return matched
}

func hasValidConfigEntrypoint(dir string) bool {
	_, ok := resolveConfigEntrypointPath(dir)
	return ok
}

func resolveConfigEntrypointPath(dir string) (string, bool) {
	rawCfg, ok := readRawJSONConfig(filepath.Join(dir, "fn.config.json"))
	if !ok {
		return "", false
	}
	entry, ok := rawCfg["entrypoint"].(string)
	if !ok || strings.TrimSpace(entry) == "" {
		return "", false
	}
	if filepath.IsAbs(entry) {
		return "", false
	}
	clean := filepath.Clean(entry)
	if clean == "." || strings.HasPrefix(clean, "..") {
		return "", false
	}
	rootResolved, err := filepathEvalSymlinks(dir)
	if err != nil {
		rootResolved, err = filepathAbs(dir)
		if err != nil {
			return "", false
		}
	}
	resolvedPath, err := filepathEvalSymlinks(filepath.Join(dir, clean))
	if err != nil {
		return "", false
	}
	rel, err := filepath.Rel(rootResolved, resolvedPath)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", false
	}
	info, err := os.Stat(resolvedPath)
	if err != nil || info.IsDir() {
		return "", false
	}
	return resolvedPath, true
}

func hasSingleEntryRoot(dir string) bool {
	return detectRuntimeFromFiles(dir) != "" || hasValidConfigEntrypoint(dir)
}

func isDefaultRouteToken(token string) bool {
	_, ok := defaultRouteTokens[strings.ToLower(strings.TrimSpace(token))]
	return ok
}

func isDynamicRouteToken(token string) bool {
	optionalCatchAll := regexp.MustCompile(`^\[\[\.\.\.([a-zA-Z0-9_]+)\]\]$`)
	catchAll := regexp.MustCompile(`^\[\.\.\.([a-zA-Z0-9_]+)\]$`)
	dynamic := regexp.MustCompile(`^\[([a-zA-Z0-9_]+)\]$`)
	return optionalCatchAll.MatchString(token) || catchAll.MatchString(token) || dynamic.MatchString(token)
}

func isExplicitFileRoute(base string) bool {
	_, parts, explicit, ambiguous := parseMethodAndRouteTokens(base)
	if ambiguous {
		return false
	}
	if explicit {
		return true
	}
	for _, part := range parts {
		if isDefaultRouteToken(part) || isDynamicRouteToken(part) {
			return true
		}
	}
	return false
}

func shouldTreatFileAsRoute(base string, mixedMode bool) bool {
	if !mixedMode {
		return true
	}
	return isExplicitFileRoute(base)
}

func looksLikeVersionLabel(name string) bool {
	version := regexp.MustCompile(`^(?:v\d[\w_.-]*|\d[\w_.-]*)$`)
	return version.MatchString(name)
}

func runtimeRootExposesRoutes(root, absDir, relDir string, depth int) bool {
	if depth > 6 {
		return false
	}
	if depth > 0 && hasSingleEntryRoot(absDir) {
		return false
	}
	zeroConfigIgnoreDirs := loadZeroConfigIgnoreDirs(root)

	manifestFns, manifestFound := detectManifestRoutes(absDir, nil)
	if manifestFound && len(manifestFns) > 0 {
		return true
	}
	if len(detectFileBasedRoutesInDir(absDir, root, relDir, false, nil)) > 0 {
		return true
	}

	entries, err := os.ReadDir(absDir)
	if err != nil {
		return false
	}
	localAssetsDir := loadAssetsDirectory(absDir)
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		name := entry.Name()
		if shouldSkipDir(name, zeroConfigIgnoreDirs) {
			continue
		}
		if localAssetsDir != "" && relativePathIntersectsPrefix(name, localAssetsDir) {
			continue
		}
		childAbs := filepath.Join(absDir, name)
		childRel := filepath.ToSlash(filepath.Join(relDir, name))
		if runtimeRootExposesRoutes(root, childAbs, childRel, depth+1) {
			return true
		}
	}
	return false
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

func detectFileBasedRoutes(path string, root string, logFn Logger) []Function {
	return detectFileBasedRoutesInDir(path, root, "", false, logFn)
}

func detectFileBasedRoutesInDir(path string, root string, relOverride string, mixedMode bool, logFn Logger) []Function {
	files, err := os.ReadDir(path)
	if err != nil {
		return nil
	}

	relPath := relOverride
	if relPath == "" {
		relPath, err = filepath.Rel(root, path)
		if err != nil {
			relPath = filepath.Base(path)
		}
	}
	relPath = filepath.ToSlash(relPath)

	rawCfg, cfgOK := readRawJSONConfig(filepath.Join(path, "fn.config.json"))
	hasExplicitCfg := cfgOK && isExplicitFunctionConfig(rawCfg)
	hasAnyConfig := cfgOK && len(rawCfg) > 0
	singleEntryRoot := hasSingleEntryRoot(path)
	if hasExplicitCfg && !singleEntryRoot && !mixedMode {
		return nil
	}

	var out []fileRoute
	for _, entry := range files {
		if entry.IsDir() {
			continue
		}

		filename := entry.Name()
		baseNoExt := strings.TrimSuffix(filename, filepath.Ext(filename))
		if shouldIgnoreFile(baseNoExt) || !shouldTreatFileAsRoute(baseNoExt, mixedMode) {
			continue
		}

		runtime := detectRuntimeFromFile(filename)
		if runtime == "" {
			continue
		}

		method, routeTokens, methodExplicit, ambiguousMethodTokens := parseMethodAndRouteTokens(baseNoExt)
		if ambiguousMethodTokens {
			if logFn != nil {
				displayName := filename
				if relPath != "." && relPath != "" {
					displayName = filepath.ToSlash(filepath.Join(relPath, filename))
				}
				logFn("WARNING: ignoring ambiguous multi-method filename: %s", displayName)
			}
			continue
		}
		if hasExplicitCfg && singleEntryRoot && !methodExplicit && isDefaultRouteToken(baseNoExt) {
			continue
		}
		routePath, isDefault := buildRoutePath(relPath, routeTokens)
		if routePathReserved(routePath) {
			if logFn != nil {
				displayName := filename
				if relPath != "." && relPath != "" {
					displayName = filepath.ToSlash(filepath.Join(relPath, filename))
				}
				logFn("WARNING: ignoring file route that resolves to reserved path %s from %s", routePath, displayName)
			}
			continue
		}
		if routePath != "" && routePath != "/" {
			out = append(out, fileRoute{
				method:       method,
				path:         routePath,
				runtime:      runtime,
				entryFile:    filename,
				defaultEntry: isDefault,
			})
		}

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
			HasConfig:     hasAnyConfig,
			OriginalRoute: routeDef,
			SourceRank:    1,
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

func isHTTPMethodToken(token string) bool {
	_, ok := httpMethodPrefix[strings.ToLower(strings.TrimSpace(token))]
	return ok
}

func parseMethodAndRouteTokens(base string) (string, []string, bool, bool) {
	method := "GET"
	explicit := false
	ambiguous := false
	parts := splitFileTokens(base)
	if len(parts) > 0 {
		if m, ok := httpMethodPrefix[strings.ToLower(parts[0])]; ok {
			method = m
			explicit = true
			parts = parts[1:]
		}
	}
	if explicit {
		for _, part := range parts {
			if isHTTPMethodToken(part) {
				ambiguous = true
				break
			}
		}
	}
	return method, parts, explicit, ambiguous
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

func routePathReserved(path string) bool {
	normalized := strings.TrimSpace(filepath.ToSlash(path))
	if normalized == "" {
		return false
	}
	matchesPrefix := func(prefix string) bool {
		return normalized == prefix || strings.HasPrefix(normalized, prefix+"/")
	}
	return matchesPrefix("/_fn") || matchesPrefix("/console")
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
	if lower == "" || lower == "index" || lower == "handler" || lower == "main" {
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

func readRawJSONConfig(path string) (map[string]interface{}, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, false
	}
	var raw map[string]interface{}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, false
	}
	return raw, true
}

func isExplicitFunctionConfig(raw map[string]interface{}) bool {
	if len(raw) == 0 {
		return false
	}

	if v, ok := raw["runtime"].(string); ok && strings.TrimSpace(v) != "" {
		return true
	}
	if v, ok := raw["name"].(string); ok && strings.TrimSpace(v) != "" {
		return true
	}
	if v, ok := raw["entrypoint"].(string); ok && strings.TrimSpace(v) != "" {
		return true
	}

	invoke, ok := raw["invoke"].(map[string]interface{})
	if !ok {
		return false
	}
	routes, ok := invoke["routes"].([]interface{})
	return ok && len(routes) > 0
}

func isSafeRootRelativePath(path string) bool {
	path = strings.TrimSpace(path)
	if path == "" || strings.HasPrefix(path, "/") || strings.Contains(path, "\\") {
		return false
	}
	for _, segment := range strings.Split(path, "/") {
		if segment == "" || segment == "." || segment == ".." {
			return false
		}
	}
	return true
}

func relativePathHasPrefix(path, prefix string) bool {
	path = strings.Trim(strings.TrimSpace(filepath.ToSlash(path)), "/")
	prefix = strings.Trim(strings.TrimSpace(filepath.ToSlash(prefix)), "/")
	if path == "" || prefix == "" {
		return false
	}
	return path == prefix || strings.HasPrefix(path, prefix+"/")
}

func relativePathIntersectsPrefix(path, prefix string) bool {
	return relativePathHasPrefix(path, prefix) || relativePathHasPrefix(prefix, path)
}

func loadAssetsDirectory(dir string) string {
	rawCfg, ok := readRawJSONConfig(filepath.Join(dir, "fn.config.json"))
	if !ok {
		return ""
	}
	assets, ok := rawCfg["assets"].(map[string]interface{})
	if !ok {
		return ""
	}
	directory, ok := assets["directory"].(string)
	if !ok || !isSafeRootRelativePath(directory) {
		return ""
	}
	return strings.Trim(strings.TrimSpace(filepath.ToSlash(directory)), "/")
}

func loadRootAssetsDirectory(root string) string {
	return loadAssetsDirectory(root)
}

func detectRuntimeFromFiles(dir string) string {
	matches := detectRuntimeMatches(dir)
	if len(matches) == 0 {
		return ""
	}
	return matches[0].runtime
}
