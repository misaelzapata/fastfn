package cmd

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

type doctorStatus string

const (
	doctorStatusOK   doctorStatus = "OK"
	doctorStatusWarn doctorStatus = "WARN"
	doctorStatusFail doctorStatus = "FAIL"
)

type doctorCheck struct {
	Domain  string            `json:"domain,omitempty"`
	ID      string            `json:"id"`
	Status  doctorStatus      `json:"status"`
	Message string            `json:"message"`
	Hint    string            `json:"hint,omitempty"`
	Details map[string]string `json:"details,omitempty"`
}

type doctorSummary struct {
	OK   int `json:"ok"`
	Warn int `json:"warn"`
	Fail int `json:"fail"`
}

type doctorReport struct {
	Scope       string        `json:"scope"`
	GeneratedAt string        `json:"generated_at"`
	Checks      []doctorCheck `json:"checks"`
	Summary     doctorSummary `json:"summary"`
}

type domainTarget struct {
	Domain         string
	ExpectedTarget string
	EnforceHTTPS   bool
}

type tlsProbeResult struct {
	NotAfter   time.Time
	CommonName string
	DNSNames   []string
}

type httpProbeResult struct {
	StatusCode    int
	FinalURL      string
	RedirectCount int
}

type domainProber interface {
	LookupHost(ctx context.Context, host string) ([]string, error)
	LookupCNAME(ctx context.Context, host string) (string, error)
	TLSInfo(ctx context.Context, host string) (tlsProbeResult, error)
	HTTPInfo(ctx context.Context, rawURL string) (httpProbeResult, error)
}

type netDomainProber struct {
	client *http.Client
}

var (
	doctorJSON bool
	doctorFix  bool

	doctorDomains        []string
	doctorExpectedTarget string
	doctorEnforceHTTPS   bool
)

var doctorCmd = &cobra.Command{
	Use:          "doctor",
	Aliases:      []string{"check"},
	Short:        "Run local environment and project diagnostics",
	SilenceUsage: true,
	Long: `Run diagnostics for local FastFN development and CI.

Use this command to validate Docker, runtime binaries, config files, and local port readiness.
Use 'fastfn doctor domains' for domain-specific checks (DNS/TLS/HTTP).`,
	Example: `  fastfn doctor
  fastfn doctor --json
  fastfn doctor --fix
  fastfn doctor domains --domain api.example.com
  fastfn doctor domains --domain api.example.com --json`,
	RunE: func(cmd *cobra.Command, args []string) error {
		report := runGeneralDoctorChecks(doctorFix)
		if err := printDoctorReport(report, doctorJSON); err != nil {
			return err
		}
		if report.Summary.Fail > 0 {
			return fmt.Errorf("doctor found %d failing check(s)", report.Summary.Fail)
		}
		return nil
	},
}

var doctorDomainsCmd = &cobra.Command{
	Use:          "domains",
	Short:        "Validate domain DNS/TLS/HTTP readiness",
	SilenceUsage: true,
	Long: `Validate domains used by FastFN for production-style serving.

Checks include:
- domain format
- DNS resolution (A/AAAA/CNAME)
- expected target match (optional)
- TLS certificate validity and expiration window
- HTTPS reachability
- HTTP->HTTPS redirect behavior
- ACME challenge path basic reachability`,
	Example: `  fastfn doctor domains --domain api.example.com
  fastfn doctor domains --domain api.example.com --expected-target lb.example.net
  fastfn doctor domains --json`,
	RunE: func(cmd *cobra.Command, args []string) error {
		targets, err := resolveDoctorDomainTargets(doctorDomains, doctorExpectedTarget, doctorEnforceHTTPS)
		if err != nil {
			return err
		}
		report := runDomainDoctorChecks(context.Background(), targets, newNetDomainProber(8*time.Second))
		if err := printDoctorReport(report, doctorJSON); err != nil {
			return err
		}
		if report.Summary.Fail > 0 {
			return fmt.Errorf("doctor domains found %d failing check(s)", report.Summary.Fail)
		}
		return nil
	},
}

