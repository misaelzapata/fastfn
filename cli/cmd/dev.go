package cmd

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/misaelzapata/fastfn/cli/embed/templates"
	"github.com/misaelzapata/fastfn/cli/internal/discovery"
	"github.com/misaelzapata/fastfn/cli/internal/process"
	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"
)

var dryRun bool
var devForceURL bool
var devBuild bool
var devNativeMode bool
var devLookPath = exec.LookPath
var devCommandRunner = exec.Command
var devFatal = log.Fatal
var devFatalf = log.Fatalf
var checkSystemRequirementsFn = checkSystemRequirements
var devStartHotReloadWatcher = process.StartHotReloadWatcher
var devExecCommand = exec.Command
var devAbsFn = filepath.Abs
var devYAMLMarshalFn = yaml.Marshal
var discoveryScanFn = discovery.Scan
var devMkdirTempFn = os.MkdirTemp
var devGenerateDockerComposeFn = templates.GenerateDockerCompose

func resolveDevTargetDir(args []string) string {
	if len(args) > 0 {
		return args[0]
	}
	if path := configuredFunctionsDir(); path != "" {
		return path
	}
	return "."
}

func checkSystemRequirements() {
	// 1. Check for docker binary
	dockerBin := strings.TrimSpace(os.Getenv("FN_DOCKER_BIN"))
	if dockerBin == "" {
		dockerBin = "docker"
	}
	if _, err := devLookPath(dockerBin); err != nil {
		devFatal("Error: Docker is not installed or not in your PATH.\nPlease install Docker: https://docs.docker.com/get-docker/")
		return
	}

	// 2. Check if Docker Daemon is running
	cmd := devCommandRunner(dockerBin, "info")
	if err := cmd.Run(); err != nil {
		devFatal("Error: Docker Daemon is not running.\nPlease start Docker Desktop or the docker daemon.")
		return
	}
}

// findProjectRoot looks for docker-compose.yml starting from startPath and moving up
func findProjectRoot(startPath string) (string, error) {
	current := startPath
	for {
		if _, err := os.Stat(filepath.Join(current, "docker-compose.yml")); err == nil {
			return current, nil
		}

		parent := filepath.Dir(current)
		if parent == current {
			return "", fmt.Errorf("could not find docker-compose.yml in any parent directory")
		}
		current = parent
	}
}

