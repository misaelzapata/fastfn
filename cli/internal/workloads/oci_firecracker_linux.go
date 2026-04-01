//go:build linux

package workloads

import (
	"archive/tar"
	"context"
	"crypto/sha1"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/Microsoft/hcsshim/ext4/tar2ext4"
	dockertypes "github.com/docker/docker/api/types"
	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/client"
	"github.com/docker/docker/pkg/archive"
)

const (
	defaultGuestInitFilename         = "fastfn-guest-init-v1-amd64"
	minRootFSBytes            int64  = 512 * 1024 * 1024
	rootFSExtraBytes          int64  = 128 * 1024 * 1024
	rootFSEntryOverheadBytes  int64  = 4 * 1024
	rootFSSizeAlignBytes      int64  = 64 * 1024 * 1024
	bundleCacheSchemaVersion         = "v6"
	legacyTarTypeReg          byte   = 0
	ext4SuperblockOffset             = 1024
	ext4FeatureRoCompatOffset        = ext4SuperblockOffset + 0x64
	ext4ReadonlyCompatFlag    uint32 = 0x1000
)

type rootFSMetadata struct {
	UID  int
	GID  int
	Mode int64
}

func ResolveWorkloadBundle(ctx context.Context, projectDir, scopeDir, kind, name, imageRef, imageFile, dockerfile, contextDir string) (FirecrackerBundle, error) {
	if localBundleRef(projectDir, imageRef) {
		return ResolveFirecrackerBundle(projectDir, imageRef)
	}

	guestInitPath, guestInitDigest, err := resolveGuestInitBinaryWithDigest(projectDir, scopeDir)
	if err != nil {
		return FirecrackerBundle{}, err
	}

	cli, err := client.NewClientWithOpts(client.FromEnv, client.WithAPIVersionNegotiation())
	if err != nil {
		return FirecrackerBundle{}, fmt.Errorf("create docker client for %s.%s: %w", kind, name, err)
	}
	defer cli.Close()

	resolvedRef, inspect, err := ensureOCIImage(ctx, cli, projectDir, kind, name, imageRef, imageFile, dockerfile, contextDir)
	if err != nil {
		return FirecrackerBundle{}, err
	}

	bundleDir := filepath.Join(projectDir, ".fastfn", "firecracker", "images", bundleCacheKey(bundleCacheSchemaVersion, inspect.ID, dockerfile, imageFile, resolvedRef, guestInitDigest))
	if bundle, err := ResolveFirecrackerBundle(projectDir, bundleDir); err == nil {
		return bundle, nil
	}

	tmpDir := bundleDir + ".tmp-" + shortHashFC(name)
	_ = os.RemoveAll(tmpDir)
	if err := os.MkdirAll(tmpDir, 0o755); err != nil {
		return FirecrackerBundle{}, fmt.Errorf("create bundle dir for %s.%s: %w", kind, name, err)
	}
	defer os.RemoveAll(tmpDir)

	rootDir := filepath.Join(tmpDir, "root")
	if err := os.MkdirAll(rootDir, 0o755); err != nil {
		return FirecrackerBundle{}, fmt.Errorf("create root staging dir for %s.%s: %w", kind, name, err)
	}

	rootMeta, err := exportContainerRootFS(ctx, cli, resolvedRef, rootDir)
	if err != nil {
		return FirecrackerBundle{}, fmt.Errorf("export image filesystem for %s.%s: %w", kind, name, err)
	}
	if err := injectGuestInit(guestInitPath, rootDir); err != nil {
		return FirecrackerBundle{}, fmt.Errorf("inject guest init for %s.%s: %w", kind, name, err)
	}
	if err := ensureRuntimeDirs(rootDir); err != nil {
		return FirecrackerBundle{}, fmt.Errorf("prepare rootfs for %s.%s: %w", kind, name, err)
	}

	rootfsPath := filepath.Join(tmpDir, "rootfs.ext4")
	if err := buildRootFS(rootDir, rootMeta, rootfsPath); err != nil {
		return FirecrackerBundle{}, fmt.Errorf("build rootfs for %s.%s: %w", kind, name, err)
	}

	envMap := envSliceToMap(imageConfigEnv(inspect))
	command := resolveGuestCommand(rootDir, envMap, defaultImageCommand(inspect))
	manifest := firecrackerBundleManifest{
		RootFS:           "rootfs.ext4",
		KernelArgs:       strings.TrimSpace(defaultFirecrackerKernelArgs + " init=/init"),
		GuestPort:        defaultFirecrackerGuestPort,
		VCPUCount:        defaultFirecrackerVCPUCount,
		MemoryMiB:        defaultFirecrackerMemoryMiB,
		ConfigDriveBytes: defaultConfigDriveBytes,
		Command:          command,
		Env:              envMap,
		WorkingDir:       strings.TrimSpace(imageWorkingDir(inspect)),
		User:             strings.TrimSpace(imageUser(inspect)),
	}
	if err := writeBundleManifest(filepath.Join(tmpDir, bundleManifestName), manifest); err != nil {
		return FirecrackerBundle{}, err
	}

	if err := os.MkdirAll(filepath.Dir(bundleDir), 0o755); err != nil {
		return FirecrackerBundle{}, fmt.Errorf("create bundle cache parent: %w", err)
	}
	_ = os.RemoveAll(bundleDir)
	if err := os.Rename(tmpDir, bundleDir); err != nil {
		return FirecrackerBundle{}, fmt.Errorf("finalize bundle cache for %s.%s: %w", kind, name, err)
	}
	return ResolveFirecrackerBundle(projectDir, bundleDir)
}

