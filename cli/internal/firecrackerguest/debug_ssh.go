//go:build linux

package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"strings"

	"github.com/misaelzapata/fastfn/cli/internal/firecrackerboot"
	"golang.org/x/crypto/ssh"
)

func startDebugSSH(cfg firecrackerboot.DebugSSHConfig) error {
	if cfg.LocalPort < 1 || strings.TrimSpace(cfg.AuthorizedKey) == "" {
		return nil
	}
	serverCfg, err := newDebugSSHServerConfig(cfg)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", net.JoinHostPort(loopbackHost, fmt.Sprintf("%d", cfg.LocalPort)))
	if err != nil {
		return fmt.Errorf("listen debug ssh tcp port %d: %w", cfg.LocalPort, err)
	}
	go serveDebugSSH(listener, serverCfg)
	return nil
}

func serveDebugSSH(listener net.Listener, cfg *ssh.ServerConfig) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		go handleDebugSSHConn(conn, cfg)
	}
}

func newDebugSSHServerConfig(cfg firecrackerboot.DebugSSHConfig) (*ssh.ServerConfig, error) {
	authorizedKey, err := parseAuthorizedSSHKey(cfg.AuthorizedKey)
	if err != nil {
		return nil, err
	}
	user := strings.TrimSpace(cfg.User)
	if user == "" {
		user = "root"
	}
	hostSigner, err := debugSSHHostSigner(cfg.HostKeyPEM)
	if err != nil {
		return nil, err
	}
	serverCfg := &ssh.ServerConfig{
		PublicKeyCallback: func(metadata ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
			if metadata.User() != user {
				return nil, fmt.Errorf("debug ssh user %q is not allowed", metadata.User())
			}
			if !bytes.Equal(key.Marshal(), authorizedKey.Marshal()) {
				return nil, errors.New("debug ssh key rejected")
			}
			return nil, nil
		},
	}
	serverCfg.AddHostKey(hostSigner)
	return serverCfg, nil
}

func parseAuthorizedSSHKey(raw string) (ssh.PublicKey, error) {
	key, _, _, _, err := ssh.ParseAuthorizedKey([]byte(strings.TrimSpace(raw)))
	if err != nil {
		return nil, fmt.Errorf("parse debug ssh authorized key: %w", err)
	}
	return key, nil
}

func debugSSHHostSigner(hostKeyPEM string) (ssh.Signer, error) {
	if strings.TrimSpace(hostKeyPEM) != "" {
		signer, err := ssh.ParsePrivateKey([]byte(hostKeyPEM))
		if err != nil {
			return nil, fmt.Errorf("parse debug ssh host key: %w", err)
		}
		return signer, nil
	}
	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generate debug ssh host key: %w", err)
	}
	signer, err := ssh.NewSignerFromKey(privateKey)
	if err != nil {
		return nil, fmt.Errorf("build debug ssh host signer: %w", err)
	}
	return signer, nil
}

func handleDebugSSHConn(conn net.Conn, cfg *ssh.ServerConfig) {
	defer conn.Close()
	serverConn, channels, requests, err := ssh.NewServerConn(conn, cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "fastfn guest debug ssh handshake failed: %v\n", err)
		return
	}
	defer serverConn.Close()
	go ssh.DiscardRequests(requests)

	for newChannel := range channels {
		if newChannel.ChannelType() != "session" {
			_ = newChannel.Reject(ssh.UnknownChannelType, "unsupported channel type")
			continue
		}
		channel, requests, err := newChannel.Accept()
		if err != nil {
			continue
		}
		go handleDebugSSHSession(channel, requests)
	}
}

func handleDebugSSHSession(channel ssh.Channel, requests <-chan *ssh.Request) {
	defer channel.Close()
	for req := range requests {
		switch req.Type {
		case "pty-req", "window-change", "env":
			_ = req.Reply(true, nil)
		case "shell":
			_ = req.Reply(true, nil)
			runDebugSSHCommand(channel, "")
			return
		case "exec":
			var payload struct {
				Command string
			}
			if err := ssh.Unmarshal(req.Payload, &payload); err != nil {
				_ = req.Reply(false, nil)
				return
			}
			_ = req.Reply(true, nil)
			runDebugSSHCommand(channel, payload.Command)
			return
		default:
			_ = req.Reply(false, nil)
		}
	}
}

func runDebugSSHCommand(channel ssh.Channel, rawCommand string) {
	exitCode := uint32(0)
	if err := executeDebugSSHCommand(channel, rawCommand); err != nil {
		exitCode = 255
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			if code := exitErr.ExitCode(); code >= 0 {
				exitCode = uint32(code)
			}
		} else {
			_, _ = io.WriteString(channel.Stderr(), err.Error()+"\n")
		}
	}
	_, _ = channel.SendRequest("exit-status", false, ssh.Marshal(struct {
		Status uint32
	}{Status: exitCode}))
}

func executeDebugSSHCommand(channel ssh.Channel, rawCommand string) error {
	shell := debugShellPath()
	if shell == "" {
		return fmt.Errorf("no debug shell was found inside the guest")
	}
	args := []string{shell, "-i"}
	if strings.TrimSpace(rawCommand) != "" {
		args = []string{shell, "-lc", rawCommand}
	}
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir = "/"
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")
	cmd.Stdin = channel
	cmd.Stdout = channel
	cmd.Stderr = channel.Stderr()
	return cmd.Run()
}

func debugShellPath() string {
	for _, candidate := range []string{"/bin/bash", "/bin/sh", "/busybox/sh"} {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate
		}
	}
	return ""
}
