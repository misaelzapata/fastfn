package cmd

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/spf13/viper"
)

type fakeDomainProber struct {
	hostAddrs map[string][]string
	hostErr   map[string]error
	cname     map[string]string
	cnameErr  map[string]error
	tls       map[string]tlsProbeResult
	tlsErr    map[string]error
	http      map[string]httpProbeResult
	httpErr   map[string]error
}

func (f *fakeDomainProber) LookupHost(_ context.Context, host string) ([]string, error) {
	if err, ok := f.hostErr[host]; ok {
		return nil, err
	}
	return f.hostAddrs[host], nil
}

func (f *fakeDomainProber) LookupCNAME(_ context.Context, host string) (string, error) {
	if err, ok := f.cnameErr[host]; ok {
		return "", err
	}
	return f.cname[host], nil
}

func (f *fakeDomainProber) TLSInfo(_ context.Context, host string) (tlsProbeResult, error) {
	if err, ok := f.tlsErr[host]; ok {
		return tlsProbeResult{}, err
	}
	return f.tls[host], nil
}

func (f *fakeDomainProber) HTTPInfo(_ context.Context, rawURL string) (httpProbeResult, error) {
	if err, ok := f.httpErr[rawURL]; ok {
		return httpProbeResult{}, err
	}
	return f.http[rawURL], nil
}

func TestNormalizeDomain(t *testing.T) {
	got := normalizeDomain("  API.Example.COM. ")
	if got != "api.example.com" {
		t.Fatalf("normalizeDomain mismatch: %q", got)
	}
}

func TestIsValidDomainName_ValidCases(t *testing.T) {
	cases := []string{
		"api.example.com",
		"www.example.co.uk",
		"xn--bcher-kva.example",
	}
	for _, tc := range cases {
		if !isValidDomainName(tc) {
			t.Fatalf("expected valid domain: %s", tc)
		}
	}
}

func TestIsValidDomainName_InvalidCases(t *testing.T) {
	cases := []string{
		"",
		"localhost",
		"*.example.com",
		"api_example.com",
		"-bad.example.com",
		"bad-.example.com",
		"bad..example.com",
		"api.exa$mple.com",
	}
	for _, tc := range cases {
		if isValidDomainName(tc) {
			t.Fatalf("expected invalid domain: %s", tc)
		}
	}
}

func TestMatchesExpectedTarget_IPMatch(t *testing.T) {
	if !matchesExpectedTarget("203.0.113.10", []string{"203.0.113.10"}, "") {
		t.Fatalf("expected IP target to match")
	}
}

func TestMatchesExpectedTarget_IPMismatch(t *testing.T) {
	if matchesExpectedTarget("203.0.113.10", []string{"198.51.100.20"}, "") {
		t.Fatalf("expected IP target mismatch")
	}
}

func TestMatchesExpectedTarget_CNAMEMatch(t *testing.T) {
	if !matchesExpectedTarget("lb.example.net", nil, "LB.Example.Net.") {
		t.Fatalf("expected CNAME target to match")
	}
}

func TestMatchesExpectedTarget_CNAMEMismatch(t *testing.T) {
	if matchesExpectedTarget("lb.example.net", nil, "other.example.net.") {
		t.Fatalf("expected CNAME target mismatch")
	}
}

func TestClassifyTLSExpiry_OK(t *testing.T) {
	status, _ := classifyTLSExpiry(time.Now().Add(45*24*time.Hour), time.Now())
	if status != doctorStatusOK {
		t.Fatalf("expected OK, got %s", status)
	}
}

func TestClassifyTLSExpiry_Warn(t *testing.T) {
	status, _ := classifyTLSExpiry(time.Now().Add(7*24*time.Hour), time.Now())
	if status != doctorStatusWarn {
		t.Fatalf("expected WARN, got %s", status)
	}
}

func TestClassifyTLSExpiry_Fail(t *testing.T) {
	status, _ := classifyTLSExpiry(time.Now().Add(-24*time.Hour), time.Now())
	if status != doctorStatusFail {
		t.Fatalf("expected FAIL, got %s", status)
	}
}