func init() {
	rootCmd.AddCommand(doctorCmd)
	doctorCmd.PersistentFlags().BoolVar(&doctorJSON, "json", false, "Print machine-readable JSON output")
	doctorCmd.Flags().BoolVar(&doctorFix, "fix", false, "Apply safe local auto-fixes when possible")

	doctorCmd.AddCommand(doctorDomainsCmd)
	doctorDomainsCmd.Flags().StringSliceVar(&doctorDomains, "domain", nil, "Domain to validate (repeat flag for multiple)")
	doctorDomainsCmd.Flags().StringVar(&doctorExpectedTarget, "expected-target", "", "Expected DNS target (IP or CNAME)")
	doctorDomainsCmd.Flags().BoolVar(&doctorEnforceHTTPS, "enforce-https", true, "Require HTTP to redirect to HTTPS")
}

func newNetDomainProber(timeout time.Duration) *netDomainProber {
	client := &http.Client{
		Timeout: timeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return http.ErrUseLastResponse
			}
			return nil
		},
	}
	return &netDomainProber{client: client}
}

func (p *netDomainProber) LookupHost(ctx context.Context, host string) ([]string, error) {
	return net.DefaultResolver.LookupHost(ctx, host)
}

func (p *netDomainProber) LookupCNAME(ctx context.Context, host string) (string, error) {
	return net.DefaultResolver.LookupCNAME(ctx, host)
}

func (p *netDomainProber) TLSInfo(ctx context.Context, host string) (tlsProbeResult, error) {
	addr := net.JoinHostPort(host, "443")
	dialer := &net.Dialer{}
	conn, err := tls.DialWithDialer(dialer, "tcp", addr, &tls.Config{
		MinVersion: tls.VersionTLS12,
		ServerName: host,
	})
	if err != nil {
		return tlsProbeResult{}, err
	}
	defer conn.Close()

	if err := conn.SetDeadline(time.Now().Add(8 * time.Second)); err != nil {
		return tlsProbeResult{}, err
	}
	if err := conn.HandshakeContext(ctx); err != nil {
		return tlsProbeResult{}, err
	}
	state := conn.ConnectionState()
	if len(state.PeerCertificates) == 0 {
		return tlsProbeResult{}, fmt.Errorf("no peer certificate returned")
	}
	cert := state.PeerCertificates[0]
	return tlsProbeResult{
		NotAfter:   cert.NotAfter,
		CommonName: cert.Subject.CommonName,
		DNSNames:   cert.DNSNames,
	}, nil
}

func (p *netDomainProber) HTTPInfo(ctx context.Context, rawURL string) (httpProbeResult, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return httpProbeResult{}, err
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return httpProbeResult{}, err
	}
	defer resp.Body.Close()
	_, _ = io.CopyN(io.Discard, resp.Body, 4096)
	finalURL := rawURL
	if resp.Request != nil && resp.Request.URL != nil {
		finalURL = resp.Request.URL.String()
	}
	return httpProbeResult{
		StatusCode:    resp.StatusCode,
		FinalURL:      finalURL,
		RedirectCount: 0,
	}, nil
}

func runGeneralDoctorChecks(applyFix bool) doctorReport {
	checks := make([]doctorCheck, 0, 12)
	now := time.Now().UTC().Format(time.RFC3339)

	checks = append(checks, checkExecutable("docker", []string{"--version"}, "docker.cli", "Docker CLI"))
	checks = append(checks, checkExecutable("docker", []string{"compose", "version"}, "docker.compose", "Docker Compose plugin"))
	checks = append(checks, checkDockerDaemon())
	checks = append(checks, checkExecutable("python3", []string{"--version"}, "runtime.python", "Python runtime"))
	checks = append(checks, checkExecutable("node", []string{"--version"}, "runtime.node", "Node runtime"))
	checks = append(checks, checkExecutable("go", []string{"version"}, "runtime.go", "Go runtime"))
	checks = append(checks, checkExecutable("openresty", []string{"-v"}, "runtime.openresty", "OpenResty runtime"))
	checks = append(checks, checkPlatform())

	configCheck, fixed := checkConfigFile(applyFix)
	checks = append(checks, configCheck)
	if fixed {
		checks = append(checks, doctorCheck{
			ID:      "project.config.fix",
			Status:  doctorStatusOK,
			Message: "Applied safe fix: created fastfn.json with default functions-dir",
		})
	}

	checks = append(checks, checkFunctionsDir())
	checks = append(checks, checkPortAvailability())

	summary := summarizeDoctorChecks(checks)
	return doctorReport{
		Scope:       "general",
		GeneratedAt: now,
		Checks:      checks,
		Summary:     summary,
	}
}

