//go:build linux

package main

import (
	"os"
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

	err := writeHostsEntries(path, []hostEntry{
		{Host: "mysql-main.internal", IP: "127.77.0.1"},
		{Host: "worker.internal", IP: "127.77.0.2"},
	})
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
