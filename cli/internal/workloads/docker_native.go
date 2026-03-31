//go:build !linux

package workloads

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"io"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	dockertypes "github.com/docker/docker/api/types"
	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/mount"
	networktypes "github.com/docker/docker/api/types/network"
	volumetypes "github.com/docker/docker/api/types/volume"
	"github.com/docker/docker/client"
	"github.com/docker/docker/pkg/archive"
	"github.com/docker/go-connections/nat"
)

type NativeManager struct {
	cfg         ManagerConfig
	cli         *client.Client
	networkName string
	containers  []managedContainer
	stopCh      chan struct{}
	doneCh      chan struct{}
	mu          sync.Mutex
	state       State
}

type managedContainer struct {
	kind        string
	name        string
	specName    string
	containerID string
	port        int
	check       HealthcheckSpec
}

func NewDockerNativeManager(cfg ManagerConfig) (*NativeManager, error) {
	if len(cfg.Apps) == 0 && len(cfg.Services) == 0 {
		return &NativeManager{cfg: cfg}, nil
	}
	if strings.TrimSpace(cfg.StatePath) == "" {
		return nil, fmt.Errorf("state path is required")
	}
	cli, err := client.NewClientWithOpts(client.FromEnv, client.WithAPIVersionNegotiation())
	if err != nil {
		return nil, fmt.Errorf("create docker client: %w", err)
	}
	if _, err := cli.Ping(context.Background()); err != nil {
		return nil, fmt.Errorf("ping docker daemon: %w", err)
	}

	return &NativeManager{
		cfg:    cfg,
		cli:    cli,
		stopCh: make(chan struct{}),
		doneCh: make(chan struct{}),
		state: State{
			Apps:     map[string]AppState{},
			Services: map[string]ServiceState{},
		},
	}, nil
}

func (m *NativeManager) HasWorkloads() bool {
	return m != nil && (len(m.cfg.Apps) > 0 || len(m.cfg.Services) > 0)
}

func (m *NativeManager) StatePath() string {
	if m == nil {
		return ""
	}
	return m.cfg.StatePath
}

func (m *NativeManager) Start(ctx context.Context) error {
	if !m.HasWorkloads() {
		return nil
	}

	networkName := "fastfn-" + shortHash(m.cfg.ProjectDir+m.cfg.StatePath)
	_, err := m.cli.NetworkCreate(ctx, networkName, dockertypes.NetworkCreate{
		CheckDuplicate: true,
		Driver:         "bridge",
	})
	if err != nil {
		return fmt.Errorf("create docker network: %w", err)
	}
	m.networkName = networkName

	services := map[string]ServiceState{}
	for _, spec := range m.cfg.Services {
		state, managed, err := m.startService(ctx, spec)
		if err != nil {
			return err
		}
		m.containers = append(m.containers, managed)
		services[spec.Name] = state
	}

	appServiceEnv := map[string]string{}
	for _, service := range services {
		appServiceEnv = BuildAppServiceEnv(service.Name, service, appServiceEnv)
	}

	apps := map[string]AppState{}
	for _, spec := range m.cfg.Apps {
		state, managed, err := m.startApp(ctx, spec, appServiceEnv)
		if err != nil {
			return err
		}
		m.containers = append(m.containers, managed)
		apps[spec.Name] = state
	}

	m.mu.Lock()
	m.state.Services = services
	m.state.Apps = apps
	m.mu.Unlock()
	if err := m.writeState(); err != nil {
		return err
	}

	go m.monitor()
	return nil
}

