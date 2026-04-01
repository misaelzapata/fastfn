//go:build linux

package workloads

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"sync"
	"time"
)

const defaultAcquireDialTimeout = 2 * time.Second
const defaultServiceReadyWindow = 5 * time.Second

var (
	controllerPatchFirecrackerVMState = patchFirecrackerVMState
	controllerDialTarget              = func(ctx context.Context, address string, timeout time.Duration) (net.Conn, error) {
		dialer := &net.Dialer{Timeout: timeout}
		return dialer.DialContext(ctx, "tcp", address)
	}
	controllerWaitForEndpoint       = waitForEndpoint
	controllerWaitForEndpointStable = waitForEndpointStable
)

type workloadController struct {
	manager *FirecrackerManager
	plan    workloadPlan

	mu              sync.Mutex
	vm              managedVM
	broker          net.Listener
	publicListeners []publicEndpointListener
	brokerHost      string
	brokerPort      int
	health          WorkloadHealth
	lifecycleState  string
	paused          bool
	inflight        int
	stopping        bool
	started         bool
	pauseTimer      *time.Timer
	resumeCount     int
	lastResumeMS    int64
}

type publicEndpointListener struct {
	plan         publicEndpointPlan
	listener     net.Listener
	host         string
	port         int
	cidrPrefixes []netip.Prefix
}

type workloadStateSnapshot struct {
	app     AppState
	service ServiceState
}

func newWorkloadController(manager *FirecrackerManager, plan workloadPlan) *workloadController {
	return &workloadController{
		manager:        manager,
		plan:           plan,
		health:         WorkloadHealth{Up: false, Reason: "booting"},
		lifecycleState: "building",
	}
}

func (c *workloadController) Start(ctx context.Context) error {
	if c == nil {
		return nil
	}

	c.mu.Lock()
	c.lifecycleState = "booting"
	c.mu.Unlock()

	vm, _, err := c.manager.startVMWithBundle(ctx, c.plan)
	if err != nil {
		c.mu.Lock()
		c.health = WorkloadHealth{Up: false, Reason: err.Error()}
		c.lifecycleState = "failed"
		c.mu.Unlock()
		_ = c.manager.writeState()
		return err
	}

	broker, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		_ = stopManagedVM(context.Background(), vm)
		c.mu.Lock()
		c.health = WorkloadHealth{Up: false, Reason: err.Error()}
		c.lifecycleState = "failed"
		c.mu.Unlock()
		_ = c.manager.writeState()
		return fmt.Errorf("start workload broker for %s.%s: %w", c.plan.Kind, c.plan.Name, err)
	}

	hostPort := broker.Addr().(*net.TCPAddr).Port
	c.mu.Lock()
	c.vm = vm
	c.broker = broker
	c.brokerHost = "127.0.0.1"
	c.brokerPort = hostPort
	c.started = true
	c.lifecycleState = "ready"
	c.health = WorkloadHealth{Up: true, Reason: "ok"}
	c.mu.Unlock()

	go c.serveBroker(broker)

	publicListeners, err := c.startPublicListeners()
	if err != nil {
		_ = broker.Close()
		_ = stopManagedVM(context.Background(), vm)
		c.mu.Lock()
		c.health = WorkloadHealth{Up: false, Reason: err.Error()}
		c.lifecycleState = "failed"
		c.mu.Unlock()
		_ = c.manager.writeState()
		return err
	}
	c.mu.Lock()
	c.publicListeners = publicListeners
	c.mu.Unlock()

	if err := c.finishInitialHealthCheck(hostPort, nil); err != nil {
		c.cleanupFailedStart(vm, broker, publicListeners)
		_ = c.manager.writeState()
		return err
	}

	if err := c.manager.writeState(); err != nil {
		return err
	}

	c.schedulePauseIfIdle()
	return nil
}

