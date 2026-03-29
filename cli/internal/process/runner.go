package process

import (
	"errors"
	"fmt"
	"github.com/misaelzapata/fastfn/cli/embed/runtime"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type RunConfig struct {
	FnDir     string
	HotReload bool
	VerifyTLS bool
	Watch     bool
}

func ensurePortAvailable(hostPort string) error {
	ln, err := net.Listen("tcp", "127.0.0.1:"+hostPort)
	if err != nil {
		return fmt.Errorf("FN_HOST_PORT=%s is already in use; stop the existing process or set FN_HOST_PORT to another port", hostPort)
	}
	_ = ln.Close()
	return nil
}

func ensureSocketPathAvailable(socketPath string) error {
	info, err := socketStatFn(socketPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("failed to inspect runtime socket %s: %w", socketPath, err)
	}
	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("runtime socket path exists but is not a unix socket: %s", socketPath)
	}

	conn, dialErr := socketDialTimeoutFn("unix", socketPath, 200*time.Millisecond)
	if dialErr == nil {
		_ = conn.Close()
		return fmt.Errorf("runtime socket already in use: %s", socketPath)
	}

	if rmErr := socketRemoveFn(socketPath); rmErr != nil && !errors.Is(rmErr, os.ErrNotExist) {
		return fmt.Errorf("failed to remove stale runtime socket %s: %w", socketPath, rmErr)
	}
	return nil
}

var nativeDefaultRuntimes = []string{"python", "node", "php", "lua"}

var nativeRuntimeRequirements = map[string][]string{
	"python": {"python"},
	"node":   {"node"},
	"php":    {"python", "php"},
	"lua":    {},
	"rust":   {"python", "cargo"},
	"go":     {"python", "go"},
}

type nativeServiceManager interface {
	AddServiceWithOptions(name, command string, args []string, env []string, dir string, opts ServiceOptions)
	StartAll() error
	StopAll()
	Done() <-chan struct{}
}

var (
	socketStatFn             = os.Stat
	socketDialTimeoutFn      = net.DialTimeout
	socketRemoveFn           = os.Remove
	checkDependenciesFn      = CheckDependencies
	runtimeExtractFn         = runtime.Extract
	generateNativeConfigFn   = GenerateNativeConfig
	mkdirAllFn               = os.MkdirAll
	chmodFn                  = os.Chmod
	removeAllFn              = os.RemoveAll
	lookPathFn               = exec.LookPath
	startHotReloadWatcherFn  = StartHotReloadWatcher
	ensurePortAvailableFn    = ensurePortAvailable
	ensureSocketPathAvailFn  = ensureSocketPathAvailable
	writeNativeSessionFn     = WriteNativeSession
	clearNativeSessionForPID = ClearNativeSessionForPID
	notifySignalFn           = signal.Notify
	runtimeSocketURIsFn      = runtimeSocketURIsByRuntime
	newNativeManagerFn       = func() nativeServiceManager { return NewManager() }
	awaitNativeStopFn        = func(pm nativeServiceManager) error {
		sigChan := make(chan os.Signal, 1)
		notifySignalFn(sigChan, os.Interrupt, syscall.SIGTERM)
		select {
		case <-sigChan:
			fmt.Println("\nStopping services...")
			pm.StopAll()
			return nil
		case <-pm.Done():
			fmt.Println("\nCritical service stopped; shutting down...")
			pm.StopAll()
			return fmt.Errorf("native services stopped unexpectedly; see logs above")
		}
	}
)

func parseRequestedRuntimes(raw string) []string {
	seen := map[string]bool{}
	requested := make([]string, 0, len(nativeDefaultRuntimes))
	for _, token := range strings.Split(raw, ",") {
		rt := strings.ToLower(strings.TrimSpace(token))
		if rt == "" || seen[rt] {
			continue
		}
		seen[rt] = true
		requested = append(requested, rt)
	}
	return requested
}

