//go:build linux

package workloads

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	firecracker "github.com/firecracker-microvm/firecracker-go-sdk"
	models "github.com/firecracker-microvm/firecracker-go-sdk/client/models"
)

const (
	defaultFirecrackerBin       = "firecracker"
	defaultVolumeBytes    int64 = 10 * 1024 * 1024 * 1024
)

type FirecrackerManager struct {
	cfg   ManagerConfig
	mu    sync.Mutex
	state State
	vms   []managedVM
}

type managedVM struct {
	kind           string
	specName       string
	vmDir          string
	hostPort       int
	check          HealthcheckSpec
	machine        *firecracker.Machine
	proxies        []io.Closer
	serviceBridges []io.Closer
}

type workloadBootConfig struct {
	Version  int                      `json:"version"`
	Kind     string                   `json:"kind"`
	Name     string                   `json:"name"`
	Port     int                      `json:"port"`
	Command  []string                 `json:"command,omitempty"`
	Env      map[string]string        `json:"env,omitempty"`
	Services []workloadServiceBinding `json:"services,omitempty"`
}

type workloadServiceBinding struct {
	Name string `json:"name"`
	Host string `json:"host"`
	Port int    `json:"port"`
	URL  string `json:"url,omitempty"`
}

func NewFirecrackerManager(cfg ManagerConfig) (*FirecrackerManager, error) {
	state := State{
		Apps:     map[string]AppState{},
		Services: map[string]ServiceState{},
	}
	if len(cfg.Apps) == 0 && len(cfg.Services) == 0 {
		return &FirecrackerManager{cfg: cfg, state: state}, nil
	}
	if strings.TrimSpace(cfg.StatePath) == "" {
		return nil, fmt.Errorf("state path is required")
	}
	return &FirecrackerManager{cfg: cfg, state: state}, nil
}

func (m *FirecrackerManager) StatePath() string {
	if m == nil {
		return ""
	}
	return m.cfg.StatePath
}

func (m *FirecrackerManager) Start(ctx context.Context) error {
	if m == nil || (len(m.cfg.Apps) == 0 && len(m.cfg.Services) == 0) {
		return nil
	}

	services := map[string]ServiceState{}
	for _, spec := range m.cfg.Services {
		state, vm, err := m.startService(ctx, spec)
		if err != nil {
			_ = m.Stop(context.Background())
			return err
		}
		m.vms = append(m.vms, vm)
		services[spec.Name] = state
	}

	apps := map[string]AppState{}
	for _, spec := range m.cfg.Apps {
		state, vm, err := m.startApp(ctx, spec, services)
		if err != nil {
			_ = m.Stop(context.Background())
			return err
		}
		m.vms = append(m.vms, vm)
		apps[spec.Name] = state
	}

	m.mu.Lock()
	m.state.Services = services
	m.state.Apps = apps
	m.mu.Unlock()
	return m.writeState()
}

func (m *FirecrackerManager) Stop(ctx context.Context) error {
	if m == nil {
		return nil
	}

	var firstErr error
	for i := len(m.vms) - 1; i >= 0; i-- {
		vm := m.vms[i]
		for _, closer := range vm.serviceBridges {
			if err := closer.Close(); err != nil && firstErr == nil {
				firstErr = err
			}
		}
		for _, closer := range vm.proxies {
			if err := closer.Close(); err != nil && firstErr == nil {
				firstErr = err
			}
		}
		if vm.machine != nil {
			shutdownCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
			_ = vm.machine.Shutdown(shutdownCtx)
			cancel()
			if err := vm.machine.StopVMM(); err != nil && firstErr == nil {
				firstErr = err
			}
			waitCtx, waitCancel := context.WithTimeout(context.Background(), 3*time.Second)
			_ = vm.machine.Wait(waitCtx)
			waitCancel()
		}
		if vm.vmDir != "" {
			if err := os.RemoveAll(vm.vmDir); err != nil && firstErr == nil {
				firstErr = err
			}
		}
	}
	m.vms = nil
	return firstErr
}

func (m *FirecrackerManager) writeState() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return WriteState(m.cfg.StatePath, m.state)
}

