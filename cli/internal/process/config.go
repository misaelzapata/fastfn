package process

import (
	"fmt"
	"os"
	"path/filepath"
	goruntime "runtime"
	"strconv"
	"strings"
)

// GenerateNativeConfig adapts the embedded nginx.conf for host execution.
// runtimeDir: path where the runtime assets were extracted
// hostPort: HTTP port for local listener (default: 8080)
func GenerateNativeConfig(runtimeDir string, hostPort string) (string, error) {
	configPath := filepath.Join(runtimeDir, "openresty", "nginx.conf")

	contentBytes, err := os.ReadFile(configPath)
	if err != nil {
		return "", fmt.Errorf("failed to read input nginx config: %w", err)
	}
	content := string(contentBytes)

	// 1. Detect SSL path
	sslPath := detectSSLPath()

	// 2. Replace the Linux-specific SSL path with the host one
	// The original file has: /etc/ssl/certs/ca-certificates.crt
	content = strings.ReplaceAll(content, "/etc/ssl/certs/ca-certificates.crt", sslPath)

	// 2b. Event backend: epoll is Linux-only.
	if goruntime.GOOS == "darwin" {
		content = strings.ReplaceAll(content, "use epoll;", "use kqueue;")
	}

	// 3. Native listener port override.
	if hostPort == "" {
		hostPort = "8080"
	}
	if _, err := strconv.Atoi(hostPort); err != nil {
		return "", fmt.Errorf("invalid native host port %q", hostPort)
	}
	content = strings.Replace(content, "listen 8080;", fmt.Sprintf("listen %s;", hostPort), 1)

	// 4. Fix Lua path injection if needed, though -p flag should handle $prefix.
	// But just in case, verify if any other hardcoded paths exist.

	// 5. Write back to a new file
	newConfigPath := filepath.Join(runtimeDir, "openresty", "nginx_native.conf")
	if err := os.WriteFile(newConfigPath, []byte(content), 0644); err != nil {
		return "", fmt.Errorf("failed to write native nginx config: %w", err)
	}

	return newConfigPath, nil
}

func detectSSLPath() string {
	candidates := []string{
		"/etc/ssl/cert.pem",                    // macOS System
		"/etc/ssl/certs/ca-certificates.crt",   // Linux (Debian/Ubuntu)
		"/etc/pki/tls/certs/ca-bundle.crt",     // Linux (RHEL/CentOS)
		"/usr/local/etc/openssl@1.1/cert.pem",  // Homebrew (Intel)
		"/opt/homebrew/etc/openssl@3/cert.pem", // Homebrew (Apple Silicon)
	}

	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}

	// Fallback to the one in the conf if nothing found (might fail but better than empty)
	return "/etc/ssl/cert.pem"
}