var devCmd = &cobra.Command{
	Use:   "dev [dir]",
	Short: "Start development environment with hot-reload",
	Args:  cobra.MaximumNArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		applyConfiguredOpenAPIIncludeInternal(func(includeInternal bool) {
			fmt.Printf("Using openapi-include-internal from config: %t\n", includeInternal)
		})
		applyConfiguredForceURL(func(forceURL bool) {
			fmt.Printf("Using force-url from config: %t\n", forceURL)
		})
		applyConfiguredRuntimeDaemons(func(value string) {
			fmt.Printf("Using runtime-daemons from config: %s\n", value)
		})
		applyConfiguredRuntimeBinaries(func(envVar, value string) {
			fmt.Printf("Using runtime binary from config: %s=%s\n", envVar, value)
		})
		imageWorkloads, hasImageWorkloads, err := configuredImageWorkloads()
		if err != nil {
			devFatalf("Invalid apps/services config: %v", err)
			return
		}
		if devForceURL {
			_ = os.Setenv("FN_FORCE_URL", "1")
			fmt.Println("force-url enabled (will allow config/policy routes to override existing URLs)")
		}

		// Resolve absolute path.
		targetDir := resolveDevTargetDir(args)
		absPath, err := devAbsFn(targetDir)
		if err != nil {
			devFatalf("Failed to resolve absolute path: %v", err)
			return
		}
		if _, err := os.Stat(absPath); err != nil {
			devFatalf("Invalid functions directory: %s", absPath)
			return
		}

		if devNativeMode {
			if dryRun || devBuild {
				devFatal("--dry-run/--build are only supported in Docker mode (omit --native)")
				return
			}
			if os.Getenv("FN_PUBLIC_BASE_URL") == "" {
				if baseURL := configuredPublicBaseURL(); baseURL != "" {
					_ = os.Setenv("FN_PUBLIC_BASE_URL", baseURL)
					fmt.Printf("Using public base URL from config: %s\n", baseURL)
				}
			}
			fmt.Println("Running in NATIVE mode (embedded runtime stack)...")
			if err := runNative(configuredProjectRoot(), absPath, imageWorkloads); err != nil {
				devFatalf("Native dev failed: %v", err)
				return
			}
			return
		}
		if hasImageWorkloads {
			devFatal("apps/services are only supported in native mode for this branch; rerun with --native")
			return
		}

		// Docker mode: ensure Docker is available and the daemon is running.
		// Resolve volume mounts.
		mounts := scanForMounts(absPath)
		if len(mounts) == 0 {
			devFatalf("Invalid functions directory: %s", absPath)
			return
		}

		// Find docker-compose.yml (recursively up).
		//
		// We prefer starting from the current working directory so repo developers
		// can run `fastfn dev /tmp/project` from the repo root and still use the
		// repo stack. If that fails, fall back to scanning from the target dir.
		projectRoot := ""
		if wd, wdErr := os.Getwd(); wdErr == nil {
			if root, rootErr := findProjectRoot(wd); rootErr == nil {
				projectRoot = root
			}
		}
		if projectRoot == "" {
			projectRoot, err = findProjectRoot(absPath)
		} else {
			err = nil
		}
		var composePath string

		if err == nil {
			// Local repo case
			composePath = filepath.Join(projectRoot, "docker-compose.yml")
			fmt.Printf("Found local docker-compose.yml at: %s\n", projectRoot)
		} else {
			// Portable case: generate temporary compose file using the published runtime image
			fmt.Println("No local docker-compose.yml found. Using portable mode...")

			tempDir, err := devMkdirTempFn("", "fastfn-dev-*")
			if err != nil {
				devFatal("Failed to create temp dir: %v", err)
				return
			}
			defer os.RemoveAll(tempDir)

			genPath, err := devGenerateDockerComposeFn(tempDir, absPath)
			if err != nil {
				devFatal("Failed to generate docker-compose.yml: %v", err)
				return
			}
			composePath = genPath
			projectRoot = tempDir
		}

		fmt.Printf("Using configuration from: %s\n", composePath)

		// 4. Parse YAML
		data, err := os.ReadFile(composePath)
		if err != nil {
			devFatalf("Failed to read docker-compose.yml: %v", err)
			return
		}

		var compose map[string]interface{}
		if err := yaml.Unmarshal(data, &compose); err != nil {
			devFatalf("Failed to parse docker-compose.yml: %v", err)
			return
		}

		// 5. Apply volumes
		services, ok := compose["services"].(map[string]interface{})
		if !ok {
			devFatal("Invalid docker-compose.yml: no services")
			return
		}
		openresty, ok := services["openresty"].(map[string]interface{})
		if !ok {
			devFatal("Invalid docker-compose.yml: no openresty service")
			return
		}

		applyOpenRestyDockerUser(openresty)

		volumes, ok := openresty["volumes"].([]interface{})
		if !ok {
			volumes = []interface{}{}
		}

		// Filter out existing /app/srv/fn/functions mounts
		newVolumes := []interface{}{}
		for _, v := range volumes {
			vStr, ok := v.(string)
			if ok && strings.Contains(vStr, "/app/srv/fn/functions") {
				continue
			}
			newVolumes = append(newVolumes, v)
		}

		// Add our calculated mounts
		for _, m := range mounts {
			newVolumes = append(newVolumes, m)
			fmt.Printf("Mounting '%s' -> '%s'\n", strings.Split(m, ":")[0], strings.Split(m, ":")[1])
		}
		openresty["volumes"] = newVolumes

		// Apply optional env toggles.
		if strings.TrimSpace(os.Getenv("FN_FORCE_URL")) != "" {
			envRaw := openresty["environment"]
			envMap, ok := envRaw.(map[string]interface{})
			if !ok || envMap == nil {
				envMap = map[string]interface{}{}
			}
			envMap["FN_FORCE_URL"] = os.Getenv("FN_FORCE_URL")
			openresty["environment"] = envMap
		}
		if strings.TrimSpace(os.Getenv("FN_RUNTIME_DAEMONS")) != "" {
			envRaw := openresty["environment"]
			envMap, ok := envRaw.(map[string]interface{})
			if !ok || envMap == nil {
				envMap = map[string]interface{}{}
			}
			envMap["FN_RUNTIME_DAEMONS"] = os.Getenv("FN_RUNTIME_DAEMONS")
			openresty["environment"] = envMap
		}
		for _, envVar := range []string{
			"FN_PYTHON_BIN",
			"FN_NODE_BIN",
			"FN_NPM_BIN",
			"FN_PHP_BIN",
			"FN_COMPOSER_BIN",
			"FN_CARGO_BIN",
			"FN_GO_BIN",
			"FN_OPENRESTY_BIN",
		} {
			if strings.TrimSpace(os.Getenv(envVar)) == "" {
				continue
			}
			envRaw := openresty["environment"]
			envMap, ok := envRaw.(map[string]interface{})
			if !ok || envMap == nil {
				envMap = map[string]interface{}{}
			}
			envMap[envVar] = os.Getenv(envVar)
			openresty["environment"] = envMap
		}
		if functionsRoot := dockerFunctionsRoot(absPath); functionsRoot != "/app/srv/fn/functions" {
			envRaw := openresty["environment"]
			envMap, ok := envRaw.(map[string]interface{})
			if !ok || envMap == nil {
				envMap = map[string]interface{}{}
			}
			envMap["FN_FUNCTIONS_ROOT"] = functionsRoot
			openresty["environment"] = envMap
		}

		// Encode back to YAML
		modifiedYAML, err := devYAMLMarshalFn(compose)
		if err != nil {
			devFatalf("Failed to generate modified YAML: %v", err)
			return
		}

		if dryRun {
			fmt.Println("# Dry Run: Generated Docker Compose configuration")
			fmt.Println(string(modifiedYAML))
			return
		}

		// Docker mode: ensure Docker is available and the daemon is running.
		checkSystemRequirementsFn()

		// On Docker Desktop (and some CI setups), bind mount filesystem events do not
		// reliably propagate into containers. Use a host watcher to trigger reloads so
		// new functions and edits are discovered without restarting.
		hostPort := strings.TrimSpace(os.Getenv("FN_HOST_PORT"))
		if hostPort == "" {
			hostPort = "8080"
		}
		reloadURL := fmt.Sprintf("http://127.0.0.1:%s/_fn/reload", hostPort)
		watcher, watchErr := devStartHotReloadWatcher(absPath, reloadURL, func(format string, args ...interface{}) {
			fmt.Printf(format+"\n", args...)
		})
		if watchErr == nil {
			defer watcher.Stop()
			fmt.Println("Watching for file changes (host watcher)...")
		} else {
			fmt.Printf("Warning: failed to start host watcher: %v\n", watchErr)
		}

		// 6. Run docker compose
		dockerArgs := []string{"compose", "-f", "-", "up"}
		if devBuild {
			dockerArgs = append(dockerArgs, "--build")
		}
		dockerCmd := devExecCommand("docker", dockerArgs...)
		dockerCmd.Stdin = bytes.NewReader(modifiedYAML)
		dockerCmd.Stdout = os.Stdout
		dockerCmd.Stderr = os.Stderr

		// Set working dir to where the original compose file is
		dockerCmd.Dir = filepath.Dir(composePath)

		fmt.Println("Starting FastFN dev server...")
		if err := dockerCmd.Run(); err != nil {
			devFatalf("Docker run failed: %v", err)
			return
		}
	},
}

