package workloads

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveFirecrackerBundle_DefaultLayout(t *testing.T) {
	projectDir := t.TempDir()
	bundleDir := filepath.Join(projectDir, "images", "admin")
	if err := os.MkdirAll(bundleDir, 0o755); err != nil {
		t.Fatalf("mkdir bundle: %v", err)
	}
	if err := os.WriteFile(filepath.Join(bundleDir, "vmlinux"), []byte("kernel"), 0o644); err != nil {
		t.Fatalf("write kernel: %v", err)
	}
	if err := os.WriteFile(filepath.Join(bundleDir, "rootfs.ext4"), []byte("rootfs"), 0o644); err != nil {
		t.Fatalf("write rootfs: %v", err)
	}

	bundle, err := ResolveFirecrackerBundle(projectDir, "./images/admin")
	if err != nil {
		t.Fatalf("ResolveFirecrackerBundle() error = %v", err)
	}
	if bundle.GuestPort != defaultFirecrackerGuestPort {
		t.Fatalf("GuestPort = %d", bundle.GuestPort)
	}
	if bundle.KernelPath != filepath.Join(bundleDir, "vmlinux") {
		t.Fatalf("KernelPath = %q", bundle.KernelPath)
	}
	if bundle.RootFSPath != filepath.Join(bundleDir, "rootfs.ext4") {
		t.Fatalf("RootFSPath = %q", bundle.RootFSPath)
	}
}

func TestResolveFirecrackerBundle_ManifestOverrides(t *testing.T) {
	projectDir := t.TempDir()
	bundleDir := filepath.Join(projectDir, "images", "mysql")
	if err := os.MkdirAll(bundleDir, 0o755); err != nil {
		t.Fatalf("mkdir bundle: %v", err)
	}
	if err := os.WriteFile(filepath.Join(bundleDir, "kernel.bin"), []byte("kernel"), 0o644); err != nil {
		t.Fatalf("write kernel: %v", err)
	}
	if err := os.WriteFile(filepath.Join(bundleDir, "mysql-rootfs.img"), []byte("rootfs"), 0o644); err != nil {
		t.Fatalf("write rootfs: %v", err)
	}
	if err := os.WriteFile(filepath.Join(bundleDir, bundleManifestName), []byte(`{
  "kernel": "kernel.bin",
  "rootfs": "mysql-rootfs.img",
  "guest_port": 12000,
  "kernel_args": "console=ttyS0 panic=1",
  "vcpu_count": 2,
  "memory_mib": 512,
  "config_drive_bytes": 131072
}`), 0o644); err != nil {
		t.Fatalf("write manifest: %v", err)
	}

	bundle, err := ResolveFirecrackerBundle(projectDir, "./images/mysql")
	if err != nil {
		t.Fatalf("ResolveFirecrackerBundle() error = %v", err)
	}
	if bundle.GuestPort != 12000 {
		t.Fatalf("GuestPort = %d", bundle.GuestPort)
	}
	if bundle.KernelArgs != "console=ttyS0 panic=1" {
		t.Fatalf("KernelArgs = %q", bundle.KernelArgs)
	}
	if bundle.VCPUCount != 2 || bundle.MemoryMiB != 512 || bundle.ConfigDriveBytes != 131072 {
		t.Fatalf("unexpected bundle sizing: %+v", bundle)
	}
}
