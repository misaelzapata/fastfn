package process

import (
	"os"
	"path/filepath"
	runtimepkg "runtime"
	"strings"
	"testing"
)

func TestGenerateNativeConfig_UpdatesPortAndSSLPath(t *testing.T) {
	runtimeDir := t.TempDir()
	openrestyDir := filepath.Join(runtimeDir, "openresty")
	if err := os.MkdirAll(openrestyDir, 0o755); err != nil {
		t.Fatalf("mkdir openresty: %v", err)
	}

	input := "events {\n  use epoll;\n}\nhttp {\n  listen 8080;\n  ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;\n}\n"
	if err := os.WriteFile(filepath.Join(openrestyDir, "nginx.conf"), []byte(input), 0o644); err != nil {
		t.Fatalf("write nginx.conf: %v", err)
	}

	outPath, err := GenerateNativeConfig(runtimeDir, "9090")
	if err != nil {
		t.Fatalf("GenerateNativeConfig() error = %v", err)
	}

	contentBytes, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatalf("read generated config: %v", err)
	}
	content := string(contentBytes)

	if !strings.Contains(content, "listen 9090;") {
		t.Fatalf("expected listener port override, got:\n%s", content)
	}
	if !strings.Contains(content, detectSSLPath()) {
		t.Fatalf("expected SSL path replacement with %q, got:\n%s", detectSSLPath(), content)
	}
	if runtimepkg.GOOS == "darwin" && !strings.Contains(content, "use kqueue;") {
		t.Fatalf("expected kqueue on darwin, got:\n%s", content)
	}
}

func TestGenerateNativeConfig_InvalidPort(t *testing.T) {
	runtimeDir := t.TempDir()
	openrestyDir := filepath.Join(runtimeDir, "openresty")
	if err := os.MkdirAll(openrestyDir, 0o755); err != nil {
		t.Fatalf("mkdir openresty: %v", err)
	}
	if err := os.WriteFile(filepath.Join(openrestyDir, "nginx.conf"), []byte("listen 8080;\n"), 0o644); err != nil {
		t.Fatalf("write nginx.conf: %v", err)
	}

	_, err := GenerateNativeConfig(runtimeDir, "bad-port")
	if err == nil {
		t.Fatalf("expected invalid port error")
	}
}

func TestGenerateNativeConfig_MissingSourceConfig(t *testing.T) {
	_, err := GenerateNativeConfig(t.TempDir(), "8080")
	if err == nil {
		t.Fatalf("expected error when source nginx.conf is missing")
	}
}
