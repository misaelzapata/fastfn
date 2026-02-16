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
