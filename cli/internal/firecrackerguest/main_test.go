//go:build linux

package main

import (
	"encoding/binary"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteHostsEntries_ReplacesExistingInternalEntry(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hosts")
	initial := "127.0.0.1 localhost\n127.77.0.9 mysql-main.internal\n"
	if err := os.WriteFile(path, []byte(initial), 0o644); err != nil {
		t.Fatalf("write hosts file: %v", err)
	}

	err := writeHostsEntries(path, append(defaultHostEntries("api"), []hostEntry{
		{Host: "mysql-main.internal", IP: "127.77.0.1"},
		{Host: "worker.internal", IP: "127.77.0.2"},
	}...))
	if err != nil {
		t.Fatalf("writeHostsEntries() error = %v", err)
	}

	gotBytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read hosts file: %v", err)
	}
	got := string(gotBytes)
	if !strings.Contains(got, "127.0.0.1 localhost\n") {
		t.Fatalf("hosts missing localhost entry: %q", got)
	}
	if strings.Contains(got, "127.77.0.9 mysql-main.internal") {
		t.Fatalf("hosts kept stale internal entry: %q", got)
	}
	if !strings.Contains(got, "127.77.0.1 mysql-main.internal\n") {
		t.Fatalf("hosts missing updated mysql-main entry: %q", got)
	}
	if !strings.Contains(got, "127.77.0.2 worker.internal\n") {
		t.Fatalf("hosts missing worker entry: %q", got)
	}
	if !strings.Contains(got, "127.0.1.1 api\n") {
		t.Fatalf("hosts missing hostname entry: %q", got)
	}
}

func TestWriteHostsEntries_AllowsShortServiceAliases(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hosts")
	err := writeHostsEntries(path, append(defaultHostEntries("api"), []hostEntry{
		{Host: "db.internal", IP: "127.77.0.1"},
		{Host: "db", IP: "127.77.0.1"},
	}...))
	if err != nil {
		t.Fatalf("writeHostsEntries() error = %v", err)
	}

	gotBytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read hosts file: %v", err)
	}
	got := string(gotBytes)
	if !strings.Contains(got, "127.77.0.1 db.internal\n") {
		t.Fatalf("hosts missing internal alias: %q", got)
	}
	if !strings.Contains(got, "127.77.0.1 db\n") {
		t.Fatalf("hosts missing short alias: %q", got)
	}
}

func TestEnsureHostResolutionConfig_AddsHostsLookup(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nsswitch.conf")
	if err := os.WriteFile(path, []byte("passwd: files\n"), 0o644); err != nil {
		t.Fatalf("write nsswitch: %v", err)
	}

	if err := ensureHostResolutionConfig(path); err != nil {
		t.Fatalf("ensureHostResolutionConfig() error = %v", err)
	}

	gotBytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read nsswitch: %v", err)
	}
	got := string(gotBytes)
	if !strings.Contains(got, "hosts: files dns\n") {
		t.Fatalf("nsswitch missing hosts lookup: %q", got)
	}
}

func TestRelevantResolverLines_FiltersRelevantEntries(t *testing.T) {
	path := filepath.Join(t.TempDir(), "resolver")
	content := "# comment\n127.0.0.1 localhost\n127.77.0.1 mysql.internal\nnameserver 127.0.0.11\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write resolver file: %v", err)
	}

	got := relevantResolverLines(path, ".internal", "localhost")
	want := "127.0.0.1 localhost; 127.77.0.1 mysql.internal"
	if got != want {
		t.Fatalf("relevantResolverLines() = %q, want %q", got, want)
	}
}

func TestEnsureStandardDeviceLinks_CreatesExpectedSymlinks(t *testing.T) {
	devRoot := filepath.Join(t.TempDir(), "dev")
	if err := os.MkdirAll(devRoot, 0o755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}

	if err := ensureStandardDeviceLinks(devRoot); err != nil {
		t.Fatalf("ensureStandardDeviceLinks() error = %v", err)
	}

	cases := map[string]string{
		"fd":     "/proc/self/fd",
		"stdin":  "/proc/self/fd/0",
		"stdout": "/proc/self/fd/1",
		"stderr": "/proc/self/fd/2",
	}
	for name, want := range cases {
		got, err := os.Readlink(filepath.Join(devRoot, name))
		if err != nil {
			t.Fatalf("Readlink(%q) error = %v", name, err)
		}
		if got != want {
			t.Fatalf("Readlink(%q) = %q, want %q", name, got, want)
		}
	}
}

func TestVolumeMountPaths_UsesStableDataSubdir(t *testing.T) {
	staging, data := volumeMountPaths("postgres-data")
	if staging != "/run/fastfn/volumes/postgres-data" {
		t.Fatalf("staging = %q", staging)
	}
	if data != "/run/fastfn/volumes/postgres-data/data" {
		t.Fatalf("data = %q", data)
	}
}

func TestGuestEntropyPayload_EncodesHeaderAndSeed(t *testing.T) {
	seed := []byte{0x01, 0x02, 0x03, 0x04}
	payload := guestEntropyPayload(seed)
	if len(payload) != 12 {
		t.Fatalf("len(payload) = %d", len(payload))
	}
	if got := binary.NativeEndian.Uint32(payload[0:4]); got != 32 {
		t.Fatalf("entropy_count = %d", got)
	}
	if got := binary.NativeEndian.Uint32(payload[4:8]); got != 4 {
		t.Fatalf("buf_size = %d", got)
	}
	if string(payload[8:]) != string(seed) {
		t.Fatalf("seed bytes = %v", payload[8:])
	}
}

func TestResolveCommandExecutable_UsesWorkloadPATH(t *testing.T) {
	binDir := filepath.Join(t.TempDir(), "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}
	executable := filepath.Join(binDir, "hello")
	if err := os.WriteFile(executable, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	got, err := resolveCommandExecutable("hello", map[string]string{"PATH": binDir})
	if err != nil {
		t.Fatalf("resolveCommandExecutable() error = %v", err)
	}
	if got != executable {
		t.Fatalf("resolveCommandExecutable() = %q, want %q", got, executable)
	}
}

func TestResolveCommandExecutable_ErrNotFoundWhenMissing(t *testing.T) {
	_, err := resolveCommandExecutable("missing-tool", map[string]string{"PATH": t.TempDir()})
	if err == nil {
		t.Fatal("resolveCommandExecutable() error = nil, want not found")
	}
	var execErr *exec.Error
	if !strings.Contains(err.Error(), "executable file not found") && !strings.Contains(err.Error(), "file not found") && !errors.As(err, &execErr) {
		t.Fatalf("resolveCommandExecutable() error = %v, want exec not found", err)
	}
}
