//go:build linux

package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"net"
	"testing"
	"time"

	"github.com/misaelzapata/fastfn/cli/internal/firecrackerboot"
	"golang.org/x/crypto/ssh"
)

func TestDebugSSH_AllowsExecWithAuthorizedKey(t *testing.T) {
	clientSigner, authorizedKey := testDebugSSHClientSigner(t)
	serverCfg, err := newDebugSSHServerConfig(firecrackerboot.DebugSSHConfig{
		User:          "root",
		AuthorizedKey: string(authorizedKey),
	})
	if err != nil {
		t.Fatalf("newDebugSSHServerConfig() error = %v", err)
	}

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen() error = %v", err)
	}
	defer listener.Close()
	go serveDebugSSH(listener, serverCfg)

	client, err := ssh.Dial("tcp", listener.Addr().String(), &ssh.ClientConfig{
		User:            "root",
		Auth:            []ssh.AuthMethod{ssh.PublicKeys(clientSigner)},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         2 * time.Second,
	})
	if err != nil {
		t.Fatalf("ssh.Dial() error = %v", err)
	}
	defer client.Close()

	session, err := client.NewSession()
	if err != nil {
		t.Fatalf("NewSession() error = %v", err)
	}
	defer session.Close()

	output, err := session.CombinedOutput("printf fastfn-ssh-ok")
	if err != nil {
		t.Fatalf("CombinedOutput() error = %v, output = %q", err, string(output))
	}
	if string(output) != "fastfn-ssh-ok" {
		t.Fatalf("output = %q, want fastfn-ssh-ok", string(output))
	}
}

func testDebugSSHClientSigner(t *testing.T) (ssh.Signer, []byte) {
	t.Helper()
	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey() error = %v", err)
	}
	signer, err := ssh.NewSignerFromKey(privateKey)
	if err != nil {
		t.Fatalf("NewSignerFromKey() error = %v", err)
	}
	return signer, ssh.MarshalAuthorizedKey(signer.PublicKey())
}
