package workloads

import (
	"strings"
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

func TestNormalizeServiceSpecs_RejectsDockerfile(t *testing.T) {
	_, _, err := NormalizeServiceSpecs(map[string]any{
		"mysql": map[string]any{
			"dockerfile": "./Dockerfile",
			"port":       3306,
		},
	})
	if err == nil {
		t.Fatal("expected error for dockerfile-based workload")
	}
	if got := err.Error(); !strings.Contains(got, "dockerfile is not supported for Firecracker workloads") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestBuildFunctionServiceEnv(t *testing.T) {
	service := ServiceState{
		Name:         "mysql",
		Host:         "127.0.0.1",
		Port:         3307,
		InternalHost: "mysql.internal",
		InternalPort: 3306,
		URL:          "mysql://app:secret@127.0.0.1:3307/app",
	}
	env := BuildFunctionServiceEnv("mysql", service, map[string]string{
		"MYSQL_DATABASE": "app",
	})
	if env["SERVICE_MYSQL_HOST"] != "127.0.0.1" {
		t.Fatalf("SERVICE_MYSQL_HOST = %q", env["SERVICE_MYSQL_HOST"])
	}
	if env["MYSQL_URL"] != service.URL {
		t.Fatalf("MYSQL_URL = %q", env["MYSQL_URL"])
	}
}