func ensureOCIImage(ctx context.Context, cli *client.Client, projectDir, kind, name, imageRef, imageFile, dockerfile, contextDir string) (string, dockertypes.ImageInspect, error) {
	if strings.TrimSpace(dockerfile) != "" {
		ref, err := buildDockerfileImage(ctx, cli, kind, name, dockerfile, contextDir)
		if err != nil {
			return "", dockertypes.ImageInspect{}, err
		}
		inspect, _, err := cli.ImageInspectWithRaw(ctx, ref)
		if err != nil {
			return "", dockertypes.ImageInspect{}, fmt.Errorf("inspect built image for %s.%s: %w", kind, name, err)
		}
		return ref, inspect, nil
	}

	if strings.TrimSpace(imageFile) != "" {
		ref, err := loadImageFile(ctx, cli, kind, name, imageFile)
		if err != nil {
			return "", dockertypes.ImageInspect{}, err
		}
		inspect, _, err := cli.ImageInspectWithRaw(ctx, ref)
		if err != nil {
			return "", dockertypes.ImageInspect{}, fmt.Errorf("inspect loaded image for %s.%s: %w", kind, name, err)
		}
		return ref, inspect, nil
	}

	ref := strings.TrimSpace(imageRef)
	if ref == "" {
		return "", dockertypes.ImageInspect{}, fmt.Errorf("%s.%s: image source is empty", kind, name)
	}
	if _, _, err := cli.ImageInspectWithRaw(ctx, ref); err != nil {
		reader, pullErr := cli.ImagePull(ctx, ref, dockertypes.ImagePullOptions{})
		if pullErr != nil {
			return "", dockertypes.ImageInspect{}, fmt.Errorf("pull image for %s.%s: %w", kind, name, pullErr)
		}
		_, _ = io.Copy(io.Discard, reader)
		_ = reader.Close()
	}
	inspect, _, err := cli.ImageInspectWithRaw(ctx, ref)
	if err != nil {
		return "", dockertypes.ImageInspect{}, fmt.Errorf("inspect image for %s.%s: %w", kind, name, err)
	}
	return ref, inspect, nil
}

