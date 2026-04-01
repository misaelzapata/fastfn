//go:build linux

package workloads

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"sync"
	"time"
)

const defaultAcquireDialTimeout = 2 * time.Second

var (
	controllerPatchFirecrackerVMState = patchFirecrackerVMState
	controllerDialTarget              = func(ctx context.Context, address string, timeout time.Duration) (net.Conn, error) {
		dialer := &net.Dialer{Timeout: timeout}
		return dialer.DialContext(ctx, "tcp", address)
	}
)

type workloadController struct {
	manager *FirecrackerManager
	plan    workloadPlan

	mu             sync.Mutex
	vm             managedVM
	broker         net.Listener
	brokerHost     string
	brokerPort     int
	health         WorkloadHealth
	lifecycleState string
	paused         bool
	inflight       int
	stopping       bool
	started        bool
	pauseTimer     *time.Timer
	resumeCount    int
	lastResumeMS   int64
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

	if err := waitForEndpoint("127.0.0.1", hostPort, c.plan.Healthcheck, 30*time.Second); err != nil {
		c.mu.Lock()
		c.health = WorkloadHealth{Up: false, Reason: err.Error()}
		c.mu.Unlock()
	}

	if err := c.manager.writeState(); err != nil {
		return err
	}

	c.schedulePauseIfIdle()
	return nil
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
	vm := c.vm
	c.broker = nil
	c.mu.Unlock()

	if broker != nil {
		_ = broker.Close()
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

	if paused {
		started := time.Now()
		if err := controllerPatchFirecrackerVMState(ctx, socketPath, "Resumed"); err != nil {
			release()
			c.mu.Lock()
			c.health = WorkloadHealth{Up: false, Reason: err.Error()}
			c.lifecycleState = "failed"
			c.mu.Unlock()
			_ = c.manager.writeState()
			return nil, nil, err
		}
		c.mu.Lock()
		c.paused = false
		c.resumeCount++
		c.lastResumeMS = time.Since(started).Milliseconds()
		c.lifecycleState = "ready"
		c.health = WorkloadHealth{Up: true, Reason: "ok"}
		c.mu.Unlock()
		_ = c.manager.writeState()
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
		service := ServiceState{
			Name:           plan.Name,
			Image:          plan.Image,
			ImageDigest:    plan.Bundle.BundleID,
			Host:           brokerHost,
			Port:           brokerPort,
			BrokerHost:     brokerHost,
			BrokerPort:     brokerPort,
			InternalHost:   plan.InternalHost,
			InternalPort:   plan.InternalPort,
			InternalURL:    plan.InternalURL,
			Health:         health,
			Lifecycle:      plan.Lifecycle,
			LifecycleState: lifecycleState,
			Paused:         paused,
			ResumeCount:    resumeCount,
			LastResumeMS:   lastResumeMS,
			FirecrackerPID: firecrackerPID,
			Volume:         plan.Volume,
			DebugSSH:       cloneDebugSSH(vm.debugSSH),
			BaseEnv:        cloneEnvMap(plan.SpecEnv),
		}
		service.URL = BuildServiceURL(plan.Name, service.Host, service.Port, plan.SpecEnv)
		service.FunctionEnv = BuildFunctionServiceEnv(plan.Name, service, plan.SpecEnv)
		return plan.Kind, plan.Name, workloadStateSnapshot{service: service}
	default:
		app := AppState{
			Name:           plan.Name,
			Image:          plan.Image,
			ImageDigest:    plan.Bundle.BundleID,
			Host:           brokerHost,
			Port:           brokerPort,
			BrokerHost:     brokerHost,
			BrokerPort:     brokerPort,
			InternalHost:   plan.InternalHost,
			InternalPort:   plan.InternalPort,
			InternalURL:    plan.InternalURL,
			Routes:         append([]string{}, plan.Routes...),
			Health:         health,
			Lifecycle:      plan.Lifecycle,
			LifecycleState: lifecycleState,
			Paused:         paused,
			ResumeCount:    resumeCount,
			LastResumeMS:   lastResumeMS,
			FirecrackerPID: firecrackerPID,
			Volume:         plan.Volume,
			DebugSSH:       cloneDebugSSH(vm.debugSSH),
			Env:            cloneEnvMap(plan.SpecEnv),
		}
		return plan.Kind, plan.Name, workloadStateSnapshot{app: app}
	}
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
