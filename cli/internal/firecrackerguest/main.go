//go:build linux

package main

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
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
	"time"
	"unsafe"

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
	if err := seedGuestEntropy(cfg.EntropySeed); err != nil {
		return err
	}
	if err := ensureStandardDeviceLinks("/dev"); err != nil {
		return err
	}
	if err := bringLoopbackUp(); err != nil {
		return err
	}
	if err := configureHostname(cfg.Name); err != nil {
		return err
	}
	if err := mountVolumes(cfg.Volumes); err != nil {
		return err
	}
	if err := configureInternalHosts(cfg.Name, cfg.Services); err != nil {
		return err
	}
	if err := ensureHostResolutionConfig("/etc/nsswitch.conf"); err != nil {
		return err
	}
	logResolverConfig(cfg.Name, cfg.Services)
	if err := startServiceBridges(cfg.Services); err != nil {
		return err
	}
	if err := startInboundProxies(cfg.InboundPorts); err != nil {
		return err
	}
	if err := startDebugSSH(cfg.DebugSSH); err != nil {
		return err
	}

	cmd, err := startCommand(cfg)
	if err != nil {
		return err
	}
	if cfg.Debug {
		logGuestCommandStart(cfg, cmd)
		logGuestDebugSnapshots(cfg, cmd.Process.Pid)
	}
	err = cmd.Wait()
	if cfg.Debug {
		logGuestCommandExit(cfg, cmd, err)
	}
	return err
}

func seedGuestEntropy(raw string) error {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	seed, err := hex.DecodeString(raw)
	if err != nil {
		return fmt.Errorf("decode guest entropy seed: %w", err)
	}
	if len(seed) == 0 {
		return nil
	}
	mode := "ioctl"
	if err := addGuestEntropy(seed); err != nil {
		if fallbackErr := writeGuestEntropy(seed); fallbackErr != nil {
			return fmt.Errorf("seed guest entropy: ioctl failed: %v; write fallback failed: %w", err, fallbackErr)
		}
		mode = "write"
	}
	fmt.Fprintf(os.Stdout, "fastfn guest entropy mode=%q bytes=%d status=%q\n", mode, len(seed), guestEntropyStatus())
	return nil
}

func addGuestEntropy(seed []byte) error {
	file, err := os.OpenFile("/dev/random", os.O_RDONLY, 0)
	if err != nil {
		return fmt.Errorf("open /dev/random: %w", err)
	}
	defer file.Close()

	payload := guestEntropyPayload(seed)
	if len(payload) == 0 {
		return nil
	}
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, file.Fd(), uintptr(unix.RNDADDENTROPY), uintptr(unsafe.Pointer(&payload[0]))); errno != 0 {
		return errno
	}
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, file.Fd(), uintptr(unix.RNDRESEEDCRNG), 0)
	if errno != 0 && errno != unix.ENOTTY && errno != unix.EINVAL {
		return errno
	}
	return nil
}

func guestEntropyPayload(seed []byte) []byte {
	if len(seed) == 0 {
		return nil
	}
	payload := make([]byte, 8+len(seed))
	binary.NativeEndian.PutUint32(payload[0:4], uint32(len(seed)*8))
	binary.NativeEndian.PutUint32(payload[4:8], uint32(len(seed)))
	copy(payload[8:], seed)
	return payload
}

func writeGuestEntropy(seed []byte) error {
	file, err := os.OpenFile("/dev/urandom", os.O_WRONLY, 0)
	if err != nil {
		return fmt.Errorf("open /dev/urandom: %w", err)
	}
	defer file.Close()
	if _, err := file.Write(seed); err != nil {
		return fmt.Errorf("write /dev/urandom: %w", err)
	}
	return nil
}

func guestEntropyStatus() string {
	buf := make([]byte, 32)
	n, err := unix.Getrandom(buf, unix.GRND_NONBLOCK)
	if err != nil {
		return fmt.Sprintf("getrandom:%v", err)
	}
	return fmt.Sprintf("getrandom:%d", n)
}

func configureHostname(name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return nil
	}
	if err := unix.Sethostname([]byte(name)); err != nil {
		return fmt.Errorf("set hostname %s: %w", name, err)
	}
	if err := os.WriteFile("/etc/hostname", []byte(name+"\n"), 0o644); err != nil {
		return fmt.Errorf("write hostname file: %w", err)
	}
	return nil
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
		{source: "tmpfs", target: "/dev/shm", fstype: "tmpfs", data: "mode=1777", mode: 0o1777},
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

