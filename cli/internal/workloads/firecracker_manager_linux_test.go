//go:build linux

package workloads

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPlanWorkloadPeerBindings_AssignsStableIPsAndNativePorts(t *testing.T) {
	source := workloadPeer{
		Kind:         "app",
		Name:         "api",
		ScopeDir:     "/project/functions/payments/api",
		InternalHost: "api.internal",
		InternalPort: 5000,
	}
	bindings, err := planWorkloadPeerBindings(source, []workloadPeer{
		source,
		{
			Kind:         "service",
			Name:         "mysql-analytics",
			ScopeDir:     "/project/functions/payments",
			InternalHost: "mysql-analytics.internal",
			InternalPort: 3306,
			InternalURL:  "mysql://analytics@mysql-analytics.internal:3306/analytics",
		},
		{
			Kind:         "service",
			Name:         "mysql-main",
			ScopeDir:     "/project/functions/payments",
			InternalHost: "mysql-main.internal",
			InternalPort: 3306,
			InternalURL:  "mysql://app@mysql-main.internal:3306/app",
		},
		{
			Kind:         "app",
			Name:         "worker",
			ScopeDir:     "/project/functions/payments/api",
			InternalHost: "worker.internal",
			InternalPort: 5000,
			InternalURL:  "http://worker.internal:5000",
		},
	})
	if err != nil {
		t.Fatalf("planWorkloadPeerBindings() error = %v", err)
	}
	if len(bindings) != 3 {
		t.Fatalf("len(bindings) = %d", len(bindings))
	}

	if bindings[0].Peer.Name != "mysql-analytics" || bindings[0].LocalIP != "127.77.0.1" || bindings[0].LocalPort != 3306 || bindings[0].VsockPort != 30000 {
		t.Fatalf("binding[0] = %+v", bindings[0])
	}
	if bindings[1].Peer.Name != "mysql-main" || bindings[1].LocalIP != "127.77.0.2" || bindings[1].LocalPort != 3306 || bindings[1].VsockPort != 30001 {
		t.Fatalf("binding[1] = %+v", bindings[1])
	}
	if bindings[2].Peer.Name != "worker" || bindings[2].LocalIP != "127.77.0.3" || bindings[2].LocalPort != 5000 || bindings[2].VsockPort != 30002 {
		t.Fatalf("binding[2] = %+v", bindings[2])
	}
}

func TestVisibleWorkloadPeers_RespectsScope(t *testing.T) {
	source := workloadPeer{
		Kind:     "app",
		Name:     "api",
		ScopeDir: "/project/functions/payments/api",
	}
	visible := visibleWorkloadPeers(source, []workloadPeer{
		source,
		{Kind: "service", Name: "payments-db", ScopeDir: "/project/functions/payments"},
		{Kind: "app", Name: "worker", ScopeDir: "/project/functions/payments/api"},
		{Kind: "service", Name: "deep-child", ScopeDir: "/project/functions/payments/api/reports"},
		{Kind: "service", Name: "sibling-db", ScopeDir: "/project/functions/other"},
	})
	if len(visible) != 2 {
		t.Fatalf("len(visible) = %d, want 2", len(visible))
	}
	if visible[0].Name != "payments-db" || visible[1].Name != "worker" {
		t.Fatalf("visible = %+v", visible)
	}
}

func TestVisibleWorkloadPeers_ServiceSourceSkipsOtherServices(t *testing.T) {
	source := workloadPeer{
		Kind:     "service",
		Name:     "postgres-main",
		ScopeDir: "/project/functions/data",
	}
	visible := visibleWorkloadPeers(source, []workloadPeer{
		source,
		{Kind: "service", Name: "postgres-analytics", ScopeDir: "/project/functions/data"},
		{Kind: "app", Name: "checker", ScopeDir: "/project/functions/data"},
		{Kind: "service", Name: "payments-db", ScopeDir: "/project/functions"},
	})
	if len(visible) != 1 {
		t.Fatalf("len(visible) = %d, want 1", len(visible))
	}
	if visible[0].Kind != "app" || visible[0].Name != "checker" {
		t.Fatalf("visible = %+v", visible)
	}
}