func runDomainDoctorChecks(ctx context.Context, targets []domainTarget, prober domainProber) doctorReport {
	checks := make([]doctorCheck, 0, len(targets)*8)
	now := time.Now().UTC().Format(time.RFC3339)

	for _, target := range targets {
		domain := normalizeDomain(target.Domain)
		if !isValidDomainName(domain) {
			checks = append(checks, doctorCheck{
				Domain:  domain,
				ID:      "domain.format",
				Status:  doctorStatusFail,
				Message: "Invalid domain format",
				Hint:    "Use a valid host like api.example.com (letters, digits, hyphens, dots)",
			})
			continue
		}
		checks = append(checks, doctorCheck{
			Domain:  domain,
			ID:      "domain.format",
			Status:  doctorStatusOK,
			Message: "Domain format is valid",
		})

		addrs, hostErr := prober.LookupHost(ctx, domain)
		cname, cnameErr := prober.LookupCNAME(ctx, domain)
		if hostErr != nil && cnameErr != nil {
			checks = append(checks, doctorCheck{
				Domain:  domain,
				ID:      "dns.resolve",
				Status:  doctorStatusFail,
				Message: fmt.Sprintf("DNS resolution failed: host=%v cname=%v", hostErr, cnameErr),
				Hint:    "Check DNS A/AAAA/CNAME records",
			})
		} else {
			details := map[string]string{
				"addresses": strings.Join(addrs, ", "),
			}
			if cnameErr == nil {
				details["cname"] = strings.TrimSuffix(strings.ToLower(cname), ".")
			}
			checks = append(checks, doctorCheck{
				Domain:  domain,
				ID:      "dns.resolve",
				Status:  doctorStatusOK,
				Message: "DNS resolution succeeded",
				Details: details,
			})
		}

		expected := normalizeDomain(target.ExpectedTarget)
		if expected != "" {
			if matchesExpectedTarget(expected, addrs, cname) {
				checks = append(checks, doctorCheck{
					Domain:  domain,
					ID:      "dns.target",
					Status:  doctorStatusOK,
					Message: fmt.Sprintf("Domain matches expected target %s", expected),
				})
			} else {
				checks = append(checks, doctorCheck{
					Domain:  domain,
					ID:      "dns.target",
					Status:  doctorStatusFail,
					Message: fmt.Sprintf("Domain does not match expected target %s", expected),
					Hint:    "Validate DNS records and provider proxy settings",
					Details: map[string]string{
						"cname":     strings.TrimSuffix(strings.ToLower(cname), "."),
						"addresses": strings.Join(addrs, ", "),
					},
				})
			}
		}

		tlsInfo, tlsErr := prober.TLSInfo(ctx, domain)
		if tlsErr != nil {
			checks = append(checks, doctorCheck{
				Domain:  domain,
				ID:      "tls.handshake",
				Status:  doctorStatusFail,
				Message: fmt.Sprintf("TLS handshake failed: %v", tlsErr),
				Hint:    "Check certificate provisioning and TLS termination",
			})
		} else {
			checks = append(checks, doctorCheck{
				Domain:  domain,
				ID:      "tls.handshake",
				Status:  doctorStatusOK,
				Message: "TLS certificate is valid for this host",
				Details: map[string]string{
					"not_after": tlsInfo.NotAfter.UTC().Format(time.RFC3339),
				},
			})

			status, msg := classifyTLSExpiry(tlsInfo.NotAfter, time.Now())
			checks = append(checks, doctorCheck{
				Domain:  domain,
				ID:      "tls.expiry",
				Status:  status,
				Message: msg,
			})
		}

		httpsResult, httpsErr := prober.HTTPInfo(ctx, "https://"+domain+"/")
		if httpsErr != nil {
			checks = append(checks, doctorCheck{
				Domain:  domain,
				ID:      "https.reachability",
				Status:  doctorStatusFail,
				Message: fmt.Sprintf("HTTPS request failed: %v", httpsErr),
				Hint:    "Ensure port 443 is reachable and serving this host",
			})
		} else {
			status := doctorStatusOK
			if httpsResult.StatusCode >= 500 {
				status = doctorStatusFail
			}
			checks = append(checks, doctorCheck{
				Domain:  domain,
				ID:      "https.reachability",
				Status:  status,
				Message: fmt.Sprintf("HTTPS responded with status %d", httpsResult.StatusCode),
				Details: map[string]string{
					"final_url": httpsResult.FinalURL,
				},
			})
		}

		httpResult, httpErr := prober.HTTPInfo(ctx, "http://"+domain+"/")
		if httpErr != nil {
			status := doctorStatusWarn
			if target.EnforceHTTPS {
				status = doctorStatusFail
			}
			checks = append(checks, doctorCheck{
				Domain:  domain,
				ID:      "http.redirect",
				Status:  status,
				Message: fmt.Sprintf("HTTP probe failed: %v", httpErr),
				Hint:    "Check port 80 routing and redirect rules",
			})
		} else {
			redirectStatus := evaluateHTTPRedirect(target.EnforceHTTPS, httpResult.FinalURL)
			msg := "HTTP endpoint reachable"
			if target.EnforceHTTPS {
				msg = "HTTP redirects to HTTPS"
				if redirectStatus != doctorStatusOK {
					msg = "HTTP does not redirect to HTTPS"
				}
			}
			checks = append(checks, doctorCheck{
				Domain:  domain,
				ID:      "http.redirect",
				Status:  redirectStatus,
				Message: msg,
				Details: map[string]string{
					"final_url": httpResult.FinalURL,
				},
			})
		}

		acmeResult, acmeErr := prober.HTTPInfo(ctx, "http://"+domain+"/.well-known/acme-challenge/fastfn-doctor-probe")
		if acmeErr != nil {
			checks = append(checks, doctorCheck{
				Domain:  domain,
				ID:      "acme.challenge",
				Status:  doctorStatusWarn,
				Message: fmt.Sprintf("ACME path probe failed: %v", acmeErr),
				Hint:    "Check firewall/WAF and HTTP path handling for ACME challenges",
			})
		} else {
			status := doctorStatusOK
			if acmeResult.StatusCode >= 500 {
				status = doctorStatusFail
			}
			checks = append(checks, doctorCheck{
				Domain:  domain,
				ID:      "acme.challenge",
				Status:  status,
				Message: fmt.Sprintf("ACME path responded with status %d", acmeResult.StatusCode),
			})
		}
	}

	summary := summarizeDoctorChecks(checks)
	return doctorReport{
		Scope:       "domains",
		GeneratedAt: now,
		Checks:      checks,
		Summary:     summary,
	}
}