func ensureStandardDeviceLinks(devRoot string) error {
	links := map[string]string{
		"fd":     "/proc/self/fd",
		"stdin":  "/proc/self/fd/0",
		"stdout": "/proc/self/fd/1",
		"stderr": "/proc/self/fd/2",
	}
	for name, target := range links {
		path := filepath.Join(devRoot, name)
		info, err := os.Lstat(path)
		if err == nil {
			if info.Mode()&os.ModeSymlink != 0 {
				current, readErr := os.Readlink(path)
				if readErr == nil && current == target {
					continue
				}
			}
			if removeErr := os.Remove(path); removeErr != nil {
				return fmt.Errorf("replace device link %s: %w", path, removeErr)
			}
		} else if !os.IsNotExist(err) {
			return fmt.Errorf("stat device link %s: %w", path, err)
		}
		if err := os.Symlink(target, path); err != nil {
			return fmt.Errorf("create device link %s -> %s: %w", path, target, err)
		}
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
		stagingRoot, dataRoot := volumeMountPaths(volume.Name)
		if err := os.MkdirAll(stagingRoot, 0o755); err != nil {
			return fmt.Errorf("create volume staging root %s: %w", stagingRoot, err)
		}
		if err := unix.Mount(volume.Device, stagingRoot, "ext4", 0, ""); err != nil && err != unix.EBUSY {
			return fmt.Errorf("mount volume %s -> %s: %w", volume.Device, stagingRoot, err)
		}
		if err := os.MkdirAll(dataRoot, 0o755); err != nil {
			return fmt.Errorf("create volume data root %s: %w", dataRoot, err)
		}
		if err := os.MkdirAll(volume.Target, 0o755); err != nil {
			return fmt.Errorf("create volume target %s: %w", volume.Target, err)
		}
		if err := unix.Mount(dataRoot, volume.Target, "", unix.MS_BIND, ""); err != nil && err != unix.EBUSY {
			return fmt.Errorf("bind mount volume %s -> %s: %w", dataRoot, volume.Target, err)
		}
	}
	return nil
}

func volumeMountPaths(name string) (string, string) {
	token := sanitizeVolumeMountName(name)
	stagingRoot := filepath.Join("/run", "fastfn", "volumes", token)
	return stagingRoot, filepath.Join(stagingRoot, "data")
}

func sanitizeVolumeMountName(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return "volume"
	}
	var builder strings.Builder
	for _, r := range name {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			builder.WriteRune(r)
		case r == '-', r == '_', r == '.':
			builder.WriteRune(r)
		default:
			builder.WriteByte('-')
		}
	}
	if builder.Len() == 0 {
		return "volume"
	}
	return builder.String()
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

func configureInternalHosts(hostname string, services []firecrackerboot.ServiceBinding) error {
	entries := defaultHostEntries(hostname)
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
	return writeHostsEntries("/etc/hosts", entries)
}

type hostEntry struct {
	Host string
	IP   string
}

func defaultHostEntries(hostname string) []hostEntry {
	entries := []hostEntry{
		{Host: "localhost", IP: "127.0.0.1"},
		{Host: "localhost", IP: "::1"},
	}
	hostname = strings.TrimSpace(hostname)
	if hostname != "" && hostname != "localhost" {
		entries = append(entries, hostEntry{Host: hostname, IP: "127.0.1.1"})
	}
	return entries
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

func logResolverConfig(hostname string, services []firecrackerboot.ServiceBinding) {
	internalHosts := make([]string, 0, len(services))
	for _, service := range services {
		host := strings.TrimSpace(service.LocalHost)
		ip := strings.TrimSpace(service.LocalIP)
		if host == "" {
			continue
		}
		if ip != "" {
			internalHosts = append(internalHosts, host+"="+ip)
			continue
		}
		internalHosts = append(internalHosts, host)
	}
	sort.Strings(internalHosts)

	fmt.Fprintf(
		os.Stdout,
		"fastfn guest resolver hostname=%q hosts=%q nsswitch=%q resolv=%q internal=%q\n",
		strings.TrimSpace(hostname),
		relevantResolverLines("/etc/hosts", ".internal", "localhost", hostname),
		relevantResolverLines("/etc/nsswitch.conf", "hosts:"),
		relevantResolverLines("/etc/resolv.conf", "nameserver", "search", "options"),
		strings.Join(internalHosts, ","),
	)
}

func relevantResolverLines(path string, patterns ...string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	matched := make([]string, 0, len(lines))
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		for _, pattern := range patterns {
			pattern = strings.TrimSpace(pattern)
			if pattern == "" {
				continue
			}
			if strings.Contains(trimmed, pattern) {
				matched = append(matched, trimmed)
				break
			}
		}
	}
	return strings.Join(matched, "; ")
}

