package workloads

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

const privateLoopbackBasePrefix = "127.77"

type workloadPeer struct {
	Kind         string
	Name         string
	ScopeDir     string
	InternalHost string
	InternalPort int
	InternalURL  string
	BaseEnv      map[string]string
	GuestPort    int
}

type workloadPeerBinding struct {
	Peer      workloadPeer
	LocalHost string
	LocalIP   string
	LocalPort int
	VsockPort int
}

func planWorkloadPeerBindings(source workloadPeer, all []workloadPeer) ([]workloadPeerBinding, error) {
	visible := visibleWorkloadPeers(source, all)
	out := make([]workloadPeerBinding, 0, len(visible))
	for idx, peer := range visible {
		localIP, err := privateLoopbackIP(idx)
		if err != nil {
			return nil, err
		}
		vsockPort := guestServiceVsockBase + idx
		if vsockPort > 65535 {
			return nil, fmt.Errorf("too many visible peers for %s (%d)", source.Name, len(visible))
		}
		if peer.InternalPort < 1 || peer.InternalPort > 65535 {
			return nil, fmt.Errorf("peer %s has invalid internal port %d", peer.Name, peer.InternalPort)
		}
		out = append(out, workloadPeerBinding{
			Peer:      peer,
			LocalHost: peer.InternalHost,
			LocalIP:   localIP,
			LocalPort: peer.InternalPort,
			VsockPort: vsockPort,
		})
	}
	return out, nil
}

func visibleWorkloadPeers(source workloadPeer, all []workloadPeer) []workloadPeer {
	visible := make([]workloadPeer, 0, len(all))
	for _, peer := range all {
		if strings.EqualFold(peer.Name, source.Name) {
			continue
		}
		if scopeContains(peer.ScopeDir, source.ScopeDir) {
			visible = append(visible, peer)
		}
	}
	sort.Slice(visible, func(i, j int) bool {
		left := strings.ToLower(strings.TrimSpace(visible[i].Name))
		right := strings.ToLower(strings.TrimSpace(visible[j].Name))
		if left == right {
			return strings.ToLower(strings.TrimSpace(visible[i].Kind)) < strings.ToLower(strings.TrimSpace(visible[j].Kind))
		}
		return left < right
	})
	return visible
}

func privateLoopbackIP(idx int) (string, error) {
	if idx < 0 {
		return "", fmt.Errorf("invalid peer index %d", idx)
	}
	third := idx / 254
	fourth := (idx % 254) + 1
	if third > 254 {
		return "", fmt.Errorf("too many visible peers (%d)", idx+1)
	}
	return fmt.Sprintf("%s.%d.%d", privateLoopbackBasePrefix, third, fourth), nil
}

func buildImageWorkloadPeerEnv(bindings []workloadPeerBinding, baseEnv map[string]string) map[string]string {
	out := map[string]string{}
	for key, value := range baseEnv {
		out[key] = value
	}

	familyCounts := visibleServiceFamilyCounts(bindings)

	for _, binding := range bindings {
		token := serviceEnvToken(binding.Peer.Name)
		out["WORKLOAD_"+token+"_HOST"] = binding.Peer.InternalHost
		out["WORKLOAD_"+token+"_PORT"] = strconv.Itoa(binding.Peer.InternalPort)
		if strings.TrimSpace(binding.Peer.InternalURL) != "" {
			out["WORKLOAD_"+token+"_URL"] = binding.Peer.InternalURL
		}

		if !strings.EqualFold(binding.Peer.Kind, "service") {
			continue
		}

		appendScopedServiceEnv(out, binding.Peer.Name, binding.Peer.BaseEnv)
		out["SERVICE_"+token+"_HOST"] = binding.Peer.InternalHost
		out["SERVICE_"+token+"_PORT"] = strconv.Itoa(binding.Peer.InternalPort)
		out["SERVICE_"+token+"_INTERNAL_HOST"] = binding.Peer.InternalHost
		out["SERVICE_"+token+"_INTERNAL_PORT"] = strconv.Itoa(binding.Peer.InternalPort)
		if strings.TrimSpace(binding.Peer.InternalURL) != "" {
			out["SERVICE_"+token+"_URL"] = binding.Peer.InternalURL
			out["SERVICE_"+token+"_INTERNAL_URL"] = binding.Peer.InternalURL
		}

		family := serviceAliasFamily(binding.Peer.Name)
		if family == "" || familyCounts[family] != 1 {
			continue
		}
		aliasPrefix := strings.ToUpper(family)
		out[aliasPrefix+"_HOST"] = binding.Peer.InternalHost
		out[aliasPrefix+"_PORT"] = strconv.Itoa(binding.Peer.InternalPort)
		if strings.TrimSpace(binding.Peer.InternalURL) != "" {
			out[aliasPrefix+"_URL"] = binding.Peer.InternalURL
		}
		appendFamilyEnv(out, aliasPrefix, binding.Peer.BaseEnv)
	}

	return out
}

func visibleServiceFamilyCounts(bindings []workloadPeerBinding) map[string]int {
	counts := map[string]int{}
	for _, binding := range bindings {
		if !strings.EqualFold(binding.Peer.Kind, "service") {
			continue
		}
		family := serviceAliasFamily(binding.Peer.Name)
		if family == "" {
			continue
		}
		counts[family]++
	}
	return counts
}

func serviceAliasFamily(name string) string {
	parts := strings.FieldsFunc(strings.ToLower(strings.TrimSpace(name)), func(r rune) bool {
		return (r < 'a' || r > 'z') && (r < '0' || r > '9')
	})
	if len(parts) == 0 {
		return ""
	}
	switch parts[0] {
	case "mysql":
		return "mysql"
	case "postgres", "postgresql":
		return "postgres"
	case "redis":
		return "redis"
	default:
		return ""
	}
}

func appendFamilyEnv(out map[string]string, familyPrefix string, source map[string]string) {
	prefix := familyPrefix + "_"
	for key, value := range source {
		normalized := normalizeEnvKey(key)
		if !strings.HasPrefix(normalized, prefix) {
			continue
		}
		out[normalized] = value
	}
}

func buildPeerServiceBindings(bindings []workloadPeerBinding) []workloadServiceBinding {
	out := make([]workloadServiceBinding, 0, len(bindings))
	for _, binding := range bindings {
		out = append(out, workloadServiceBinding{
			Name:      binding.Peer.Name,
			LocalHost: binding.LocalHost,
			LocalIP:   binding.LocalIP,
			LocalPort: binding.LocalPort,
			VsockPort: binding.VsockPort,
			URL:       binding.Peer.InternalURL,
		})
	}
	return out
}