func resolveDoctorDomainTargets(flagDomains []string, expectedTarget string, enforceHTTPS bool) ([]domainTarget, error) {
	if len(flagDomains) > 0 {
		targets := make([]domainTarget, 0, len(flagDomains))
		for _, raw := range flagDomains {
			d := normalizeDomain(raw)
			if d == "" {
				continue
			}
			targets = append(targets, domainTarget{
				Domain:         d,
				ExpectedTarget: strings.TrimSpace(expectedTarget),
				EnforceHTTPS:   enforceHTTPS,
			})
		}
		if len(targets) == 0 {
			return nil, fmt.Errorf("no valid --domain values provided")
		}
		return targets, nil
	}

	raw := viper.Get("domains")
	targets, errs := parseDomainTargets(raw)
	if len(errs) > 0 {
		return nil, fmt.Errorf("invalid domains config: %v", errs[0])
	}
	if len(targets) == 0 {
		return nil, fmt.Errorf("no domains configured. use --domain or set domains in fastfn.json")
	}

	if expectedTarget != "" {
		for i := range targets {
			targets[i].ExpectedTarget = strings.TrimSpace(expectedTarget)
		}
	}
	return targets, nil
}

func parseDomainTargets(raw any) ([]domainTarget, []error) {
	if raw == nil {
		return nil, nil
	}

	targets := make([]domainTarget, 0)
	errs := make([]error, 0)

	appendTarget := func(t domainTarget, err error) {
		if err != nil {
			errs = append(errs, err)
			return
		}
		if strings.TrimSpace(t.Domain) == "" {
			errs = append(errs, fmt.Errorf("domain cannot be empty"))
			return
		}
		targets = append(targets, t)
	}

	switch v := raw.(type) {
	case string:
		appendTarget(domainTarget{Domain: normalizeDomain(v), EnforceHTTPS: true}, nil)
	case []string:
		for _, item := range v {
			appendTarget(domainTarget{Domain: normalizeDomain(item), EnforceHTTPS: true}, nil)
		}
	case []any:
		for _, item := range v {
			t, err := parseOneDomainTarget(item)
			appendTarget(t, err)
		}
	default:
		errs = append(errs, fmt.Errorf("domains must be an array or string"))
	}

	// De-duplicate while preserving order.
	seen := map[string]bool{}
	dedup := make([]domainTarget, 0, len(targets))
	for _, t := range targets {
		k := strings.ToLower(t.Domain) + "|" + strings.ToLower(t.ExpectedTarget) + "|" + strconv.FormatBool(t.EnforceHTTPS)
		if seen[k] {
			continue
		}
		seen[k] = true
		dedup = append(dedup, t)
	}
	return dedup, errs
}