func TestBuildImageWorkloadPeerEnv_UsesInternalHostsAndServiceNameAliases(t *testing.T) {
	env := buildImageWorkloadPeerEnv([]workloadPeerBinding{
		{
			Peer: workloadPeer{
				Kind:         "service",
				Name:         "mysql-main",
				InternalHost: "mysql-main.internal",
				InternalPort: 3306,
				InternalURL:  "mysql://app@mysql-main.internal:3306/app",
				BaseEnv: map[string]string{
					"MYSQL_USER":     "app",
					"MYSQL_PASSWORD": "secret",
					"MYSQL_DATABASE": "app",
				},
			},
			LocalHost: "mysql-main.internal",
			LocalIP:   "127.77.0.1",
			LocalPort: 3306,
			VsockPort: 30000,
		},
		{
			Peer: workloadPeer{
				Kind:         "service",
				Name:         "mysql-analytics",
				InternalHost: "mysql-analytics.internal",
				InternalPort: 3306,
				InternalURL:  "mysql://analytics@mysql-analytics.internal:3306/analytics",
				BaseEnv: map[string]string{
					"MYSQL_USER":     "analytics",
					"MYSQL_PASSWORD": "secret2",
					"MYSQL_DATABASE": "analytics",
				},
			},
			LocalHost: "mysql-analytics.internal",
			LocalIP:   "127.77.0.2",
			LocalPort: 3306,
			VsockPort: 30001,
		},
		{
			Peer: workloadPeer{
				Kind:         "app",
				Name:         "worker",
				InternalHost: "worker.internal",
				InternalPort: 5000,
				InternalURL:  "http://worker.internal:5000",
			},
			LocalHost: "worker.internal",
			LocalIP:   "127.77.0.3",
			LocalPort: 5000,
			VsockPort: 30002,
		},
	}, map[string]string{
		"APP_ENV": "test",
	})

	if env["APP_ENV"] != "test" {
		t.Fatalf("APP_ENV = %q", env["APP_ENV"])
	}
	if env["WORKLOAD_WORKER_HOST"] != "worker.internal" {
		t.Fatalf("WORKLOAD_WORKER_HOST = %q", env["WORKLOAD_WORKER_HOST"])
	}
	if env["WORKLOAD_WORKER_PORT"] != "5000" {
		t.Fatalf("WORKLOAD_WORKER_PORT = %q", env["WORKLOAD_WORKER_PORT"])
	}
	if env["SERVICE_MYSQL_MAIN_HOST"] != "mysql-main.internal" {
		t.Fatalf("SERVICE_MYSQL_MAIN_HOST = %q", env["SERVICE_MYSQL_MAIN_HOST"])
	}
	if env["SERVICE_MYSQL_MAIN_MYSQL_PASSWORD"] != "secret" {
		t.Fatalf("SERVICE_MYSQL_MAIN_MYSQL_PASSWORD = %q", env["SERVICE_MYSQL_MAIN_MYSQL_PASSWORD"])
	}
	if env["MYSQL_MAIN_HOST"] != "mysql-main.internal" {
		t.Fatalf("MYSQL_MAIN_HOST = %q", env["MYSQL_MAIN_HOST"])
	}
	if env["MYSQL_ANALYTICS_HOST"] != "mysql-analytics.internal" {
		t.Fatalf("MYSQL_ANALYTICS_HOST = %q", env["MYSQL_ANALYTICS_HOST"])
	}
	if _, ok := env["MYSQL_HOST"]; ok {
		t.Fatalf("MYSQL_HOST should not be synthesized from a hardcoded family alias")
	}
}

func TestBuildImageWorkloadPeerEnv_AddsAliasForActualServiceName(t *testing.T) {
	env := buildImageWorkloadPeerEnv([]workloadPeerBinding{
		{
			Peer: workloadPeer{
				Kind:         "service",
				Name:         "mariadb",
				InternalHost: "mariadb.internal",
				InternalPort: 5432,
				InternalURL:  "mysql://db@mariadb.internal:5432/app",
				BaseEnv: map[string]string{
					"MARIADB_USER":     "db",
					"MARIADB_PASSWORD": "secret",
					"MARIADB_DATABASE": "app",
				},
			},
			LocalHost: "mariadb.internal",
			LocalIP:   "127.77.0.1",
			LocalPort: 5432,
			VsockPort: 30000,
		},
	}, nil)

	if env["MARIADB_HOST"] != "mariadb.internal" {
		t.Fatalf("MARIADB_HOST = %q", env["MARIADB_HOST"])
	}
	if env["MARIADB_URL"] != "mysql://db@mariadb.internal:5432/app" {
		t.Fatalf("MARIADB_URL = %q", env["MARIADB_URL"])
	}
	if env["SERVICE_MARIADB_URL"] != "mysql://db@mariadb.internal:5432/app" {
		t.Fatalf("SERVICE_MARIADB_URL = %q", env["SERVICE_MARIADB_URL"])
	}
	if _, ok := env["MARIADB_PASSWORD"]; ok {
		t.Fatalf("MARIADB_PASSWORD should stay namespaced under SERVICE_MARIADB_*")
	}
}

func TestReadVsockConnectAck_PreservesPayloadAfterAck(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()

	go func() {
		_, _ = io.WriteString(server, "OK 5000\nmysql-handshake")
	}()

	line, err := readVsockConnectAck(client)
	if err != nil {
		t.Fatalf("readVsockConnectAck() error = %v", err)
	}
	if line != "OK 5000\n" {
		t.Fatalf("ack line = %q", line)
	}

	payload := make([]byte, len("mysql-handshake"))
	if _, err := io.ReadFull(client, payload); err != nil {
		t.Fatalf("ReadFull() error = %v", err)
	}
	if string(payload) != "mysql-handshake" {
		t.Fatalf("payload = %q", string(payload))
	}
}

