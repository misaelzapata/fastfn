//go:build linux

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"

	"github.com/mdlayher/vsock"
	"github.com/misaelzapata/fastfn/cli/internal/firecrackerboot"
	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"
)

const (
	configDrivePath = "/dev/vdb"
	loopbackHost    = "127.0.0.1"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "fastfn guest init error: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := readBootConfig(configDrivePath)
	if err != nil {
		return err
	}
	if len(cfg.Command) == 0 {
		return fmt.Errorf("boot config command is empty")
	}
	if err := mountRuntimeFilesystems(); err != nil {
		return err
	}
	if err := bringLoopbackUp(); err != nil {
		return err
	}
	if err := mountVolumes(cfg.Volumes); err != nil {
		return err
	}
	if err := configureInternalHosts(cfg.Services); err != nil {
		return err
	}
	if err := ensureHostResolutionConfig("/etc/nsswitch.conf"); err != nil {
		return err
	}
	if err := startServiceBridges(cfg.Services); err != nil {
		return err
	}
	if err := startInboundProxies(cfg.InboundPorts); err != nil {
		return err
	}

	cmd, err := startCommand(cfg)
	if err != nil {
		return err
	}
	return cmd.Wait()
}

func readBootConfig(path string) (firecrackerboot.Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return firecrackerboot.Config{}, fmt.Errorf("read boot config %s: %w", path, err)
	}
	if idx := bytes.IndexByte(raw, 0); idx >= 0 {
		raw = raw[:idx]
	}
	raw = bytes.TrimSpace(raw)
	var cfg firecrackerboot.Config
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return firecrackerboot.Config{}, fmt.Errorf("decode boot config: %w", err)
	}
	return cfg, nil
}

func mountRuntimeFilesystems() error {
	for _, spec := range []struct {
		source string
		target string
		fstype string
		flags  uintptr
		data   string
		mode   os.FileMode
	}{
		{source: "proc", target: "/proc", fstype: "proc", mode: 0o755},
		{source: "sysfs", target: "/sys", fstype: "sysfs", mode: 0o755},
		{source: "devtmpfs", target: "/dev", fstype: "devtmpfs", mode: 0o755},
		{source: "devpts", target: "/dev/pts", fstype: "devpts", mode: 0o755},
		{source: "tmpfs", target: "/run", fstype: "tmpfs", data: "mode=0755", mode: 0o755},
		{source: "tmpfs", target: "/tmp", fstype: "tmpfs", data: "mode=1777", mode: 0o1777},
	} {
		if err := mountIfNeeded(spec.source, spec.target, spec.fstype, spec.flags, spec.data, spec.mode); err != nil {
			return err
		}
	}
	return nil
}

func mountIfNeeded(source, target, fstype string, flags uintptr, data string, mode os.FileMode) error {
	if err := os.MkdirAll(target, mode); err != nil {
		return fmt.Errorf("create mount target %s: %w", target, err)
	}
	if err := unix.Mount(source, target, fstype, flags, data); err != nil && err != unix.EBUSY {
		return fmt.Errorf("mount %s on %s: %w", fstype, target, err)
	}
	return nil
}

func bringLoopbackUp() error {
	link, err := netlink.LinkByName("lo")
	if err != nil {
		return fmt.Errorf("lookup loopback: %w", err)
	}
	if err := netlink.LinkSetUp(link); err != nil {
		return fmt.Errorf("set loopback up: %w", err)
	}
	return nil
}

func mountVolumes(volumes []firecrackerboot.VolumeMount) error {
	for _, volume := range volumes {
		if strings.TrimSpace(volume.Target) == "" || strings.TrimSpace(volume.Device) == "" {
			continue
		}
		if err := os.MkdirAll(volume.Target, 0o755); err != nil {
			return fmt.Errorf("create volume target %s: %w", volume.Target, err)
		}
		if err := unix.Mount(volume.Device, volume.Target, "ext4", 0, ""); err != nil && err != unix.EBUSY {
			return fmt.Errorf("mount volume %s -> %s: %w", volume.Device, volume.Target, err)
		}
	}
	return nil
}