func parseOneDomainTarget(raw any) (domainTarget, error) {
	switch v := raw.(type) {
	case string:
		return domainTarget{
			Domain:       normalizeDomain(v),
			EnforceHTTPS: true,
		}, nil
	case map[string]any:
		return parseDomainTargetMap(v)
	case map[any]any:
		m := map[string]any{}
		for mk, mv := range v {
			m[fmt.Sprint(mk)] = mv
		}
		return parseDomainTargetMap(m)
	default:
		return domainTarget{}, fmt.Errorf("unsupported domain entry type %T", raw)
	}
}

func parseDomainTargetMap(m map[string]any) (domainTarget, error) {
	domain := firstMapString(m, "domain", "host", "name")
	if domain == "" {
		return domainTarget{}, fmt.Errorf("domain entry missing required field 'domain'")
	}
	expected := firstMapString(m, "expected-target", "expected_target", "expectedTarget", "target")
	enforceHTTPS := firstMapBoolDefault(m, true, "enforce-https", "enforce_https", "enforceHttps")
	return domainTarget{
		Domain:         normalizeDomain(domain),
		ExpectedTarget: normalizeDomain(expected),
		EnforceHTTPS:   enforceHTTPS,
	}, nil
}

func firstMapString(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			switch s := v.(type) {
			case string:
				if trimmed := strings.TrimSpace(s); trimmed != "" {
					return trimmed
				}
			default:
				val := strings.TrimSpace(fmt.Sprint(s))
				if val != "" && val != "<nil>" {
					return val
				}
			}
		}
	}
	return ""
}

func firstMapBoolDefault(m map[string]any, def bool, keys ...string) bool {
	for _, k := range keys {
		v, ok := m[k]
		if !ok {
			continue
		}
		switch b := v.(type) {
		case bool:
			return b
		case string:
			p, err := strconv.ParseBool(strings.TrimSpace(b))
			if err == nil {
				return p
			}
		}
	}
	return def
}

