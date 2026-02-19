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
	info, err := os.Stat(socketPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("failed to inspect runtime socket %s: %w", socketPath, err)
	}
	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("runtime socket path exists but is not a unix socket: %s", socketPath)
	}

	conn, dialErr := net.DialTimeout("unix", socketPath, 200*time.Millisecond)
	if dialErr == nil {
		_ = conn.Close()
		return fmt.Errorf("runtime socket already in use: %s", socketPath)
	}

	if rmErr := os.Remove(socketPath); rmErr != nil && !errors.Is(rmErr, os.ErrNotExist) {
		return fmt.Errorf("failed to remove stale runtime socket %s: %w", socketPath, rmErr)
	}
	return nil
}

var nativeDefaultRuntimes = []string{"python", "node", "php", "lua"}

var nativeRuntimeRequirements = map[string][]string{
	"python": {"python3"},
	"node":   {"node"},
	"php":    {"php"},
	"lua":    {},
	"rust":   {"python3", "cargo"},
	"go":     {"python3", "go"},
}

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
		if explicit {
			return nil, warnings, fmt.Errorf("no compatible runtimes enabled (FN_RUNTIMES=%q)", rawRequested)
		}
		return nil, warnings, fmt.Errorf("no compatible runtimes available on this machine (need at least one of: python3, node, php, lua)")
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
	if err := CheckDependencies(); err != nil {
		return err
	}

	// 2. Extract Embedded Runtime Assets
	runtimeDir, err := runtime.Extract()
	if err != nil {
		return fmt.Errorf("failed to extract runtime assets: %w", err)
	}
	defer os.RemoveAll(runtimeDir) // Cleanup temp dir on exit
	fmt.Printf("Runtime extracted to: %s\n", runtimeDir)

	hostPort := os.Getenv("FN_HOST_PORT")
	if hostPort == "" {
		hostPort = "8080"
	}
	portNum, err := strconv.Atoi(hostPort)
	if err != nil || portNum < 1 || portNum > 65535 {
		return fmt.Errorf("invalid FN_HOST_PORT %q", hostPort)
	}
	if err := ensurePortAvailable(hostPort); err != nil {
		return err
	}

	// 3. Generate Nginx Config
	nginxConf, err := GenerateNativeConfig(runtimeDir, hostPort)
	if err != nil {
		return fmt.Errorf("failed to generate nginx config: %w", err)
	}
	fmt.Printf("Config generated: %s\n", nginxConf)

	// 4. Setup Environment Variables
	//
	// Native mode runs OpenResty directly on the host. Keep runtime temp dirs
	// consistent with the Docker stack (/tmp/fastfn/*) and ensure the parent
	// exists before OpenResty starts (it will create subdirectories itself).
	if err := os.MkdirAll("/tmp/fastfn", 0o777); err != nil {
		return fmt.Errorf("failed to create /tmp/fastfn: %w", err)
	}
	_ = os.Chmod("/tmp/fastfn", 0o1777)

	socketDir := filepath.Join(runtimeDir, "sockets")
	if err := os.MkdirAll(socketDir, 0755); err != nil {
		return err
	}
	socketByRuntime := map[string]string{
		"python": filepath.Join(socketDir, "fn-python.sock"),
		"node":   filepath.Join(socketDir, "fn-node.sock"),
		"php":    filepath.Join(socketDir, "fn-php.sock"),
		"rust":   filepath.Join(socketDir, "fn-rust.sock"),
		"go":     filepath.Join(socketDir, "fn-go.sock"),
	}

	pythonCmd := "python3"
	nodeCmd := "node"
	phpCmd := "php"
	goCmd := "go"
	hasPython := false
	hasNode := false
	hasPHP := false
	hasGo := false
	hasCargo := false

	if resolved, err := exec.LookPath("python3"); err == nil {
		pythonCmd = resolved
		hasPython = true
	}
	if resolved, err := exec.LookPath("node"); err == nil {
		nodeCmd = resolved
		hasNode = true
	}
	if resolved, err := exec.LookPath("php"); err == nil {
		phpCmd = resolved
		hasPHP = true
	}
	if resolved, err := exec.LookPath("go"); err == nil {
		goCmd = resolved
		hasGo = true
	}
	if _, err := exec.LookPath("cargo"); err == nil {
		hasCargo = true
	}

	rawRequested := strings.TrimSpace(os.Getenv("FN_RUNTIMES"))
	runtimes, warnings, err := selectNativeRuntimes(rawRequested, map[string]bool{
		"python3": hasPython,
		"node":    hasNode,
		"php":     hasPHP,
		"lua":     true,
		"cargo":   hasCargo,
		"go":      hasGo,
	})
	if err != nil {
		return err
	}
	for _, message := range warnings {
		fmt.Printf("Warning: %s\n", message)
	}

	selected := map[string]bool{}
	for _, rt := range runtimes {
		selected[rt] = true
	}
	for runtimeName, socketPath := range socketByRuntime {
		if !selected[runtimeName] {
			continue
		}
		if err := ensureSocketPathAvailable(socketPath); err != nil {
			return err
		}
	}

	runtimesDir := filepath.Join(runtimeDir, "srv", "fn", "runtimes")
	logsDir := filepath.Join(runtimeDir, "openresty", "logs")
	if err := os.MkdirAll(logsDir, 0755); err != nil {
		return err
	}
	if err := WriteNativeSession(NativeSession{
		RuntimeDir: runtimeDir,
		LogsDir:    logsDir,
		LaunchPID:  os.Getpid(),
	}); err != nil {
		fmt.Printf("Warning: failed to write native session metadata: %v\n", err)
	} else {
		defer func() {
			if err := ClearNativeSessionForPID(os.Getpid()); err != nil {
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
		"FN_PY_SOCKET=" + socketByRuntime["python"],
		"FN_NODE_SOCKET=" + socketByRuntime["node"],
		"FN_PHP_SOCKET=" + socketByRuntime["php"],
		"FN_RUST_SOCKET=" + socketByRuntime["rust"],
		"FN_GO_SOCKET=" + socketByRuntime["go"],
		"FN_RUNTIMES=" + strings.Join(runtimes, ","),
		"FN_HOT_RELOAD=" + reloadVal,
		"FN_HOT_RELOAD_INTERVAL=2",
		"FN_HTTP_VERIFY_TLS=" + verifyTLS,
		"LUA_PATH=" + filepath.Join(runtimeDir, "openresty", "lua", "?.lua") + ";" + filepath.Join(runtimeDir, "openresty", "lua", "?", "init.lua") + ";;",
		"LUA_CPATH=;;", // Default
	}
	if v := strings.TrimSpace(os.Getenv("FN_FORCE_URL")); v != "" {
		baseEnv = append(baseEnv, "FN_FORCE_URL="+v)
	}

	// 5. Initialize Process Manager
	pm := NewManager()

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
	pm.AddServiceWithOptions("openresty", "openresty", []string{
		"-e", "/dev/stderr",
		"-p", openrestyDir,
		"-c", filepath.Base(nginxConf),
		"-g", "daemon off;",
	}, baseEnv, openrestyDir, runtimeServiceOptions)

	if selected["python"] {
		pm.AddServiceWithOptions("python", pythonCmd, []string{
			filepath.Join(runtimesDir, "python-daemon.py"),
		}, baseEnv, runtimesDir, runtimeServiceOptions)
	}

	if selected["node"] {
		pm.AddServiceWithOptions("node", nodeCmd, []string{
			filepath.Join(runtimesDir, "node-daemon.js"),
		}, baseEnv, runtimesDir, runtimeServiceOptions)
	}

	if selected["php"] {
		pm.AddServiceWithOptions("php", phpCmd, []string{
			filepath.Join(runtimesDir, "php-daemon.py"),
		}, baseEnv, runtimesDir, runtimeServiceOptions)
	}

	if selected["rust"] {
		pm.AddServiceWithOptions("rust", pythonCmd, []string{
			filepath.Join(runtimesDir, "rust-daemon.py"),
		}, baseEnv, runtimesDir, runtimeServiceOptions)
	}

	if selected["go"] {
		pm.AddServiceWithOptions("go", pythonCmd, []string{
			filepath.Join(runtimesDir, "go-daemon.py"),
		}, append(baseEnv, "FN_GO_BIN="+goCmd), runtimesDir, runtimeServiceOptions)
	}

	// 7. Start All
	fmt.Println("Starting services...")
	if err := pm.StartAll(); err != nil {
		return err
	}

	// 7b. Optional Watcher (Hot Reload)
	if cfg.Watch {
		reloadURL := fmt.Sprintf("http://localhost:%s/_fn/reload", hostPort)
		watcher, err := StartHotReloadWatcher(cfg.FnDir, reloadURL, func(format string, args ...interface{}) {
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

	// 8. Wait for Interrupt
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)
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