func startServiceBridges(services []firecrackerboot.ServiceBinding) error {
	for _, service := range services {
		if service.LocalPort < 1 || service.VsockPort < 1 {
			continue
		}
		host := strings.TrimSpace(service.LocalIP)
		if host == "" {
			host = loopbackHost
		}
		listener, err := net.Listen("tcp", net.JoinHostPort(host, strconv.Itoa(service.LocalPort)))
		if err != nil {
			return fmt.Errorf("listen service bridge %s: %w", service.Name, err)
		}
		go func(binding firecrackerboot.ServiceBinding, ln net.Listener) {
			for {
				conn, err := ln.Accept()
				if err != nil {
					return
				}
				go handleServiceConn(binding, conn)
			}
		}(service, listener)
	}
	return nil
}

func configureInternalHosts(services []firecrackerboot.ServiceBinding) error {
	entries := make([]hostEntry, 0, len(services))
	for _, service := range services {
		host := strings.TrimSpace(service.LocalHost)
		ip := strings.TrimSpace(service.LocalIP)
		if host == "" || ip == "" {
			continue
		}
		if err := addLoopbackIP(ip); err != nil {
			return err
		}
		entries = append(entries, hostEntry{Host: host, IP: ip})
	}
	if len(entries) == 0 {
		return nil
	}
	return writeHostsEntries("/etc/hosts", entries)
}

type hostEntry struct {
	Host string
	IP   string
}

func addLoopbackIP(ip string) error {
	addr, err := netlink.ParseAddr(ip + "/32")
	if err != nil {
		return fmt.Errorf("parse loopback ip %s: %w", ip, err)
	}
	link, err := netlink.LinkByName("lo")
	if err != nil {
		return fmt.Errorf("lookup loopback for %s: %w", ip, err)
	}
	if err := netlink.AddrAdd(link, addr); err != nil && err != unix.EEXIST {
		return fmt.Errorf("assign loopback ip %s: %w", ip, err)
	}
	return nil
}

func writeHostsEntries(path string, entries []hostEntry) error {
	existing, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("read hosts file %s: %w", path, err)
	}
	lines := []string{}
	if len(existing) > 0 {
		lines = append(lines, strings.Split(strings.TrimRight(string(existing), "\n"), "\n")...)
	}
	filtered := make([]string, 0, len(lines))
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			filtered = append(filtered, line)
			continue
		}
		if strings.HasPrefix(trimmed, "#") {
			filtered = append(filtered, line)
			continue
		}
		skip := false
		for _, entry := range entries {
			if strings.Contains(line, entry.Host) {
				skip = true
				break
			}
		}
		if !skip {
			filtered = append(filtered, line)
		}
	}
	for _, entry := range entries {
		filtered = append(filtered, entry.IP+" "+entry.Host)
	}
	payload := strings.Join(filtered, "\n")
	if !strings.HasSuffix(payload, "\n") {
		payload += "\n"
	}
	if err := os.WriteFile(path, []byte(payload), 0o644); err != nil {
		return fmt.Errorf("write hosts file %s: %w", path, err)
	}
	return nil
}

func ensureHostResolutionConfig(path string) error {
	data, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("read nsswitch file %s: %w", path, err)
	}

	lines := []string{}
	if len(data) > 0 {
		lines = strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	}
	found := false
	for idx, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "hosts:") {
			lines[idx] = "hosts: files dns"
			found = true
			break
		}
	}
	if !found {
		lines = append(lines, "hosts: files dns")
	}

	payload := strings.Join(lines, "\n")
	if !strings.HasSuffix(payload, "\n") {
		payload += "\n"
	}
	if err := os.WriteFile(path, []byte(payload), 0o644); err != nil {
		return fmt.Errorf("write nsswitch file %s: %w", path, err)
	}
	return nil
}

func handleServiceConn(binding firecrackerboot.ServiceBinding, localConn net.Conn) {
	defer localConn.Close()
	hostConn, err := vsock.Dial(vsock.Host, uint32(binding.VsockPort), nil)
	if err != nil {
		return
	}
	defer hostConn.Close()
	copyBidirectional(localConn, hostConn)
}