func buildDockerfileImage(ctx context.Context, cli *client.Client, kind, name, dockerfile, contextDir string) (string, error) {
	buildDir := strings.TrimSpace(contextDir)
	if buildDir == "" {
		buildDir = filepath.Dir(dockerfile)
	}
	resolvedDockerfile := filepath.Clean(dockerfile)
	relativeDockerfile, err := filepath.Rel(buildDir, resolvedDockerfile)
	if err != nil {
		return "", fmt.Errorf("resolve dockerfile path for %s.%s: %w", kind, name, err)
	}
	buildCtx, err := archive.TarWithOptions(buildDir, &archive.TarOptions{})
	if err != nil {
		return "", fmt.Errorf("build docker context for %s.%s: %w", kind, name, err)
	}
	defer buildCtx.Close()

	tag := "fastfn/" + kind + "-" + sanitizeName(name) + ":" + shortDockerHash(resolvedDockerfile+"|"+buildDir)
	resp, err := cli.ImageBuild(ctx, buildCtx, dockertypes.ImageBuildOptions{
		Dockerfile: relativeDockerfile,
		Tags:       []string{tag},
		Remove:     true,
	})
	if err != nil {
		return "", fmt.Errorf("build image for %s.%s: %w", kind, name, err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return tag, nil
}

func loadImageFile(ctx context.Context, cli *client.Client, kind, name, imageFile string) (string, error) {
	file, err := os.Open(imageFile)
	if err != nil {
		return "", fmt.Errorf("open image_file for %s.%s: %w", kind, name, err)
	}
	defer file.Close()

	resp, err := cli.ImageLoad(ctx, file, true)
	if err != nil {
		return "", fmt.Errorf("load image_file for %s.%s: %w", kind, name, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	lines := strings.Split(string(body), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "Loaded image: ") {
			return strings.TrimSpace(strings.TrimPrefix(line, "Loaded image: ")), nil
		}
		if strings.HasPrefix(line, "Loaded image ID: ") {
			return strings.TrimSpace(strings.TrimPrefix(line, "Loaded image ID: ")), nil
		}
	}
	return "", fmt.Errorf("load image_file for %s.%s did not report a loaded image reference", kind, name)
}

func exportContainerRootFS(ctx context.Context, cli *client.Client, imageRef, rootDir string) (map[string]rootFSMetadata, error) {
	resp, err := cli.ContainerCreate(ctx, &container.Config{
		Image: imageRef,
		Cmd:   []string{"/bin/true"},
		Tty:   false,
	}, nil, nil, nil, "")
	if err != nil {
		return nil, fmt.Errorf("create export container: %w", err)
	}
	containerID := resp.ID
	defer func() {
		_ = cli.ContainerRemove(context.Background(), containerID, dockertypes.ContainerRemoveOptions{Force: true})
	}()

	exported, err := cli.ContainerExport(ctx, containerID)
	if err != nil {
		return nil, fmt.Errorf("export container filesystem: %w", err)
	}
	defer exported.Close()
	return untarRootFS(exported, rootDir)
}

func untarRootFS(reader io.Reader, rootDir string) (map[string]rootFSMetadata, error) {
	tr := tar.NewReader(reader)
	meta := map[string]rootFSMetadata{}
	for {
		header, err := tr.Next()
		if err == io.EOF {
			return meta, nil
		}
		if err != nil {
			return nil, err
		}

		target := filepath.Join(rootDir, filepath.Clean(header.Name))
		if !strings.HasPrefix(target, filepath.Clean(rootDir)+string(os.PathSeparator)) && filepath.Clean(target) != filepath.Clean(rootDir) {
			return nil, fmt.Errorf("archive entry escaped rootfs: %s", header.Name)
		}

		relPath := normalizeRootFSRelPath(header.Name)
		if relPath != "" {
			meta[relPath] = rootFSMetadata{
				UID:  header.Uid,
				GID:  header.Gid,
				Mode: header.Mode,
			}
		}

		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, writableDirMode(os.FileMode(header.Mode))); err != nil {
				return nil, err
			}
		case tar.TypeReg, legacyTarTypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return nil, err
			}
			file, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, readableFileMode(os.FileMode(header.Mode)))
			if err != nil {
				return nil, err
			}
			if _, err := io.Copy(file, tr); err != nil {
				_ = file.Close()
				return nil, err
			}
			if err := file.Close(); err != nil {
				return nil, err
			}
		case tar.TypeSymlink:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return nil, err
			}
			_ = os.Remove(target)
			if err := os.Symlink(header.Linkname, target); err != nil {
				return nil, err
			}
		case tar.TypeLink:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return nil, err
			}
			linkTarget := filepath.Join(rootDir, filepath.Clean(header.Linkname))
			if err := os.Link(linkTarget, target); err != nil {
				return nil, err
			}
		default:
			// Device nodes are recreated by mounted devtmpfs inside the guest.
		}
	}
}

