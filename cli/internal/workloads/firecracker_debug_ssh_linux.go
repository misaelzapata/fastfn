//go:build linux

package workloads

import (
	"crypto/ed25519"
	"crypto/rsa"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/crypto/ssh"
)

const (
	defaultDebugSSHGuestPort = 2222
	defaultDebugSSHLocalPort = 2222
	defaultDebugSSHUser      = "root"
)

type workloadDebugSSH struct {
	GuestPort      int
	LocalPort      int
	User           string
	AuthorizedKey  string
	HostKeyPEM     string
	PrivateKeyPath string
}

func firecrackerDebugSSHEnabled() bool {
	value := strings.ToLower(strings.TrimSpace(os.Getenv("FN_FIRECRACKER_DEBUG_SSH")))
	switch value {
	case "1", "true", "yes", "on", "debug", "ssh":
		return true
	default:
		return false
	}
}

func firecrackerDebugSSHUser() string {
	value := strings.TrimSpace(os.Getenv("FN_FIRECRACKER_DEBUG_SSH_USER"))
	if value == "" {
		return defaultDebugSSHUser
	}
	return value
}

func planDebugSSH(vmDir string) (*workloadDebugSSH, error) {
	if !firecrackerDebugSSHEnabled() {
		return nil, nil
	}
	privateKeyPEM, authorizedKey, err := generateDebugSSHKeyPair()
	if err != nil {
		return nil, err
	}
	hostKeyPEM, err := generateDebugSSHPrivateKeyPEM()
	if err != nil {
		return nil, err
	}
	privateKeyPath := filepath.Join(vmDir, "debug_ssh_ed25519")
	if err := os.WriteFile(privateKeyPath, privateKeyPEM, 0o600); err != nil {
		return nil, fmt.Errorf("write firecracker debug ssh key %s: %w", privateKeyPath, err)
	}
	return &workloadDebugSSH{
		GuestPort:      defaultDebugSSHGuestPort,
		LocalPort:      defaultDebugSSHLocalPort,
		User:           firecrackerDebugSSHUser(),
		AuthorizedKey:  strings.TrimSpace(string(authorizedKey)),
		HostKeyPEM:     string(hostKeyPEM),
		PrivateKeyPath: privateKeyPath,
	}, nil
}

func generateDebugSSHKeyPair() ([]byte, []byte, error) {
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, nil, fmt.Errorf("generate debug ssh rsa key: %w", err)
	}
	signer, err := ssh.NewSignerFromKey(privateKey)
	if err != nil {
		return nil, nil, fmt.Errorf("build debug ssh signer: %w", err)
	}
	privateKeyPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(privateKey),
	})
	return privateKeyPEM, ssh.MarshalAuthorizedKey(signer.PublicKey()), nil
}

func generateDebugSSHPrivateKeyPEM() ([]byte, error) {
	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generate debug ssh private key: %w", err)
	}
	encodedKey, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return nil, fmt.Errorf("marshal debug ssh host key: %w", err)
	}
	return pem.EncodeToMemory(&pem.Block{
		Type:  "PRIVATE KEY",
		Bytes: encodedKey,
	}), nil
}
