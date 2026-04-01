//go:build linux

package workloads

import (
	"context"
	"errors"
	"net"
	"strconv"
	"sync"
	"testing"
	"time"
)

func TestWorkloadControllerAcquireConnection_ReadyDoesNotPatchVM(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen() error = %v", err)
	}
	defer listener.Close()

	accepted := make(chan net.Conn, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr == nil {
			accepted <- conn
		}
	}()

	restore := withControllerTestHooks(t)
	defer restore()

	patchCalls := 0
	controllerPatchFirecrackerVMState = func(context.Context, string, string) error {
		patchCalls++
		return nil
	}

	controller := &workloadController{
		plan: workloadPlan{
			Kind:       "app",
			Name:       "admin",
			SocketPath: "/tmp/firecracker.sock",
		},
		vm:             managedVM{hostPort: listener.Addr().(*net.TCPAddr).Port},
		lifecycleState: "ready",
	}

	conn, release, err := controller.AcquireConnection(context.Background())
	if err != nil {
		t.Fatalf("AcquireConnection() error = %v", err)
	}
	defer conn.Close()

	select {
	case serverConn := <-accepted:
		_ = serverConn.Close()
	case <-time.After(1 * time.Second):
		t.Fatalf("AcquireConnection() did not reach target listener")
	}

	if patchCalls != 0 {
		t.Fatalf("patchCalls = %d, want 0", patchCalls)
	}

	controller.mu.Lock()
	inflight := controller.inflight
	controller.mu.Unlock()
	if inflight != 1 {
		t.Fatalf("inflight = %d, want 1 before release", inflight)
	}

	release()
	controller.mu.Lock()
	inflight = controller.inflight
	controller.mu.Unlock()
	if inflight != 0 {
		t.Fatalf("inflight = %d, want 0 after release", inflight)
	}
}

func TestWorkloadControllerAcquireConnection_ResumesPausedVM(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen() error = %v", err)
	}
	defer listener.Close()

	accepted := make(chan net.Conn, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr == nil {
			accepted <- conn
		}
	}()

	restore := withControllerTestHooks(t)
	defer restore()

	var mu sync.Mutex
	var patched []string
	controllerPatchFirecrackerVMState = func(_ context.Context, socketPath string, state string) error {
		mu.Lock()
		patched = append(patched, socketPath+":"+state)
		mu.Unlock()
		return nil
	}

	controller := &workloadController{
		plan: workloadPlan{
			Kind:       "app",
			Name:       "api",
			SocketPath: "/tmp/api.sock",
		},
		vm:             managedVM{hostPort: listener.Addr().(*net.TCPAddr).Port},
		lifecycleState: "paused",
		paused:         true,
	}

	conn, release, err := controller.AcquireConnection(context.Background())
	if err != nil {
		t.Fatalf("AcquireConnection() error = %v", err)
	}
	defer conn.Close()
	defer release()

	select {
	case serverConn := <-accepted:
		_ = serverConn.Close()
	case <-time.After(1 * time.Second):
		t.Fatalf("AcquireConnection() did not reach target listener")
	}

	mu.Lock()
	gotPatched := append([]string(nil), patched...)
	mu.Unlock()
	if len(gotPatched) != 1 || gotPatched[0] != "/tmp/api.sock:Resumed" {
		t.Fatalf("patched = %+v", gotPatched)
	}

	controller.mu.Lock()
	defer controller.mu.Unlock()
	if controller.paused {
		t.Fatalf("paused = true, want false")
	}
	if controller.lifecycleState != "ready" {
		t.Fatalf("lifecycleState = %q", controller.lifecycleState)
	}
	if controller.resumeCount != 1 {
		t.Fatalf("resumeCount = %d", controller.resumeCount)
	}
}