func startInboundProxies(inbound []firecrackerboot.InboundPort) error {
	for _, port := range inbound {
		if port.GuestPort < 1 || port.ContainerPort < 1 {
			continue
		}
		listener, err := vsock.Listen(uint32(port.GuestPort), nil)
		if err != nil {
			return fmt.Errorf("listen vsock port %d: %w", port.GuestPort, err)
		}
		go func(binding firecrackerboot.InboundPort, ln net.Listener) {
			for {
				conn, err := ln.Accept()
				if err != nil {
					return
				}
				go handleInboundConn(binding, conn)
			}
		}(port, listener)
	}
	return nil
}

func handleInboundConn(binding firecrackerboot.InboundPort, guestConn net.Conn) {
	defer guestConn.Close()
	localConn, err := net.Dial("tcp", net.JoinHostPort(loopbackHost, strconv.Itoa(binding.ContainerPort)))
	if err != nil {
		return
	}
	defer localConn.Close()
	copyBidirectional(guestConn, localConn)
}

func startCommand(cfg firecrackerboot.Config) (*exec.Cmd, error) {
	command := append([]string{}, cfg.Command...)
	cmd := exec.Command(command[0], command[1:]...)
	cmd.Dir = workingDir(cfg.WorkingDir)
	cmd.Env = envList(cfg.Env)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin

	cred, err := resolveCredential(cfg.User)
	if err != nil {
		return nil, err
	}
	if cred != nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{Credential: cred}
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return cmd, nil
}

func resolveCredential(spec string) (*syscall.Credential, error) {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		return nil, nil
	}

	userPart, groupPart, _ := strings.Cut(spec, ":")
	uid, gid, err := lookupUser(userPart)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(groupPart) != "" {
		gid, err = lookupGroup(groupPart)
		if err != nil {
			return nil, err
		}
	}
	return &syscall.Credential{
		Uid: uint32(uid),
		Gid: uint32(gid),
	}, nil
}

func lookupUser(spec string) (int, int, error) {
	if uid, err := strconv.Atoi(spec); err == nil {
		return uid, uid, nil
	}
	entry, err := user.Lookup(spec)
	if err != nil {
		return 0, 0, fmt.Errorf("lookup user %q: %w", spec, err)
	}
	uid, err := strconv.Atoi(entry.Uid)
	if err != nil {
		return 0, 0, fmt.Errorf("parse uid for %q: %w", spec, err)
	}
	gid, err := strconv.Atoi(entry.Gid)
	if err != nil {
		return 0, 0, fmt.Errorf("parse gid for %q: %w", spec, err)
	}
	return uid, gid, nil
}

func lookupGroup(spec string) (int, error) {
	if gid, err := strconv.Atoi(spec); err == nil {
		return gid, nil
	}
	entry, err := user.LookupGroup(spec)
	if err != nil {
		return 0, fmt.Errorf("lookup group %q: %w", spec, err)
	}
	gid, err := strconv.Atoi(entry.Gid)
	if err != nil {
		return 0, fmt.Errorf("parse gid for group %q: %w", spec, err)
	}
	return gid, nil
}

func workingDir(dir string) string {
	dir = strings.TrimSpace(dir)
	if dir == "" {
		return "/"
	}
	return filepath.Clean(dir)
}

func envList(env map[string]string) []string {
	if len(env) == 0 {
		return nil
	}
	keys := make([]string, 0, len(env))
	for key := range env {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	out := make([]string, 0, len(keys))
	for _, key := range keys {
		out = append(out, key+"="+env[key])
	}
	return out
}

func copyBidirectional(left net.Conn, right net.Conn) {
	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(left, right)
		if closer, ok := left.(interface{ CloseWrite() error }); ok {
			_ = closer.CloseWrite()
		}
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(right, left)
		if closer, ok := right.(interface{ CloseWrite() error }); ok {
			_ = closer.CloseWrite()
		}
		done <- struct{}{}
	}()
	<-done
	<-done
}