func normalizeRootFSRelPath(raw string) string {
	value := filepath.ToSlash(filepath.Clean(strings.TrimSpace(raw)))
	value = strings.TrimPrefix(value, "./")
	value = strings.TrimPrefix(value, "/")
	if value == "." {
		return ""
	}
	return value
}

func writableDirMode(mode os.FileMode) os.FileMode {
	if mode == 0 {
		return 0o755
	}
	return mode | 0o700
}

func readableFileMode(mode os.FileMode) os.FileMode {
	if mode == 0 {
		return 0o644
	}
	return mode | 0o600
}

func injectGuestInit(source, rootDir string) error {
	target := filepath.Join(rootDir, "init")
	return copyFile(source, target, 0o755)
}

func resolveGuestInitBinary(projectDir, scopeDir string) (string, error) {
	path, _, err := resolveGuestInitBinaryWithDigest(projectDir, scopeDir)
	return path, err
}

func resolveGuestInitBinaryWithDigest(projectDir, scopeDir string) (string, string, error) {
	if configured := strings.TrimSpace(os.Getenv("FN_FIRECRACKER_GUEST_INIT")); configured != "" {
		path := filepath.Clean(configured)
		digest, err := fileSHA1(path)
		if err != nil {
			return "", "", err
		}
		return path, digest, nil
	}
	candidates := []string{}
	appendCandidate := func(base string) {
		if strings.TrimSpace(base) == "" {
			return
		}
		candidates = append(candidates,
			filepath.Join(base, ".fastfn", "firecracker", "bin", defaultGuestInitFilename),
			filepath.Join(base, ".fastfn", "firecracker", "bin", defaultGuestInitFilename+"-amd64"),
		)
	}
	appendCandidate(projectDir)
	for dir := strings.TrimSpace(scopeDir); dir != ""; {
		appendCandidate(dir)
		next := filepath.Dir(dir)
		if next == dir {
			break
		}
		dir = next
	}
	for _, candidate := range candidates {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			digest, err := fileSHA1(candidate)
			if err != nil {
				return "", "", err
			}
			return candidate, digest, nil
		}
	}
	return "", "", fmt.Errorf("firecracker guest init binary was not found; set FN_FIRECRACKER_GUEST_INIT or place %s under .fastfn/firecracker/bin", defaultGuestInitFilename)
}

func ensureRuntimeDirs(rootDir string) error {
	dirs := []string{
		filepath.Join(rootDir, "proc"),
		filepath.Join(rootDir, "sys"),
		filepath.Join(rootDir, "dev"),
		filepath.Join(rootDir, "dev", "pts"),
		filepath.Join(rootDir, "run"),
		filepath.Join(rootDir, "tmp"),
	}
	for _, dir := range dirs {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	return nil
}

func buildRootFS(rootDir string, meta map[string]rootFSMetadata, outputPath string) error {
	sizeBytes, err := rootFSSizeBytes(rootDir)
	if err != nil {
		return err
	}
	image, err := os.OpenFile(outputPath, os.O_CREATE|os.O_TRUNC|os.O_RDWR, 0o644)
	if err != nil {
		return fmt.Errorf("create rootfs image: %w", err)
	}
	defer image.Close()

	reader, writer := io.Pipe()
	errCh := make(chan error, 1)
	go func() {
		errCh <- writeRootFSTar(writer, rootDir, meta)
	}()

	if err := tar2ext4.ConvertTarToExt4(reader, image, tar2ext4.MaximumDiskSize(sizeBytes)); err != nil {
		_ = reader.Close()
		return fmt.Errorf("build ext4 rootfs: %w", err)
	}
	if err := <-errCh; err != nil {
		return err
	}
	if err := clearExt4ReadonlyCompatFlag(outputPath); err != nil {
		return err
	}
	if err := growExt4Filesystem(outputPath, sizeBytes); err != nil {
		return err
	}
	if err := repairExt4Filesystem(outputPath); err != nil {
		return err
	}
	return nil
}

func clearExt4ReadonlyCompatFlag(path string) error {
	image, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return fmt.Errorf("open ext4 rootfs for patching: %w", err)
	}
	defer image.Close()

	if _, err := image.Seek(ext4FeatureRoCompatOffset, io.SeekStart); err != nil {
		return fmt.Errorf("seek ext4 ro_compat flags: %w", err)
	}
	var flags uint32
	if err := binary.Read(image, binary.LittleEndian, &flags); err != nil {
		return fmt.Errorf("read ext4 ro_compat flags: %w", err)
	}
	flags &^= ext4ReadonlyCompatFlag
	if _, err := image.Seek(ext4FeatureRoCompatOffset, io.SeekStart); err != nil {
		return fmt.Errorf("rewind ext4 ro_compat flags: %w", err)
	}
	if err := binary.Write(image, binary.LittleEndian, flags); err != nil {
		return fmt.Errorf("write ext4 ro_compat flags: %w", err)
	}
	if err := image.Sync(); err != nil {
		return fmt.Errorf("sync patched ext4 rootfs: %w", err)
	}
	return nil
}