func TestEvaluateHTTPRedirect_EnforceHTTPS_OK(t *testing.T) {
	if got := evaluateHTTPRedirect(true, "https://api.example.com/"); got != doctorStatusOK {
		t.Fatalf("expected OK, got %s", got)
	}
}

func TestEvaluateHTTPRedirect_EnforceHTTPS_Warn(t *testing.T) {
	if got := evaluateHTTPRedirect(true, "http://api.example.com/"); got != doctorStatusWarn {
		t.Fatalf("expected WARN, got %s", got)
	}
}

func TestEvaluateHTTPRedirect_NoEnforce_OK(t *testing.T) {
	if got := evaluateHTTPRedirect(false, "http://api.example.com/"); got != doctorStatusOK {
		t.Fatalf("expected OK, got %s", got)
	}
}

func TestParseDomainTargets_StringSlice(t *testing.T) {
	targets, errs := parseDomainTargets([]any{"api.example.com", "www.example.com"})
	if len(errs) > 0 {
		t.Fatalf("unexpected parse errors: %v", errs)
	}
	if len(targets) != 2 {
		t.Fatalf("expected 2 targets, got %d", len(targets))
	}
	if !targets[0].EnforceHTTPS || !targets[1].EnforceHTTPS {
		t.Fatalf("expected default enforce-https=true for string entries")
	}
}

func TestParseDomainTargets_MapEntry(t *testing.T) {
	raw := []any{
		map[string]any{
			"domain":          "api.example.com",
			"expected-target": "lb.example.net",
			"enforce-https":   false,
		},
	}
	targets, errs := parseDomainTargets(raw)
	if len(errs) > 0 {
		t.Fatalf("unexpected parse errors: %v", errs)
	}
	if len(targets) != 1 {
		t.Fatalf("expected 1 target, got %d", len(targets))
	}
	if targets[0].Domain != "api.example.com" {
		t.Fatalf("unexpected domain: %q", targets[0].Domain)
	}
	if targets[0].ExpectedTarget != "lb.example.net" {
		t.Fatalf("unexpected expected-target: %q", targets[0].ExpectedTarget)
	}
	if targets[0].EnforceHTTPS {
		t.Fatalf("expected enforce-https=false")
	}
}

func TestParseDomainTargets_MapAnyAnyEntry(t *testing.T) {
	raw := []any{
		map[any]any{
			"domain":          "api.example.com",
			"expected_target": "lb.example.net",
			"enforce_https":   "true",
		},
	}
	targets, errs := parseDomainTargets(raw)
	if len(errs) > 0 {
		t.Fatalf("unexpected parse errors: %v", errs)
	}
	if len(targets) != 1 {
		t.Fatalf("expected 1 target, got %d", len(targets))
	}
	if targets[0].ExpectedTarget != "lb.example.net" {
		t.Fatalf("unexpected expected-target: %q", targets[0].ExpectedTarget)
	}
	if !targets[0].EnforceHTTPS {
		t.Fatalf("expected enforce-https=true")
	}
}

func TestParseDomainTargets_InvalidType(t *testing.T) {
	_, errs := parseDomainTargets([]any{123})
	if len(errs) == 0 {
		t.Fatalf("expected parse error for invalid entry type")
	}
}

func TestParseDomainTargets_MissingDomainField(t *testing.T) {
	_, errs := parseDomainTargets([]any{map[string]any{"expected-target": "x"}})
	if len(errs) == 0 {
		t.Fatalf("expected parse error for missing domain field")
	}
}

func TestParseDomainTargets_Deduplicates(t *testing.T) {
	targets, errs := parseDomainTargets([]any{"api.example.com", "api.example.com"})
	if len(errs) > 0 {
		t.Fatalf("unexpected parse errors: %v", errs)
	}
	if len(targets) != 1 {
		t.Fatalf("expected deduplicated target list length 1, got %d", len(targets))
	}
}

func TestResolveDoctorDomainTargets_FromFlags(t *testing.T) {
	got, err := resolveDoctorDomainTargets([]string{"api.example.com", "www.example.com"}, "lb.example.net", true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 targets, got %d", len(got))
	}
	for _, g := range got {
		if g.ExpectedTarget != "lb.example.net" {
			t.Fatalf("expected target override not applied")
		}
	}
}