func (c *workloadController) finishInitialHealthCheck(hostPort int, initialErr error) error {
	err := initialErr
	if err == nil {
		timeout := 30 * time.Second
		stableFor := c.initialHealthStableWindow()
		if stableFor > 0 {
			err = controllerWaitForEndpointStable("127.0.0.1", hostPort, c.plan.Healthcheck, timeout, stableFor)
		} else {
			err = controllerWaitForEndpoint("127.0.0.1", hostPort, c.plan.Healthcheck, timeout)
		}
	}
	if err == nil {
		c.mu.Lock()
		c.health = WorkloadHealth{Up: true, Reason: "ok"}
		c.mu.Unlock()
		return nil
	}

	c.mu.Lock()
	c.health = WorkloadHealth{Up: false, Reason: err.Error()}
	if c.plan.Lifecycle.Prewarm {
		c.lifecycleState = "failed"
	}
	c.mu.Unlock()
	if c.plan.Lifecycle.Prewarm {
		return fmt.Errorf("prewarm %s.%s: %w", c.plan.Kind, c.plan.Name, err)
	}
	return nil
}

func (c *workloadController) initialHealthStableWindow() time.Duration {
	if c == nil || c.plan.Kind != "service" || !c.plan.Lifecycle.Prewarm {
		return 0
	}
	window := time.Duration(c.plan.Healthcheck.IntervalMS) * time.Millisecond * 5
	if window < defaultServiceReadyWindow {
		window = defaultServiceReadyWindow
	}
	return window
}

func (c *workloadController) cleanupFailedStart(vm managedVM, broker net.Listener, publicListeners []publicEndpointListener) {
	if broker != nil {
		_ = broker.Close()
	}
	for _, endpoint := range publicListeners {
		if endpoint.listener != nil {
			_ = endpoint.listener.Close()
		}
	}
	_ = stopManagedVM(context.Background(), vm)

	c.mu.Lock()
	c.vm = managedVM{}
	c.broker = nil
	c.publicListeners = nil
	c.started = false
	c.mu.Unlock()
}

func (c *workloadController) Stop(ctx context.Context) error {
	if c == nil {
		return nil
	}

	c.mu.Lock()
	if c.stopping {
		c.mu.Unlock()
		return nil
	}
	c.stopping = true
	if c.pauseTimer != nil {
		c.pauseTimer.Stop()
		c.pauseTimer = nil
	}
	broker := c.broker
	publicListeners := append([]publicEndpointListener(nil), c.publicListeners...)
	vm := c.vm
	c.broker = nil
	c.publicListeners = nil
	c.mu.Unlock()

	if broker != nil {
		_ = broker.Close()
	}
	for _, endpoint := range publicListeners {
		if endpoint.listener != nil {
			_ = endpoint.listener.Close()
		}
	}
	return stopManagedVM(ctx, vm)
}

func (c *workloadController) serveBroker(listener net.Listener) {
	for {
		clientConn, err := listener.Accept()
		if err != nil {
			return
		}
		go func(conn net.Conn) {
			defer conn.Close()
			targetConn, release, err := c.AcquireConnection(context.Background())
			if err != nil {
				return
			}
			defer release()
			defer targetConn.Close()
			copyBidirectional(conn, targetConn)
		}(clientConn)
	}
}

func (c *workloadController) AcquireConnection(ctx context.Context) (net.Conn, func(), error) {
	if c == nil {
		return nil, nil, fmt.Errorf("workload controller is nil")
	}
	if ctx == nil {
		ctx = context.Background()
	}

	c.mu.Lock()
	if c.stopping {
		c.mu.Unlock()
		return nil, nil, fmt.Errorf("%s.%s is stopping", c.plan.Kind, c.plan.Name)
	}
	c.inflight++
	if c.pauseTimer != nil {
		c.pauseTimer.Stop()
		c.pauseTimer = nil
	}
	paused := c.paused
	socketPath := c.plan.SocketPath
	hostPort := c.vm.hostPort
	c.mu.Unlock()
	if hostPort < 1 {
		release := func() {
			c.releaseConnection()
		}
		release()
		return nil, nil, fmt.Errorf("%s.%s is not ready", c.plan.Kind, c.plan.Name)
	}

	release := func() {
		c.releaseConnection()
	}

	if err := c.resumeIfNeeded(ctx, socketPath, paused, release); err != nil {
		return nil, nil, err
	}

	var conn net.Conn
	var err error
	targetAddr := fmt.Sprintf("127.0.0.1:%d", hostPort)
	for attempt := 0; attempt < 3; attempt++ {
		conn, err = controllerDialTarget(ctx, targetAddr, defaultAcquireDialTimeout)
		if err == nil {
			return conn, release, nil
		}
		time.Sleep(25 * time.Millisecond)
	}
	release()
	return nil, nil, err
}

