//go:build linux

package workloads

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const guestEntropySeedBytes = 256

type workloadPlan struct {
	Kind         string
	Name         string
	ScopeDir     string
	Image        string
	Lifecycle    LifecycleSpec
	InternalHost string
	InternalPort int
	InternalURL  string
	Routes       []string
	Volume       *VolumeSpec
	Healthcheck  HealthcheckSpec
	SpecEnv      map[string]string
	BaseEnv      map[string]string
	Bundle       FirecrackerBundle
	Boot         workloadBootConfig
	DebugSSH     *workloadDebugSSH
	Peer         workloadPeer
	Bridges      []workloadServiceBridgeTarget
	VMDir        string
	ConfigDrive  string
	SocketPath   string
	VsockPath    string
	LogPath      string
	ConsolePath  string
}

func (m *FirecrackerManager) planWorkloads(ctx context.Context) ([]workloadPlan, error) {
	plans := make([]workloadPlan, 0, len(m.cfg.Services)+len(m.cfg.Apps))
	seen := map[string]string{}

	for _, spec := range m.cfg.Services {
		plan, err := m.planService(ctx, spec, seen)
		if err != nil {
			return nil, err
		}
		plans = append(plans, plan)
	}
	for _, spec := range m.cfg.Apps {
		plan, err := m.planApp(ctx, spec, seen)
		if err != nil {
			return nil, err
		}
		plans = append(plans, plan)
	}

	peers := make([]workloadPeer, 0, len(plans))
	targets := map[string]workloadPlan{}
	for _, plan := range plans {
		peers = append(peers, plan.Peer)
		targets[workloadPlanKey(plan.Kind, plan.Name)] = plan
	}

	for idx := range plans {
		bindings, err := planWorkloadPeerBindings(plans[idx].Peer, peers)
		if err != nil {
			return nil, err
		}
		plans[idx].Boot.Env = buildImageWorkloadPeerEnv(bindings, plans[idx].BaseEnv)
		plans[idx].Boot.Services = buildPeerServiceBindings(bindings)
		plans[idx].Boot.InboundPorts = appendDebugSSHInboundPort(plans[idx].Boot.InboundPorts, plans[idx].DebugSSH)
		bridges, err := buildPeerBridgeTargets(bindings, targets)
		if err != nil {
			return nil, err
		}
		plans[idx].Bridges = bridges
	}

	return plans, nil
}

func (m *FirecrackerManager) planService(ctx context.Context, spec ServiceSpec, seen map[string]string) (workloadPlan, error) {
	if err := validateWorkloadPlanName("service", spec.Name, seen); err != nil {
		return workloadPlan{}, err
	}
	bundle, err := ResolveWorkloadBundle(ctx, m.cfg.ProjectDir, spec.ScopeDir, "service", spec.Name, spec.Image, spec.ImageFile, spec.Dockerfile, spec.Context)
	if err != nil {
		return workloadPlan{}, err
	}
	layout, err := allocateVMLayout(m.cfg.StatePath, "service", spec.Name)
	if err != nil {
		return workloadPlan{}, err
	}
	internalHost := spec.Name + ".internal"
	internalURL := BuildServiceURL(spec.Name, internalHost, spec.Port, spec.Env)
	baseEnv := mergeWorkloadEnv(bundle.DefaultEnv, spec.Env)
	entropySeed, err := generateGuestEntropySeed()
	if err != nil {
		return workloadPlan{}, err
	}
	debugSSH, err := planDebugSSH(layout.vmDir)
	if err != nil {
		return workloadPlan{}, err
	}

	plan := workloadPlan{
		Kind:         "service",
		Name:         spec.Name,
		ScopeDir:     spec.ScopeDir,
		Image:        firstNonEmpty(spec.Image, spec.ImageFile, spec.Dockerfile),
		Lifecycle:    spec.Lifecycle,
		InternalHost: internalHost,
		InternalPort: spec.Port,
		InternalURL:  internalURL,
		Volume:       spec.Volume,
		Healthcheck:  effectiveHealthcheck(spec.Healthcheck),
		SpecEnv:      cloneEnvMap(spec.Env),
		BaseEnv:      baseEnv,
		Bundle:       bundle,
		DebugSSH:     debugSSH,
		Boot: workloadBootConfig{
			Version:      1,
			Kind:         "service",
			Name:         spec.Name,
			Debug:        firecrackerDebugEnabled(),
			EntropySeed:  entropySeed,
			DebugSSH:     buildWorkloadDebugSSHConfig(debugSSH),
			Port:         spec.Port,
			Command:      defaultWorkloadCommand(spec.Command, bundle.DefaultCommand),
			WorkingDir:   firstNonEmpty(bundle.WorkingDir, spec.WorkingDir),
			User:         firstNonEmpty(bundle.User, spec.User),
			InboundPorts: buildInboundPorts(bundle.GuestPort, spec.Ports),
			Volumes:      buildVolumeMounts(spec.Volume),
		},
		Peer: workloadPeer{
			Kind:         "service",
			Name:         spec.Name,
			ScopeDir:     spec.ScopeDir,
			InternalHost: internalHost,
			InternalPort: spec.Port,
			InternalURL:  internalURL,
			BaseEnv:      cloneEnvMap(spec.Env),
			GuestPort:    bundle.GuestPort,
		},
		VMDir:       layout.vmDir,
		ConfigDrive: layout.configDrive,
		SocketPath:  layout.socketPath,
		VsockPath:   layout.vsockPath,
		LogPath:     layout.logPath,
		ConsolePath: layout.consolePath,
	}
	return plan, nil
}