func TestWorkloadControllerPauseIfIdle_PatchesAppVMWhenPauseEnabled(t *testing.T) {
	restore := withControllerTestHooks(t)
	defer restore()

	var patched []string
	controllerPatchFirecrackerVMState = func(_ context.Context, socketPath string, state string) error {
		patched = append(patched, socketPath+":"+state)
		return nil
	}

	controller := &workloadController{
		manager: &FirecrackerManager{},
		plan: workloadPlan{
			Kind:       "app",
			Name:       "admin",
			SocketPath: "/tmp/admin.sock",
			Lifecycle: LifecycleSpec{
				IdleAction:   "pause",
				PauseAfterMS: 1000,
				Prewarm:      true,
			},
		},
		lifecycleState: "ready",
		health:         WorkloadHealth{Up: true, Reason: "ok"},
	}

	controller.pauseIfIdle()

	if len(patched) != 1 || patched[0] != "/tmp/admin.sock:Paused" {
		t.Fatalf("patched = %+v", patched)
	}
	controller.mu.Lock()
	defer controller.mu.Unlock()
	if !controller.paused {
		t.Fatalf("paused = false, want true")
	}
	if controller.lifecycleState != "paused" {
		t.Fatalf("lifecycleState = %q", controller.lifecycleState)
	}
}

func TestWorkloadControllerSnapshotState_UsesBrokerEndpoint(t *testing.T) {
	controller := &workloadController{
		plan: workloadPlan{
			Kind:         "service",
			Name:         "postgres-main",
			Image:        "postgres:16",
			InternalHost: "postgres-main.internal",
			InternalPort: 5432,
			InternalURL:  "postgres://postgres-main.internal:5432/app",
			Lifecycle: LifecycleSpec{
				IdleAction: "run",
				Prewarm:    true,
			},
			Bundle: FirecrackerBundle{BundleID: "bundle-1"},
			SpecEnv: map[string]string{
				"POSTGRES_USER": "app",
				"POSTGRES_DB":   "app",
			},
		},
		started:        true,
		brokerHost:     "127.0.0.1",
		brokerPort:     19090,
		lifecycleState: "ready",
		health:         WorkloadHealth{Up: true, Reason: "ok"},
	}

	kind, name, snapshot := controller.snapshotState()
	if kind != "service" || name != "postgres-main" {
		t.Fatalf("snapshot identity = %s.%s", kind, name)
	}
	if snapshot.service.Host != "127.0.0.1" || snapshot.service.Port != 19090 {
		t.Fatalf("service broker endpoint = %s:%d", snapshot.service.Host, snapshot.service.Port)
	}
	if snapshot.service.BrokerHost != "127.0.0.1" || snapshot.service.BrokerPort != 19090 {
		t.Fatalf("service broker fields = %s:%d", snapshot.service.BrokerHost, snapshot.service.BrokerPort)
	}
	if snapshot.service.InternalHost != "postgres-main.internal" || snapshot.service.InternalPort != 5432 {
		t.Fatalf("service internal endpoint = %s:%d", snapshot.service.InternalHost, snapshot.service.InternalPort)
	}
	if snapshot.service.Lifecycle.IdleAction != "run" || !snapshot.service.Lifecycle.Prewarm {
		t.Fatalf("service lifecycle = %+v", snapshot.service.Lifecycle)
	}
}

func TestFirecrackerManagerDialBridgeTarget_UsesResidentController(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen() error = %v", err)
	}
	defer listener.Close()

	accepted := make(chan net.Conn, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr == nil {
			accepted <- conn
		}
	}()

	restore := withControllerTestHooks(t)
	defer restore()

	patchCalls := 0
	controllerPatchFirecrackerVMState = func(context.Context, string, string) error {
		patchCalls++
		return nil
	}

	controller := &workloadController{
		plan: workloadPlan{Kind: "service", Name: "postgres-main"},
		vm:   managedVM{hostPort: listener.Addr().(*net.TCPAddr).Port},
	}
	manager := &FirecrackerManager{
		controllers: map[string]*workloadController{
			workloadPlanKey("service", "postgres-main"): controller,
		},
	}

	conn, release, err := manager.dialBridgeTarget(context.Background(), "service", "postgres-main")
	if err != nil {
		t.Fatalf("dialBridgeTarget() error = %v", err)
	}
	defer conn.Close()
	defer release()

	select {
	case serverConn := <-accepted:
		_ = serverConn.Close()
	case <-time.After(1 * time.Second):
		t.Fatalf("dialBridgeTarget() did not reach target listener")
	}
	if patchCalls != 0 {
		t.Fatalf("patchCalls = %d, want 0", patchCalls)
	}
}