func (m *NativeManager) Stop(ctx context.Context) error {
	if m == nil || !m.HasWorkloads() {
		return nil
	}
	select {
	case <-m.stopCh:
	default:
		close(m.stopCh)
	}
	select {
	case <-m.doneCh:
	case <-time.After(500 * time.Millisecond):
	}

	var firstErr error
	timeout := 5
	for i := len(m.containers) - 1; i >= 0; i-- {
		item := m.containers[i]
		_ = m.cli.ContainerStop(ctx, item.containerID, container.StopOptions{Timeout: &timeout})
		if err := m.cli.ContainerRemove(ctx, item.containerID, dockertypes.ContainerRemoveOptions{Force: true}); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	if m.networkName != "" {
		if err := m.cli.NetworkRemove(ctx, m.networkName); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func (m *NativeManager) writeState() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return WriteState(m.cfg.StatePath, m.state)
}

func (m *NativeManager) monitor() {
	defer close(m.doneCh)
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-m.stopCh:
			return
		case <-ticker.C:
			changed := false
			for _, item := range m.containers {
				health := m.inspectHealth(item)
				m.mu.Lock()
				switch item.kind {
				case "app":
					state := m.state.Apps[item.specName]
					if state.Health != health {
						state.Health = health
						m.state.Apps[item.specName] = state
						changed = true
					}
				case "service":
					state := m.state.Services[item.specName]
					if state.Health != health {
						state.Health = health
						m.state.Services[item.specName] = state
						changed = true
					}
				}
				m.mu.Unlock()
			}
			if changed {
				_ = m.writeState()
			}
		}
	}
}

func (m *NativeManager) inspectHealth(item managedContainer) WorkloadHealth {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	inspect, err := m.cli.ContainerInspect(ctx, item.containerID)
	if err != nil {
		return WorkloadHealth{Up: false, Reason: "inspect failed"}
	}
	if inspect.State == nil || !inspect.State.Running {
		reason := "not running"
		if inspect.State != nil && inspect.State.Status != "" {
			reason = inspect.State.Status
		}
		return WorkloadHealth{Up: false, Reason: reason}
	}

	if healthErr := waitForEndpoint("127.0.0.1", item.port, item.check, 1500*time.Millisecond); healthErr != nil {
		return WorkloadHealth{Up: false, Reason: healthErr.Error()}
	}
	return WorkloadHealth{Up: true, Reason: "ok"}
}

func (m *NativeManager) startService(ctx context.Context, spec ServiceSpec) (ServiceState, managedContainer, error) {
	imageRef, digest, err := m.ensureImage(ctx, "service", spec.Name, spec.Image, spec.Dockerfile)
	if err != nil {
		return ServiceState{}, managedContainer{}, err
	}
	envList := toEnvList(spec.Env)
	mounts, err := m.ensureVolumeMounts(ctx, spec.Volume)
	if err != nil {
		return ServiceState{}, managedContainer{}, err
	}

	hostPort, containerID, err := m.runContainer(ctx, "service", spec.Name, imageRef, spec.Port, envList, spec.Command, mounts)
	if err != nil {
		return ServiceState{}, managedContainer{}, err
	}

	service := ServiceState{
		Name:         spec.Name,
		Image:        firstNonEmpty(spec.Image, spec.Dockerfile),
		ImageDigest:  digest,
		Host:         "127.0.0.1",
		Port:         hostPort,
		InternalHost: spec.Name + ".internal",
		InternalPort: spec.Port,
		ContainerID:  containerID,
		Health:       WorkloadHealth{Up: true, Reason: "ok"},
		Volume:       spec.Volume,
	}
	service.URL = BuildServiceURL(spec.Name, service.Host, service.Port, spec.Env)
	service.InternalURL = BuildServiceURL(spec.Name, service.InternalHost, service.InternalPort, spec.Env)
	service.FunctionEnv = BuildFunctionServiceEnv(spec.Name, service, spec.Env)

	if err := waitForEndpoint(service.Host, service.Port, effectiveHealthcheck(spec.Healthcheck), 30*time.Second); err != nil {
		service.Health = WorkloadHealth{Up: false, Reason: err.Error()}
	}

	return service, managedContainer{
		kind:        "service",
		name:        "service-" + spec.Name,
		specName:    spec.Name,
		containerID: containerID,
		port:        hostPort,
		check:       effectiveHealthcheck(spec.Healthcheck),
	}, nil
}

