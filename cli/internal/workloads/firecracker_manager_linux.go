//go:build linux

package workloads

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	firecracker "github.com/firecracker-microvm/firecracker-go-sdk"
	models "github.com/firecracker-microvm/firecracker-go-sdk/client/models"
)

const (
	defaultFirecrackerBin       = "firecracker"
	defaultVolumeBytes    int64 = 10 * 1024 * 1024 * 1024
	guestServiceVsockBase       = 30000
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
	vsockPath      string
	guestPort      int
	internalHost   string
	check          HealthcheckSpec
	machine        *firecracker.Machine
	proxies        []io.Closer
	serviceBridges []io.Closer
}

type workloadBootConfig struct {
	Version      int                      `json:"version"`
	Kind         string                   `json:"kind"`
	Name         string                   `json:"name"`
	ProcessGroup string                   `json:"process_group,omitempty"`
	Replica      int                      `json:"replica,omitempty"`
	Port         int                      `json:"port,omitempty"`
	Command      []string                 `json:"command,omitempty"`
	Env          map[string]string        `json:"env,omitempty"`
	WorkingDir   string                   `json:"working_dir,omitempty"`
	User         string                   `json:"user,omitempty"`
	InboundPorts []workloadInboundPort    `json:"inbound_ports,omitempty"`
	Services     []workloadServiceBinding `json:"services,omitempty"`
	Volumes      []workloadVolumeMount    `json:"volumes,omitempty"`
}

type workloadInboundPort struct {
	Name          string `json:"name"`
	Protocol      string `json:"protocol,omitempty"`
	GuestPort     int    `json:"guest_port"`
	ContainerPort int    `json:"container_port"`
}

type workloadServiceBinding struct {
	Name      string `json:"name"`
	LocalHost string `json:"local_host,omitempty"`
	LocalIP   string `json:"local_ip,omitempty"`
	LocalPort int    `json:"local_port"`
	VsockPort int    `json:"vsock_port"`
	URL       string `json:"url,omitempty"`
}

type workloadVolumeMount struct {
	Name   string `json:"name"`
	Target string `json:"target"`
	Device string `json:"device"`
}