func summarizeDoctorChecks(checks []doctorCheck) doctorSummary {
	s := doctorSummary{}
	for _, c := range checks {
		switch c.Status {
		case doctorStatusOK:
			s.OK++
		case doctorStatusWarn:
			s.Warn++
		case doctorStatusFail:
			s.Fail++
		}
	}
	return s
}

func printDoctorReport(report doctorReport, asJSON bool) error {
	if asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(report)
	}

	fmt.Printf("FastFN Doctor (%s)\n", report.Scope)
	for _, check := range report.Checks {
		prefix := statusPrefix(check.Status)
		target := ""
		if check.Domain != "" {
			target = "[" + check.Domain + "] "
		}
		fmt.Printf("%s %s%s: %s\n", prefix, target, check.ID, check.Message)
		if check.Hint != "" {
			fmt.Printf("  hint: %s\n", check.Hint)
		}
		if len(check.Details) > 0 {
			keys := make([]string, 0, len(check.Details))
			for k := range check.Details {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, k := range keys {
				fmt.Printf("  %s: %s\n", k, check.Details[k])
			}
		}
	}
	fmt.Printf("Summary: OK=%d WARN=%d FAIL=%d\n", report.Summary.OK, report.Summary.Warn, report.Summary.Fail)
	return nil
}

func statusPrefix(s doctorStatus) string {
	switch s {
	case doctorStatusOK:
		return "[OK]"
	case doctorStatusWarn:
		return "[WARN]"
	case doctorStatusFail:
		return "[FAIL]"
	default:
		return "[INFO]"
	}
}

func installHintForBinary(bin string) string {
	switch bin {
	case "openresty":
		if runtime.GOOS == "darwin" {
			return "Install OpenResty (Homebrew: brew install openresty) and ensure it is in PATH"
		}
		if runtime.GOOS == "linux" {
			return "Install OpenResty and ensure it is in PATH (for example: apt install openresty, dnf install openresty, or OpenResty official repo packages)"
		}
		return "Install OpenResty and ensure it is in PATH"
	case "docker":
		switch runtime.GOOS {
		case "darwin":
			return "Install Docker Desktop (Homebrew: brew install --cask docker) and ensure docker is in PATH"
		case "linux":
			return "Install Docker Engine/CLI and ensure docker is in PATH (for example: apt install docker.io docker-compose-plugin, dnf install docker docker-compose-plugin, or snap install docker)"
		default:
			return "Install Docker CLI and daemon, then ensure docker is in PATH"
		}
	default:
		return fmt.Sprintf("Install %s or ensure it is available in PATH", bin)
	}
}

func checkExecutable(bin string, versionArgs []string, id, label string) doctorCheck {
	path, err := exec.LookPath(bin)
	if err != nil {
		return doctorCheck{
			ID:      id,
			Status:  doctorStatusWarn,
			Message: fmt.Sprintf("%s not found in PATH", label),
			Hint:    installHintForBinary(bin),
		}
	}
	cmd := exec.Command(bin, versionArgs...)
	out, err := cmd.CombinedOutput()
	version := strings.TrimSpace(string(out))
	if version == "" {
		version = "found at " + path
	}
	status := doctorStatusOK
	msg := fmt.Sprintf("%s available", label)
	if err != nil {
		status = doctorStatusWarn
		msg = fmt.Sprintf("%s found but version probe failed", label)
	}
	return doctorCheck{
		ID:      id,
		Status:  status,
		Message: msg,
		Details: map[string]string{
			"path":    path,
			"version": version,
		},
	}
}

func checkDockerDaemon() doctorCheck {
	if _, err := exec.LookPath("docker"); err != nil {
		return doctorCheck{
			ID:      "docker.daemon",
			Status:  doctorStatusWarn,
			Message: "Docker daemon check skipped (docker CLI not found)",
		}
	}
	cmd := exec.Command("docker", "info", "--format", "{{.ServerVersion}}")
	out, err := cmd.CombinedOutput()
	output := strings.TrimSpace(string(out))
	lower := strings.ToLower(output)
	if err != nil ||
		strings.Contains(lower, "permission denied") ||
		strings.Contains(lower, "cannot connect") ||
		strings.Contains(lower, "is the docker daemon running") ||
		strings.Contains(lower, "error response from daemon") {
		return doctorCheck{
			ID:      "docker.daemon",
			Status:  doctorStatusFail,
			Message: "Docker daemon is not reachable",
			Hint:    "Start Docker Desktop/daemon and verify socket permissions",
			Details: map[string]string{"error": output},
		}
	}
	if output == "" {
		output = "reachable"
	}
	return doctorCheck{
		ID:      "docker.daemon",
		Status:  doctorStatusOK,
		Message: "Docker daemon is reachable",
		Details: map[string]string{"server_version": output},
	}
}

