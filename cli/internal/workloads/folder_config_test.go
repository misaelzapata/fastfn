package workloads

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadConfigured_LoadsFolderConfigs(t *testing.T) {
	projectDir := t.TempDir()
	functionsDir := filepath.Join(projectDir, "functions")
	appDir := filepath.Join(functionsDir, "flask-api")
	if err := os.MkdirAll(appDir, 0o755); err != nil {
		t.Fatalf("mkdir app dir: %v", err)
	}

	raw := `{
  "app": {
    "dockerfile": "./Dockerfile",
    "context": ".",
    "env": {
      "MYSQL_USER": "app"
    },
    "ports": {
      "http": {
        "container_port": 5000,
        "protocol": "http",
        "expose": {
          "public": true,
          "routes": ["/api/*"]
        },
        "healthcheck": {
          "type": "http",
          "path": "/api/health"
        }
      }
    }
  },
  "services": {
    "mysql": {
      "image": "mysql:8.4",
      "env": {
        "MYSQL_DATABASE": "app"
      },
      "volumes": {
        "data": {
          "target": "/var/lib/mysql"
        }
      },
      "ports": {
        "mysql": {
          "container_port": 3306,
          "protocol": "tcp"
        }
      }
    }
  }
}`
	if err := os.WriteFile(filepath.Join(appDir, "fn.config.json"), []byte(raw), 0o644); err != nil {
		t.Fatalf("write fn.config.json: %v", err)
	}

	cfg, ok, err := LoadConfigured(projectDir, functionsDir, nil)
	if err != nil {
		t.Fatalf("LoadConfigured() error = %v", err)
	}
	if !ok {
		t.Fatal("expected folder workloads to be detected")
	}
	if len(cfg.Apps) != 1 {
		t.Fatalf("expected 1 app, got %d", len(cfg.Apps))
	}
	if cfg.Apps[0].Name != "flask-api" {
		t.Fatalf("app name = %q", cfg.Apps[0].Name)
	}
	if cfg.Apps[0].Dockerfile != filepath.Join(appDir, "Dockerfile") {
		t.Fatalf("dockerfile = %q", cfg.Apps[0].Dockerfile)
	}
	if cfg.Apps[0].Port != 5000 {
		t.Fatalf("app port = %d", cfg.Apps[0].Port)
	}
	if len(cfg.Apps[0].Routes) != 1 || cfg.Apps[0].Routes[0] != "/api/*" {
		t.Fatalf("routes = %+v", cfg.Apps[0].Routes)
	}
	if len(cfg.Services) != 1 || cfg.Services[0].Name != "mysql" {
		t.Fatalf("services = %+v", cfg.Services)
	}
	if cfg.Services[0].Volume == nil || cfg.Services[0].Volume.Name != "mysql-data" {
		t.Fatalf("volume = %+v", cfg.Services[0].Volume)
	}
}

func TestLoadConfigured_LoadsSingularFolderServiceWithoutGlobalWorkloads(t *testing.T) {
	projectDir := t.TempDir()
	functionsDir := filepath.Join(projectDir, "functions")
	paymentsDir := filepath.Join(functionsDir, "payments")
	if err := os.MkdirAll(paymentsDir, 0o755); err != nil {
		t.Fatalf("mkdir payments dir: %v", err)
	}

	raw := `{
  "service": {
    "image": "mysql:8.4",
    "port": 3306,
    "volume": {
      "name": "payments-data",
      "target": "/var/lib/mysql"
    },
    "env": {
      "MYSQL_DATABASE": "payments"
    }
  }
}`
	if err := os.WriteFile(filepath.Join(paymentsDir, "fn.config.json"), []byte(raw), 0o644); err != nil {
		t.Fatalf("write fn.config.json: %v", err)
	}

	cfg, ok, err := LoadConfigured(projectDir, functionsDir, map[string]any{
		"functions-dir": "functions",
	})
	if err != nil {
		t.Fatalf("LoadConfigured() error = %v", err)
	}
	if !ok {
		t.Fatal("expected folder-local service to be detected")
	}
	if len(cfg.Apps) != 0 {
		t.Fatalf("expected no apps, got %d", len(cfg.Apps))
	}
	if len(cfg.Services) != 1 {
		t.Fatalf("expected 1 service, got %d", len(cfg.Services))
	}
	if cfg.Services[0].Name != "payments" {
		t.Fatalf("service name = %q", cfg.Services[0].Name)
	}
	if cfg.Services[0].ScopeDir != paymentsDir {
		t.Fatalf("scope dir = %q", cfg.Services[0].ScopeDir)
	}
	if cfg.Services[0].Volume == nil || cfg.Services[0].Volume.Name != "payments-data" {
		t.Fatalf("volume = %+v", cfg.Services[0].Volume)
	}
	if cfg.Services[0].Volume.Target != "/var/lib/mysql" {
		t.Fatalf("volume target = %q", cfg.Services[0].Volume.Target)
	}
}