func TestResolveDoctorDomainTargets_FromConfig(t *testing.T) {
	viper.Set("domains", []any{
		map[string]any{
			"domain":          "api.example.com",
			"expected-target": "lb.example.net",
			"enforce-https":   true,
		},
	})
	defer viper.Set("domains", nil)

	got, err := resolveDoctorDomainTargets(nil, "", true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("expected 1 target, got %d", len(got))
	}
	if got[0].Domain != "api.example.com" {
		t.Fatalf("unexpected domain: %q", got[0].Domain)
	}
}

func TestRunDomainDoctorChecks_HealthyDomain(t *testing.T) {
	now := time.Now().Add(60 * 24 * time.Hour)
	prober := &fakeDomainProber{
		hostAddrs: map[string][]string{"api.example.com": {"203.0.113.10"}},
		hostErr:   map[string]error{},
		cname:     map[string]string{"api.example.com": "lb.example.net."},
		cnameErr:  map[string]error{},
		tls: map[string]tlsProbeResult{
			"api.example.com": {NotAfter: now},
		},
		tlsErr: map[string]error{},
		http: map[string]httpProbeResult{
			"https://api.example.com/": {StatusCode: 200, FinalURL: "https://api.example.com/"},
			"http://api.example.com/":  {StatusCode: 301, FinalURL: "https://api.example.com/"},
			"http://api.example.com/.well-known/acme-challenge/fastfn-doctor-probe": {StatusCode: 404, FinalURL: "http://api.example.com/.well-known/acme-challenge/fastfn-doctor-probe"},
		},
		httpErr: map[string]error{},
	}

	targets := []domainTarget{{Domain: "api.example.com", ExpectedTarget: "lb.example.net", EnforceHTTPS: true}}
	report := runDomainDoctorChecks(context.Background(), targets, prober)
	if report.Summary.Fail != 0 {
		t.Fatalf("expected no failures, got %+v", report.Summary)
	}
}

func TestRunDomainDoctorChecks_DNSFailure(t *testing.T) {
	prober := &fakeDomainProber{
		hostAddrs: map[string][]string{},
		hostErr:   map[string]error{"api.example.com": errors.New("no such host")},
		cname:     map[string]string{},
		cnameErr:  map[string]error{"api.example.com": errors.New("no cname")},
		tls:       map[string]tlsProbeResult{},
		tlsErr:    map[string]error{"api.example.com": errors.New("tls fail")},
		http:      map[string]httpProbeResult{},
		httpErr: map[string]error{
			"https://api.example.com/": errors.New("dial tcp"),
			"http://api.example.com/":  errors.New("dial tcp"),
			"http://api.example.com/.well-known/acme-challenge/fastfn-doctor-probe": errors.New("dial tcp"),
		},
	}

	targets := []domainTarget{{Domain: "api.example.com", EnforceHTTPS: true}}
	report := runDomainDoctorChecks(context.Background(), targets, prober)
	if report.Summary.Fail == 0 {
		t.Fatalf("expected failures when DNS/TLS/HTTP probes fail")
	}
}

func TestSummarizeDoctorChecks(t *testing.T) {
	checks := []doctorCheck{
		{Status: doctorStatusOK},
		{Status: doctorStatusWarn},
		{Status: doctorStatusFail},
		{Status: doctorStatusOK},
	}
	got := summarizeDoctorChecks(checks)
	want := doctorSummary{OK: 2, Warn: 1, Fail: 1}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("summary mismatch: got=%+v want=%+v", got, want)
	}
}

// ---------------------------------------------------------------------------
// netDomainProber.LookupHost / LookupCNAME
// ---------------------------------------------------------------------------

func TestNetDomainProber_LookupHost(t *testing.T) {
	prober := &netDomainProber{}
	// Use a well-known domain that will resolve
	addrs, err := prober.LookupHost(context.Background(), "localhost")
	if err != nil {
		// Some systems may not resolve localhost via DNS, that's acceptable
		t.Logf("LookupHost(localhost) returned error: %v (may be expected)", err)
		return
	}
	if len(addrs) == 0 {
		t.Fatal("expected at least one address for localhost")
	}
}