func (m *FirecrackerManager) planApp(ctx context.Context, spec AppSpec, seen map[string]string) (workloadPlan, error) {
	if err := validateWorkloadPlanName("app", spec.Name, seen); err != nil {
		return workloadPlan{}, err
	}
	bundle, err := ResolveWorkloadBundle(ctx, m.cfg.ProjectDir, spec.ScopeDir, "app", spec.Name, spec.Image, spec.ImageFile, spec.Dockerfile, spec.Context)
	if err != nil {
		return workloadPlan{}, err
	}
	layout, err := allocateVMLayout(m.cfg.StatePath, "app", spec.Name)
	if err != nil {
		return workloadPlan{}, err
	}
	internalHost := spec.Name + ".internal"
	internalURL := BuildAppURL(internalHost, spec.Port, primaryAppProtocol(spec))
	baseEnv := mergeWorkloadEnv(bundle.DefaultEnv, spec.Env)
	entropySeed, err := generateGuestEntropySeed()
	if err != nil {
		return workloadPlan{}, err
	}
	debugSSH, err := planDebugSSH(layout.vmDir)
	if err != nil {
		return workloadPlan{}, err
	}

	plan := workloadPlan{
		Kind:         "app",
		Name:         spec.Name,
		ScopeDir:     spec.ScopeDir,
		Image:        firstNonEmpty(spec.Image, spec.ImageFile, spec.Dockerfile),
		Lifecycle:    spec.Lifecycle,
		InternalHost: internalHost,
		InternalPort: spec.Port,
		InternalURL:  internalURL,
		Routes:       append([]string{}, spec.Routes...),
		Volume:       spec.Volume,
		Healthcheck:  effectiveHealthcheck(spec.Healthcheck),
		SpecEnv:      cloneEnvMap(spec.Env),
		BaseEnv:      baseEnv,
		Bundle:       bundle,
		DebugSSH:     debugSSH,
		Boot: workloadBootConfig{
			Version:      1,
			Kind:         "app",
			Name:         spec.Name,
			Debug:        firecrackerDebugEnabled(),
			EntropySeed:  entropySeed,
			DebugSSH:     buildWorkloadDebugSSHConfig(debugSSH),
			Port:         spec.Port,
			Command:      defaultWorkloadCommand(spec.Command, bundle.DefaultCommand),
			WorkingDir:   firstNonEmpty(bundle.WorkingDir, spec.WorkingDir),
			User:         firstNonEmpty(bundle.User, spec.User),
			InboundPorts: buildInboundPorts(bundle.GuestPort, spec.Ports),
			Volumes:      buildVolumeMounts(spec.Volume),
		},
		Peer: workloadPeer{
			Kind:         "app",
			Name:         spec.Name,
			ScopeDir:     spec.ScopeDir,
			InternalHost: internalHost,
			InternalPort: spec.Port,
			InternalURL:  internalURL,
			GuestPort:    bundle.GuestPort,
		},
		VMDir:       layout.vmDir,
		ConfigDrive: layout.configDrive,
		SocketPath:  layout.socketPath,
		VsockPath:   layout.vsockPath,
		LogPath:     layout.logPath,
		ConsolePath: layout.consolePath,
	}
	return plan, nil
}