func (m *FirecrackerManager) startService(ctx context.Context, spec ServiceSpec) (ServiceState, managedVM, error) {
	serviceEnv := map[string]string{}
	for key, value := range spec.Env {
		serviceEnv[key] = value
	}
	bindings := []workloadServiceBinding{}
	boot := workloadBootConfig{
		Version: 1,
		Kind:    "service",
		Name:    spec.Name,
		Port:    spec.Port,
		Command: append([]string{}, spec.Command...),
		Env:     serviceEnv,
	}

	vm, bundle, hostPort, err := m.startVM(ctx, "service", spec.Name, spec.Image, spec.Dockerfile, spec.Port, spec.Volume, boot, bindings)
	if err != nil {
		return ServiceState{}, managedVM{}, err
	}

	service := ServiceState{
		Name:         spec.Name,
		Image:        spec.Image,
		ImageDigest:  bundle.BundleID,
		Host:         "127.0.0.1",
		Port:         hostPort,
		InternalHost: spec.Name + ".internal",
		InternalPort: spec.Port,
		Health:       WorkloadHealth{Up: true, Reason: "ok"},
		Volume:       spec.Volume,
	}
	service.URL = BuildServiceURL(spec.Name, service.Host, service.Port, spec.Env)
	service.InternalURL = BuildServiceURL(spec.Name, "127.0.0.1", spec.Port, spec.Env)
	service.FunctionEnv = BuildFunctionServiceEnv(spec.Name, service, spec.Env)

	if err := waitForEndpoint(service.Host, service.Port, effectiveHealthcheck(spec.Healthcheck), 30*time.Second); err != nil {
		service.Health = WorkloadHealth{Up: false, Reason: err.Error()}
	}

	vm.specName = spec.Name
	vm.kind = "service"
	vm.check = effectiveHealthcheck(spec.Healthcheck)
	return service, vm, nil
}

func (m *FirecrackerManager) startApp(ctx context.Context, spec AppSpec, services map[string]ServiceState) (AppState, managedVM, error) {
	appEnv := buildGuestLoopbackServiceEnv(services, spec.Env)
	bindings := buildGuestServiceBindings(services)
	boot := workloadBootConfig{
		Version:  1,
		Kind:     "app",
		Name:     spec.Name,
		Port:     spec.Port,
		Command:  append([]string{}, spec.Command...),
		Env:      appEnv,
		Services: bindings,
	}

	vm, bundle, hostPort, err := m.startVM(ctx, "app", spec.Name, spec.Image, spec.Dockerfile, spec.Port, spec.Volume, boot, bindings)
	if err != nil {
		return AppState{}, managedVM{}, err
	}

	app := AppState{
		Name:         spec.Name,
		Image:        spec.Image,
		ImageDigest:  bundle.BundleID,
		Host:         "127.0.0.1",
		Port:         hostPort,
		InternalPort: spec.Port,
		Routes:       append([]string{}, spec.Routes...),
		Health:       WorkloadHealth{Up: true, Reason: "ok"},
		Volume:       spec.Volume,
		Env:          spec.Env,
	}

	if err := waitForEndpoint(app.Host, app.Port, effectiveHealthcheck(spec.Healthcheck), 30*time.Second); err != nil {
		app.Health = WorkloadHealth{Up: false, Reason: err.Error()}
	}

	vm.specName = spec.Name
	vm.kind = "app"
	vm.check = effectiveHealthcheck(spec.Healthcheck)
	return app, vm, nil
}