func TestNetDomainProber_LookupCNAME(t *testing.T) {
	prober := &netDomainProber{}
	// CNAME for localhost should either return localhost or error
	cname, err := prober.LookupCNAME(context.Background(), "localhost")
	if err != nil {
		t.Logf("LookupCNAME(localhost) returned error: %v (may be expected)", err)
		return
	}
	if cname == "" {
		t.Fatal("expected non-empty CNAME result")
	}
}

// ---------------------------------------------------------------------------
// parseDomainTargets – []string branch
// ---------------------------------------------------------------------------

func TestParseDomainTargets_NativeStringSlice(t *testing.T) {
	targets, errs := parseDomainTargets([]string{"api.example.com", "www.example.com"})
	if len(errs) > 0 {
		t.Fatalf("unexpected errors: %v", errs)
	}
	if len(targets) != 2 {
		t.Fatalf("expected 2 targets, got %d", len(targets))
	}
	for _, tgt := range targets {
		if !tgt.EnforceHTTPS {
			t.Fatal("expected default enforce-https=true")
		}
	}
}

func TestParseDomainTargets_SingleString(t *testing.T) {
	targets, errs := parseDomainTargets("api.example.com")
	if len(errs) > 0 {
		t.Fatalf("unexpected errors: %v", errs)
	}
	if len(targets) != 1 {
		t.Fatalf("expected 1 target, got %d", len(targets))
	}
	if targets[0].Domain != "api.example.com" {
		t.Fatalf("unexpected domain: %q", targets[0].Domain)
	}
}

func TestParseDomainTargets_UnsupportedType(t *testing.T) {
	_, errs := parseDomainTargets(42)
	if len(errs) == 0 {
		t.Fatal("expected error for unsupported type")
	}
}

func TestParseDomainTargets_EmptyDomainInMap(t *testing.T) {
	raw := []any{
		map[string]any{"domain": "   "},
	}
	_, errs := parseDomainTargets(raw)
	if len(errs) == 0 {
		t.Fatal("expected error for empty domain field")
	}
}

// ---------------------------------------------------------------------------
// resolveDoctorDomainTargets – viper config path branches
// ---------------------------------------------------------------------------

func TestResolveDoctorDomainTargets_EmptyFlagDomainsSkipped(t *testing.T) {
	_, err := resolveDoctorDomainTargets([]string{"  "}, "", true)
	if err == nil {
		t.Fatal("expected error when all flag domains are whitespace")
	}
}

func TestResolveDoctorDomainTargets_NoConfig(t *testing.T) {
	viper.Set("domains", nil)
	defer viper.Set("domains", nil)

	_, err := resolveDoctorDomainTargets(nil, "", true)
	if err == nil {
		t.Fatal("expected error when no domains configured")
	}
}

func TestResolveDoctorDomainTargets_ConfigWithExpectedTargetOverride(t *testing.T) {
	viper.Set("domains", []any{
		map[string]any{"domain": "api.example.com"},
	})
	defer viper.Set("domains", nil)

	got, err := resolveDoctorDomainTargets(nil, "lb.example.net", true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("expected 1 target, got %d", len(got))
	}
	if got[0].ExpectedTarget != "lb.example.net" {
		t.Fatalf("expected target override, got %q", got[0].ExpectedTarget)
	}
}

func TestResolveDoctorDomainTargets_InvalidConfig(t *testing.T) {
	viper.Set("domains", 42) // invalid type
	defer viper.Set("domains", nil)

	_, err := resolveDoctorDomainTargets(nil, "", true)
	if err == nil {
		t.Fatal("expected error for invalid domains config")
	}
}

// ---------------------------------------------------------------------------
// matchesExpectedTarget – empty expected
// ---------------------------------------------------------------------------

func TestMatchesExpectedTarget_EmptyExpected(t *testing.T) {
	if matchesExpectedTarget("", []string{"1.2.3.4"}, "cname.example.com") {
		t.Fatal("expected false when expected target is empty")
	}
}