func TestPutEntropyDevice_UsesFirecrackerEntropyEndpoint(t *testing.T) {
	var requests chan firecrackerTestRequest
	socketPath, requests, shutdown := startFirecrackerUnixTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		payload, _ := io.ReadAll(r.Body)
		_ = r.Body.Close()
		requests <- firecrackerTestRequest{
			Method: r.Method,
			Path:   r.URL.Path,
			Body:   append([]byte(nil), payload...),
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer shutdown()

	if err := putEntropyDevice(context.Background(), socketPath); err != nil {
		t.Fatalf("putEntropyDevice() error = %v", err)
	}

	req := <-requests
	if req.Method != http.MethodPut {
		t.Fatalf("method = %q", req.Method)
	}
	if req.Path != "/entropy" {
		t.Fatalf("path = %q", req.Path)
	}
	if string(req.Body) != "{}" {
		t.Fatalf("body = %q", string(req.Body))
	}
}

func TestPutMachineConfigSMT_DisablesSMT(t *testing.T) {
	var requests chan firecrackerTestRequest
	socketPath, requests, shutdown := startFirecrackerUnixTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		payload, _ := io.ReadAll(r.Body)
		_ = r.Body.Close()
		requests <- firecrackerTestRequest{
			Method: r.Method,
			Path:   r.URL.Path,
			Body:   append([]byte(nil), payload...),
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer shutdown()

	if err := putMachineConfigSMT(context.Background(), socketPath, 2, 256); err != nil {
		t.Fatalf("putMachineConfigSMT() error = %v", err)
	}

	req := <-requests
	if req.Method != http.MethodPut {
		t.Fatalf("method = %q", req.Method)
	}
	if req.Path != "/machine-config" {
		t.Fatalf("path = %q", req.Path)
	}
	var body map[string]any
	if err := json.Unmarshal(req.Body, &body); err != nil {
		t.Fatalf("Unmarshal() error = %v", err)
	}
	if body["vcpu_count"] != float64(2) {
		t.Fatalf("vcpu_count = %#v", body["vcpu_count"])
	}
	if body["mem_size_mib"] != float64(256) {
		t.Fatalf("mem_size_mib = %#v", body["mem_size_mib"])
	}
	if body["smt"] != false {
		t.Fatalf("smt = %#v", body["smt"])
	}
}

func TestPatchFirecrackerVMState_UsesVMEndpoint(t *testing.T) {
	var requests chan firecrackerTestRequest
	socketPath, requests, shutdown := startFirecrackerUnixTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		payload, _ := io.ReadAll(r.Body)
		_ = r.Body.Close()
		requests <- firecrackerTestRequest{
			Method: r.Method,
			Path:   r.URL.Path,
			Body:   append([]byte(nil), payload...),
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer shutdown()

	if err := patchFirecrackerVMState(context.Background(), socketPath, "Paused"); err != nil {
		t.Fatalf("patchFirecrackerVMState() error = %v", err)
	}

	req := <-requests
	if req.Method != http.MethodPatch {
		t.Fatalf("method = %q", req.Method)
	}
	if req.Path != "/vm" {
		t.Fatalf("path = %q", req.Path)
	}
	var body map[string]any
	if err := json.Unmarshal(req.Body, &body); err != nil {
		t.Fatalf("Unmarshal() error = %v", err)
	}
	if body["state"] != "Paused" {
		t.Fatalf("state = %#v", body["state"])
	}
}

type firecrackerTestRequest struct {
	Method string
	Path   string
	Body   []byte
}

func startFirecrackerUnixTestServer(t *testing.T, handler http.Handler) (string, chan firecrackerTestRequest, func()) {
	t.Helper()

	dir := t.TempDir()
	socketPath := filepath.Join(dir, "firecracker.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("Listen(unix) error = %v", err)
	}

	requests := make(chan firecrackerTestRequest, 8)
	server := &http.Server{Handler: handler}
	go func() {
		_ = server.Serve(listener)
	}()

	shutdown := func() {
		_ = server.Close()
		_ = listener.Close()
		_ = os.Remove(socketPath)
	}
	return socketPath, requests, shutdown
}

func TestGenerateGuestEntropySeed_UsesExpectedSize(t *testing.T) {
	seed, err := generateGuestEntropySeed()
	if err != nil {
		t.Fatalf("generateGuestEntropySeed() error = %v", err)
	}
	if len(seed) != guestEntropySeedBytes*2 {
		t.Fatalf("len(seed) = %d", len(seed))
	}
	if strings.Trim(seed, "0123456789abcdef") != "" {
		t.Fatalf("seed is not lowercase hex: %q", seed)
	}
}