func selectNativeRuntimes(rawRequested string, hasCommand map[string]bool) ([]string, []string, error) {
	requested := parseRequestedRuntimes(rawRequested)
	explicit := strings.TrimSpace(rawRequested) != ""
	if len(requested) == 0 {
		requested = append(requested, nativeDefaultRuntimes...)
		explicit = false
	}

	selected := make([]string, 0, len(requested))
	warnings := make([]string, 0)
	for _, rt := range requested {
		requiredCommands, known := nativeRuntimeRequirements[rt]
		if !known {
			if explicit {
				warnings = append(warnings, fmt.Sprintf("Ignoring unknown runtime in FN_RUNTIMES: %s", rt))
			}
			continue
		}

		missing := make([]string, 0, len(requiredCommands))
		for _, command := range requiredCommands {
			if !hasCommand[command] {
				missing = append(missing, command)
			}
		}
		if len(missing) > 0 {
			if explicit {
				warnings = append(warnings, fmt.Sprintf("Ignoring runtime %s (missing: %s)", rt, strings.Join(missing, ", ")))
			}
			continue
		}

		selected = append(selected, rt)
	}

	if len(selected) == 0 {
		return nil, warnings, fmt.Errorf("no compatible runtimes enabled (FN_RUNTIMES=%q)", rawRequested)
	}

	return selected, warnings, nil
}