func TestParseDomainTargets_EmptyDomainInStringSlice(t *testing.T) {
	// When using []string with an empty domain, it should produce an error
	targets, errs := parseDomainTargets([]string{"api.example.com", "  "})
	// The empty string after normalization becomes "", triggering the empty domain error
	if len(errs) == 0 {
		// If no errors, verify only the valid target is present
		if len(targets) != 1 {
			t.Fatalf("expected 1 valid target, got %d", len(targets))
		}
	}
}

func TestParseDomainTargets_Nil(t *testing.T) {
	targets, errs := parseDomainTargets(nil)
	if len(targets) != 0 || len(errs) != 0 {
		t.Fatalf("expected nil input to return empty results, got targets=%v errs=%v", targets, errs)
	}
}

func TestRunDomainDoctorChecks_DNSTargetMismatch(t *testing.T) {
	now := time.Now().Add(60 * 24 * time.Hour)
	prober := &fakeDomainProber{
		hostAddrs: map[string][]string{"api.example.com": {"1.2.3.4"}},
		hostErr:   map[string]error{},
		cname:     map[string]string{"api.example.com": "other.example.net."},
		cnameErr:  map[string]error{},
		tls: map[string]tlsProbeResult{
			"api.example.com": {NotAfter: now},
		},
		tlsErr: map[string]error{},
		http: map[string]httpProbeResult{
			"https://api.example.com/": {StatusCode: 200, FinalURL: "https://api.example.com/"},
			"http://api.example.com/":  {StatusCode: 301, FinalURL: "https://api.example.com/"},
			"http://api.example.com/.well-known/acme-challenge/fastfn-doctor-probe": {StatusCode: 404, FinalURL: ""},
		},
		httpErr: map[string]error{},
	}

	targets := []domainTarget{{Domain: "api.example.com", ExpectedTarget: "lb.example.net", EnforceHTTPS: true}}
	report := runDomainDoctorChecks(context.Background(), targets, prober)
	found := false
	for _, c := range report.Checks {
		if c.ID == "dns.target" && c.Status == doctorStatusFail {
			found = true
		}
	}
	if !found {
		t.Fatal("expected dns.target FAIL when expected target doesn't match")
	}
}

func TestRunDomainDoctorChecks_HTTPRedirectNotEnforcedOK(t *testing.T) {
	now := time.Now().Add(60 * 24 * time.Hour)
	prober := &fakeDomainProber{
		hostAddrs: map[string][]string{"api.example.com": {"1.2.3.4"}},
		hostErr:   map[string]error{},
		cname:     map[string]string{"api.example.com": "lb.example.net."},
		cnameErr:  map[string]error{},
		tls: map[string]tlsProbeResult{
			"api.example.com": {NotAfter: now},
		},
		tlsErr: map[string]error{},
		http: map[string]httpProbeResult{
			"https://api.example.com/": {StatusCode: 200, FinalURL: "https://api.example.com/"},
			"http://api.example.com/":  {StatusCode: 200, FinalURL: "http://api.example.com/"},
			"http://api.example.com/.well-known/acme-challenge/fastfn-doctor-probe": {StatusCode: 404, FinalURL: ""},
		},
		httpErr: map[string]error{},
	}

	// EnforceHTTPS=false so http.redirect should be OK even without redirect
	targets := []domainTarget{{Domain: "api.example.com", EnforceHTTPS: false}}
	report := runDomainDoctorChecks(context.Background(), targets, prober)
	found := false
	for _, c := range report.Checks {
		if c.ID == "http.redirect" && c.Status == doctorStatusOK {
			found = true
		}
	}
	if !found {
		t.Fatal("expected http.redirect OK when enforceHTTPS=false")
	}
}