func handleServiceConn(binding firecrackerboot.ServiceBinding, localConn net.Conn) {
	defer localConn.Close()
	hostConn, err := vsock.Dial(vsock.Host, uint32(binding.VsockPort), nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "fastfn guest service bridge name=%q vsock_port=%d dial failed: %v\n", binding.Name, binding.VsockPort, err)
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
		fmt.Fprintf(os.Stderr, "fastfn guest inbound proxy name=%q guest_port=%d container_port=%d dial failed: %v\n", binding.Name, binding.GuestPort, binding.ContainerPort, err)
		return
	}
	defer localConn.Close()
	copyBidirectional(guestConn, localConn)
}

func logGuestCommandStart(cfg firecrackerboot.Config, cmd *exec.Cmd) {
	fmt.Fprintf(
		os.Stdout,
		"fastfn guest debug start name=%q kind=%q pid=%d cwd=%q user=%q command=%q env_count=%d listeners=%q procs=%q sockets=%q\n",
		cfg.Name,
		cfg.Kind,
		cmd.Process.Pid,
		cmd.Dir,
		cfg.User,
		strings.Join(cmd.Args, " "),
		len(cmd.Env),
		strings.Join(tcpListenersSummary(), ","),
		processTableSummary(),
		socketFileSummary(),
	)
}

func logGuestCommandExit(cfg firecrackerboot.Config, cmd *exec.Cmd, err error) {
	status := "ok"
	if err != nil {
		status = err.Error()
	}
	fmt.Fprintf(
		os.Stdout,
		"fastfn guest debug exit name=%q kind=%q pid=%d status=%q listeners=%q proc=%q procs=%q sockets=%q\n",
		cfg.Name,
		cfg.Kind,
		cmd.Process.Pid,
		status,
		strings.Join(tcpListenersSummary(), ","),
		procStatusSummary(cmd.Process.Pid),
		processTableSummary(),
		socketFileSummary(),
	)
}

func logGuestDebugSnapshots(cfg firecrackerboot.Config, pid int) {
	for _, delay := range []time.Duration{2 * time.Second, 8 * time.Second, 20 * time.Second} {
		go func(after time.Duration) {
			time.Sleep(after)
			fmt.Fprintf(
				os.Stdout,
				"fastfn guest debug snapshot name=%q kind=%q after=%s pid=%d proc=%q listeners=%q procs=%q sockets=%q\n",
				cfg.Name,
				cfg.Kind,
				after.String(),
				pid,
				procStatusSummary(pid),
				strings.Join(tcpListenersSummary(), ","),
				processTableSummary(),
				socketFileSummary(),
			)
		}(delay)
	}
}

func procStatusSummary(pid int) string {
	if pid <= 0 {
		return ""
	}
	path := filepath.Join("/proc", strconv.Itoa(pid), "status")
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Sprintf("status_unavailable:%v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	keep := []string{}
	for _, line := range lines {
		switch {
		case strings.HasPrefix(line, "Name:"),
			strings.HasPrefix(line, "State:"),
			strings.HasPrefix(line, "Pid:"),
			strings.HasPrefix(line, "PPid:"),
			strings.HasPrefix(line, "Uid:"),
			strings.HasPrefix(line, "Gid:"),
			strings.HasPrefix(line, "Threads:"),
			strings.HasPrefix(line, "VmRSS:"):
			keep = append(keep, strings.TrimSpace(line))
		}
	}
	return strings.Join(keep, "; ")
}

func tcpListenersSummary() []string {
	seen := map[string]struct{}{}
	for _, path := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		lines := strings.Split(strings.TrimSpace(string(data)), "\n")
		for idx, line := range lines {
			if idx == 0 {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) < 4 || fields[3] != "0A" {
				continue
			}
			addr := decodeProcNetAddr(fields[1])
			if addr == "" {
				continue
			}
			seen[addr] = struct{}{}
		}
	}
	out := make([]string, 0, len(seen))
	for value := range seen {
		out = append(out, value)
	}
	sort.Strings(out)
	return out
}

