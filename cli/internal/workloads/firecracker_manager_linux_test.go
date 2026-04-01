//go:build linux

package workloads

import "testing"

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

func TestBuildImageWorkloadPeerEnv_UsesInternalHostsAndOmitsAmbiguousAliases(t *testing.T) {
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
	if _, ok := env["MYSQL_HOST"]; ok {
		t.Fatalf("MYSQL_HOST should be omitted when multiple MySQL services are visible")
	}
	if _, ok := env["MYSQL_PASSWORD"]; ok {
		t.Fatalf("MYSQL_PASSWORD should be omitted when multiple MySQL services are visible")
	}
}

func TestBuildImageWorkloadPeerEnv_AddsGenericAliasForSingleKnownService(t *testing.T) {
	env := buildImageWorkloadPeerEnv([]workloadPeerBinding{
		{
			Peer: workloadPeer{
				Kind:         "service",
				Name:         "postgres-primary",
				InternalHost: "postgres-primary.internal",
				InternalPort: 5432,
				InternalURL:  "postgres://pg@postgres-primary.internal:5432/app",
				BaseEnv: map[string]string{
					"POSTGRES_USER":     "pg",
					"POSTGRES_PASSWORD": "secret",
					"POSTGRES_DB":       "app",
				},
			},
			LocalHost: "postgres-primary.internal",
			LocalIP:   "127.77.0.1",
			LocalPort: 5432,
			VsockPort: 30000,
		},
	}, nil)

	if env["POSTGRES_HOST"] != "postgres-primary.internal" {
		t.Fatalf("POSTGRES_HOST = %q", env["POSTGRES_HOST"])
	}
	if env["POSTGRES_PASSWORD"] != "secret" {
		t.Fatalf("POSTGRES_PASSWORD = %q", env["POSTGRES_PASSWORD"])
	}
	if env["SERVICE_POSTGRES_PRIMARY_URL"] != "postgres://pg@postgres-primary.internal:5432/app" {
		t.Fatalf("SERVICE_POSTGRES_PRIMARY_URL = %q", env["SERVICE_POSTGRES_PRIMARY_URL"])
	}
}
