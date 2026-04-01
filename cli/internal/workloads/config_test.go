package workloads

import (
	"path/filepath"
	"testing"
)

func TestNormalizeAppSpecs(t *testing.T) {
	apps, ok, err := NormalizeAppSpecs(map[string]any{
		"admin": map[string]any{
			"image": "ghcr.io/acme/admin:latest",
			"port":  3000,
			"routes": []any{
				"/admin/*",
			},
			"env": map[string]any{
				"NODE_ENV": "production",
			},
		},
	})
	if err != nil {
		t.Fatalf("NormalizeAppSpecs() error = %v", err)
	}
	if !ok {
		t.Fatalf("expected apps config to be detected")
	}
	if len(apps) != 1 {
		t.Fatalf("expected 1 app, got %d", len(apps))
	}
	if apps[0].Name != "admin" || apps[0].Port != 3000 {
		t.Fatalf("unexpected app spec: %+v", apps[0])
	}
	if len(apps[0].Routes) != 1 || apps[0].Routes[0] != "/admin/*" {
		t.Fatalf("unexpected routes: %+v", apps[0].Routes)
	}
	if apps[0].Lifecycle.IdleAction != "run" || apps[0].Lifecycle.PauseAfterMS != 15000 || !apps[0].Lifecycle.Prewarm {
		t.Fatalf("unexpected lifecycle: %+v", apps[0].Lifecycle)
	}
}

func TestNormalizeAppSpecs_LifecycleOverride(t *testing.T) {
	apps, ok, err := NormalizeAppSpecs(map[string]any{
		"admin": map[string]any{
			"image": "ghcr.io/acme/admin:latest",
			"port":  3000,
			"routes": []any{
				"/admin/*",
			},
			"lifecycle": map[string]any{
				"idle_action":    "pause",
				"pause_after_ms": 2500,
				"prewarm":        false,
			},
		},
	})
	if err != nil {
		t.Fatalf("NormalizeAppSpecs() error = %v", err)
	}
	if !ok || len(apps) != 1 {
		t.Fatalf("expected one app, got ok=%v apps=%d", ok, len(apps))
	}
	if apps[0].Lifecycle.IdleAction != "pause" {
		t.Fatalf("IdleAction = %q", apps[0].Lifecycle.IdleAction)
	}
	if apps[0].Lifecycle.PauseAfterMS != 2500 {
		t.Fatalf("PauseAfterMS = %d", apps[0].Lifecycle.PauseAfterMS)
	}
	if apps[0].Lifecycle.Prewarm {
		t.Fatalf("Prewarm = true, want false")
	}
}

func TestNormalizeServiceSpecs_WithInferredVolumeTarget(t *testing.T) {
	services, ok, err := NormalizeServiceSpecs(map[string]any{
		"mysql": map[string]any{
			"image":  "mysql:8.4",
			"port":   3306,
			"volume": "mysql-data",
			"env": map[string]any{
				"MYSQL_DATABASE": "app",
			},
		},
	})
	if err != nil {
		t.Fatalf("NormalizeServiceSpecs() error = %v", err)
	}
	if !ok {
		t.Fatalf("expected services config to be detected")
	}
	if len(services) != 1 {
		t.Fatalf("expected 1 service, got %d", len(services))
	}
	if services[0].Volume == nil || services[0].Volume.Target != "/var/lib/mysql" {
		t.Fatalf("unexpected volume: %+v", services[0].Volume)
	}
	if services[0].Lifecycle.IdleAction != "run" || services[0].Lifecycle.PauseAfterMS != 0 || !services[0].Lifecycle.Prewarm {
		t.Fatalf("unexpected lifecycle: %+v", services[0].Lifecycle)
	}
}

func TestNormalizeServiceSpecs_LifecycleOverride(t *testing.T) {
	services, ok, err := NormalizeServiceSpecs(map[string]any{
		"postgres-main": map[string]any{
			"image": "postgres:16",
			"port":  5432,
			"lifecycle": map[string]any{
				"idle_action":    "pause",
				"pause_after_ms": 4000,
				"prewarm":        false,
			},
		},
	})
	if err != nil {
		t.Fatalf("NormalizeServiceSpecs() error = %v", err)
	}
	if !ok || len(services) != 1 {
		t.Fatalf("expected one service, got ok=%v services=%d", ok, len(services))
	}
	if services[0].Lifecycle.IdleAction != "pause" {
		t.Fatalf("IdleAction = %q", services[0].Lifecycle.IdleAction)
	}
	if services[0].Lifecycle.PauseAfterMS != 4000 {
		t.Fatalf("PauseAfterMS = %d", services[0].Lifecycle.PauseAfterMS)
	}
	if services[0].Lifecycle.Prewarm {
		t.Fatalf("Prewarm = true, want false")
	}
}

func TestNormalizeServiceSpecs_ImageOnlyLeavesDockerfileEmpty(t *testing.T) {
	services, ok, err := NormalizeServiceSpecs(map[string]any{
		"redis": map[string]any{
			"image": "redis:7",
			"port":  6379,
		},
	})
	if err != nil {
		t.Fatalf("NormalizeServiceSpecs() error = %v", err)
	}
	if !ok {
		t.Fatalf("expected services config to be detected")
	}
	if len(services) != 1 {
		t.Fatalf("expected 1 service, got %d", len(services))
	}
	if services[0].Dockerfile != "" {
		t.Fatalf("Dockerfile = %q, want empty", services[0].Dockerfile)
	}
}

func TestNormalizeServiceSpecs_AcceptsDockerfile(t *testing.T) {
	services, ok, err := NormalizeServiceSpecs(map[string]any{
		"mysql": map[string]any{
			"dockerfile": "./Dockerfile",
			"port":       3306,
		},
	})
	if err != nil {
		t.Fatalf("NormalizeServiceSpecs() error = %v", err)
	}
	if !ok || len(services) != 1 {
		t.Fatalf("expected one service, got ok=%v services=%d", ok, len(services))
	}
	if services[0].Dockerfile != filepath.Clean("./Dockerfile") {
		t.Fatalf("unexpected dockerfile path: %q", services[0].Dockerfile)
	}
}

func TestBuildFunctionServiceEnv_UsesServiceNameAliases(t *testing.T) {
	service := ServiceState{
		Name:         "mariadb",
		Host:         "127.0.0.1",
		Port:         3307,
		InternalHost: "mariadb.internal",
		InternalPort: 3306,
		URL:          "mysql://app@127.0.0.1:3307/app",
	}
	env := BuildFunctionServiceEnv("mariadb", service, map[string]string{
		"MARIADB_DATABASE": "app",
		"MARIADB_PASSWORD": "secret",
	})
	if env["SERVICE_MARIADB_HOST"] != "127.0.0.1" {
		t.Fatalf("SERVICE_MARIADB_HOST = %q", env["SERVICE_MARIADB_HOST"])
	}
	if env["MARIADB_URL"] != service.URL {
		t.Fatalf("MARIADB_URL = %q", env["MARIADB_URL"])
	}
	if env["SERVICE_MARIADB_MARIADB_PASSWORD"] != "secret" {
		t.Fatalf("SERVICE_MARIADB_MARIADB_PASSWORD = %q", env["SERVICE_MARIADB_MARIADB_PASSWORD"])
	}
}