// RunNative orchestrates the entire runtime lifecycle on bare metal
func RunNative(cfg RunConfig) error {
	fmt.Printf("Initializing native mode for %s...\n", cfg.FnDir)
	if !cfg.HotReload {
		fmt.Println("Production mode: hot reload disabled")
	}

	// 1. Check Dependencies
	if err := checkDependenciesFn(); err != nil {
		return err
	}

	// 2. Extract Embedded Runtime Assets
	runtimeDir, err := runtimeExtractFn()
	if err != nil {
		return fmt.Errorf("failed to extract runtime assets: %w", err)
	}
	defer removeAllFn(runtimeDir) // Cleanup temp dir on exit
	fmt.Printf("Runtime extracted to: %s\n", runtimeDir)

	hostPort := os.Getenv("FN_HOST_PORT")
	if hostPort == "" {
		hostPort = "8080"
	}
	portNum, err := strconv.Atoi(hostPort)
	if err != nil || portNum < 1 || portNum > 65535 {
		return fmt.Errorf("invalid FN_HOST_PORT %q", hostPort)
	}
	if err := ensurePortAvailableFn(hostPort); err != nil {
		return err
	}

	// 3. Generate Nginx Config
	nginxConf, err := generateNativeConfigFn(runtimeDir, hostPort)
	if err != nil {
		return fmt.Errorf("failed to generate nginx config: %w", err)
	}
	fmt.Printf("Config generated: %s\n", nginxConf)

	// 4. Setup Environment Variables
	//
	// Native mode runs OpenResty directly on the host. Keep runtime temp dirs
	// consistent with the Docker stack by default, but still honor an explicit
	// FN_SOCKET_BASE_DIR override when the environment or caller needs a custom
	// native socket root.
	socketBaseDir := strings.TrimSpace(os.Getenv("FN_SOCKET_BASE_DIR"))
	if socketBaseDir == "" {
		socketBaseDir = "/tmp/fastfn"
	}
	if err := mkdirAllFn(socketBaseDir, 0o777); err != nil {
		return fmt.Errorf("failed to create %s: %w", socketBaseDir, err)
	}
	_ = chmodFn(socketBaseDir, 0o1777)

	binaries := map[string]BinaryResolution{}
	hasBinary := map[string]bool{
		"lua": true,
	}
	resolveIfAvailable := func(key string) error {
		resolution, err := ResolveConfiguredBinary(key)
		if err != nil {
			hasBinary[key] = false
			if envVar, ok := BinaryEnvVarName(key); ok && strings.TrimSpace(os.Getenv(envVar)) != "" {
				return err
			}
			return nil
		}
		binaries[key] = resolution
		hasBinary[key] = true
		return nil
	}
	for _, key := range []string{"openresty", "python", "node", "php", "composer", "cargo", "go"} {
		if err := resolveIfAvailable(key); err != nil {
			return err
		}
	}

	rawRequested := strings.TrimSpace(os.Getenv("FN_RUNTIMES"))
	runtimes, warnings, err := selectNativeRuntimes(rawRequested, hasBinary)
	if err != nil {
		return err
	}
	for _, message := range warnings {
		fmt.Printf("Warning: %s\n", message)
	}
	runtimeDaemonCounts, daemonWarnings, err := resolveRuntimeDaemonCounts(runtimes, strings.TrimSpace(os.Getenv("FN_RUNTIME_DAEMONS")))
	if err != nil {
		return err
	}
	for _, message := range daemonWarnings {
		fmt.Printf("Warning: %s\n", message)
	}
	socketDir, usedFallbackSocketDir := chooseNativeSocketDir(socketBaseDir, os.Getpid(), runtimes, runtimeDaemonCounts)
	if usedFallbackSocketDir {
		fmt.Printf("Warning: runtime socket paths under %s exceed safe unix socket limits; using shorter native socket dir %s\n", socketBaseDir, socketDir)
	}
	if err := removeAllFn(socketDir); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("failed to clear native socket dir %s: %w", socketDir, err)
	}
	if err := mkdirAllFn(socketDir, 0755); err != nil {
		return err
	}
	defer func() {
		if err := removeAllFn(socketDir); err != nil && !errors.Is(err, os.ErrNotExist) {
			fmt.Printf("Warning: failed to remove native socket dir %s: %v\n", socketDir, err)
		}
	}()
	runtimeSockets := runtimeSocketURIsFn(socketDir, runtimes, runtimeDaemonCounts)
	runtimeSocketMapJSON, err := encodeRuntimeSocketMap(runtimeSockets)
	if err != nil {
		return fmt.Errorf("failed to encode runtime socket map: %w", err)
	}

	selected := map[string]bool{}
	for _, rt := range runtimes {
		selected[rt] = true
	}
	for runtimeName, socketURIs := range runtimeSockets {
		if !selected[runtimeName] {
			continue
		}
		for _, socketURI := range socketURIs {
			socketPath := strings.TrimPrefix(socketURI, "unix:")
			if err := ensureSocketPathAvailFn(socketPath); err != nil {
				return err
			}
		}
	}

	runtimesDir := filepath.Join(runtimeDir, "srv", "fn", "runtimes")
	logsDir := filepath.Join(runtimeDir, "openresty", "logs")
	if err := mkdirAllFn(logsDir, 0755); err != nil {
		return err
	}
	if err := writeNativeSessionFn(NativeSession{
		RuntimeDir: runtimeDir,
		LogsDir:    logsDir,
		LaunchPID:  os.Getpid(),
	}); err != nil {
		fmt.Printf("Warning: failed to write native session metadata: %v\n", err)
	} else {
		defer func() {
			if err := clearNativeSessionForPID(os.Getpid()); err != nil {
				fmt.Printf("Warning: failed to clear native session metadata: %v\n", err)
			}
		}()
	}

	reloadVal := "false"
	if cfg.HotReload {
		reloadVal = "true"
	}
	verifyTLS := "false"
	if cfg.VerifyTLS {
		verifyTLS = "true"
	}

	baseEnv := []string{
		"FN_FUNCTIONS_ROOT=" + cfg.FnDir,
		"FN_SOCKET_BASE_DIR=" + socketDir,
		"FN_RUNTIME_LOG_FILE=" + filepath.Join(logsDir, "runtime.log"),
		"FN_PY_SOCKET=" + strings.TrimPrefix(firstRuntimeSocket(runtimeSockets["python"]), "unix:"),
		"FN_NODE_SOCKET=" + strings.TrimPrefix(firstRuntimeSocket(runtimeSockets["node"]), "unix:"),
		"FN_PHP_SOCKET=" + strings.TrimPrefix(firstRuntimeSocket(runtimeSockets["php"]), "unix:"),
		"FN_RUST_SOCKET=" + strings.TrimPrefix(firstRuntimeSocket(runtimeSockets["rust"]), "unix:"),
		"FN_GO_SOCKET=" + strings.TrimPrefix(firstRuntimeSocket(runtimeSockets["go"]), "unix:"),
		"FN_RUNTIMES=" + strings.Join(runtimes, ","),
		"FN_RUNTIME_SOCKETS=" + runtimeSocketMapJSON,
		"FN_HOT_RELOAD=" + reloadVal,
		"FN_HOT_RELOAD_INTERVAL=2",
		"FN_HTTP_VERIFY_TLS=" + verifyTLS,
		"LUA_PATH=" + filepath.Join(runtimeDir, "openresty", "lua", "?.lua") + ";" + filepath.Join(runtimeDir, "openresty", "lua", "?", "init.lua") + ";;",
		"LUA_CPATH=;;", // Default
	}
	for _, key := range []string{"python", "node", "php", "composer", "cargo", "go", "openresty"} {
		resolution, ok := binaries[key]
		if !ok {
			continue
		}
		baseEnv = append(baseEnv, resolution.EnvVar+"="+resolution.Path)
	}
	if v := strings.TrimSpace(os.Getenv("FN_FORCE_URL")); v != "" {
		baseEnv = append(baseEnv, "FN_FORCE_URL="+v)
	}

	// 5. Initialize Process Manager
	pm := newNativeManagerFn()

	// 6. Register Services
	runtimeServiceOptions := ServiceOptions{
		Restart: RestartPolicy{
			Enabled:        true,
			MaxAttempts:    0, // unlimited
			InitialBackoff: 500 * time.Millisecond,
			MaxBackoff:     8 * time.Second,
		},
	}
	openrestyDir := filepath.Join(runtimeDir, "openresty")
	openrestyCommand := BinaryConfiguredCommand("openresty")
	if resolution, ok := binaries["openresty"]; ok {
		openrestyCommand = resolution.Path
	}
	pm.AddServiceWithOptions("openresty", openrestyCommand, []string{
		"-e", "/dev/stderr",
		"-p", openrestyDir,
		"-c", filepath.Base(nginxConf),
		"-g", "daemon off;",
	}, baseEnv, openrestyDir, runtimeServiceOptions)

	if selected["python"] {
		for idx, socketURI := range runtimeSockets["python"] {
			count := len(runtimeSockets["python"])
			pm.AddServiceWithOptions(runtimeServiceName("python", idx+1, count), binaries["python"].Path, []string{
				filepath.Join(runtimesDir, "python-daemon.py"),
			}, runtimeServiceEnv(baseEnv, "python", socketURI, idx+1, count), runtimesDir, runtimeServiceOptions)
		}
	}

	if selected["node"] {
		for idx, socketURI := range runtimeSockets["node"] {
			count := len(runtimeSockets["node"])
			pm.AddServiceWithOptions(runtimeServiceName("node", idx+1, count), binaries["node"].Path, []string{
				filepath.Join(runtimesDir, "node-daemon.js"),
			}, runtimeServiceEnv(baseEnv, "node", socketURI, idx+1, count), runtimesDir, runtimeServiceOptions)
		}
	}

	if selected["php"] {
		for idx, socketURI := range runtimeSockets["php"] {
			count := len(runtimeSockets["php"])
			pm.AddServiceWithOptions(runtimeServiceName("php", idx+1, count), binaries["php"].Path, []string{
				filepath.Join(runtimesDir, "php-daemon.php"),
			}, runtimeServiceEnv(baseEnv, "php", socketURI, idx+1, count), runtimesDir, runtimeServiceOptions)
		}
	}

	if selected["rust"] {
		for idx, socketURI := range runtimeSockets["rust"] {
			count := len(runtimeSockets["rust"])
			pm.AddServiceWithOptions(runtimeServiceName("rust", idx+1, count), binaries["python"].Path, []string{
				filepath.Join(runtimesDir, "rust-daemon.py"),
			}, runtimeServiceEnv(baseEnv, "rust", socketURI, idx+1, count), runtimesDir, runtimeServiceOptions)
		}
	}

	if selected["go"] {
		for idx, socketURI := range runtimeSockets["go"] {
			count := len(runtimeSockets["go"])
			env := runtimeServiceEnv(baseEnv, "go", socketURI, idx+1, count)
			pm.AddServiceWithOptions(runtimeServiceName("go", idx+1, count), binaries["python"].Path, []string{
				filepath.Join(runtimesDir, "go-daemon.py"),
			}, env, runtimesDir, runtimeServiceOptions)
		}
	}

	// 7. Start All
	fmt.Println("Starting services...")
	if err := pm.StartAll(); err != nil {
		return err
	}

	// 7b. Optional Watcher (Hot Reload)
	if cfg.Watch {
		reloadURL := fmt.Sprintf("http://localhost:%s/_fn/reload", hostPort)
		watcher, err := startHotReloadWatcherFn(cfg.FnDir, reloadURL, func(format string, args ...interface{}) {
			fmt.Printf(format+"\n", args...)
		})
		if err == nil {
			defer watcher.Stop()
			fmt.Println("Watching for file changes...")
		} else {
			fmt.Printf("Warning: failed to start watcher: %v\n", err)
		}
	}

	fmt.Printf("\nFastFN is running at http://localhost:%s\n", hostPort)
	fmt.Println("Logs are streaming below. Press Ctrl+C to stop.")

	return awaitNativeStopFn(pm)
}
