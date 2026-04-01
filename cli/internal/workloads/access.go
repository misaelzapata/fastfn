package workloads

import (
	"fmt"
	"net"
	"net/netip"
	"sort"
	"strings"
)

type AccessSpec struct {
	AllowHosts []string `json:"allow_hosts,omitempty"`
	AllowCIDRs []string `json:"allow_cidrs,omitempty"`
}

func (a AccessSpec) IsZero() bool {
	return len(a.AllowHosts) == 0 && len(a.AllowCIDRs) == 0
}

func normalizeAccess(raw any) (AccessSpec, error) {
	cfg, ok := normalizeStringMap(raw)
	if !ok {
		return AccessSpec{}, nil
	}

	hosts, err := normalizeAccessHosts(cfg["allow_hosts"])
	if err != nil {
		return AccessSpec{}, fmt.Errorf("allow_hosts: %w", err)
	}
	cidrs, err := normalizeAccessCIDRs(cfg["allow_cidrs"])
	if err != nil {
		return AccessSpec{}, fmt.Errorf("allow_cidrs: %w", err)
	}

	return AccessSpec{
		AllowHosts: hosts,
		AllowCIDRs: cidrs,
	}, nil
}

func normalizeAccessHosts(raw any) ([]string, error) {
	values := normalizeStringSlice(raw)
	if len(values) == 0 {
		return nil, nil
	}

	seen := map[string]struct{}{}
	out := make([]string, 0, len(values))
	for _, value := range values {
		host := strings.ToLower(strings.TrimSpace(value))
		if host == "" {
			continue
		}
		if len(host) > 200 {
			return nil, fmt.Errorf("host length must be <= 200")
		}
		if strings.ContainsAny(host, " /") {
			return nil, fmt.Errorf("host entries may not include spaces or '/'")
		}
		if _, ok := seen[host]; ok {
			continue
		}
		seen[host] = struct{}{}
		out = append(out, host)
	}
	if len(out) == 0 {
		return nil, nil
	}
	sort.Strings(out)
	return out, nil
}

func normalizeAccessCIDRs(raw any) ([]string, error) {
	values := normalizeStringSlice(raw)
	if len(values) == 0 {
		return nil, nil
	}

	seen := map[string]struct{}{}
	out := make([]string, 0, len(values))
	for _, value := range values {
		prefix, err := normalizeAccessCIDROrIP(value)
		if err != nil {
			return nil, err
		}
		if prefix == "" {
			continue
		}
		if _, ok := seen[prefix]; ok {
			continue
		}
		seen[prefix] = struct{}{}
		out = append(out, prefix)
	}
	if len(out) == 0 {
		return nil, nil
	}
	sort.Strings(out)
	return out, nil
}

func normalizeAccessCIDROrIP(raw string) (string, error) {
	value := strings.TrimSpace(raw)
	if value == "" {
		return "", nil
	}
	if prefix, err := netip.ParsePrefix(value); err == nil {
		return prefix.Masked().String(), nil
	}
	addr, err := netip.ParseAddr(value)
	if err != nil {
		return "", fmt.Errorf("invalid CIDR/IP %q", raw)
	}
	if addr.Is4() {
		return netip.PrefixFrom(addr, 32).String(), nil
	}
	return netip.PrefixFrom(addr, 128).String(), nil
}

func normalizeStringSlice(raw any) []string {
	switch typed := raw.(type) {
	case string:
		value := strings.TrimSpace(typed)
		if value == "" {
			return nil
		}
		return []string{value}
	case []string:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			value := strings.TrimSpace(item)
			if value != "" {
				out = append(out, value)
			}
		}
		return out
	case []any:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			value := strings.TrimSpace(toString(item))
			if value != "" {
				out = append(out, value)
			}
		}
		return out
	default:
		return nil
	}
}

func parseAccessCIDRs(allowCIDRs []string) ([]netip.Prefix, error) {
	if len(allowCIDRs) == 0 {
		return nil, nil
	}
	out := make([]netip.Prefix, 0, len(allowCIDRs))
	for _, value := range allowCIDRs {
		prefix, err := netip.ParsePrefix(strings.TrimSpace(value))
		if err != nil {
			return nil, fmt.Errorf("parse CIDR %q: %w", value, err)
		}
		out = append(out, prefix.Masked())
	}
	return out, nil
}

func accessCIDRsAllowRemote(allowCIDRs []string, remoteAddr net.Addr) bool {
	prefixes, err := parseAccessCIDRs(allowCIDRs)
	if err != nil {
		return false
	}
	return accessPrefixesAllowRemote(prefixes, remoteAddr)
}

func accessPrefixesAllowRemote(prefixes []netip.Prefix, remoteAddr net.Addr) bool {
	if len(prefixes) == 0 {
		return true
	}
	ip, ok := remoteAddrIP(remoteAddr)
	if !ok {
		return false
	}
	for _, prefix := range prefixes {
		if prefix.Contains(ip) {
			return true
		}
	}
	return false
}

func remoteAddrIP(remoteAddr net.Addr) (netip.Addr, bool) {
	switch typed := remoteAddr.(type) {
	case *net.TCPAddr:
		if typed == nil {
			return netip.Addr{}, false
		}
		addr, ok := netip.AddrFromSlice(typed.IP)
		return addr.Unmap(), ok
	case *net.UDPAddr:
		if typed == nil {
			return netip.Addr{}, false
		}
		addr, ok := netip.AddrFromSlice(typed.IP)
		return addr.Unmap(), ok
	default:
		host, _, err := net.SplitHostPort(strings.TrimSpace(remoteAddr.String()))
		if err != nil {
			host = strings.TrimSpace(remoteAddr.String())
		}
		addr, err := netip.ParseAddr(host)
		if err != nil {
			return netip.Addr{}, false
		}
		return addr.Unmap(), true
	}
}