func (m *FirecrackerManager) startVM(ctx context.Context, kind, name, imageRef, dockerfile string, internalPort int, volume *VolumeSpec, boot workloadBootConfig, services []workloadServiceBinding) (managedVM, FirecrackerBundle, int, error) {
	if strings.TrimSpace(dockerfile) != "" {
		return managedVM{}, FirecrackerBundle{}, 0, fmt.Errorf("%s.%s: dockerfile-based bundle conversion is not implemented yet; provide a Firecracker image bundle path in image", kind, name)
	}

	bundle, err := ResolveFirecrackerBundle(m.cfg.ProjectDir, imageRef)
	if err != nil {
		return managedVM{}, FirecrackerBundle{}, 0, fmt.Errorf("%s.%s: %w", kind, name, err)
	}

	vmDir := filepath.Join(filepath.Dir(m.cfg.StatePath), "firecracker-"+sanitizeName(kind)+"-"+sanitizeName(name)+"-"+shortHashFC(time.Now().UTC().String()))
	if err := os.MkdirAll(vmDir, 0o755); err != nil {
		return managedVM{}, FirecrackerBundle{}, 0, fmt.Errorf("create firecracker vm dir for %s.%s: %w", kind, name, err)
	}

	configDrivePath := filepath.Join(vmDir, "config.raw")
	if err := writeRawConfigDrive(configDrivePath, bundle.ConfigDriveBytes, boot); err != nil {
		return managedVM{}, FirecrackerBundle{}, 0, err
	}

	drives := firecracker.NewDrivesBuilder(bundle.RootFSPath).Build()
	drives = append(drives, models.Drive{
		DriveID:      firecracker.String("config"),
		PathOnHost:   firecracker.String(configDrivePath),
		IsReadOnly:   firecracker.Bool(true),
		IsRootDevice: firecracker.Bool(false),
	})
	if volume != nil {
		volumePath, err := ensureVolumeFile(m.cfg.ProjectDir, volume)
		if err != nil {
			return managedVM{}, FirecrackerBundle{}, 0, err
		}
		drives = append(drives, models.Drive{
			DriveID:      firecracker.String("data"),
			PathOnHost:   firecracker.String(volumePath),
			IsReadOnly:   firecracker.Bool(false),
			IsRootDevice: firecracker.Bool(false),
		})
	}

	socketPath := filepath.Join(vmDir, "api.sock")
	vsockPath := filepath.Join(vmDir, "vsock.sock")
	logPath := filepath.Join(vmDir, "firecracker.log")
	fcCfg := firecracker.Config{
		SocketPath:      socketPath,
		LogPath:         logPath,
		LogLevel:        "Info",
		KernelImagePath: bundle.KernelPath,
		KernelArgs:      bundle.KernelArgs,
		Drives:          drives,
		VsockDevices: []firecracker.VsockDevice{{
			ID:   "fastfn",
			Path: vsockPath,
			CID:  3,
		}},
		MachineCfg: models.MachineConfiguration{
			VcpuCount:  firecracker.Int64(bundle.VCPUCount),
			MemSizeMib: firecracker.Int64(bundle.MemoryMiB),
			HtEnabled:  firecracker.Bool(false),
		},
	}

	cmd := firecracker.VMCommandBuilder{}.
		WithBin(firecrackerBinary()).
		WithSocketPath(socketPath).
		Build(ctx)

	machine, err := firecracker.NewMachine(ctx, fcCfg, firecracker.WithProcessRunner(cmd))
	if err != nil {
		return managedVM{}, FirecrackerBundle{}, 0, fmt.Errorf("create firecracker machine for %s.%s: %w", kind, name, err)
	}
	if err := machine.Start(ctx); err != nil {
		return managedVM{}, FirecrackerBundle{}, 0, fmt.Errorf("start firecracker machine for %s.%s: %w", kind, name, err)
	}

	proxy, hostPort, err := startGuestTCPProxy(vsockPath, bundle.GuestPort)
	if err != nil {
		_ = machine.StopVMM()
		return managedVM{}, FirecrackerBundle{}, 0, fmt.Errorf("start host proxy for %s.%s: %w", kind, name, err)
	}

	vm := managedVM{
		kind:     kind,
		specName: name,
		vmDir:    vmDir,
		hostPort: hostPort,
		machine:  machine,
		proxies:  []io.Closer{proxy},
	}

	for _, service := range services {
		bridge, err := startHostServiceBridge(vsockPath, service.Port, net.JoinHostPort(service.Host, fmt.Sprintf("%d", service.Port)))
		if err != nil {
			_ = proxy.Close()
			_ = machine.StopVMM()
			return managedVM{}, FirecrackerBundle{}, 0, fmt.Errorf("start host service bridge for %s.%s: %w", kind, name, err)
		}
		vm.serviceBridges = append(vm.serviceBridges, bridge)
	}

	_ = internalPort
	return vm, bundle, hostPort, nil
}

func buildGuestLoopbackServiceEnv(services map[string]ServiceState, baseEnv map[string]string) map[string]string {
	out := map[string]string{}
	for key, value := range baseEnv {
		out[key] = value
	}

	names := make([]string, 0, len(services))
	for name := range services {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, serviceName := range names {
		service := services[serviceName]
		upper := strings.ToUpper(strings.ReplaceAll(serviceName, "-", "_"))
		out["SERVICE_"+upper+"_HOST"] = "127.0.0.1"
		out["SERVICE_"+upper+"_PORT"] = fmt.Sprintf("%d", service.InternalPort)
		out["SERVICE_"+upper+"_URL"] = BuildServiceURL(serviceName, "127.0.0.1", service.InternalPort, service.FunctionEnv)

		switch strings.ToLower(serviceName) {
		case "mysql":
			out["MYSQL_HOST"] = "127.0.0.1"
			out["MYSQL_PORT"] = fmt.Sprintf("%d", service.InternalPort)
			out["MYSQL_URL"] = BuildServiceURL(serviceName, "127.0.0.1", service.InternalPort, service.FunctionEnv)
		case "postgres", "postgresql":
			out["POSTGRES_HOST"] = "127.0.0.1"
			out["POSTGRES_PORT"] = fmt.Sprintf("%d", service.InternalPort)
			out["POSTGRES_URL"] = BuildServiceURL(serviceName, "127.0.0.1", service.InternalPort, service.FunctionEnv)
		case "redis":
			out["REDIS_HOST"] = "127.0.0.1"
			out["REDIS_PORT"] = fmt.Sprintf("%d", service.InternalPort)
			out["REDIS_URL"] = BuildServiceURL(serviceName, "127.0.0.1", service.InternalPort, service.FunctionEnv)
		}
	}
	return out
}

func buildGuestServiceBindings(services map[string]ServiceState) []workloadServiceBinding {
	names := make([]string, 0, len(services))
	for name := range services {
		names = append(names, name)
	}
	sort.Strings(names)

	out := make([]workloadServiceBinding, 0, len(names))
	for _, name := range names {
		service := services[name]
		out = append(out, workloadServiceBinding{
			Name: name,
			Host: "127.0.0.1",
			Port: service.InternalPort,
			URL:  BuildServiceURL(name, "127.0.0.1", service.InternalPort, service.FunctionEnv),
		})
	}
	return out
}

func writeRawConfigDrive(path string, size int64, boot workloadBootConfig) error {
	if size < 4096 {
		size = defaultConfigDriveBytes
	}
	payload, err := json.MarshalIndent(boot, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal firecracker workload config for %s: %w", boot.Name, err)
	}
	if int64(len(payload)+1) > size {
		return fmt.Errorf("firecracker workload config for %s exceeds config drive size (%d bytes)", boot.Name, size)
	}
	raw := make([]byte, size)
	copy(raw, payload)
	file, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("create firecracker config drive for %s: %w", boot.Name, err)
	}
	defer file.Close()
	if _, err := file.Write(raw); err != nil {
		return fmt.Errorf("write firecracker config drive for %s: %w", boot.Name, err)
	}
	return nil
}