func (m *NativeManager) startApp(ctx context.Context, spec AppSpec, serviceEnv map[string]string) (AppState, managedContainer, error) {
	imageRef, digest, err := m.ensureImage(ctx, "app", spec.Name, spec.Image, spec.Dockerfile)
	if err != nil {
		return AppState{}, managedContainer{}, err
	}
	envMap := map[string]string{}
	for key, value := range serviceEnv {
		envMap[key] = value
	}
	for key, value := range spec.Env {
		envMap[key] = value
	}
	envList := toEnvList(envMap)
	mounts, err := m.ensureVolumeMounts(ctx, spec.Volume)
	if err != nil {
		return AppState{}, managedContainer{}, err
	}

	hostPort, containerID, err := m.runContainer(ctx, "app", spec.Name, imageRef, spec.Port, envList, spec.Command, mounts)
	if err != nil {
		return AppState{}, managedContainer{}, err
	}

	app := AppState{
		Name:         spec.Name,
		Image:        firstNonEmpty(spec.Image, spec.Dockerfile),
		ImageDigest:  digest,
		Host:         "127.0.0.1",
		Port:         hostPort,
		InternalPort: spec.Port,
		Routes:       append([]string{}, spec.Routes...),
		ContainerID:  containerID,
		Health:       WorkloadHealth{Up: true, Reason: "ok"},
		Volume:       spec.Volume,
		Env:          spec.Env,
	}

	if err := waitForEndpoint(app.Host, app.Port, effectiveHealthcheck(spec.Healthcheck), 30*time.Second); err != nil {
		app.Health = WorkloadHealth{Up: false, Reason: err.Error()}
	}

	return app, managedContainer{
		kind:        "app",
		name:        "app-" + spec.Name,
		specName:    spec.Name,
		containerID: containerID,
		port:        hostPort,
		check:       effectiveHealthcheck(spec.Healthcheck),
	}, nil
}

func (m *NativeManager) ensureImage(ctx context.Context, kind, name, imageRef, dockerfile string) (string, string, error) {
	if strings.TrimSpace(dockerfile) != "" {
		resolved, err := resolvePath(m.cfg.ProjectDir, dockerfile)
		if err != nil {
			return "", "", fmt.Errorf("resolve %s.%s dockerfile: %w", kind, name, err)
		}
		tag := "fastfn/" + kind + "-" + sanitizeName(name) + ":" + shortHash(resolved)
		buildDir := filepath.Dir(resolved)
		buildCtx, err := archive.TarWithOptions(buildDir, &archive.TarOptions{})
		if err != nil {
			return "", "", fmt.Errorf("build context for %s.%s: %w", kind, name, err)
		}
		defer buildCtx.Close()
		resp, err := m.cli.ImageBuild(ctx, buildCtx, dockertypes.ImageBuildOptions{
			Dockerfile: filepath.Base(resolved),
			Tags:       []string{tag},
			Remove:     true,
		})
		if err != nil {
			return "", "", fmt.Errorf("build image for %s.%s: %w", kind, name, err)
		}
		defer resp.Body.Close()
		_, _ = io.Copy(io.Discard, resp.Body)
		imageRef = tag
	} else {
		if _, _, err := m.cli.ImageInspectWithRaw(ctx, imageRef); err != nil {
			reader, pullErr := m.cli.ImagePull(ctx, imageRef, dockertypes.ImagePullOptions{})
			if pullErr != nil {
				return "", "", fmt.Errorf("pull image for %s.%s: %w", kind, name, pullErr)
			}
			_, _ = io.Copy(io.Discard, reader)
			_ = reader.Close()
		}
	}

	inspect, _, err := m.cli.ImageInspectWithRaw(ctx, imageRef)
	if err != nil {
		return "", "", fmt.Errorf("inspect image for %s.%s: %w", kind, name, err)
	}
	digest := inspect.ID
	if len(inspect.RepoDigests) > 0 {
		digest = inspect.RepoDigests[0]
	}
	return imageRef, digest, nil
}