// applyOpenRestyDockerUser makes Docker dev behave predictably on Linux bind mounts.
//
// Why: Nginx/OpenResty workers can run as an unprivileged user by default. That
// breaks write flows (console write, ad-hoc function creation, etc.) on bind
// mounts where the project directory is not world-writable (e.g. mktemp() creates
// 0700 dirs in CI).
//
// Override knobs:
// - FN_DOCKER_USER: explicit docker user value (e.g. "1000:1000")
// - FN_DOCKER_RUN_AS_ROOT=1: keep the service user unset
func applyOpenRestyDockerUser(openresty map[string]interface{}) {
	if openresty == nil {
		return
	}
	if _, hasUser := openresty["user"]; hasUser {
		return
	}
	if strings.TrimSpace(os.Getenv("FN_DOCKER_RUN_AS_ROOT")) == "1" {
		return
	}
	if u := strings.TrimSpace(os.Getenv("FN_DOCKER_USER")); u != "" {
		openresty["user"] = u
		return
	}
	uid, gid := os.Getuid(), os.Getgid()
	if uid >= 0 && gid >= 0 {
		openresty["user"] = fmt.Sprintf("%d:%d", uid, gid)
	}
}

type FnConfig struct {
	Runtime    string `json:"runtime"`
	Name       string `json:"name"`
	Entrypoint string `json:"entrypoint"`
}