func ensureVolumeFile(projectDir string, volume *VolumeSpec) (string, error) {
	baseDir := filepath.Join(projectDir, ".fastfn", "firecracker-volumes")
	if err := os.MkdirAll(baseDir, 0o755); err != nil {
		return "", fmt.Errorf("create firecracker volumes dir: %w", err)
	}
	path := filepath.Join(baseDir, sanitizeName(volume.Name)+".img")
	if _, err := os.Stat(path); os.IsNotExist(err) {
		file, createErr := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
		if createErr != nil {
			return "", fmt.Errorf("create firecracker volume %s: %w", volume.Name, createErr)
		}
		if err := file.Truncate(defaultVolumeBytes); err != nil {
			_ = file.Close()
			return "", fmt.Errorf("size firecracker volume %s: %w", volume.Name, err)
		}
		if err := file.Close(); err != nil {
			return "", fmt.Errorf("close firecracker volume %s: %w", volume.Name, err)
		}
	} else if err != nil {
		return "", fmt.Errorf("stat firecracker volume %s: %w", volume.Name, err)
	}
	return path, nil
}

func firecrackerBinary() string {
	if configured := strings.TrimSpace(os.Getenv("FN_FIRECRACKER_BIN")); configured != "" {
		return configured
	}
	return defaultFirecrackerBin
}

func startGuestTCPProxy(vsockPath string, guestPort int) (io.Closer, int, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, 0, err
	}
	hostPort := listener.Addr().(*net.TCPAddr).Port

	go serveGuestTCPProxy(listener, vsockPath, guestPort)
	return listener, hostPort, nil
}

func serveGuestTCPProxy(listener net.Listener, vsockPath string, guestPort int) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		go func(clientConn net.Conn) {
			defer clientConn.Close()
			guestConn, err := net.Dial("unix", vsockPath)
			if err != nil {
				return
			}
			defer guestConn.Close()
			if _, err := fmt.Fprintf(guestConn, "CONNECT %d\n", guestPort); err != nil {
				return
			}
			copyBidirectional(clientConn, guestConn)
		}(conn)
	}
}

func startHostServiceBridge(vsockPath string, guestPort int, targetAddr string) (io.Closer, error) {
	path := fmt.Sprintf("%s_%d", vsockPath, guestPort)
	_ = os.Remove(path)
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	go serveHostServiceBridge(listener, targetAddr)
	return &hostBridgeCloser{Listener: listener, path: path}, nil
}

type hostBridgeCloser struct {
	net.Listener
	path string
}

func (c *hostBridgeCloser) Close() error {
	err := c.Listener.Close()
	_ = os.Remove(c.path)
	return err
}

func serveHostServiceBridge(listener net.Listener, targetAddr string) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		go func(clientConn net.Conn) {
			defer clientConn.Close()
			targetConn, err := net.Dial("tcp", targetAddr)
			if err != nil {
				return
			}
			defer targetConn.Close()
			copyBidirectional(clientConn, targetConn)
		}(conn)
	}
}

func copyBidirectional(left net.Conn, right net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(left, right)
		if closer, ok := left.(interface{ CloseWrite() error }); ok {
			_ = closer.CloseWrite()
		}
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(right, left)
		if closer, ok := right.(interface{ CloseWrite() error }); ok {
			_ = closer.CloseWrite()
		}
	}()
	wg.Wait()
}