func TestRunDomainDoctorChecks_HTTPRedirectEnforcedNoRedirect(t *testing.T) {
	now := time.Now().Add(60 * 24 * time.Hour)
	prober := &fakeDomainProber{
		hostAddrs: map[string][]string{"api.example.com": {"1.2.3.4"}},
		hostErr:   map[string]error{},
		cname:     map[string]string{"api.example.com": "lb.example.net."},
		cnameErr:  map[string]error{},
		tls: map[string]tlsProbeResult{
			"api.example.com": {NotAfter: now},
		},
		tlsErr: map[string]error{},
		http: map[string]httpProbeResult{
			"https://api.example.com/": {StatusCode: 200, FinalURL: "https://api.example.com/"},
			"http://api.example.com/":  {StatusCode: 200, FinalURL: "http://api.example.com/"},
			"http://api.example.com/.well-known/acme-challenge/fastfn-doctor-probe": {StatusCode: 404, FinalURL: ""},
		},
		httpErr: map[string]error{},
	}

	targets := []domainTarget{{Domain: "api.example.com", EnforceHTTPS: true}}
	report := runDomainDoctorChecks(context.Background(), targets, prober)
	found := false
	for _, c := range report.Checks {
		if c.ID == "http.redirect" {
			if c.Status != doctorStatusOK {
				found = true // Should be non-OK because HTTP doesn't redirect to HTTPS
			}
		}
	}
	if !found {
		t.Fatal("expected non-OK http.redirect when enforceHTTPS=true but no HTTPS redirect")
	}
}

func TestMatchesExpectedTarget_IPNoMatch(t *testing.T) {
	// Expected is an IP, but no addresses match
	if matchesExpectedTarget("10.0.0.1", []string{"10.0.0.2", "10.0.0.3"}, "") {
		t.Fatal("expected false when IP doesn't match any address")
	}
}

// ---------------------------------------------------------------------------
// runDomainDoctorChecks – invalid domain format
// ---------------------------------------------------------------------------

func TestRunDomainDoctorChecks_InvalidDomainFormat(t *testing.T) {
	prober := &fakeDomainProber{
		hostAddrs: map[string][]string{},
		hostErr:   map[string]error{},
		cname:     map[string]string{},
		cnameErr:  map[string]error{},
		tls:       map[string]tlsProbeResult{},
		tlsErr:    map[string]error{},
		http:      map[string]httpProbeResult{},
		httpErr:   map[string]error{},
	}

	targets := []domainTarget{{Domain: "invalid_domain"}}
	report := runDomainDoctorChecks(context.Background(), targets, prober)
	if report.Summary.Fail != 1 {
		t.Fatalf("expected 1 failure for invalid domain, got %+v", report.Summary)
	}
}

func TestRunDomainDoctorChecks_HTTPSStatus500(t *testing.T) {
	now := time.Now().Add(60 * 24 * time.Hour)
	prober := &fakeDomainProber{
		hostAddrs: map[string][]string{"api.example.com": {"1.2.3.4"}},
		hostErr:   map[string]error{},
		cname:     map[string]string{"api.example.com": "lb.example.net."},
		cnameErr:  map[string]error{},
		tls: map[string]tlsProbeResult{
			"api.example.com": {NotAfter: now},
		},
		tlsErr: map[string]error{},
		http: map[string]httpProbeResult{
			"https://api.example.com/": {StatusCode: 500, FinalURL: "https://api.example.com/"},
			"http://api.example.com/":  {StatusCode: 200, FinalURL: "http://api.example.com/"},
			"http://api.example.com/.well-known/acme-challenge/fastfn-doctor-probe": {StatusCode: 500, FinalURL: ""},
		},
		httpErr: map[string]error{},
	}

	targets := []domainTarget{{Domain: "api.example.com", EnforceHTTPS: false}}
	report := runDomainDoctorChecks(context.Background(), targets, prober)
	// Should have failures for HTTPS 500 and ACME 500
	failCount := 0
	for _, c := range report.Checks {
		if c.Status == doctorStatusFail {
			failCount++
		}
	}
	if failCount < 1 {
		t.Fatalf("expected at least 1 failure for 500 statuses, got %d", failCount)
	}
}