func TestControllerDialTarget_ErrorPropagatesWithoutPatch(t *testing.T) {
	restore := withControllerTestHooks(t)
	defer restore()

	patchCalls := 0
	controllerPatchFirecrackerVMState = func(context.Context, string, string) error {
		patchCalls++
		return nil
	}
	controllerDialTarget = func(context.Context, string, time.Duration) (net.Conn, error) {
		return nil, errors.New("dial failed")
	}

	controller := &workloadController{
		plan: workloadPlan{
			Kind: "app",
			Name: "web",
		},
		vm: managedVM{hostPort: 18080},
	}

	conn, release, err := controller.AcquireConnection(context.Background())
	if err == nil {
		if release != nil {
			release()
		}
		if conn != nil {
			_ = conn.Close()
		}
		t.Fatalf("AcquireConnection() error = nil, want dial error")
	}
	if patchCalls != 0 {
		t.Fatalf("patchCalls = %d, want 0", patchCalls)
	}
	controller.mu.Lock()
	inflight := controller.inflight
	controller.mu.Unlock()
	if inflight != 0 {
		t.Fatalf("inflight = %d, want 0 after dial failure", inflight)
	}
}

func withControllerTestHooks(t *testing.T) func() {
	return withControllerTestHooksTB(t)
}

func TestWorkloadControllerSnapshotState_TracksResumeMetrics(t *testing.T) {
	controller := &workloadController{
		plan: workloadPlan{
			Kind:         "app",
			Name:         "dashboard",
			Image:        "ghcr.io/acme/dashboard:latest",
			InternalHost: "dashboard.internal",
			InternalPort: 3000,
			InternalURL:  "http://dashboard.internal:3000",
			Routes:       []string{"/dashboard/*"},
			Lifecycle: LifecycleSpec{
				IdleAction:   "pause",
				PauseAfterMS: 1500,
				Prewarm:      true,
			},
			Bundle: FirecrackerBundle{BundleID: "bundle-app"},
		},
		started:        true,
		brokerHost:     "127.0.0.1",
		brokerPort:     18081,
		lifecycleState: "ready",
		resumeCount:    3,
		lastResumeMS:   7,
		health:         WorkloadHealth{Up: true, Reason: "ok"},
	}

	kind, name, snapshot := controller.snapshotState()
	if kind != "app" || name != "dashboard" {
		t.Fatalf("snapshot identity = %s.%s", kind, name)
	}
	if snapshot.app.Host != "127.0.0.1" || snapshot.app.Port != 18081 {
		t.Fatalf("app broker endpoint = %s:%d", snapshot.app.Host, snapshot.app.Port)
	}
	if snapshot.app.ResumeCount != 3 || snapshot.app.LastResumeMS != 7 {
		t.Fatalf("resume metrics = %+v", snapshot.app)
	}
}