func (c *workloadController) acquireGuestPortConnection(ctx context.Context, guestPort int) (net.Conn, func(), error) {
	if c == nil {
		return nil, nil, fmt.Errorf("workload controller is nil")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if guestPort < 1 {
		return nil, nil, fmt.Errorf("guest port is not ready")
	}

	c.mu.Lock()
	if c.stopping {
		c.mu.Unlock()
		return nil, nil, fmt.Errorf("%s.%s is stopping", c.plan.Kind, c.plan.Name)
	}
	c.inflight++
	if c.pauseTimer != nil {
		c.pauseTimer.Stop()
		c.pauseTimer = nil
	}
	paused := c.paused
	socketPath := c.plan.SocketPath
	vsockPath := c.plan.VsockPath
	c.mu.Unlock()

	release := func() {
		c.releaseConnection()
	}
	if err := c.resumeIfNeeded(ctx, socketPath, paused, release); err != nil {
		return nil, nil, err
	}

	conn, err := dialGuestVsock(vsockPath, guestPort)
	if err != nil {
		release()
		return nil, nil, err
	}
	return conn, release, nil
}

func (c *workloadController) resumeIfNeeded(ctx context.Context, socketPath string, paused bool, release func()) error {
	if !paused {
		return nil
	}
	started := time.Now()
	if err := controllerPatchFirecrackerVMState(ctx, socketPath, "Resumed"); err != nil {
		release()
		c.mu.Lock()
		c.health = WorkloadHealth{Up: false, Reason: err.Error()}
		c.lifecycleState = "failed"
		c.mu.Unlock()
		_ = c.manager.writeState()
		return err
	}
	c.mu.Lock()
	c.paused = false
	c.resumeCount++
	c.lastResumeMS = time.Since(started).Milliseconds()
	c.lifecycleState = "ready"
	c.health = WorkloadHealth{Up: true, Reason: "ok"}
	c.mu.Unlock()
	_ = c.manager.writeState()
	return nil
}

func (c *workloadController) releaseConnection() {
	c.mu.Lock()
	if c.inflight > 0 {
		c.inflight--
	}
	c.mu.Unlock()
	c.schedulePauseIfIdle()
}

func (c *workloadController) schedulePauseIfIdle() {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.stopping || !c.shouldPauseLocked() {
		return
	}
	if c.pauseTimer != nil {
		c.pauseTimer.Stop()
	}
	delay := time.Duration(c.plan.Lifecycle.PauseAfterMS) * time.Millisecond
	if delay <= 0 {
		delay = 15 * time.Second
	}
	c.pauseTimer = time.AfterFunc(delay, c.pauseIfIdle)
}

func (c *workloadController) shouldPauseLocked() bool {
	return c.plan.Kind == "app" &&
		c.plan.Lifecycle.IdleAction == "pause" &&
		c.inflight == 0 &&
		!c.paused
}

func (c *workloadController) pauseIfIdle() {
	c.mu.Lock()
	if c.stopping || !c.shouldPauseLocked() {
		c.mu.Unlock()
		return
	}
	socketPath := c.plan.SocketPath
	c.lifecycleState = "paused"
	c.mu.Unlock()

	if err := controllerPatchFirecrackerVMState(context.Background(), socketPath, "Paused"); err != nil {
		c.mu.Lock()
		c.lifecycleState = "ready"
		c.health = WorkloadHealth{Up: false, Reason: err.Error()}
		c.mu.Unlock()
		_ = c.manager.writeState()
		return
	}

	c.mu.Lock()
	c.paused = true
	c.health = WorkloadHealth{Up: true, Reason: "ok"}
	c.mu.Unlock()
	_ = c.manager.writeState()
}

func (c *workloadController) snapshotState() (string, string, workloadStateSnapshot) {
	c.mu.Lock()
	plan := c.plan
	vm := c.vm
	started := c.started
	brokerHost := c.brokerHost
	brokerPort := c.brokerPort
	health := c.health
	lifecycleState := c.lifecycleState
	paused := c.paused
	resumeCount := c.resumeCount
	lastResumeMS := c.lastResumeMS
	publicListeners := append([]publicEndpointListener(nil), c.publicListeners...)
	c.mu.Unlock()
	if !started {
		return "", "", workloadStateSnapshot{}
	}

	firecrackerPID := 0
	if vm.machine != nil {
		if pid, err := vm.machine.PID(); err == nil {
			firecrackerPID = pid
		}
	}

	switch plan.Kind {
	case "service":
		publicEndpoints := c.snapshotPublicEndpoints(brokerHost, brokerPort, publicListeners)
		service := ServiceState{
			Name:            plan.Name,
			Image:           plan.Image,
			ImageDigest:     plan.Bundle.BundleID,
			Host:            brokerHost,
			Port:            brokerPort,
			BrokerHost:      brokerHost,
			BrokerPort:      brokerPort,
			InternalHost:    plan.InternalHost,
			InternalPort:    plan.InternalPort,
			InternalURL:     plan.InternalURL,
			PublicEndpoints: publicEndpoints,
			Health:          health,
			Lifecycle:       plan.Lifecycle,
			LifecycleState:  lifecycleState,
			Paused:          paused,
			ResumeCount:     resumeCount,
			LastResumeMS:    lastResumeMS,
			FirecrackerPID:  firecrackerPID,
			Volume:          plan.Volume,
			DebugSSH:        cloneDebugSSH(vm.debugSSH),
			BaseEnv:         cloneEnvMap(plan.SpecEnv),
		}
		service.URL = BuildServiceURL(plan.Name, service.Host, service.Port, plan.SpecEnv)
		service.FunctionEnv = BuildFunctionServiceEnv(plan.Name, service, plan.SpecEnv)
		return plan.Kind, plan.Name, workloadStateSnapshot{service: service}
	default:
		publicEndpoints := c.snapshotPublicEndpoints(brokerHost, brokerPort, publicListeners)
		appHost, appPort, appRoutes := c.primaryHTTPState(brokerHost, brokerPort, publicEndpoints)
		app := AppState{
			Name:            plan.Name,
			Image:           plan.Image,
			ImageDigest:     plan.Bundle.BundleID,
			Host:            appHost,
			Port:            appPort,
			BrokerHost:      appHost,
			BrokerPort:      appPort,
			InternalHost:    plan.InternalHost,
			InternalPort:    plan.InternalPort,
			InternalURL:     plan.InternalURL,
			Routes:          appRoutes,
			PublicEndpoints: publicEndpoints,
			Health:          health,
			Lifecycle:       plan.Lifecycle,
			LifecycleState:  lifecycleState,
			Paused:          paused,
			ResumeCount:     resumeCount,
			LastResumeMS:    lastResumeMS,
			FirecrackerPID:  firecrackerPID,
			Volume:          plan.Volume,
			DebugSSH:        cloneDebugSSH(vm.debugSSH),
			Env:             cloneEnvMap(plan.SpecEnv),
		}
		return plan.Kind, plan.Name, workloadStateSnapshot{app: app}
	}
}

func (c *workloadController) startPublicListeners() ([]publicEndpointListener, error) {
	if c == nil || len(c.plan.PublicEndpoints) == 0 {
		return nil, nil
	}
	out := make([]publicEndpointListener, 0, len(c.plan.PublicEndpoints))
	for _, endpoint := range c.plan.PublicEndpoints {
		if endpoint.Protocol == "http" && endpoint.ContainerPort == c.plan.InternalPort {
			continue
		}

		prefixes, err := parseAccessCIDRs(endpoint.Access.AllowCIDRs)
		if err != nil {
			for _, listener := range out {
				if listener.listener != nil {
					_ = listener.listener.Close()
				}
			}
			return nil, fmt.Errorf("parse access CIDRs for %s.%s endpoint %s: %w", c.plan.Kind, c.plan.Name, endpoint.Name, err)
		}

		bindAddr := "127.0.0.1:0"
		host := "127.0.0.1"
		if endpoint.Protocol == "tcp" {
			bindAddr = fmt.Sprintf("0.0.0.0:%d", endpoint.ListenPort)
			host = "0.0.0.0"
		}
		listener, err := net.Listen("tcp", bindAddr)
		if err != nil {
			for _, active := range out {
				if active.listener != nil {
					_ = active.listener.Close()
				}
			}
			return nil, fmt.Errorf("listen public endpoint for %s.%s %s: %w", c.plan.Kind, c.plan.Name, endpoint.Name, err)
		}
		port := listener.Addr().(*net.TCPAddr).Port
		state := publicEndpointListener{
			plan:         endpoint,
			listener:     listener,
			host:         host,
			port:         port,
			cidrPrefixes: prefixes,
		}
		out = append(out, state)
		go c.servePublicEndpoint(state)
	}
	return out, nil
}

func (c *workloadController) servePublicEndpoint(endpoint publicEndpointListener) {
	for {
		conn, err := endpoint.listener.Accept()
		if err != nil {
			return
		}
		go func(clientConn net.Conn) {
			defer clientConn.Close()
			if !accessPrefixesAllowRemote(endpoint.cidrPrefixes, clientConn.RemoteAddr()) {
				return
			}
			targetConn, release, err := c.acquireGuestPortConnection(context.Background(), endpoint.plan.GuestPort)
			if err != nil {
				return
			}
			defer release()
			defer targetConn.Close()
			copyBidirectional(clientConn, targetConn)
		}(conn)
	}
}

func (c *workloadController) snapshotPublicEndpoints(brokerHost string, brokerPort int, listeners []publicEndpointListener) []PublicEndpointState {
	if c == nil || len(c.plan.PublicEndpoints) == 0 {
		return nil
	}

	byName := map[string]publicEndpointListener{}
	for _, listener := range listeners {
		byName[stringsTrimSpaceLowerInvariant(listener.plan.Name)] = listener
	}

	out := make([]PublicEndpointState, 0, len(c.plan.PublicEndpoints))
	for _, endpoint := range c.plan.PublicEndpoints {
		state := PublicEndpointState{
			Name:          endpoint.Name,
			Protocol:      endpoint.Protocol,
			ContainerPort: endpoint.ContainerPort,
			ListenPort:    endpoint.ListenPort,
			Routes:        append([]string{}, endpoint.Routes...),
			AllowHosts:    append([]string{}, endpoint.Access.AllowHosts...),
			AllowCIDRs:    append([]string{}, endpoint.Access.AllowCIDRs...),
		}
		if endpoint.Protocol == "http" && endpoint.ContainerPort == c.plan.InternalPort {
			state.Host = brokerHost
			state.Port = brokerPort
		} else if listener, ok := byName[stringsTrimSpaceLowerInvariant(endpoint.Name)]; ok {
			state.Host = listener.host
			state.Port = listener.port
		}
		out = append(out, state)
	}
	return out
}

func (c *workloadController) primaryHTTPState(brokerHost string, brokerPort int, endpoints []PublicEndpointState) (string, int, []string) {
	for _, endpoint := range endpoints {
		if endpoint.Protocol != "http" {
			continue
		}
		return endpoint.Host, endpoint.Port, append([]string{}, endpoint.Routes...)
	}
	return brokerHost, brokerPort, append([]string{}, c.plan.Routes...)
}

func patchFirecrackerVMState(ctx context.Context, socketPath string, state string) error {
	state = stringsTrimSpaceLowerInvariant(state)
	switch state {
	case "paused":
		return patchFirecrackerJSON(ctx, socketPath, "/vm", map[string]any{"state": "Paused"})
	case "resumed":
		return patchFirecrackerJSON(ctx, socketPath, "/vm", map[string]any{"state": "Resumed"})
	default:
		return fmt.Errorf("unsupported firecracker VM state %q", state)
	}
}

func patchFirecrackerJSON(ctx context.Context, socketPath string, resourcePath string, body any) error {
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
	request, err := http.NewRequestWithContext(ctx, http.MethodPatch, "http://unix"+resourcePath, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("create firecracker request %s: %w", resourcePath, err)
	}
	request.Header.Set("Content-Type", "application/json")

	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("patch firecracker %s: %w", resourcePath, err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("patch firecracker %s returned status %d", resourcePath, response.StatusCode)
	}
	return nil
}

func stringsTrimSpaceLowerInvariant(raw string) string {
	var out bytes.Buffer
	for _, ch := range raw {
		switch {
		case ch >= 'A' && ch <= 'Z':
			out.WriteRune(ch + ('a' - 'A'))
		case ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r':
			out.WriteRune(ch)
		}
	}
	return out.String()
}