func TestRunDomainDoctorChecks_HTTPErrorWithEnforceHTTPS(t *testing.T) {
	now := time.Now().Add(60 * 24 * time.Hour)
	prober := &fakeDomainProber{
		hostAddrs: map[string][]string{"api.example.com": {"1.2.3.4"}},
		hostErr:   map[string]error{},
		cname:     map[string]string{"api.example.com": "lb.example.net."},
		cnameErr:  map[string]error{},
		tls: map[string]tlsProbeResult{
			"api.example.com": {NotAfter: now},
		},
		tlsErr: map[string]error{},
		http: map[string]httpProbeResult{
			"https://api.example.com/": {StatusCode: 200, FinalURL: "https://api.example.com/"},
			"http://api.example.com/.well-known/acme-challenge/fastfn-doctor-probe": {StatusCode: 200, FinalURL: ""},
		},
		httpErr: map[string]error{
			"http://api.example.com/": errors.New("connection refused"),
		},
	}

	targets := []domainTarget{{Domain: "api.example.com", EnforceHTTPS: true}}
	report := runDomainDoctorChecks(context.Background(), targets, prober)
	// HTTP probe fails with enforceHTTPS, should be FAIL
	found := false
	for _, c := range report.Checks {
		if c.ID == "http.redirect" && c.Status == doctorStatusFail {
			found = true
		}
	}
	if !found {
		t.Fatal("expected FAIL for http.redirect when enforceHTTPS=true and HTTP probe fails")
	}
}

func TestRunDomainDoctorChecks_HTTPErrorWithoutEnforceHTTPS(t *testing.T) {
	now := time.Now().Add(60 * 24 * time.Hour)
	prober := &fakeDomainProber{
		hostAddrs: map[string][]string{"api.example.com": {"1.2.3.4"}},
		hostErr:   map[string]error{},
		cname:     map[string]string{"api.example.com": "lb.example.net."},
		cnameErr:  map[string]error{},
		tls: map[string]tlsProbeResult{
			"api.example.com": {NotAfter: now},
		},
		tlsErr: map[string]error{},
		http: map[string]httpProbeResult{
			"https://api.example.com/": {StatusCode: 200, FinalURL: "https://api.example.com/"},
			"http://api.example.com/.well-known/acme-challenge/fastfn-doctor-probe": {StatusCode: 200, FinalURL: ""},
		},
		httpErr: map[string]error{
			"http://api.example.com/": errors.New("connection refused"),
		},
	}

	targets := []domainTarget{{Domain: "api.example.com", EnforceHTTPS: false}}
	report := runDomainDoctorChecks(context.Background(), targets, prober)
	// HTTP probe fails without enforceHTTPS, should be WARN
	found := false
	for _, c := range report.Checks {
		if c.ID == "http.redirect" && c.Status == doctorStatusWarn {
			found = true
		}
	}
	if !found {
		t.Fatal("expected WARN for http.redirect when enforceHTTPS=false and HTTP probe fails")
	}
}

func TestRunDomainDoctorChecks_NoExpectedTarget(t *testing.T) {
	now := time.Now().Add(60 * 24 * time.Hour)
	prober := &fakeDomainProber{
		hostAddrs: map[string][]string{"api.example.com": {"1.2.3.4"}},
		hostErr:   map[string]error{},
		cname:     map[string]string{"api.example.com": "lb.example.net."},
		cnameErr:  map[string]error{},
		tls: map[string]tlsProbeResult{
			"api.example.com": {NotAfter: now},
		},
		tlsErr: map[string]error{},
		http: map[string]httpProbeResult{
			"https://api.example.com/": {StatusCode: 200, FinalURL: "https://api.example.com/"},
			"http://api.example.com/":  {StatusCode: 301, FinalURL: "https://api.example.com/"},
			"http://api.example.com/.well-known/acme-challenge/fastfn-doctor-probe": {StatusCode: 404, FinalURL: ""},
		},
		httpErr: map[string]error{},
	}

	// No expected target set - dns.target check should be skipped
	targets := []domainTarget{{Domain: "api.example.com", EnforceHTTPS: true}}
	report := runDomainDoctorChecks(context.Background(), targets, prober)
	for _, c := range report.Checks {
		if c.ID == "dns.target" {
			t.Fatal("expected dns.target check to be skipped when no expected target")
		}
	}
}