func TestWorkloadControllerSnapshotState_ExposesPublicEndpoints(t *testing.T) {
	controller := &workloadController{
		plan: workloadPlan{
			Kind:         "app",
			Name:         "admin",
			Image:        "ghcr.io/acme/admin:latest",
			InternalHost: "admin.internal",
			InternalPort: 3000,
			InternalURL:  "http://admin.internal:3000",
			Routes:       []string{"/admin/*"},
			PublicEndpoints: []publicEndpointPlan{
				{
					Name:          "http",
					Protocol:      "http",
					ContainerPort: 3000,
					GuestPort:     10700,
					Routes:        []string{"/admin/*"},
					Access: AccessSpec{
						AllowHosts: []string{"admin.example.com"},
						AllowCIDRs: []string{"10.0.0.0/8"},
					},
				},
				{
					Name:          "metrics",
					Protocol:      "http",
					ContainerPort: 9090,
					GuestPort:     10701,
					Routes:        []string{"/metrics"},
				},
				{
					Name:          "sql",
					Protocol:      "tcp",
					ContainerPort: 5432,
					GuestPort:     10702,
					ListenPort:    15432,
					Access: AccessSpec{
						AllowCIDRs: []string{"10.0.0.0/8"},
					},
				},
			},
			Lifecycle: LifecycleSpec{
				IdleAction: "run",
				Prewarm:    true,
			},
			Bundle: FirecrackerBundle{BundleID: "bundle-admin"},
		},
		started:        true,
		brokerHost:     "127.0.0.1",
		brokerPort:     18081,
		lifecycleState: "ready",
		health:         WorkloadHealth{Up: true, Reason: "ok"},
		publicListeners: []publicEndpointListener{
			{
				plan: publicEndpointPlan{
					Name:          "metrics",
					Protocol:      "http",
					ContainerPort: 9090,
					GuestPort:     10701,
					Routes:        []string{"/metrics"},
				},
				host: "127.0.0.1",
				port: 18082,
			},
			{
				plan: publicEndpointPlan{
					Name:          "sql",
					Protocol:      "tcp",
					ContainerPort: 5432,
					GuestPort:     10702,
					ListenPort:    15432,
					Access: AccessSpec{
						AllowCIDRs: []string{"10.0.0.0/8"},
					},
				},
				host: "0.0.0.0",
				port: 15432,
			},
		},
	}

	kind, name, snapshot := controller.snapshotState()
	if kind != "app" || name != "admin" {
		t.Fatalf("snapshot identity = %s.%s", kind, name)
	}
	if snapshot.app.Host != "127.0.0.1" || snapshot.app.Port != 18081 {
		t.Fatalf("primary app endpoint = %s:%d", snapshot.app.Host, snapshot.app.Port)
	}
	if len(snapshot.app.PublicEndpoints) != 3 {
		t.Fatalf("PublicEndpoints = %+v", snapshot.app.PublicEndpoints)
	}
	if snapshot.app.PublicEndpoints[0].AllowHosts[0] != "admin.example.com" {
		t.Fatalf("primary public endpoint = %+v", snapshot.app.PublicEndpoints[0])
	}
	if snapshot.app.PublicEndpoints[1].Host != "127.0.0.1" || snapshot.app.PublicEndpoints[1].Port != 18082 {
		t.Fatalf("metrics endpoint = %+v", snapshot.app.PublicEndpoints[1])
	}
	if snapshot.app.PublicEndpoints[2].Host != "0.0.0.0" || snapshot.app.PublicEndpoints[2].Port != 15432 {
		t.Fatalf("tcp endpoint = %+v", snapshot.app.PublicEndpoints[2])
	}
}

func BenchmarkControllerAcquireConnection_Hot(b *testing.B) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		b.Fatalf("Listen() error = %v", err)
	}
	defer listener.Close()

	done := make(chan struct{})
	go func() {
		for {
			conn, acceptErr := listener.Accept()
			if acceptErr != nil {
				close(done)
				return
			}
			_ = conn.Close()
		}
	}()

	controller := &workloadController{
		plan: workloadPlan{Name: "bench", Kind: "app"},
		vm:   managedVM{hostPort: listener.Addr().(*net.TCPAddr).Port},
	}

	restore := withControllerTestHooksTB(b)
	defer restore()
	controllerPatchFirecrackerVMState = func(context.Context, string, string) error { return nil }

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		conn, release, err := controller.AcquireConnection(context.Background())
		if err != nil {
			b.Fatalf("AcquireConnection() error = %v", err)
		}
		_ = conn.Close()
		release()
	}
	_ = listener.Close()
	<-done
}