func decodeProcNetAddr(raw string) string {
	hostHex, portHex, ok := strings.Cut(strings.TrimSpace(raw), ":")
	if !ok {
		return ""
	}
	portValue, err := strconv.ParseUint(portHex, 16, 16)
	if err != nil {
		return ""
	}
	if len(hostHex) == 8 {
		buf, err := hex.DecodeString(hostHex)
		if err != nil || len(buf) != 4 {
			return ""
		}
		return net.IPv4(buf[3], buf[2], buf[1], buf[0]).String() + ":" + strconv.FormatUint(portValue, 10)
	}
	return hostHex + ":" + strconv.FormatUint(portValue, 10)
}

func processTableSummary() string {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return ""
	}
	type procLine struct {
		pid  int
		line string
	}
	lines := make([]procLine, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid <= 0 {
			continue
		}
		status := procStatusSummary(pid)
		if status == "" {
			continue
		}
		cmdlineBytes, _ := os.ReadFile(filepath.Join("/proc", entry.Name(), "cmdline"))
		cmdline := strings.ReplaceAll(string(bytes.TrimRight(cmdlineBytes, "\x00")), "\x00", " ")
		ppid := procStatusValue(status, "PPid:")
		state := procStatusValue(status, "State:")
		if strings.TrimSpace(cmdline) == "" && pid != 1 && ppid == "2" && !strings.HasPrefix(state, "Z") {
			continue
		}
		line := status
		if strings.TrimSpace(cmdline) != "" {
			line += "; Cmd: " + cmdline
		}
		lines = append(lines, procLine{pid: pid, line: line})
	}
	sort.Slice(lines, func(i, j int) bool {
		return lines[i].pid < lines[j].pid
	})
	if len(lines) > 12 {
		lines = lines[:12]
	}
	out := make([]string, 0, len(lines))
	for _, item := range lines {
		out = append(out, item.line)
	}
	return strings.Join(out, " | ")
}

func procStatusValue(summary, prefix string) string {
	prefix = strings.TrimSpace(prefix)
	for _, field := range strings.Split(summary, ";") {
		field = strings.TrimSpace(field)
		if strings.HasPrefix(field, prefix) {
			return strings.TrimSpace(strings.TrimPrefix(field, prefix))
		}
	}
	return ""
}

func socketFileSummary() string {
	roots := []string{"/run", "/var/run", "/tmp"}
	found := []string{}
	for _, root := range roots {
		info, err := os.Stat(root)
		if err != nil || !info.IsDir() {
			continue
		}
		_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
			if err != nil || info == nil {
				return nil
			}
			if info.Mode()&os.ModeSocket != 0 {
				found = append(found, path)
			}
			return nil
		})
	}
	sort.Strings(found)
	if len(found) > 16 {
		found = found[:16]
	}
	return strings.Join(found, ",")
}

func startCommand(cfg firecrackerboot.Config) (*exec.Cmd, error) {
	command := append([]string{}, cfg.Command...)
	executable, err := resolveCommandExecutable(command[0], cfg.Env)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(executable, command[1:]...)
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

func resolveCommandExecutable(name string, env map[string]string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", fmt.Errorf("command executable is empty")
	}
	if strings.ContainsRune(name, os.PathSeparator) {
		return name, nil
	}
	pathValue := strings.TrimSpace(env["PATH"])
	if pathValue == "" {
		pathValue = strings.TrimSpace(os.Getenv("PATH"))
	}
	if pathValue == "" {
		pathValue = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	}
	return lookPathWithValue(name, pathValue)
}

func lookPathWithValue(name, pathValue string) (string, error) {
	for _, dir := range filepath.SplitList(pathValue) {
		if dir == "" {
			dir = "."
		}
		candidate := filepath.Join(dir, name)
		info, err := os.Stat(candidate)
		if err != nil {
			continue
		}
		mode := info.Mode()
		if mode.IsRegular() && mode&0o111 != 0 {
			return candidate, nil
		}
	}
	return "", &exec.Error{Name: name, Err: exec.ErrNotFound}
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
