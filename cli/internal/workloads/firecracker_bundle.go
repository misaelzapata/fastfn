package workloads

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	defaultFirecrackerKernelArgs = "console=ttyS0 reboot=k panic=1 pci=off"
	defaultFirecrackerGuestPort  = 10700
	defaultFirecrackerVCPUCount  = 1
	defaultFirecrackerMemoryMiB  = 512
	defaultConfigDriveBytes      = 64 * 1024
	bundleManifestName           = "fastfn-image.json"
)

type FirecrackerBundle struct {
	BundleDir        string
	KernelPath       string
	RootFSPath       string
	KernelArgs       string
	GuestPort        int
	VCPUCount        int64
	MemoryMiB        int64
	ConfigDriveBytes int64
	BundleID         string
	DefaultCommand   []string
	DefaultEnv       map[string]string
	WorkingDir       string
	User             string
}

type firecrackerBundleManifest struct {
	Kernel           string            `json:"kernel,omitempty"`
	RootFS           string            `json:"rootfs,omitempty"`
	KernelArgs       string            `json:"kernel_args,omitempty"`
	GuestPort        int               `json:"guest_port,omitempty"`
	VCPUCount        int64             `json:"vcpu_count,omitempty"`
	MemoryMiB        int64             `json:"memory_mib,omitempty"`
	ConfigDriveBytes int64             `json:"config_drive_bytes,omitempty"`
	Command          []string          `json:"command,omitempty"`
	Env              map[string]string `json:"env,omitempty"`
	WorkingDir       string            `json:"working_dir,omitempty"`
	User             string            `json:"user,omitempty"`
}

func ResolveFirecrackerBundle(projectDir, imageRef string) (FirecrackerBundle, error) {
	imageRef = strings.TrimSpace(imageRef)
	if imageRef == "" {
		return FirecrackerBundle{}, fmt.Errorf("image bundle path is required")
	}

	bundleDir, err := resolveBundlePath(projectDir, imageRef)
	if err != nil {
		return FirecrackerBundle{}, err
	}

	info, err := os.Stat(bundleDir)
	if err != nil {
		return FirecrackerBundle{}, fmt.Errorf("stat firecracker image bundle %q: %w", imageRef, err)
	}
	if !info.IsDir() {
		return FirecrackerBundle{}, fmt.Errorf("firecracker image %q must be a directory bundle", imageRef)
	}

	manifest, err := loadBundleManifest(bundleDir)
	if err != nil {
		return FirecrackerBundle{}, err
	}

	kernelPath := filepath.Join(bundleDir, "vmlinux")
	if configured := strings.TrimSpace(os.Getenv("FN_FIRECRACKER_KERNEL")); configured != "" {
		kernelPath = filepath.Clean(configured)
	} else if strings.TrimSpace(manifest.Kernel) != "" {
		kernelPath = filepath.Join(bundleDir, filepath.Clean(strings.TrimSpace(manifest.Kernel)))
	}
	rootfsPath := filepath.Join(bundleDir, "rootfs.ext4")
	if strings.TrimSpace(manifest.RootFS) != "" {
		rootfsPath = filepath.Join(bundleDir, filepath.Clean(strings.TrimSpace(manifest.RootFS)))
	}

	if stat, err := os.Stat(kernelPath); err != nil || stat.IsDir() {
		return FirecrackerBundle{}, fmt.Errorf("firecracker image bundle %q is missing kernel %q", imageRef, kernelPath)
	}
	if stat, err := os.Stat(rootfsPath); err != nil || stat.IsDir() {
		return FirecrackerBundle{}, fmt.Errorf("firecracker image bundle %q is missing rootfs %q", imageRef, rootfsPath)
	}

	bundle := FirecrackerBundle{
		BundleDir:        bundleDir,
		KernelPath:       kernelPath,
		RootFSPath:       rootfsPath,
		KernelArgs:       firstNonEmptyFC(strings.TrimSpace(manifest.KernelArgs), defaultFirecrackerKernelArgs),
		GuestPort:        positiveIntOr(manifest.GuestPort, defaultFirecrackerGuestPort),
		VCPUCount:        positiveInt64Or(manifest.VCPUCount, defaultFirecrackerVCPUCount),
		MemoryMiB:        positiveInt64Or(manifest.MemoryMiB, defaultFirecrackerMemoryMiB),
		ConfigDriveBytes: positiveInt64Or(manifest.ConfigDriveBytes, defaultConfigDriveBytes),
		DefaultCommand:   append([]string{}, manifest.Command...),
		DefaultEnv:       cloneStringMap(manifest.Env),
		WorkingDir:       strings.TrimSpace(manifest.WorkingDir),
		User:             strings.TrimSpace(manifest.User),
	}
	bundle.BundleID = shortHashFC(bundle.BundleDir + "|" + bundle.KernelPath + "|" + bundle.RootFSPath)
	return bundle, nil
}

func loadBundleManifest(bundleDir string) (firecrackerBundleManifest, error) {
	manifestPath := filepath.Join(bundleDir, bundleManifestName)
	if _, err := os.Stat(manifestPath); errorsIsNotExist(err) {
		return firecrackerBundleManifest{}, nil
	} else if err != nil {
		return firecrackerBundleManifest{}, fmt.Errorf("read bundle manifest %q: %w", manifestPath, err)
	}

	raw, err := os.ReadFile(manifestPath)
	if err != nil {
		return firecrackerBundleManifest{}, fmt.Errorf("read bundle manifest %q: %w", manifestPath, err)
	}

	var manifest firecrackerBundleManifest
	if err := json.Unmarshal(raw, &manifest); err != nil {
		return firecrackerBundleManifest{}, fmt.Errorf("parse bundle manifest %q: %w", manifestPath, err)
	}
	return manifest, nil
}

func resolveBundlePath(projectDir, raw string) (string, error) {
	if filepath.IsAbs(raw) {
		return filepath.Clean(raw), nil
	}

	candidates := []string{}
	if strings.TrimSpace(projectDir) != "" {
		candidates = append(candidates, filepath.Join(projectDir, raw))
	}
	candidates = append(candidates, raw)

	for _, candidate := range candidates {
		resolved := filepath.Clean(candidate)
		if _, err := os.Stat(resolved); err == nil {
			return resolved, nil
		}
	}

	return "", fmt.Errorf("firecracker image bundle %q was not found; expected a local directory with %s", raw, bundleManifestName)
}

func positiveIntOr(value, fallback int) int {
	if value > 0 {
		return value
	}
	return fallback
}

func positiveInt64Or(value, fallback int64) int64 {
	if value > 0 {
		return value
	}
	return fallback
}

func errorsIsNotExist(err error) bool {
	return err != nil && os.IsNotExist(err)
}

func shortHashFC(raw string) string {
	sum := sha1.Sum([]byte(raw))
	return hex.EncodeToString(sum[:])[:8]
}

func firstNonEmptyFC(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func cloneStringMap(source map[string]string) map[string]string {
	if len(source) == 0 {
		return nil
	}
	out := make(map[string]string, len(source))
	for key, value := range source {
		out[key] = value
	}
	return out
}