func generateGuestEntropySeed() (string, error) {
	seed := make([]byte, guestEntropySeedBytes)
	if _, err := rand.Read(seed); err != nil {
		return "", fmt.Errorf("generate guest entropy seed: %w", err)
	}
	return hex.EncodeToString(seed), nil
}

type vmLayout struct {
	vmDir       string
	configDrive string
	socketPath  string
	vsockPath   string
	logPath     string
	consolePath string
}

func allocateVMLayout(statePath, kind, name string) (vmLayout, error) {
	vmDir := filepath.Join(filepath.Dir(statePath), "firecracker-"+sanitizeName(kind)+"-"+sanitizeName(name)+"-"+shortHashFC(time.Now().UTC().String()))
	if err := os.MkdirAll(vmDir, 0o755); err != nil {
		return vmLayout{}, fmt.Errorf("create firecracker vm dir for %s.%s: %w", kind, name, err)
	}
	return vmLayout{
		vmDir:       vmDir,
		configDrive: filepath.Join(vmDir, "config.raw"),
		socketPath:  filepath.Join(vmDir, "api.sock"),
		vsockPath:   filepath.Join(vmDir, "vsock.sock"),
		logPath:     filepath.Join(vmDir, "firecracker.log"),
		consolePath: filepath.Join(vmDir, "console.log"),
	}, nil
}

func validateWorkloadPlanName(kind, name string, seen map[string]string) error {
	key := strings.ToLower(strings.TrimSpace(name))
	if previous, ok := seen[key]; ok {
		return fmt.Errorf("duplicate image workload %q across %s and %s", name, previous, kind)
	}
	seen[key] = kind
	return nil
}

func buildPeerBridgeTargets(bindings []workloadPeerBinding, targets map[string]workloadPlan) ([]workloadServiceBridgeTarget, error) {
	out := make([]workloadServiceBridgeTarget, 0, len(bindings))
	for _, binding := range bindings {
		target, ok := targets[workloadPlanKey(binding.Peer.Kind, binding.Peer.Name)]
		if !ok {
			return nil, fmt.Errorf("peer target %s.%s was not planned", binding.Peer.Kind, binding.Peer.Name)
		}
		out = append(out, workloadServiceBridgeTarget{
			VsockPort:       binding.VsockPort,
			TargetKind:      target.Kind,
			TargetName:      target.Name,
			TargetVsockPath: target.VsockPath,
			TargetGuestPort: target.Bundle.GuestPort,
		})
	}
	return out, nil
}

func primaryAppProtocol(spec AppSpec) string {
	for _, port := range spec.Ports {
		if port.ContainerPort == spec.Port && strings.TrimSpace(port.Protocol) != "" {
			return port.Protocol
		}
	}
	if len(spec.Ports) > 0 {
		return spec.Ports[0].Protocol
	}
	return "http"
}

func workloadPlanKey(kind, name string) string {
	return strings.ToLower(strings.TrimSpace(kind)) + ":" + strings.ToLower(strings.TrimSpace(name))
}

func appendDebugSSHInboundPort(inbound []workloadInboundPort, debugSSH *workloadDebugSSH) []workloadInboundPort {
	if debugSSH == nil || debugSSH.GuestPort < 1 || debugSSH.LocalPort < 1 {
		return inbound
	}
	out := append([]workloadInboundPort{}, inbound...)
	out = append(out, workloadInboundPort{
		Name:          "debug-ssh",
		Protocol:      "tcp",
		GuestPort:     debugSSH.GuestPort,
		ContainerPort: debugSSH.LocalPort,
	})
	return out
}
