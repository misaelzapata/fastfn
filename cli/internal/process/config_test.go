package process

import (
	"errors"
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

func TestGenerateNativeConfig_EmptyPortDefaultsTo8080(t *testing.T) {
	runtimeDir := t.TempDir()
	openrestyDir := filepath.Join(runtimeDir, "openresty")
	if err := os.MkdirAll(openrestyDir, 0o755); err != nil {
		t.Fatalf("mkdir openresty: %v", err)
	}

	input := "http {\n  listen 8080;\n}\n"
	if err := os.WriteFile(filepath.Join(openrestyDir, "nginx.conf"), []byte(input), 0o644); err != nil {
		t.Fatalf("write nginx.conf: %v", err)
	}

	outPath, err := GenerateNativeConfig(runtimeDir, "")
	if err != nil {
		t.Fatalf("GenerateNativeConfig() error = %v", err)
	}

	content, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatalf("read generated config: %v", err)
	}

	if !strings.Contains(string(content), "listen 8080;") {
		t.Fatalf("expected default port 8080 in output, got:\n%s", string(content))
	}
}

func TestDetectSSLPath_ReturnsSomething(t *testing.T) {
	path := detectSSLPath()
	if path == "" {
		t.Fatalf("detectSSLPath() returned empty string")
	}
}

func TestGenerateNativeConfig_SSLReplacementApplied(t *testing.T) {
	runtimeDir := t.TempDir()
	openrestyDir := filepath.Join(runtimeDir, "openresty")
	if err := os.MkdirAll(openrestyDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	input := "ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;\nlisten 8080;\n"
	if err := os.WriteFile(filepath.Join(openrestyDir, "nginx.conf"), []byte(input), 0o644); err != nil {
		t.Fatalf("write nginx.conf: %v", err)
	}

	outPath, err := GenerateNativeConfig(runtimeDir, "8080")
	if err != nil {
		t.Fatalf("GenerateNativeConfig() error = %v", err)
	}

	content, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatalf("read: %v", err)
	}

	sslPath := detectSSLPath()
	if !strings.Contains(string(content), sslPath) {
		t.Fatalf("expected SSL path %q in output, got:\n%s", sslPath, string(content))
	}
}

func TestGenerateNativeConfig_OutputFileIsNginxNative(t *testing.T) {
	runtimeDir := t.TempDir()
	openrestyDir := filepath.Join(runtimeDir, "openresty")
	if err := os.MkdirAll(openrestyDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(openrestyDir, "nginx.conf"), []byte("listen 8080;\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	outPath, err := GenerateNativeConfig(runtimeDir, "8080")
	if err != nil {
		t.Fatalf("GenerateNativeConfig() error = %v", err)
	}

	expected := filepath.Join(runtimeDir, "openresty", "nginx_native.conf")
	if outPath != expected {
		t.Fatalf("output path = %q, want %q", outPath, expected)
	}
}

func TestGenerateNativeConfig_WriteError(t *testing.T) {
	runtimeDir := t.TempDir()
	openrestyDir := filepath.Join(runtimeDir, "openresty")
	if err := os.MkdirAll(openrestyDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(openrestyDir, "nginx.conf"), []byte("listen 8080;\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	// Make the output file path unwritable by removing write permissions on the dir
	if err := os.Chmod(openrestyDir, 0o555); err != nil {
		t.Fatalf("chmod: %v", err)
	}
	t.Cleanup(func() { os.Chmod(openrestyDir, 0o755) })

	_, err := GenerateNativeConfig(runtimeDir, "8080")
	if err == nil {
		t.Fatal("expected error when output dir is not writable")
	}
	if !strings.Contains(err.Error(), "failed to write native nginx config") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestGenerateNativeConfig_DarwinBranch(t *testing.T) {
	origGOOS := configGOOS
	defer func() { configGOOS = origGOOS }()

	configGOOS = "darwin"

	runtimeDir := t.TempDir()
	openrestyDir := filepath.Join(runtimeDir, "openresty")
	if err := os.MkdirAll(openrestyDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	input := "events {\n  use epoll;\n}\nlisten 8080;\n"
	if err := os.WriteFile(filepath.Join(openrestyDir, "nginx.conf"), []byte(input), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	outPath, err := GenerateNativeConfig(runtimeDir, "8080")
	if err != nil {
		t.Fatalf("GenerateNativeConfig() error = %v", err)
	}

	content, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !strings.Contains(string(content), "use kqueue;") {
		t.Fatalf("expected kqueue on darwin, got:\n%s", string(content))
	}
	if strings.Contains(string(content), "use epoll;") {
		t.Fatal("expected epoll to be replaced with kqueue")
	}
}

func TestGenerateNativeConfig_NonDarwinBranch(t *testing.T) {
	origGOOS := configGOOS
	defer func() { configGOOS = origGOOS }()

	configGOOS = "linux"

	runtimeDir := t.TempDir()
	openrestyDir := filepath.Join(runtimeDir, "openresty")
	if err := os.MkdirAll(openrestyDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	input := "events {\n  use epoll;\n}\nlisten 8080;\n"
	if err := os.WriteFile(filepath.Join(openrestyDir, "nginx.conf"), []byte(input), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	outPath, err := GenerateNativeConfig(runtimeDir, "8080")
	if err != nil {
		t.Fatalf("GenerateNativeConfig() error = %v", err)
	}

	content, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !strings.Contains(string(content), "use epoll;") {
		t.Fatalf("expected epoll on linux, got:\n%s", string(content))
	}
}

func TestDetectSSLPath_FallbackWhenNoCertsExist(t *testing.T) {
	origStat := configStatFn
	defer func() { configStatFn = origStat }()

	// Make all Stat calls fail so no candidate is found.
	configStatFn = func(name string) (os.FileInfo, error) {
		return nil, errors.New("injected stat error")
	}

	path := detectSSLPath()
	if path != "/etc/ssl/cert.pem" {
		t.Fatalf("expected fallback path /etc/ssl/cert.pem, got %q", path)
	}
}

func TestGenerateNativeConfig_EventBackendOnCurrentOS(t *testing.T) {
	runtimeDir := t.TempDir()
	openrestyDir := filepath.Join(runtimeDir, "openresty")
	if err := os.MkdirAll(openrestyDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	input := "events {\n  use epoll;\n}\nlisten 8080;\n"
	if err := os.WriteFile(filepath.Join(openrestyDir, "nginx.conf"), []byte(input), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	outPath, err := GenerateNativeConfig(runtimeDir, "8080")
	if err != nil {
		t.Fatalf("GenerateNativeConfig() error = %v", err)
	}

	content, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatalf("read: %v", err)
	}

	if runtimepkg.GOOS == "darwin" {
		if !strings.Contains(string(content), "use kqueue;") {
			t.Fatalf("expected kqueue on darwin")
		}
	} else {
		if !strings.Contains(string(content), "use epoll;") {
			t.Fatalf("expected epoll on non-darwin")
		}
	}
}
