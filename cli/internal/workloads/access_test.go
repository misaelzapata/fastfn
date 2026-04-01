package workloads

import (
	"net"
	"testing"
)

func TestNormalizeAccess_NormalizesHostsAndCIDRs(t *testing.T) {
	access, err := normalizeAccess(map[string]any{
		"allow_hosts": []any{" API.example.com ", "*.example.com", "api.example.com"},
		"allow_cidrs": []any{"10.0.0.1", "2001:db8::1", "10.0.0.0/8"},
	})
	if err != nil {
		t.Fatalf("normalizeAccess() error = %v", err)
	}
	if len(access.AllowHosts) != 2 {
		t.Fatalf("AllowHosts = %+v", access.AllowHosts)
	}
	if access.AllowHosts[0] != "*.example.com" || access.AllowHosts[1] != "api.example.com" {
		t.Fatalf("AllowHosts = %+v", access.AllowHosts)
	}
	if len(access.AllowCIDRs) != 3 {
		t.Fatalf("AllowCIDRs = %+v", access.AllowCIDRs)
	}
	if access.AllowCIDRs[0] != "10.0.0.0/8" || access.AllowCIDRs[1] != "10.0.0.1/32" || access.AllowCIDRs[2] != "2001:db8::1/128" {
		t.Fatalf("AllowCIDRs = %+v", access.AllowCIDRs)
	}
}

func TestNormalizeAccess_RejectsInvalidHost(t *testing.T) {
	if _, err := normalizeAccess(map[string]any{"allow_hosts": []any{"api.example.com/path"}}); err == nil {
		t.Fatalf("normalizeAccess() error = nil, want invalid host error")
	}
}

func TestAccessCIDRsAllowRemote(t *testing.T) {
	if !accessCIDRsAllowRemote([]string{"10.0.0.0/8"}, &net.TCPAddr{IP: net.ParseIP("10.1.2.3"), Port: 1234}) {
		t.Fatalf("expected remote 10.1.2.3 to be allowed")
	}
	if accessCIDRsAllowRemote([]string{"10.0.0.0/8"}, &net.TCPAddr{IP: net.ParseIP("192.168.1.10"), Port: 1234}) {
		t.Fatalf("expected remote 192.168.1.10 to be denied")
	}
	if !accessCIDRsAllowRemote([]string{"2001:db8::/32"}, &net.TCPAddr{IP: net.ParseIP("2001:db8::10"), Port: 1234}) {
		t.Fatalf("expected remote 2001:db8::10 to be allowed")
	}
}