func (m *NativeManager) ensureVolumeMounts(ctx context.Context, volume *VolumeSpec) ([]mount.Mount, error) {
	if volume == nil {
		return nil, nil
	}
	if _, err := m.cli.VolumeCreate(ctx, volumetypes.CreateOptions{Name: volume.Name}); err != nil {
		return nil, fmt.Errorf("create volume %s: %w", volume.Name, err)
	}
	return []mount.Mount{{
		Type:   mount.TypeVolume,
		Source: volume.Name,
		Target: volume.Target,
	}}, nil
}

func (m *NativeManager) runContainer(ctx context.Context, kind, name, imageRef string, containerPort int, env []string, command []string, mounts []mount.Mount) (int, string, error) {
	port := nat.Port(fmt.Sprintf("%d/tcp", containerPort))
	containerName := "fastfn-" + kind + "-" + sanitizeName(name) + "-" + shortHash(imageRef+time.Now().String())

	containerCfg := &container.Config{
		Image:        imageRef,
		Env:          env,
		ExposedPorts: nat.PortSet{port: struct{}{}},
	}
	if len(command) > 0 {
		containerCfg.Cmd = command
	}

	hostCfg := &container.HostConfig{
		RestartPolicy: container.RestartPolicy{Name: "unless-stopped"},
		Mounts:        mounts,
		PortBindings: nat.PortMap{
			port: []nat.PortBinding{{
				HostIP:   "127.0.0.1",
				HostPort: "",
			}},
		},
	}

	networkCfg := &networktypes.NetworkingConfig{
		EndpointsConfig: map[string]*networktypes.EndpointSettings{
			m.networkName: {
				Aliases: []string{name, name + ".internal"},
			},
		},
	}

	resp, err := m.cli.ContainerCreate(ctx, containerCfg, hostCfg, networkCfg, nil, containerName)
	if err != nil {
		return 0, "", fmt.Errorf("create container %s: %w", name, err)
	}
	if err := m.cli.ContainerStart(ctx, resp.ID, dockertypes.ContainerStartOptions{}); err != nil {
		return 0, "", fmt.Errorf("start container %s: %w", name, err)
	}

	inspect, err := m.cli.ContainerInspect(ctx, resp.ID)
	if err != nil {
		return 0, "", fmt.Errorf("inspect container %s: %w", name, err)
	}
	bindings := inspect.NetworkSettings.Ports[port]
	if len(bindings) == 0 {
		return 0, "", fmt.Errorf("container %s did not publish port %d", name, containerPort)
	}
	hostPort, err := strconvAtoi(bindings[0].HostPort)
	if err != nil {
		return 0, "", fmt.Errorf("parse published port for %s: %w", name, err)
	}
	return hostPort, resp.ID, nil
}

func resolvePath(root, raw string) (string, error) {
	if strings.TrimSpace(raw) == "" {
		return "", fmt.Errorf("empty path")
	}
	if filepath.IsAbs(raw) {
		return raw, nil
	}
	return filepath.Abs(filepath.Join(root, raw))
}

func shortHash(raw string) string {
	sum := sha1.Sum([]byte(raw))
	return hex.EncodeToString(sum[:4])
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func toEnvList(env map[string]string) []string {
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

func strconvAtoi(raw string) (int, error) {
	value := strings.TrimSpace(raw)
	if value == "" {
		return 0, fmt.Errorf("empty port")
	}
	var port int
	for _, ch := range value {
		if ch < '0' || ch > '9' {
			return 0, fmt.Errorf("invalid port %q", raw)
		}
		port = (port * 10) + int(ch-'0')
	}
	return port, nil
}