func growExt4Filesystem(path string, sizeBytes int64) error {
	if sizeBytes <= 0 {
		return fmt.Errorf("grow ext4 rootfs: invalid size %d", sizeBytes)
	}
	if err := os.Truncate(path, sizeBytes); err != nil {
		return fmt.Errorf("expand ext4 rootfs to %d bytes: %w", sizeBytes, err)
	}
	resize2fsPath, err := exec.LookPath("resize2fs")
	if err != nil {
		return fmt.Errorf("locate resize2fs: %w", err)
	}
	cmd := exec.Command(resize2fsPath, "-f", path)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("resize ext4 rootfs: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}

func repairExt4Filesystem(path string) error {
	e2fsckPath, err := exec.LookPath("e2fsck")
	if err != nil {
		return fmt.Errorf("locate e2fsck: %w", err)
	}
	cmd := exec.Command(e2fsckPath, "-fy", path)
	output, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	if exitErr, ok := err.(*exec.ExitError); ok && allowedE2FSCKExitCode(exitErr.ExitCode()) {
		return nil
	}
	return fmt.Errorf("repair ext4 rootfs: %w: %s", err, strings.TrimSpace(string(output)))
}

func allowedE2FSCKExitCode(code int) bool {
	return code >= 0 && code&^0x3 == 0
}

func writeRootFSTar(pipeWriter *io.PipeWriter, rootDir string, meta map[string]rootFSMetadata) error {
	tw := tar.NewWriter(pipeWriter)

	walkErr := filepath.Walk(rootDir, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path == rootDir {
			return nil
		}

		relPath, err := filepath.Rel(rootDir, path)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		linkTarget := ""
		if info.Mode()&os.ModeSymlink != 0 {
			linkTarget, err = os.Readlink(path)
			if err != nil {
				return err
			}
		}

		header, err := tar.FileInfoHeader(info, linkTarget)
		if err != nil {
			return err
		}
		header.Name = relPath
		if entry, ok := meta[relPath]; ok {
			header.Uid = entry.UID
			header.Gid = entry.GID
			header.Mode = entry.Mode
		} else {
			header.Uid = 0
			header.Gid = 0
		}
		if info.IsDir() && !strings.HasSuffix(header.Name, "/") {
			header.Name += "/"
		}
		if err := tw.WriteHeader(header); err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return nil
		}

		file, err := os.Open(path)
		if err != nil {
			return err
		}
		if _, err := io.Copy(tw, file); err != nil {
			_ = file.Close()
			return err
		}
		return file.Close()
	})
	if walkErr != nil {
		_ = tw.Close()
		_ = pipeWriter.CloseWithError(walkErr)
		return walkErr
	}
	if err := tw.Close(); err != nil {
		_ = pipeWriter.CloseWithError(err)
		return err
	}
	return pipeWriter.Close()
}