func checkPlatform() doctorCheck {
	supported := (runtime.GOOS == "linux" || runtime.GOOS == "darwin") &&
		(runtime.GOARCH == "amd64" || runtime.GOARCH == "arm64")
	if supported {
		return doctorCheck{
			ID:      "system.platform",
			Status:  doctorStatusOK,
			Message: fmt.Sprintf("Platform supported (%s/%s)", runtime.GOOS, runtime.GOARCH),
		}
	}
	return doctorCheck{
		ID:      "system.platform",
		Status:  doctorStatusWarn,
		Message: fmt.Sprintf("Platform not in primary support matrix (%s/%s)", runtime.GOOS, runtime.GOARCH),
		Hint:    "Preferred platforms: linux/darwin with amd64/arm64",
	}
}

func checkConfigFile(applyFix bool) (doctorCheck, bool) {
	path := detectConfigPath()
	if path == "" {
		if !applyFix {
			return doctorCheck{
				ID:      "project.config",
				Status:  doctorStatusWarn,
				Message: "No fastfn.json found",
				Hint:    "Create fastfn.json to define functions-dir and optional domains",
			}, false
		}
		payload := []byte("{\n  \"functions-dir\": \".\"\n}\n")
		if err := os.WriteFile("fastfn.json", payload, 0644); err != nil {
			return doctorCheck{
				ID:      "project.config",
				Status:  doctorStatusFail,
				Message: "Failed to auto-create fastfn.json",
				Details: map[string]string{"error": err.Error()},
			}, false
		}
		return doctorCheck{
			ID:      "project.config",
			Status:  doctorStatusOK,
			Message: "fastfn.json created",
			Details: map[string]string{"path": "fastfn.json"},
		}, true
	}

	ext := strings.ToLower(filepath.Ext(path))
	if ext == ".toml" {
		return doctorCheck{
			ID:      "project.config",
			Status:  doctorStatusWarn,
			Message: fmt.Sprintf("Using fallback config file %s", path),
			Hint:    "Prefer fastfn.json to avoid format ambiguity",
		}, false
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		return doctorCheck{
			ID:      "project.config",
			Status:  doctorStatusFail,
			Message: fmt.Sprintf("Cannot read config file %s", path),
			Details: map[string]string{"error": err.Error()},
		}, false
	}
	var parsed map[string]any
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return doctorCheck{
			ID:      "project.config",
			Status:  doctorStatusFail,
			Message: fmt.Sprintf("Invalid JSON in %s", path),
			Details: map[string]string{"error": err.Error()},
		}, false
	}

	check := doctorCheck{
		ID:      "project.config",
		Status:  doctorStatusOK,
		Message: fmt.Sprintf("Config file valid: %s", path),
	}

	if rawDomains, ok := parsed["domains"]; ok {
		if _, errs := parseDomainTargets(rawDomains); len(errs) > 0 {
			check.Status = doctorStatusWarn
			check.Message = fmt.Sprintf("Config file valid, but domains block has issues: %s", errs[0].Error())
		}
	}
	return check, false
}

func detectConfigPath() string {
	if cfgFile != "" {
		if _, err := os.Stat(cfgFile); err == nil {
			return cfgFile
		}
		return ""
	}
	if _, err := os.Stat("fastfn.json"); err == nil {
		return "fastfn.json"
	}
	if _, err := os.Stat("fastfn.toml"); err == nil {
		return "fastfn.toml"
	}
	return ""
}