type workloadServiceBridgeTarget struct {
	VsockPort       int
	TargetVsockPath string
	TargetGuestPort int
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

	plans, err := m.planWorkloads(ctx)
	if err != nil {
		return err
	}

	services := map[string]ServiceState{}
	apps := map[string]AppState{}
	for _, plan := range plans {
		serviceState, appState, vm, err := m.startPlannedWorkload(ctx, plan)
		if err != nil {
			_ = m.Stop(context.Background())
			return err
		}
		m.vms = append(m.vms, vm)
		switch plan.Kind {
		case "service":
			services[plan.Name] = serviceState
		case "app":
			apps[plan.Name] = appState
		}
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

func (m *FirecrackerManager) startPlannedWorkload(ctx context.Context, plan workloadPlan) (ServiceState, AppState, managedVM, error) {
	vm, hostPort, err := m.startVMWithBundle(ctx, plan)
	if err != nil {
		return ServiceState{}, AppState{}, managedVM{}, err
	}

	switch plan.Kind {
	case "service":
		service := ServiceState{
			Name:         plan.Name,
			Image:        plan.Image,
			ImageDigest:  plan.Bundle.BundleID,
			Host:         "127.0.0.1",
			Port:         hostPort,
			InternalHost: plan.InternalHost,
			InternalPort: plan.InternalPort,
			InternalURL:  plan.InternalURL,
			Health:       WorkloadHealth{Up: true, Reason: "ok"},
			Volume:       plan.Volume,
			BaseEnv:      cloneEnvMap(plan.SpecEnv),
		}
		service.URL = BuildServiceURL(plan.Name, service.Host, service.Port, plan.SpecEnv)
		service.FunctionEnv = BuildFunctionServiceEnv(plan.Name, service, plan.SpecEnv)
		if err := waitForEndpoint(service.Host, service.Port, plan.Healthcheck, 30*time.Second); err != nil {
			service.Health = WorkloadHealth{Up: false, Reason: err.Error()}
		}
		vm.specName = plan.Name
		vm.kind = plan.Kind
		vm.check = plan.Healthcheck
		return service, AppState{}, vm, nil
	case "app":
		app := AppState{
			Name:         plan.Name,
			Image:        plan.Image,
			ImageDigest:  plan.Bundle.BundleID,
			Host:         "127.0.0.1",
			Port:         hostPort,
			InternalHost: plan.InternalHost,
			InternalPort: plan.InternalPort,
			InternalURL:  plan.InternalURL,
			Routes:       append([]string{}, plan.Routes...),
			Health:       WorkloadHealth{Up: true, Reason: "ok"},
			Volume:       plan.Volume,
			Env:          cloneEnvMap(plan.SpecEnv),
		}
		if err := waitForEndpoint(app.Host, app.Port, plan.Healthcheck, 30*time.Second); err != nil {
			app.Health = WorkloadHealth{Up: false, Reason: err.Error()}
		}
		vm.specName = plan.Name
		vm.kind = plan.Kind
		vm.check = plan.Healthcheck
		return ServiceState{}, app, vm, nil
	default:
		return ServiceState{}, AppState{}, managedVM{}, fmt.Errorf("unknown workload kind %q", plan.Kind)
	}
}

func (m *FirecrackerManager) startVMWithBundle(ctx context.Context, plan workloadPlan) (managedVM, int, error) {
	if err := writeRawConfigDrive(plan.ConfigDrive, plan.Bundle.ConfigDriveBytes, plan.Boot); err != nil {
		return managedVM{}, 0, err
	}

	drives := firecracker.NewDrivesBuilder(plan.Bundle.RootFSPath).Build()
	drives = append(drives, models.Drive{
		DriveID:      firecracker.String("config"),
		PathOnHost:   firecracker.String(plan.ConfigDrive),
		IsReadOnly:   firecracker.Bool(true),
		IsRootDevice: firecracker.Bool(false),
	})
	if plan.Volume != nil {
		volumePath, err := ensureVolumeFile(m.cfg.ProjectDir, plan.Volume)
		if err != nil {
			return managedVM{}, 0, err
		}
		drives = append(drives, models.Drive{
			DriveID:      firecracker.String("data"),
			PathOnHost:   firecracker.String(volumePath),
			IsReadOnly:   firecracker.Bool(false),
			IsRootDevice: firecracker.Bool(false),
		})
	}

	bridgeClosers := make([]io.Closer, 0, len(plan.Bridges))
	for _, target := range plan.Bridges {
		bridge, err := startHostServiceBridge(plan.VsockPath, target.VsockPort, target.TargetVsockPath, target.TargetGuestPort)
		if err != nil {
			for _, closer := range bridgeClosers {
				_ = closer.Close()
			}
			return managedVM{}, 0, fmt.Errorf("start host service bridge for %s.%s: %w", plan.Kind, plan.Name, err)
		}
		bridgeClosers = append(bridgeClosers, bridge)
	}

	consoleFile, err := os.OpenFile(plan.ConsolePath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		for _, closer := range bridgeClosers {
			_ = closer.Close()
		}
		return managedVM{}, 0, fmt.Errorf("create console log for %s.%s: %w", plan.Kind, plan.Name, err)
	}
	fcCfg := firecracker.Config{
		SocketPath:        plan.SocketPath,
		LogPath:           plan.LogPath,
		LogLevel:          "Info",
		DisableValidation: true,
		KernelImagePath:   plan.Bundle.KernelPath,
		KernelArgs:        plan.Bundle.KernelArgs,
		Drives:            drives,
		VsockDevices: []firecracker.VsockDevice{{
			ID:   "fastfn",
			Path: plan.VsockPath,
			CID:  3,
		}},
		MachineCfg: models.MachineConfiguration{
			VcpuCount:  firecracker.Int64(plan.Bundle.VCPUCount),
			MemSizeMib: firecracker.Int64(plan.Bundle.MemoryMiB),
		},
	}

	cmd := firecracker.VMCommandBuilder{}.
		WithBin(firecrackerBinary()).
		WithSocketPath(plan.SocketPath).
		WithStdout(consoleFile).
		WithStderr(consoleFile).
		Build(ctx)

	machine, err := firecracker.NewMachine(ctx, fcCfg, firecracker.WithProcessRunner(cmd))
	if err != nil {
		for _, closer := range bridgeClosers {
			_ = closer.Close()
		}
		_ = consoleFile.Close()
		return managedVM{}, 0, fmt.Errorf("create firecracker machine for %s.%s: %w", plan.Kind, plan.Name, err)
	}
	machine.Handlers.FcInit = machine.Handlers.FcInit.Swap(firecracker.Handler{
		Name: firecracker.CreateMachineHandlerName,
		Fn: func(handlerCtx context.Context, _ *firecracker.Machine) error {
			return putMachineConfigSMT(handlerCtx, plan.SocketPath, plan.Bundle.VCPUCount, plan.Bundle.MemoryMiB)
		},
	})
	if err := machine.Start(ctx); err != nil {
		for _, closer := range bridgeClosers {
			_ = closer.Close()
		}
		_ = consoleFile.Close()
		return managedVM{}, 0, fmt.Errorf("start firecracker machine for %s.%s: %w", plan.Kind, plan.Name, err)
	}

	proxy, hostPort, err := startGuestTCPProxy(plan.VsockPath, plan.Bundle.GuestPort)
	if err != nil {
		_ = machine.StopVMM()
		for _, closer := range bridgeClosers {
			_ = closer.Close()
		}
		_ = consoleFile.Close()
		return managedVM{}, 0, fmt.Errorf("start host proxy for %s.%s: %w", plan.Kind, plan.Name, err)
	}

	vm := managedVM{
		kind:           plan.Kind,
		specName:       plan.Name,
		vmDir:          plan.VMDir,
		hostPort:       hostPort,
		vsockPath:      plan.VsockPath,
		guestPort:      plan.Bundle.GuestPort,
		internalHost:   plan.InternalHost,
		machine:        machine,
		proxies:        []io.Closer{proxy, consoleFile},
		serviceBridges: bridgeClosers,
	}
	return vm, hostPort, nil
}

func scopeContains(parent, child string) bool {
	parent = strings.TrimSpace(parent)
	child = strings.TrimSpace(child)
	if parent == "" || child == "" {
		return true
	}
	parent = filepath.Clean(parent)
	child = filepath.Clean(child)
	if parent == child {
		return true
	}
	if !strings.HasSuffix(parent, string(os.PathSeparator)) {
		parent += string(os.PathSeparator)
	}
	return strings.HasPrefix(child+string(os.PathSeparator), parent)
}

func mergeWorkloadEnv(defaults, overrides map[string]string) map[string]string {
	if len(defaults) == 0 && len(overrides) == 0 {
		return nil
	}
	out := map[string]string{}
	for key, value := range defaults {
		out[key] = value
	}
	for key, value := range overrides {
		out[key] = value
	}
	return out
}

func defaultWorkloadCommand(command, fallback []string) []string {
	if len(command) > 0 {
		return append([]string{}, command...)
	}
	return append([]string{}, fallback...)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func buildInboundPorts(guestPort int, ports []PortSpec) []workloadInboundPort {
	if guestPort < 1 || len(ports) == 0 {
		return nil
	}
	primary := ports[0]
	for _, port := range ports {
		if port.Public {
			primary = port
			break
		}
	}
	return []workloadInboundPort{{
		Name:          primary.Name,
		Protocol:      primary.Protocol,
		GuestPort:     guestPort,
		ContainerPort: primary.ContainerPort,
	}}
}

func buildVolumeMounts(volume *VolumeSpec) []workloadVolumeMount {
	if volume == nil {
		return nil
	}
	return []workloadVolumeMount{{
		Name:   volume.Name,
		Target: volume.Target,
		Device: "/dev/vdc",
	}}
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
		blocks := defaultVolumeBytes / 1024
		cmd := exec.Command("mke2fs", "-q", "-t", "ext4", "-F", path, fmt.Sprintf("%d", blocks))
		if output, err := cmd.CombinedOutput(); err != nil {
			return "", fmt.Errorf("format firecracker volume %s: %w: %s", volume.Name, err, strings.TrimSpace(string(output)))
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
			guestConn, err := dialGuestVsock(vsockPath, guestPort)
			if err != nil {
				return
			}
			defer guestConn.Close()
			copyBidirectional(clientConn, guestConn)
		}(conn)
	}
}

func dialGuestVsock(vsockPath string, guestPort int) (net.Conn, error) {
	conn, err := net.DialTimeout("unix", vsockPath, 2*time.Second)
	if err != nil {
		return nil, err
	}

	// Firecracker documents a host-initiated vsock handshake on the UDS:
	// write "CONNECT <port>\n", then consume the "OK <port>\n" ack before
	// treating the socket as the proxied data stream.
	if err := conn.SetDeadline(time.Now().Add(1 * time.Second)); err != nil {
		_ = conn.Close()
		return nil, err
	}
	if _, err := fmt.Fprintf(conn, "CONNECT %d\n", guestPort); err != nil {
		_ = conn.Close()
		return nil, err
	}
	line, err := bufio.NewReaderSize(conn, 32).ReadString('\n')
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	if err := conn.SetDeadline(time.Time{}); err != nil {
		_ = conn.Close()
		return nil, err
	}
	if !strings.HasPrefix(line, "OK ") {
		_ = conn.Close()
		return nil, fmt.Errorf("unexpected vsock ack for guest port %d: %q", guestPort, strings.TrimSpace(line))
	}
	return conn, nil
}

func startHostServiceBridge(vsockPath string, guestPort int, targetVsockPath string, targetGuestPort int) (io.Closer, error) {
	path := fmt.Sprintf("%s_%d", vsockPath, guestPort)
	_ = os.Remove(path)
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	go serveHostServiceBridge(listener, targetVsockPath, targetGuestPort)
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

func serveHostServiceBridge(listener net.Listener, targetVsockPath string, targetGuestPort int) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		go func(clientConn net.Conn) {
			defer clientConn.Close()
			targetConn, err := dialGuestVsock(targetVsockPath, targetGuestPort)
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

func putMachineConfigSMT(ctx context.Context, socketPath string, vcpuCount, memoryMiB int64) error {
	payload, err := json.Marshal(map[string]any{
		"vcpu_count":   vcpuCount,
		"mem_size_mib": memoryMiB,
		"smt":          false,
	})
	if err != nil {
		return fmt.Errorf("marshal firecracker machine config: %w", err)
	}

	transport := &http.Transport{
		DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
			return net.Dial("unix", socketPath)
		},
	}
	defer transport.CloseIdleConnections()

	client := &http.Client{Transport: transport}
	request, err := http.NewRequestWithContext(ctx, http.MethodPut, "http://unix/machine-config", bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("create firecracker machine-config request: %w", err)
	}
	request.Header.Set("Content-Type", "application/json")

	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("put firecracker machine-config: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		body, _ := io.ReadAll(response.Body)
		return fmt.Errorf("put firecracker machine-config: status %d: %s", response.StatusCode, strings.TrimSpace(string(body)))
	}
	return nil
}
