//go:build linux

package workloads

import (
	"os"
	"strings"
	"testing"
)

func TestPlanDebugSSH_WritesEphemeralKeyPair(t *testing.T) {
	t.Setenv("FN_FIRECRACKER_DEBUG_SSH", "1")
	t.Setenv("FN_FIRECRACKER_DEBUG_SSH_USER", "debugger")

	cfg, err := planDebugSSH(t.TempDir())
	if err != nil {
		t.Fatalf("planDebugSSH() error = %v", err)
	}
	if cfg == nil {
		t.Fatal("planDebugSSH() = nil, want config")
	}
	if cfg.GuestPort != defaultDebugSSHGuestPort {
		t.Fatalf("GuestPort = %d, want %d", cfg.GuestPort, defaultDebugSSHGuestPort)
	}
	if cfg.User != "debugger" {
		t.Fatalf("User = %q, want debugger", cfg.User)
	}
	if !strings.HasPrefix(cfg.AuthorizedKey, "ssh-rsa ") {
		t.Fatalf("AuthorizedKey = %q", cfg.AuthorizedKey)
	}
	if !strings.Contains(cfg.HostKeyPEM, "PRIVATE KEY") {
		t.Fatalf("HostKeyPEM = %q", cfg.HostKeyPEM)
	}
	keyBytes, err := os.ReadFile(cfg.PrivateKeyPath)
	if err != nil {
		t.Fatalf("ReadFile(%q) error = %v", cfg.PrivateKeyPath, err)
	}
	if !strings.Contains(string(keyBytes), "PRIVATE KEY") {
		t.Fatalf("private key file does not look like a PEM key: %q", string(keyBytes))
	}
}