func checkFunctionsDir() doctorCheck {
	dir := configuredFunctionsDir()
	if dir == "" {
		dir = "."
	}
	if _, err := os.Stat(dir); err != nil {
		return doctorCheck{
			ID:      "project.functions_dir",
			Status:  doctorStatusFail,
			Message: fmt.Sprintf("functions-dir not found: %s", dir),
			Hint:    "Fix fastfn.json functions-dir or pass an explicit directory to fastfn dev/run",
		}
	}
	return doctorCheck{
		ID:      "project.functions_dir",
		Status:  doctorStatusOK,
		Message: fmt.Sprintf("functions-dir exists: %s", dir),
	}
}

func checkPortAvailability() doctorCheck {
	port := strings.TrimSpace(os.Getenv("FN_HOST_PORT"))
	if port == "" {
		port = "8080"
	}
	n, err := strconv.Atoi(port)
	if err != nil || n < 1 || n > 65535 {
		return doctorCheck{
			ID:      "project.port",
			Status:  doctorStatusFail,
			Message: fmt.Sprintf("Invalid FN_HOST_PORT value: %q", port),
			Hint:    "Use a valid TCP port between 1 and 65535",
		}
	}
	addr := net.JoinHostPort("127.0.0.1", port)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return doctorCheck{
			ID:      "project.port",
			Status:  doctorStatusWarn,
			Message: fmt.Sprintf("Port %s is already in use", port),
			Hint:    "Set FN_HOST_PORT to a free port before running fastfn dev/run",
		}
	}
	_ = ln.Close()
	return doctorCheck{
		ID:      "project.port",
		Status:  doctorStatusOK,
		Message: fmt.Sprintf("Port %s is available", port),
	}
}

func normalizeDomain(raw string) string {
	s := strings.TrimSpace(strings.ToLower(raw))
	return strings.TrimSuffix(s, ".")
}

func isValidDomainName(domain string) bool {
	if domain == "" || len(domain) > 253 {
		return false
	}
	if strings.Contains(domain, "*") || strings.Contains(domain, "_") {
		return false
	}
	parts := strings.Split(domain, ".")
	if len(parts) < 2 {
		return false
	}
	for _, part := range parts {
		if part == "" || len(part) > 63 {
			return false
		}
		if part[0] == '-' || part[len(part)-1] == '-' {
			return false
		}
		for _, r := range part {
			isLetter := r >= 'a' && r <= 'z'
			isDigit := r >= '0' && r <= '9'
			if !isLetter && !isDigit && r != '-' {
				return false
			}
		}
	}
	return true
}

func matchesExpectedTarget(expected string, addrs []string, cname string) bool {
	normalizedExpected := normalizeDomain(expected)
	if normalizedExpected == "" {
		return false
	}
	if ip := net.ParseIP(normalizedExpected); ip != nil {
		for _, addr := range addrs {
			if parsed := net.ParseIP(strings.TrimSpace(addr)); parsed != nil && parsed.Equal(ip) {
				return true
			}
		}
		return false
	}
	return normalizeDomain(cname) == normalizedExpected
}

func classifyTLSExpiry(notAfter time.Time, now time.Time) (doctorStatus, string) {
	days := int(notAfter.Sub(now).Hours() / 24)
	switch {
	case days < 0:
		return doctorStatusFail, fmt.Sprintf("TLS certificate expired %d day(s) ago", -days)
	case days <= 14:
		return doctorStatusWarn, fmt.Sprintf("TLS certificate expires soon (%d day(s))", days)
	default:
		return doctorStatusOK, fmt.Sprintf("TLS certificate expires in %d day(s)", days)
	}
}

func evaluateHTTPRedirect(enforceHTTPS bool, finalURL string) doctorStatus {
	isHTTPS := strings.HasPrefix(strings.ToLower(strings.TrimSpace(finalURL)), "https://")
	if enforceHTTPS {
		if isHTTPS {
			return doctorStatusOK
		}
		return doctorStatusWarn
	}
	return doctorStatusOK
}
