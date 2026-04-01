//go:build linux

package workloads

import (
	"archive/tar"
	"bytes"
	"crypto/sha1"
	"encoding/binary"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestUntarRootFSAcceptsLegacyRegularFileType(t *testing.T) {
	var payload bytes.Buffer
	tw := tar.NewWriter(&payload)
	if err := tw.WriteHeader(&tar.Header{
		Name:     "app/hello.txt",
		Mode:     0o644,
		Uid:      0,
		Gid:      0,
		Size:     int64(len("hello")),
		Typeflag: legacyTarTypeReg,
	}); err != nil {
		t.Fatalf("WriteHeader() error = %v", err)
	}
	if _, err := tw.Write([]byte("hello")); err != nil {
		t.Fatalf("Write() error = %v", err)
	}
	if err := tw.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}

	rootDir := t.TempDir()
	meta, err := untarRootFS(bytes.NewReader(payload.Bytes()), rootDir)
	if err != nil {
		t.Fatalf("untarRootFS() error = %v", err)
	}

	got, err := os.ReadFile(filepath.Join(rootDir, "app", "hello.txt"))
	if err != nil {
		t.Fatalf("ReadFile() error = %v", err)
	}
	if string(got) != "hello" {
		t.Fatalf("file contents = %q", string(got))
	}
	entry, ok := meta["app/hello.txt"]
	if !ok {
		t.Fatalf("metadata missing for extracted file")
	}
	if entry.UID != 0 || entry.GID != 0 || entry.Mode != 0o644 {
		t.Fatalf("metadata = %+v", entry)
	}
}

func TestResolveGuestInitBinaryWithDigest(t *testing.T) {
	projectDir := t.TempDir()
	guestInitDir := filepath.Join(projectDir, ".fastfn", "firecracker", "bin")
	if err := os.MkdirAll(guestInitDir, 0o755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}

	payload := []byte("guest-init")
	guestInitPath := filepath.Join(guestInitDir, defaultGuestInitFilename)
	if err := os.WriteFile(guestInitPath, payload, 0o755); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	gotPath, gotDigest, err := resolveGuestInitBinaryWithDigest(projectDir, projectDir)
	if err != nil {
		t.Fatalf("resolveGuestInitBinaryWithDigest() error = %v", err)
	}
	if gotPath != guestInitPath {
		t.Fatalf("path = %q, want %q", gotPath, guestInitPath)
	}

	sum := sha1.Sum(payload)
	wantDigest := hex.EncodeToString(sum[:])
	if gotDigest != wantDigest {
		t.Fatalf("digest = %q, want %q", gotDigest, wantDigest)
	}
}

func TestClearExt4ReadonlyCompatFlag(t *testing.T) {
	imagePath := filepath.Join(t.TempDir(), "rootfs.ext4")
	raw := make([]byte, ext4FeatureRoCompatOffset+4)
	binary.LittleEndian.PutUint32(raw[ext4FeatureRoCompatOffset:], ext4ReadonlyCompatFlag|0x40)
	if err := os.WriteFile(imagePath, raw, 0o644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	if err := clearExt4ReadonlyCompatFlag(imagePath); err != nil {
		t.Fatalf("clearExt4ReadonlyCompatFlag() error = %v", err)
	}

	patched, err := os.ReadFile(imagePath)
	if err != nil {
		t.Fatalf("ReadFile() error = %v", err)
	}
	got := binary.LittleEndian.Uint32(patched[ext4FeatureRoCompatOffset:])
	if got&ext4ReadonlyCompatFlag != 0 {
		t.Fatalf("readonly flag still set: %#x", got)
	}
	if got != 0x40 {
		t.Fatalf("unexpected ro_compat flags = %#x, want %#x", got, uint32(0x40))
	}
}

func TestRootFSSizeBytes_AddsPerEntryOverheadAndAligns(t *testing.T) {
	rootDir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(rootDir, "app", "nested"), 0o755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}
	if err := os.WriteFile(filepath.Join(rootDir, "app", "nested", "hello.txt"), []byte("hello"), 0o644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	got, err := rootFSSizeBytes(rootDir)
	if err != nil {
		t.Fatalf("rootFSSizeBytes() error = %v", err)
	}

	wantMin := minRootFSBytes
	if got < wantMin {
		t.Fatalf("rootFSSizeBytes() = %d, want at least %d", got, wantMin)
	}
	if got%rootFSSizeAlignBytes != 0 {
		t.Fatalf("rootFSSizeBytes() = %d, want multiple of %d", got, rootFSSizeAlignBytes)
	}
}

func TestAllowedE2FSCKExitCode(t *testing.T) {
	for _, code := range []int{0, 1, 2, 3} {
		if !allowedE2FSCKExitCode(code) {
			t.Fatalf("allowedE2FSCKExitCode(%d) = false, want true", code)
		}
	}
	for _, code := range []int{4, 8, 16, 5} {
		if allowedE2FSCKExitCode(code) {
			t.Fatalf("allowedE2FSCKExitCode(%d) = true, want false", code)
		}
	}
}

func TestConsumeDockerBuildOutput_Success(t *testing.T) {
	payload := strings.NewReader("{\"stream\":\"Step 1/3 : FROM alpine\\n\"}\n{\"stream\":\"Successfully built\\n\"}\n")
	if err := consumeDockerBuildOutput(payload); err != nil {
		t.Fatalf("consumeDockerBuildOutput() error = %v", err)
	}
}

func TestConsumeDockerBuildOutput_Error(t *testing.T) {
	payload := strings.NewReader("{\"stream\":\"Step 1/3 : FROM alpine\\n\"}\n{\"errorDetail\":{\"message\":\"boom\"}}\n")
	err := consumeDockerBuildOutput(payload)
	if err == nil || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("consumeDockerBuildOutput() error = %v, want boom", err)
	}
}