func rootFSSizeBytes(rootDir string) (int64, error) {
	var total int64
	err := filepath.Walk(rootDir, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path == rootDir {
			return nil
		}
		total += rootFSEntryOverheadBytes
		if info.Mode().IsRegular() {
			total += info.Size()
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	total += rootFSExtraBytes
	if total < minRootFSBytes {
		total = minRootFSBytes
	}
	if rem := total % rootFSSizeAlignBytes; rem != 0 {
		total += rootFSSizeAlignBytes - rem
	}
	return total, nil
}

func writeBundleManifest(path string, manifest firecrackerBundleManifest) error {
	raw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal firecracker bundle manifest: %w", err)
	}
	if err := os.WriteFile(path, append(raw, '\n'), 0o644); err != nil {
		return fmt.Errorf("write firecracker bundle manifest: %w", err)
	}
	return nil
}

func defaultImageCommand(inspect dockertypes.ImageInspect) []string {
	command := []string{}
	command = append(command, imageEntrypoint(inspect)...)
	command = append(command, imageCmd(inspect)...)
	return command
}

func resolveGuestCommand(rootDir string, env map[string]string, command []string) []string {
	if len(command) == 0 {
		return nil
	}
	out := append([]string{}, command...)
	if strings.HasPrefix(out[0], "/") {
		return out
	}

	searchPath := env["PATH"]
	if strings.TrimSpace(searchPath) == "" {
		searchPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	}
	for _, dir := range strings.Split(searchPath, ":") {
		dir = strings.TrimSpace(dir)
		if dir == "" {
			continue
		}
		guestPath := filepath.ToSlash(filepath.Join(dir, out[0]))
		hostPath := filepath.Join(rootDir, strings.TrimPrefix(guestPath, "/"))
		if _, err := os.Lstat(hostPath); err == nil {
			out[0] = guestPath
			return out
		}
	}
	return out
}

func imageEntrypoint(inspect dockertypes.ImageInspect) []string {
	if inspect.Config == nil {
		return nil
	}
	return append([]string{}, inspect.Config.Entrypoint...)
}

func imageCmd(inspect dockertypes.ImageInspect) []string {
	if inspect.Config == nil {
		return nil
	}
	return append([]string{}, inspect.Config.Cmd...)
}

func imageConfigEnv(inspect dockertypes.ImageInspect) []string {
	if inspect.Config == nil {
		return nil
	}
	return append([]string{}, inspect.Config.Env...)
}

func imageWorkingDir(inspect dockertypes.ImageInspect) string {
	if inspect.Config == nil {
		return ""
	}
	return inspect.Config.WorkingDir
}

func imageUser(inspect dockertypes.ImageInspect) string {
	if inspect.Config == nil {
		return ""
	}
	return inspect.Config.User
}

func envSliceToMap(values []string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	out := make(map[string]string, len(values))
	for _, item := range values {
		key, value, ok := strings.Cut(item, "=")
		if !ok {
			continue
		}
		out[key] = value
	}
	if len(out) == 0 {
		return nil
	}
	keys := make([]string, 0, len(out))
	for key := range out {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	normalized := make(map[string]string, len(keys))
	for _, key := range keys {
		normalized[key] = out[key]
	}
	return normalized
}

func copyFile(source, target string, mode os.FileMode) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()

	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	output, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(output, input); err != nil {
		_ = output.Close()
		return err
	}
	return output.Close()
}

func localBundleRef(projectDir, imageRef string) bool {
	imageRef = strings.TrimSpace(imageRef)
	if imageRef == "" {
		return false
	}
	if filepath.IsAbs(imageRef) {
		if info, err := os.Stat(imageRef); err == nil && info.IsDir() {
			return true
		}
		return false
	}
	if projectDir == "" {
		return false
	}
	if info, err := os.Stat(filepath.Join(projectDir, imageRef)); err == nil && info.IsDir() {
		return true
	}
	return false
}

func bundleCacheKey(parts ...string) string {
	h := sha1.New()
	for _, part := range parts {
		_, _ = io.WriteString(h, strings.TrimSpace(part))
		_, _ = io.WriteString(h, "|")
	}
	return hex.EncodeToString(h.Sum(nil))
}

func shortDockerHash(raw string) string {
	sum := sha1.Sum([]byte(raw))
	return hex.EncodeToString(sum[:])[:12]
}

func fileSHA1(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read file %s: %w", path, err)
	}
	sum := sha1.Sum(data)
	return hex.EncodeToString(sum[:]), nil
}
