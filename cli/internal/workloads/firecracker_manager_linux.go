//go:build linux

package workloads

import (
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
	defaultVolumeBytes    int64 = 1 * 1024 * 1024 * 1024
	guestServiceVsockBase       = 30000
)

type FirecrackerManager struct {
	cfg             ManagerConfig
	mu              sync.Mutex
	state           State
	controllers     map[string]*workloadController
	controllerOrder []*workloadController
}

type managedVM struct {
	kind           string
	specName       string
	vmDir          string
	hostPort       int
	vsockPath      string
	guestPort      int
	internalHost   string
	debugSSH       *WorkloadDebugSSH
	check          HealthcheckSpec
	machine        *firecracker.Machine
	proxies        []io.Closer
	serviceBridges []io.Closer
}

type workloadBootConfig struct {
	Version      int                      `json:"version"`
	Kind         string                   `json:"kind"`
	Name         string                   `json:"name"`
	Debug        bool                     `json:"debug,omitempty"`
	EntropySeed  string                   `json:"entropy_seed,omitempty"`
	DebugSSH     *workloadDebugSSHConfig  `json:"debug_ssh,omitempty"`
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

type workloadDebugSSHConfig struct {
	GuestPort     int    `json:"guest_port,omitempty"`
	LocalPort     int    `json:"local_port,omitempty"`
	User          string `json:"user,omitempty"`
	AuthorizedKey string `json:"authorized_key,omitempty"`
	HostKeyPEM    string `json:"host_key_pem,omitempty"`
}

type workloadServiceBridgeTarget struct {
	VsockPort       int
	TargetKind      string
	TargetName      string
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

func firecrackerDebugEnabled() bool {
	value := strings.ToLower(strings.TrimSpace(os.Getenv("FN_FIRECRACKER_DEBUG")))
	switch value {
	case "1", "true", "yes", "on", "debug":
		return true
	default:
		return false
	}
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

	controllers := make(map[string]*workloadController, len(plans))
	order := make([]*workloadController, 0, len(plans))
	for _, plan := range plans {
		controller := newWorkloadController(m, plan)
		controllers[workloadPlanKey(plan.Kind, plan.Name)] = controller
		order = append(order, controller)
	}

	m.mu.Lock()
	m.controllers = controllers
	m.controllerOrder = order
	m.mu.Unlock()
	for _, controller := range order {
		if err := controller.Start(ctx); err != nil {
			_ = m.Stop(context.Background())
			return err
		}
	}
	return m.writeState()
}

func (m *FirecrackerManager) Stop(ctx context.Context) error {
	if m == nil {
		return nil
	}

	var firstErr error
	m.mu.Lock()
	order := append([]*workloadController(nil), m.controllerOrder...)
	m.mu.Unlock()
	for i := len(order) - 1; i >= 0; i-- {
		if err := order[i].Stop(ctx); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	m.mu.Lock()
	m.controllers = nil
	m.controllerOrder = nil
	m.state = State{
		Apps:     map[string]AppState{},
		Services: map[string]ServiceState{},
	}
	m.mu.Unlock()
	return firstErr
}

func (m *FirecrackerManager) writeState() error {
	if m == nil {
		return nil
	}
	state := State{
		Apps:     map[string]AppState{},
		Services: map[string]ServiceState{},
	}
	m.mu.Lock()
	order := append([]*workloadController(nil), m.controllerOrder...)
	m.mu.Unlock()
	for _, controller := range order {
		kind, name, snapshot := controller.snapshotState()
		if kind == "" || name == "" {
			continue
		}
		switch kind {
		case "service":
			state.Services[name] = snapshot.service
		case "app":
			state.Apps[name] = snapshot.app
		}
	}
	m.mu.Lock()
	m.state = state
	m.mu.Unlock()
	return WriteState(m.cfg.StatePath, state)
}

func (m *FirecrackerManager) controllerFor(kind, name string) (*workloadController, bool) {
	if m == nil {
		return nil, false
	}
	key := workloadPlanKey(kind, name)
	m.mu.Lock()
	defer m.mu.Unlock()
	controller, ok := m.controllers[key]
	return controller, ok
}

func (m *FirecrackerManager) dialBridgeTarget(ctx context.Context, kind, name string) (net.Conn, func(), error) {
	controller, ok := m.controllerFor(kind, name)
	if !ok {
		return nil, nil, fmt.Errorf("bridge target %s.%s is not registered", kind, name)
	}
	return controller.AcquireConnection(ctx)
}

func stopManagedVM(ctx context.Context, vm managedVM) error {
	var firstErr error
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
	return firstErr
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
			DebugSSH:     cloneDebugSSH(vm.debugSSH),
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
			DebugSSH:     cloneDebugSSH(vm.debugSSH),
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
		bridgeTarget := target
		bridge, err := startHostServiceBridge(plan.VsockPath, target.VsockPort, func(handlerCtx context.Context) (net.Conn, func(), error) {
			return m.dialBridgeTarget(handlerCtx, bridgeTarget.TargetKind, bridgeTarget.TargetName)
		})
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
	machine.Handlers.FcInit = machine.Handlers.FcInit.AppendAfter(firecracker.CreateMachineHandlerName, firecracker.Handler{
		Name: "fastfn.ConfigureEntropy",
		Fn: func(handlerCtx context.Context, _ *firecracker.Machine) error {
			return putEntropyDevice(handlerCtx, plan.SocketPath)
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

	var debugSSHState *WorkloadDebugSSH
	proxies := []io.Closer{proxy, consoleFile}
	if plan.DebugSSH != nil {
		debugProxy, debugHostPort, err := startGuestTCPProxy(plan.VsockPath, plan.DebugSSH.GuestPort)
		if err != nil {
			_ = proxy.Close()
			_ = machine.StopVMM()
			for _, closer := range bridgeClosers {
				_ = closer.Close()
			}
			_ = consoleFile.Close()
			return managedVM{}, 0, fmt.Errorf("start debug ssh proxy for %s.%s: %w", plan.Kind, plan.Name, err)
		}
		proxies = append(proxies, debugProxy)
		debugSSHState = &WorkloadDebugSSH{
			Host:    "127.0.0.1",
			Port:    debugHostPort,
			User:    plan.DebugSSH.User,
			KeyPath: plan.DebugSSH.PrivateKeyPath,
		}
	}

	vm := managedVM{
		kind:           plan.Kind,
		specName:       plan.Name,
		vmDir:          plan.VMDir,
		hostPort:       hostPort,
		vsockPath:      plan.VsockPath,
		guestPort:      plan.Bundle.GuestPort,
		internalHost:   plan.InternalHost,
		debugSSH:       debugSSHState,
		machine:        machine,
		proxies:        proxies,
		serviceBridges: bridgeClosers,
	}
	return vm, hostPort, nil
}

func buildWorkloadDebugSSHConfig(cfg *workloadDebugSSH) *workloadDebugSSHConfig {
	if cfg == nil {
		return nil
	}
	return &workloadDebugSSHConfig{
		GuestPort:     cfg.GuestPort,
		LocalPort:     cfg.LocalPort,
		User:          cfg.User,
		AuthorizedKey: cfg.AuthorizedKey,
		HostKeyPEM:    cfg.HostKeyPEM,
	}
}

func cloneDebugSSH(cfg *WorkloadDebugSSH) *WorkloadDebugSSH {
	if cfg == nil {
		return nil
	}
	out := *cfg
	return &out
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
		cmd := exec.Command(
			"mke2fs",
			"-q",
			"-t", "ext4",
			"-m", "0",
			"-E", "lazy_itable_init=0,lazy_journal_init=0",
			"-F",
			path,
			fmt.Sprintf("%d", blocks),
		)
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
	line, err := readVsockConnectAck(conn)
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

func readVsockConnectAck(conn net.Conn) (string, error) {
	var line []byte
	for len(line) < 64 {
		var chunk [1]byte
		if _, err := conn.Read(chunk[:]); err != nil {
			return "", err
		}
		line = append(line, chunk[0])
		if chunk[0] == '\n' {
			return string(line), nil
		}
	}
	return "", fmt.Errorf("vsock ack exceeded %d bytes", 64)
}

type bridgeDialFunc func(context.Context) (net.Conn, func(), error)

func startHostServiceBridge(vsockPath string, guestPort int, dialTarget bridgeDialFunc) (io.Closer, error) {
	path := fmt.Sprintf("%s_%d", vsockPath, guestPort)
	_ = os.Remove(path)
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	go serveHostServiceBridge(listener, dialTarget)
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

func serveHostServiceBridge(listener net.Listener, dialTarget bridgeDialFunc) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		go func(clientConn net.Conn) {
			defer clientConn.Close()
			targetConn, releaseTarget, err := dialTarget(context.Background())
			if err != nil {
				return
			}
			defer releaseTarget()
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
	return putFirecrackerJSON(ctx, socketPath, "/machine-config", map[string]any{
		"vcpu_count":   vcpuCount,
		"mem_size_mib": memoryMiB,
		"smt":          false,
	})
}

func putEntropyDevice(ctx context.Context, socketPath string) error {
	return putFirecrackerJSON(ctx, socketPath, "/entropy", map[string]any{})
}

func putFirecrackerJSON(ctx context.Context, socketPath string, resourcePath string, body any) error {
	payload, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal firecracker request %s: %w", resourcePath, err)
	}

	transport := &http.Transport{
		DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
			return net.Dial("unix", socketPath)
		},
	}
	defer transport.CloseIdleConnections()

	client := &http.Client{Transport: transport}
	request, err := http.NewRequestWithContext(ctx, http.MethodPut, "http://unix"+resourcePath, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("create firecracker request %s: %w", resourcePath, err)
	}
	request.Header.Set("Content-Type", "application/json")

	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("put firecracker %s: %w", resourcePath, err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		body, _ := io.ReadAll(response.Body)
		return fmt.Errorf("put firecracker %s: status %d: %s", resourcePath, response.StatusCode, strings.TrimSpace(string(body)))
	}
	return nil
}