func withControllerTestHooksTB(tb interface{ Helper() }) func() {
	tb.Helper()

	originalPatch := controllerPatchFirecrackerVMState
	originalDial := controllerDialTarget
	originalWait := controllerWaitForEndpoint
	originalWaitStable := controllerWaitForEndpointStable
	return func() {
		controllerPatchFirecrackerVMState = originalPatch
		controllerDialTarget = originalDial
		controllerWaitForEndpoint = originalWait
		controllerWaitForEndpointStable = originalWaitStable
	}
}

func TestWorkloadControllerFinishInitialHealthCheck_PrewarmFailureReturnsError(t *testing.T) {
	restore := withControllerTestHooks(t)
	defer restore()

	controller := &workloadController{
		plan: workloadPlan{
			Kind: "service",
			Name: "db",
			Lifecycle: LifecycleSpec{
				Prewarm: true,
			},
		},
		lifecycleState: "ready",
		health:         WorkloadHealth{Up: true, Reason: "ok"},
	}

	err := controller.finishInitialHealthCheck(3306, errors.New("connection refused"))
	if err == nil {
		t.Fatalf("finishInitialHealthCheck() error = nil, want prewarm failure")
	}
	controller.mu.Lock()
	defer controller.mu.Unlock()
	if controller.lifecycleState != "failed" {
		t.Fatalf("lifecycleState = %q, want failed", controller.lifecycleState)
	}
	if controller.health.Up {
		t.Fatalf("health.Up = true, want false")
	}
}

func TestWorkloadControllerFinishInitialHealthCheck_UsesStableWaitForPrewarmedServices(t *testing.T) {
	restore := withControllerTestHooks(t)
	defer restore()

	var (
		stableCalled bool
		stableFor    time.Duration
	)
	controllerWaitForEndpointStable = func(host string, port int, check HealthcheckSpec, timeout time.Duration, window time.Duration) error {
		stableCalled = true
		stableFor = window
		return nil
	}

	controller := &workloadController{
		plan: workloadPlan{
			Kind: "service",
			Name: "db",
			Healthcheck: HealthcheckSpec{
				IntervalMS: 1000,
			},
			Lifecycle: LifecycleSpec{
				Prewarm: true,
			},
		},
		lifecycleState: "booting",
	}

	if err := controller.finishInitialHealthCheck(3306, nil); err != nil {
		t.Fatalf("finishInitialHealthCheck() error = %v", err)
	}
	if !stableCalled {
		t.Fatalf("finishInitialHealthCheck() did not use stable wait")
	}
	if stableFor < defaultServiceReadyWindow {
		t.Fatalf("stableFor = %s, want >= %s", stableFor, defaultServiceReadyWindow)
	}
}

func TestControllerPatchHookUsesProvidedState(t *testing.T) {
	restore := withControllerTestHooks(t)
	defer restore()

	var got string
	controllerPatchFirecrackerVMState = func(_ context.Context, _, state string) error {
		got = state
		return nil
	}
	controller := &workloadController{
		manager: &FirecrackerManager{},
		plan: workloadPlan{
			Kind:       "app",
			Name:       "debug",
			SocketPath: "/tmp/debug.sock",
			Lifecycle:  LifecycleSpec{IdleAction: "pause"},
		},
	}
	controller.pauseIfIdle()
	if got != "Paused" {
		t.Fatalf("patched state = %q", got)
	}
}

func TestControllerDialTargetUsesHostPortAddress(t *testing.T) {
	restore := withControllerTestHooks(t)
	defer restore()

	var gotAddress string
	controllerDialTarget = func(_ context.Context, address string, _ time.Duration) (net.Conn, error) {
		gotAddress = address
		server, client := net.Pipe()
		_ = server.Close()
		return client, nil
	}

	controller := &workloadController{
		plan: workloadPlan{Kind: "app", Name: "ui"},
		vm:   managedVM{hostPort: 19091},
	}

	conn, release, err := controller.AcquireConnection(context.Background())
	if err != nil {
		t.Fatalf("AcquireConnection() error = %v", err)
	}
	_ = conn.Close()
	release()

	if gotAddress != net.JoinHostPort("127.0.0.1", strconv.Itoa(19091)) {
		t.Fatalf("address = %q", gotAddress)
	}
}