func readRawFnConfig(path string) (map[string]interface{}, bool) {
	data, err := os.ReadFile(filepath.Join(path, "fn.config.json"))
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

func mountProjectRoot(rootPath string) []string {
	return []string{fmt.Sprintf("%s:/app/srv/fn/functions", dockerMountSourceRoot(rootPath))}
}

func hasRuntimeLayoutDirs(rootPath string) bool {
	for _, dir := range []string{"node", "python", "php", "lua", "rust", "go"} {
		if info, err := os.Stat(filepath.Join(rootPath, dir)); err == nil && info.IsDir() {
			return true
		}
	}
	return false
}

func hasSiblingRuntimeLayoutDirs(rootPath, currentRuntime string) bool {
	for _, dir := range []string{"node", "python", "php", "lua", "rust", "go"} {
		if dir == currentRuntime {
			continue
		}
		if info, err := os.Stat(filepath.Join(rootPath, dir)); err == nil && info.IsDir() {
			return true
		}
	}
	return false
}

func runtimeScopedRoot(rootPath string) (string, string, bool) {
	cleanRoot := filepath.Clean(rootPath)
	runtime := strings.ToLower(filepath.Base(cleanRoot))
	switch runtime {
	case "node", "python", "php", "lua", "rust", "go":
	default:
		return "", "", false
	}

	parent := filepath.Dir(cleanRoot)
	if parent == "." || parent == cleanRoot {
		return "", "", false
	}
	if hasSiblingRuntimeLayoutDirs(parent, runtime) {
		return runtime, parent, true
	}
	if info, err := os.Stat(filepath.Join(parent, ".fastfn")); err == nil && info.IsDir() {
		return runtime, parent, true
	}
	return "", "", false
}

func dockerMountSourceRoot(rootPath string) string {
	_, parent, ok := runtimeScopedRoot(rootPath)
	if ok {
		return parent
	}
	return rootPath
}

func dockerFunctionsRoot(rootPath string) string {
	runtime, _, ok := runtimeScopedRoot(rootPath)
	if !ok {
		return "/app/srv/fn/functions"
	}
	return filepath.ToSlash(filepath.Join("/app/srv/fn/functions", runtime))
}

// scanForMounts returns a list of "hostPath:containerPath" strings.
// Dual/hybrid behavior:
//   - If the target dir uses the standard runtime layout (node/, python/, etc), mount the
//     root so hot-reload can discover newly created functions without restarting.
//   - If the target dir is a single function leaf (has fn.config.json), mount it into
//     the runtime layout location inside the container.
//   - Otherwise, mount the project root for hot-reload visibility and add discovered
//     fn.config mounts individually when config name/runtime overrides need a stable
//     runtime-scoped target inside the container.
func scanForMounts(rootPath string) []string {
	info, err := os.Stat(rootPath)
	if err != nil || !info.IsDir() {
		return nil
	}

	if isFunction(rootPath) {
		rt, name := getFunctionDetails(rootPath)
		return []string{fmt.Sprintf("%s:/app/srv/fn/functions/%s/%s", rootPath, rt, name)}
	}

	if hasRuntimeLayoutDirs(rootPath) {
		return mountProjectRoot(rootPath)
	}

	_, _ = discoveryScanFn(rootPath, func(format string, v ...interface{}) {
		msg := fmt.Sprintf(format, v...)
		if strings.Contains(strings.ToLower(msg), "route conflict") {
			fmt.Fprintf(os.Stderr, "%s\n", msg)
		}
	})
	return mountProjectRoot(rootPath)
}

func isFunction(path string) bool {
	raw, ok := readRawFnConfig(path)
	return ok && isExplicitFunctionConfig(raw)
}

func getFunctionDetails(path string) (string, string) {
	data, err := os.ReadFile(filepath.Join(path, "fn.config.json"))
	if err != nil {
		return "node", filepath.Base(path)
	}
	var cfg FnConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return "node", filepath.Base(path)
	}
	if cfg.Runtime == "" {
		cfg.Runtime = "node"
	}
	if cfg.Name == "" {
		cfg.Name = filepath.Base(path)
	}
	return cfg.Runtime, cfg.Name
}

func init() {
	rootCmd.AddCommand(devCmd)
	devCmd.Flags().BoolVar(&devNativeMode, "native", false, "Run on host using the embedded runtime stack (no Docker)")
	devCmd.Flags().BoolVar(&dryRun, "dry-run", false, "Print generated docker-compose config without running")
	devCmd.Flags().BoolVar(&devForceURL, "force-url", false, "Allow config/policy routes to override existing mapped URLs (unsafe; prefer fixing route conflicts)")
	devCmd.Flags().BoolVar(&devBuild, "build", false, "Build the runtime image before starting the dev server (slower)")
}
