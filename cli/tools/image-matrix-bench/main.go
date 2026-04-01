package main

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"math"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type repoRef struct {
	URL      string
	Commit   string
	LocalDir string
	Subdir   string
}

type workloadSpec struct {
	Name              string
	DockerfilePath    string
	DockerfileAppend  string
	DockerfileContent string
	Image             string
	Port              int
	Routes            []string
	Env               map[string]string
	Files             map[string]string
	HealthPath        string
	HealthType        string
	Command           []string
	VolumeName        string
	VolumeTarget      string
}

type verifySpec struct {
	Path             string
	ExpectContains   string
	ExpectStatusCode int
}

type matrixCase struct {
	Name        string
	Description string
	Repo        *repoRef
	App         workloadSpec
	Services    []workloadSpec
	Verify      verifySpec
	Notes       []string
}

type preparedCase struct {
	Case       matrixCase
	ProjectDir string
	AppDir     string
	RepoRoot   string
}

type workloadPIDSnapshot struct {
	Kind string `json:"kind"`
	Name string `json:"name"`
	PID  int    `json:"firecracker_pid"`
}

type traceMetric struct {
	BuildOrPullMS int64 `json:"build_or_pull_ms"`
	BundleMS      int64 `json:"bundle_ms"`
}

type caseResult struct {
	Name             string                `json:"name"`
	Description      string                `json:"description,omitempty"`
	RepoURL          string                `json:"repo_url,omitempty"`
	RepoCommit       string                `json:"repo_commit,omitempty"`
	RepoSubdir       string                `json:"repo_subdir,omitempty"`
	SourceImage      string                `json:"source_image,omitempty"`
	ProjectDir       string                `json:"project_dir"`
	AppDir           string                `json:"app_dir"`
	LogPath          string                `json:"log_path"`
	Endpoint         string                `json:"endpoint"`
	BuildOrPullMS    int64                 `json:"build_or_pull_ms"`
	BundleMS         int64                 `json:"bundle_ms"`
	PrewarmReadyMS   int64                 `json:"prewarm_ready_ms"`
	FirstOKMS        int64                 `json:"first_ok_ms"`
	HotRequests      int                   `json:"hot_requests"`
	HotP50MS         float64               `json:"hot_p50_ms"`
	HotP95MS         float64               `json:"hot_p95_ms"`
	HotP99MS         float64               `json:"hot_p99_ms"`
	SameFirecracker  bool                  `json:"same_firecracker_pid"`
	PIDsBefore       []workloadPIDSnapshot `json:"pids_before,omitempty"`
	PIDsAfter        []workloadPIDSnapshot `json:"pids_after,omitempty"`
	VerifyStatusCode int                   `json:"verify_status_code"`
	VerifySnippet    string                `json:"verify_snippet,omitempty"`
	Error            string                `json:"error,omitempty"`
	Notes            []string              `json:"notes,omitempty"`
}

type benchConfig struct {
	Workspace         string
	ResultsDir        string
	SmokeDir          string
	FastFNBinary      string
	GuestInitBinary   string
	KernelPath        string
	FirecrackerBinary string
	HostBasePort      int
	Requests          int
	ReadyTimeout      time.Duration
}

type healthSnapshot struct {
	AppPIDs     []workloadPIDSnapshot
	ServicePIDs []workloadPIDSnapshot
	AllHealthy  bool
}

func main() {
	var (
		caseFilter        = flag.String("case", "all", "case name, comma-separated names, or all")
		workspace         = flag.String("workspace", "/tmp/fastfn-image-matrix", "working directory for clones, generated projects, and logs")
		smokeDir          = flag.String("smoke-dir", "/home/misael/Desktop/fastfn-firecracker-smoke", "desktop smoke folder for markdown/json/csv outputs")
		kernelPath        = flag.String("kernel", "/home/misael/Desktop/fastfn-firecracker-smoke/tools/vmlinux.bin", "Firecracker kernel path")
		firecrackerBinary = flag.String("firecracker-bin", "/home/misael/Desktop/fastfn-firecracker-smoke/tools/firecracker-v1.15.0-x86_64", "Firecracker binary path")
		hostBasePort      = flag.Int("host-base-port", 18200, "starting public port to probe for benchmark runs")
		requests          = flag.Int("requests", 50, "hot request count per case")
		readyTimeout      = flag.Duration("ready-timeout", 12*time.Minute, "maximum time to wait for a case to become ready")
		rebuildBinary     = flag.Bool("rebuild-binary", true, "rebuild FastFN and guest-init before running")
	)
	flag.Parse()

	selected, err := filterCases(defaultMatrixCases(), *caseFilter)
	if err != nil {
		fmt.Fprintf(os.Stderr, "filter cases: %v\n", err)
		os.Exit(1)
	}

	cfg := benchConfig{
		Workspace:         *workspace,
		ResultsDir:        filepath.Join(*workspace, "results"),
		SmokeDir:          *smokeDir,
		FastFNBinary:      filepath.Join(*workspace, "bin", "fastfn-linux-amd64"),
		GuestInitBinary:   filepath.Join(*workspace, "bin", "fastfn-guest-init-v1-amd64"),
		KernelPath:        *kernelPath,
		FirecrackerBinary: *firecrackerBinary,
		HostBasePort:      *hostBasePort,
		Requests:          *requests,
		ReadyTimeout:      *readyTimeout,
	}
	if err := ensureDir(cfg.ResultsDir); err != nil {
		fmt.Fprintf(os.Stderr, "create results dir: %v\n", err)
		os.Exit(1)
	}
	if err := ensureDir(cfg.SmokeDir); err != nil {
		fmt.Fprintf(os.Stderr, "create smoke dir: %v\n", err)
		os.Exit(1)
	}

	if *rebuildBinary {
		if err := rebuildBenchBinaries(cfg); err != nil {
			fmt.Fprintf(os.Stderr, "rebuild bench binaries: %v\n", err)
			os.Exit(1)
		}
	}

	prepared := make([]preparedCase, 0, len(selected))
	for _, tc := range selected {
		pc, err := prepareCase(cfg, tc)
		if err != nil {
			fmt.Fprintf(os.Stderr, "prepare %s: %v\n", tc.Name, err)
			os.Exit(1)
		}
		prepared = append(prepared, pc)
	}

	results := make([]caseResult, 0, len(prepared))
	failed := false
	for idx, pc := range prepared {
		fmt.Fprintf(os.Stderr, "==> %s\n", pc.Case.Name)
		result := runCase(cfg, pc, idx)
		if result.Error != "" {
			failed = true
			fmt.Fprintf(os.Stderr, "    failed: %s\n", result.Error)
		}
		results = append(results, result)
	}

	if err := writeOutputs(cfg, selected, results); err != nil {
		fmt.Fprintf(os.Stderr, "write outputs: %v\n", err)
		os.Exit(1)
	}

	for _, result := range results {
		status := "ok"
		if result.Error != "" {
			status = "failed"
		}
		fmt.Printf("%s,%s,%d,%d,%.2f,%.2f,%.2f,%t\n",
			result.Name,
			status,
			result.BuildOrPullMS,
			result.FirstOKMS,
			result.HotP50MS,
			result.HotP95MS,
			result.HotP99MS,
			result.SameFirecracker,
		)
	}

	if failed {
		os.Exit(1)
	}
}

func filterCases(all []matrixCase, raw string) ([]matrixCase, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" || strings.EqualFold(raw, "all") {
		return all, nil
	}
	lookup := map[string]matrixCase{}
	for _, tc := range all {
		lookup[tc.Name] = tc
	}
	var out []matrixCase
	for _, token := range strings.Split(raw, ",") {
		name := strings.TrimSpace(token)
		tc, ok := lookup[name]
		if !ok {
			return nil, fmt.Errorf("unknown case %q", name)
		}
		out = append(out, tc)
	}
	return out, nil
}

func rebuildBenchBinaries(cfg benchConfig) error {
	if err := ensureDir(filepath.Dir(cfg.FastFNBinary)); err != nil {
		return err
	}
	cliDir := filepath.Join(repoRoot(), "cli")
	if err := runCmd(cliDir, nil, "go", "build", "-trimpath", "-ldflags=-s -w", "-o", cfg.FastFNBinary, "."); err != nil {
		return fmt.Errorf("build fastfn: %w", err)
	}
	env := map[string]string{"CGO_ENABLED": "0"}
	if err := runCmd(cliDir, env, "go", "build", "-trimpath", "-ldflags=-s -w", "-o", cfg.GuestInitBinary, "./internal/firecrackerguest"); err != nil {
		return fmt.Errorf("build guest init: %w", err)
	}
	return nil
}

func prepareCase(cfg benchConfig, tc matrixCase) (preparedCase, error) {
	projectDir := filepath.Join(cfg.Workspace, "projects", tc.Name)
	appDir := filepath.Join(projectDir, "functions", "app")
	if err := os.RemoveAll(projectDir); err != nil {
		return preparedCase{}, fmt.Errorf("reset project dir: %w", err)
	}
	if err := ensureDir(appDir); err != nil {
		return preparedCase{}, err
	}

	var repoRootDir string
	if tc.Repo != nil {
		repoDir, err := ensureRepo(cfg, *tc.Repo)
		if err != nil {
			return preparedCase{}, err
		}
		repoRootDir = repoDir
		sourceDir := repoDir
		if strings.TrimSpace(tc.Repo.Subdir) != "" {
			sourceDir = filepath.Join(repoDir, tc.Repo.Subdir)
		}
		if err := copyDir(sourceDir, appDir); err != nil {
			return preparedCase{}, fmt.Errorf("copy app source: %w", err)
		}
	}

	for relPath, content := range tc.App.Files {
		if err := writeFile(filepath.Join(appDir, relPath), content); err != nil {
			return preparedCase{}, err
		}
	}
	if err := materializeDockerfile(appDir, tc.App); err != nil {
		return preparedCase{}, err
	}
	if err := writeJSON(filepath.Join(projectDir, "fastfn.json"), map[string]any{
		"functions-dir": "functions",
	}); err != nil {
		return preparedCase{}, err
	}
	if err := writeJSON(filepath.Join(appDir, "fn.config.json"), buildFolderConfig(projectDir, tc)); err != nil {
		return preparedCase{}, err
	}
	return preparedCase{
		Case:       tc,
		ProjectDir: projectDir,
		AppDir:     appDir,
		RepoRoot:   repoRootDir,
	}, nil
}

func materializeDockerfile(appDir string, app workloadSpec) error {
	if strings.TrimSpace(app.Image) != "" {
		return nil
	}
	targetPath := filepath.Join(appDir, "Dockerfile.fastfn")
	switch {
	case strings.TrimSpace(app.DockerfileContent) != "":
		return writeFile(targetPath, app.DockerfileContent)
	case strings.TrimSpace(app.DockerfileAppend) != "":
		basePath := filepath.Join(appDir, app.DockerfilePath)
		data, err := os.ReadFile(basePath)
		if err != nil {
			return fmt.Errorf("read dockerfile %s: %w", basePath, err)
		}
		sanitized := sanitizeDockerfile(string(data))
		return writeFile(targetPath, strings.TrimRight(sanitized, "\n")+"\n\n"+strings.TrimSpace(app.DockerfileAppend)+"\n")
	case strings.TrimSpace(app.DockerfilePath) != "":
		sourcePath := filepath.Join(appDir, app.DockerfilePath)
		data, err := os.ReadFile(sourcePath)
		if err != nil {
			return fmt.Errorf("read dockerfile %s: %w", sourcePath, err)
		}
		return writeFile(targetPath, sanitizeDockerfile(string(data)))
	default:
		return fmt.Errorf("app %q is missing image or dockerfile material", app.Name)
	}
}

var dockerMountPattern = regexp.MustCompile(`--mount=[^ ]+\s*`)
var dockerPlatformPattern = regexp.MustCompile(`\s+--platform=[^ ]+`)

func sanitizeDockerfile(raw string) string {
	lines := strings.Split(raw, "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), "# syntax=") {
			continue
		}
		line = dockerMountPattern.ReplaceAllString(line, "")
		if strings.HasPrefix(strings.TrimSpace(line), "FROM ") {
			line = dockerPlatformPattern.ReplaceAllString(line, "")
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

func buildFolderConfig(projectDir string, tc matrixCase) map[string]any {
	appCfg := map[string]any{
		"port": tc.App.Port,
	}
	if strings.TrimSpace(tc.App.Image) != "" {
		appCfg["image"] = tc.App.Image
	} else {
		appCfg["dockerfile"] = "./Dockerfile.fastfn"
		appCfg["context"] = "."
	}
	if len(tc.App.Routes) > 0 {
		appCfg["routes"] = tc.App.Routes
	}
	if len(tc.App.Env) > 0 {
		appCfg["env"] = tc.App.Env
	}
	if len(tc.App.Command) > 0 {
		appCfg["command"] = tc.App.Command
	}
	if strings.TrimSpace(tc.App.HealthPath) != "" {
		healthType := tc.App.HealthType
		if healthType == "" {
			healthType = "http"
		}
		appCfg["healthcheck"] = map[string]any{
			"type":        healthType,
			"path":        tc.App.HealthPath,
			"interval_ms": 1000,
			"timeout_ms":  4000,
		}
	}

	root := map[string]any{"app": appCfg}
	if len(tc.Services) == 0 {
		return root
	}
	services := map[string]any{}
	for _, svc := range tc.Services {
		entry := map[string]any{
			"image": svc.Image,
			"port":  svc.Port,
		}
		if len(svc.Env) > 0 {
			entry["env"] = svc.Env
		}
		if len(svc.Command) > 0 {
			entry["command"] = svc.Command
		}
		if svc.VolumeName != "" && svc.VolumeTarget != "" {
			entry["volume"] = map[string]any{
				"name":   svc.VolumeName,
				"target": svc.VolumeTarget,
			}
		}
		services[svc.Name] = entry
	}
	root["services"] = services
	return root
}

func runCase(cfg benchConfig, pc preparedCase, index int) caseResult {
	result := caseResult{
		Name:        pc.Case.Name,
		Description: pc.Case.Description,
		ProjectDir:  pc.ProjectDir,
		AppDir:      pc.AppDir,
		Endpoint:    pc.Case.Verify.Path,
		HotRequests: cfg.Requests,
		Notes:       append([]string(nil), pc.Case.Notes...),
	}
	if pc.Case.Repo != nil {
		result.RepoURL = pc.Case.Repo.URL
		result.RepoCommit = pc.Case.Repo.Commit
		result.RepoSubdir = pc.Case.Repo.Subdir
	}
	if pc.Case.App.Image != "" {
		result.SourceImage = pc.Case.App.Image
	}

	_ = os.RemoveAll(filepath.Join(pc.ProjectDir, ".fastfn"))
	logPath := filepath.Join(cfg.ResultsDir, pc.Case.Name+".log")
	result.LogPath = logPath
	logFile, err := os.Create(logPath)
	if err != nil {
		result.Error = err.Error()
		return result
	}
	defer logFile.Close()

	hostPort, err := pickAvailablePort(cfg.HostBasePort + index*10)
	if err != nil {
		result.Error = err.Error()
		return result
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cmd := exec.CommandContext(ctx, cfg.FastFNBinary, "run", "--native", pc.ProjectDir)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	cmd.Env = append(os.Environ(),
		"FN_HOT_RELOAD=0",
		"FN_BENCHMARK_TIMINGS=1",
		fmt.Sprintf("FN_HOST_PORT=%d", hostPort),
		fmt.Sprintf("FN_FIRECRACKER_GUEST_INIT=%s", cfg.GuestInitBinary),
		fmt.Sprintf("FN_FIRECRACKER_KERNEL=%s", cfg.KernelPath),
		fmt.Sprintf("FN_FIRECRACKER_BIN=%s", cfg.FirecrackerBinary),
	)
	if err := cmd.Start(); err != nil {
		result.Error = err.Error()
		return result
	}
	done := make(chan error, 1)
	go func() {
		done <- cmd.Wait()
	}()
	defer stopProcess(cmd, done)

	started := time.Now()
	baseURL := fmt.Sprintf("http://127.0.0.1:%d", hostPort)
	verifyURL := baseURL + pc.Case.Verify.Path

	prewarmMS, firstOKMS, statusCode, snippet, err := waitForReadiness(started, done, baseURL, verifyURL, pc.Case, cfg.ReadyTimeout)
	result.PrewarmReadyMS = prewarmMS
	result.FirstOKMS = firstOKMS
	result.VerifyStatusCode = statusCode
	result.VerifySnippet = snippet
	if err != nil {
		result.Error = err.Error()
		trace, _ := parseTraceMetrics(logPath)
		result.BuildOrPullMS = trace.BuildOrPullMS
		result.BundleMS = trace.BundleMS
		return result
	}

	before, err := fetchHealthSnapshot(baseURL, pc.Case)
	if err != nil {
		result.Error = fmt.Sprintf("fetch health before hot loop: %v", err)
		return result
	}
	result.PIDsBefore = append(append([]workloadPIDSnapshot(nil), before.AppPIDs...), before.ServicePIDs...)

	samples, hotErr := measureHot(baseURL, pc.Case.Verify, cfg.Requests)
	if hotErr != nil {
		result.Error = hotErr.Error()
		return result
	}
	result.HotP50MS = percentileMS(samples, 50)
	result.HotP95MS = percentileMS(samples, 95)
	result.HotP99MS = percentileMS(samples, 99)

	after, err := fetchHealthSnapshot(baseURL, pc.Case)
	if err != nil {
		result.Error = fmt.Sprintf("fetch health after hot loop: %v", err)
		return result
	}
	result.PIDsAfter = append(append([]workloadPIDSnapshot(nil), after.AppPIDs...), after.ServicePIDs...)
	result.SameFirecracker = samePIDSnapshots(result.PIDsBefore, result.PIDsAfter)

	trace, err := parseTraceMetrics(logPath)
	if err != nil {
		result.Error = fmt.Sprintf("parse trace metrics: %v", err)
		return result
	}
	result.BuildOrPullMS = trace.BuildOrPullMS
	result.BundleMS = trace.BundleMS
	return result
}

func waitForReadiness(started time.Time, done <-chan error, baseURL, verifyURL string, tc matrixCase, readyTimeout time.Duration) (int64, int64, int, string, error) {
	if readyTimeout <= 0 {
		readyTimeout = 12 * time.Minute
	}
	deadline := time.Now().Add(readyTimeout)
	var prewarmReadyAt time.Time
	var lastStatus int
	var lastBody string
	for time.Now().Before(deadline) {
		select {
		case err := <-done:
			return 0, 0, lastStatus, lastBody, fmt.Errorf("fastfn exited before ready: %v", err)
		default:
		}

		if prewarmReadyAt.IsZero() {
			if snapshot, err := fetchHealthSnapshot(baseURL, tc); err == nil && snapshot.AllHealthy {
				prewarmReadyAt = time.Now()
			}
		}

		status, body, err := fetchURL(verifyURL, "", 10*time.Second)
		if err == nil {
			lastStatus = status
			lastBody = trimSnippet(body)
			expectedStatus := tc.Verify.ExpectStatusCode
			if expectedStatus == 0 {
				expectedStatus = 200
			}
			if status == expectedStatus && (tc.Verify.ExpectContains == "" || strings.Contains(body, tc.Verify.ExpectContains)) {
				first := time.Now()
				if prewarmReadyAt.IsZero() {
					prewarmReadyAt = first
				}
				return prewarmReadyAt.Sub(started).Milliseconds(), first.Sub(started).Milliseconds(), status, trimSnippet(body), nil
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	if prewarmReadyAt.IsZero() {
		return 0, 0, lastStatus, lastBody, fmt.Errorf("timeout waiting for %s", verifyURL)
	}
	return prewarmReadyAt.Sub(started).Milliseconds(), 0, lastStatus, lastBody, fmt.Errorf("timeout waiting for %s", verifyURL)
}

func fetchHealthSnapshot(baseURL string, tc matrixCase) (healthSnapshot, error) {
	status, body, err := fetchURL(baseURL+"/_fn/health", "", 10*time.Second)
	if err != nil {
		return healthSnapshot{}, err
	}
	if status != 200 {
		return healthSnapshot{}, fmt.Errorf("unexpected health status %d", status)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(body), &payload); err != nil {
		return healthSnapshot{}, err
	}

	snapshot := healthSnapshot{AllHealthy: true}
	apps := toStringAnyMap(payload["apps"])
	appName := tc.App.Name
	if appName == "" {
		appName = "app"
	}
	appState := toStringAnyMap(apps[appName])
	if len(appState) == 0 {
		snapshot.AllHealthy = false
	} else {
		if !workloadHealthUp(appState) {
			snapshot.AllHealthy = false
		}
		snapshot.AppPIDs = append(snapshot.AppPIDs, workloadPIDSnapshot{
			Kind: "app",
			Name: appName,
			PID:  toInt(appState["firecracker_pid"]),
		})
	}

	serviceStates := toStringAnyMap(payload["services"])
	for _, svc := range tc.Services {
		entry := toStringAnyMap(serviceStates[svc.Name])
		if len(entry) == 0 {
			snapshot.AllHealthy = false
			continue
		}
		if !workloadHealthUp(entry) {
			snapshot.AllHealthy = false
		}
		snapshot.ServicePIDs = append(snapshot.ServicePIDs, workloadPIDSnapshot{
			Kind: "service",
			Name: svc.Name,
			PID:  toInt(entry["firecracker_pid"]),
		})
	}

	sort.Slice(snapshot.AppPIDs, func(i, j int) bool { return snapshot.AppPIDs[i].Name < snapshot.AppPIDs[j].Name })
	sort.Slice(snapshot.ServicePIDs, func(i, j int) bool { return snapshot.ServicePIDs[i].Name < snapshot.ServicePIDs[j].Name })
	return snapshot, nil
}

func measureHot(baseURL string, verify verifySpec, requests int) ([]time.Duration, error) {
	if requests < 1 {
		requests = 1
	}
	expectedStatus := verify.ExpectStatusCode
	if expectedStatus == 0 {
		expectedStatus = 200
	}
	url := baseURL + verify.Path
	samples := make([]time.Duration, 0, requests)
	for i := 0; i < requests; i++ {
		started := time.Now()
		status, body, err := fetchURL(url, "", 10*time.Second)
		if err != nil {
			return nil, err
		}
		if status != expectedStatus {
			return nil, fmt.Errorf("hot request %d status = %d", i+1, status)
		}
		if verify.ExpectContains != "" && !strings.Contains(body, verify.ExpectContains) {
			return nil, fmt.Errorf("hot request %d body mismatch", i+1)
		}
		samples = append(samples, time.Since(started))
	}
	return samples, nil
}

func percentileMS(samples []time.Duration, percentile float64) float64 {
	if len(samples) == 0 {
		return 0
	}
	values := make([]float64, 0, len(samples))
	for _, sample := range samples {
		values = append(values, float64(sample.Microseconds())/1000)
	}
	sort.Float64s(values)
	if len(values) == 1 {
		return roundMS(values[0])
	}
	rank := (percentile / 100) * float64(len(values)-1)
	lower := int(math.Floor(rank))
	upper := int(math.Ceil(rank))
	if lower == upper {
		return roundMS(values[lower])
	}
	weight := rank - float64(lower)
	value := values[lower] + (values[upper]-values[lower])*weight
	return roundMS(value)
}

func parseTraceMetrics(logPath string) (traceMetric, error) {
	data, err := os.ReadFile(logPath)
	if err != nil {
		return traceMetric{}, err
	}
	type traceState struct {
		ociReadyMS    int64
		bundleReadyMS int64
	}
	states := map[string]*traceState{}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "fastfn benchmark ") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 5 {
			continue
		}
		event := fields[2]
		kind := ""
		name := ""
		elapsedMS := int64(0)
		for _, field := range fields[3:] {
			parts := strings.SplitN(field, "=", 2)
			if len(parts) != 2 {
				continue
			}
			switch parts[0] {
			case "kind":
				kind = parts[1]
			case "name":
				name = parts[1]
			case "elapsed_ms":
				elapsedMS, _ = strconv.ParseInt(parts[1], 10, 64)
			}
		}
		if kind == "" || name == "" {
			continue
		}
		key := kind + ":" + name
		state := states[key]
		if state == nil {
			state = &traceState{}
			states[key] = state
		}
		switch event {
		case "oci_ready":
			state.ociReadyMS = elapsedMS
		case "bundle_ready":
			state.bundleReadyMS = elapsedMS
		}
	}

	var metric traceMetric
	for _, state := range states {
		metric.BuildOrPullMS += state.ociReadyMS
		if state.bundleReadyMS > state.ociReadyMS {
			metric.BundleMS += state.bundleReadyMS - state.ociReadyMS
		}
	}
	return metric, nil
}

func writeOutputs(cfg benchConfig, cases []matrixCase, results []caseResult) error {
	day := time.Now().Format("20060102")
	jsonPath := filepath.Join(cfg.SmokeDir, "bench-"+day+".json")
	csvPath := filepath.Join(cfg.SmokeDir, "bench-"+day+".csv")
	mdPath := filepath.Join(cfg.SmokeDir, "REPO_BENCHMARKS.md")

	payload, err := json.MarshalIndent(results, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(jsonPath, append(payload, '\n'), 0o644); err != nil {
		return err
	}
	if err := writeCSV(csvPath, results); err != nil {
		return err
	}
	if err := os.WriteFile(mdPath, []byte(renderMarkdown(cfg, cases, results, jsonPath, csvPath)), 0o644); err != nil {
		return err
	}
	return nil
}

func writeCSV(path string, results []caseResult) error {
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer file.Close()
	writer := csv.NewWriter(file)
	defer writer.Flush()
	if err := writer.Write([]string{
		"name",
		"repo_url",
		"repo_commit",
		"repo_subdir",
		"source_image",
		"project_dir",
		"endpoint",
		"build_or_pull_ms",
		"bundle_ms",
		"prewarm_ready_ms",
		"first_ok_ms",
		"hot_requests",
		"hot_p50_ms",
		"hot_p95_ms",
		"hot_p99_ms",
		"same_firecracker_pid",
		"error",
	}); err != nil {
		return err
	}
	for _, result := range results {
		record := []string{
			result.Name,
			result.RepoURL,
			result.RepoCommit,
			result.RepoSubdir,
			result.SourceImage,
			result.ProjectDir,
			result.Endpoint,
			strconv.FormatInt(result.BuildOrPullMS, 10),
			strconv.FormatInt(result.BundleMS, 10),
			strconv.FormatInt(result.PrewarmReadyMS, 10),
			strconv.FormatInt(result.FirstOKMS, 10),
			strconv.Itoa(result.HotRequests),
			fmt.Sprintf("%.2f", result.HotP50MS),
			fmt.Sprintf("%.2f", result.HotP95MS),
			fmt.Sprintf("%.2f", result.HotP99MS),
			strconv.FormatBool(result.SameFirecracker),
			result.Error,
		}
		if err := writer.Write(record); err != nil {
			return err
		}
	}
	return writer.Error()
}

func renderMarkdown(cfg benchConfig, cases []matrixCase, results []caseResult, jsonPath, csvPath string) string {
	lookup := map[string]caseResult{}
	for _, result := range results {
		lookup[result.Name] = result
	}
	var builder strings.Builder
	builder.WriteString("# FastFN Firecracker Repo Benchmarks\n\n")
	builder.WriteString("Date: " + time.Now().Format("2006-01-02") + "\n\n")
	builder.WriteString("This document captures the reproducible 20-case benchmark matrix for FastFN image workloads on Firecracker.\n\n")
	builder.WriteString("## Paths\n\n")
	builder.WriteString("- FastFN repo: `" + repoRoot() + "`\n")
	builder.WriteString("- Benchmark workspace: `" + cfg.Workspace + "`\n")
	builder.WriteString("- Logs: `" + cfg.ResultsDir + "`\n")
	builder.WriteString("- Linux FastFN binary: `" + cfg.FastFNBinary + "`\n")
	builder.WriteString("- Linux guest init: `" + cfg.GuestInitBinary + "`\n")
	builder.WriteString("- Kernel: `" + cfg.KernelPath + "`\n")
	builder.WriteString("- Firecracker: `" + cfg.FirecrackerBinary + "`\n")
	builder.WriteString("- JSON results: `" + jsonPath + "`\n")
	builder.WriteString("- CSV results: `" + csvPath + "`\n\n")

	builder.WriteString("## Summary\n\n")
	builder.WriteString("| Case | Source | Build/Pull | Bundle | Prewarm Ready | First OK | Hot p50 | Hot p95 | Hot p99 | Same PID |\n")
	builder.WriteString("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |\n")
	for _, tc := range cases {
		result := lookup[tc.Name]
		source := sourceLabel(tc)
		if result.Error != "" {
			builder.WriteString(fmt.Sprintf("| `%s` | %s | n/a | n/a | n/a | n/a | n/a | n/a | n/a | failed |\n", tc.Name, source))
			continue
		}
		builder.WriteString(fmt.Sprintf(
			"| `%s` | %s | `%dms` | `%dms` | `%dms` | `%dms` | `%.2fms` | `%.2fms` | `%.2fms` | `%t` |\n",
			tc.Name,
			source,
			result.BuildOrPullMS,
			result.BundleMS,
			result.PrewarmReadyMS,
			result.FirstOKMS,
			result.HotP50MS,
			result.HotP95MS,
			result.HotP99MS,
			result.SameFirecracker,
		))
	}

	builder.WriteString("\n## Cases\n\n")
	for _, tc := range cases {
		result := lookup[tc.Name]
		builder.WriteString("### `" + tc.Name + "`\n\n")
		builder.WriteString("- Description: " + tc.Description + "\n")
		if tc.Repo != nil {
			builder.WriteString("- Repo: `" + tc.Repo.URL + "`\n")
			builder.WriteString("- Commit: `" + shortRef(tc.Repo.Commit) + "`\n")
			if tc.Repo.Subdir != "" {
				builder.WriteString("- Subdir: `" + tc.Repo.Subdir + "`\n")
			}
		}
		if tc.App.Image != "" {
			builder.WriteString("- Image: `" + tc.App.Image + "`\n")
		}
		builder.WriteString("- Project dir: `" + result.ProjectDir + "`\n")
		builder.WriteString("- Verify endpoint: `" + result.Endpoint + "`\n")
		if result.Error == "" {
			builder.WriteString(fmt.Sprintf("- Build/Pull: `%dms`\n", result.BuildOrPullMS))
			builder.WriteString(fmt.Sprintf("- Bundle: `%dms`\n", result.BundleMS))
			builder.WriteString(fmt.Sprintf("- Prewarm ready: `%dms`\n", result.PrewarmReadyMS))
			builder.WriteString(fmt.Sprintf("- First OK: `%dms`\n", result.FirstOKMS))
			builder.WriteString(fmt.Sprintf("- Hot steady-state: `p50=%.2fms`, `p95=%.2fms`, `p99=%.2fms`\n", result.HotP50MS, result.HotP95MS, result.HotP99MS))
			builder.WriteString(fmt.Sprintf("- Same Firecracker PID before/after hot loop: `%t`\n", result.SameFirecracker))
		} else {
			builder.WriteString("- Error: `" + result.Error + "`\n")
		}
		builder.WriteString("- Log: `" + result.LogPath + "`\n")
		for _, note := range tc.Notes {
			builder.WriteString("- Note: " + note + "\n")
		}
		builder.WriteString("\n")
	}

	builder.WriteString("## Rebuild and Run\n\n")
	builder.WriteString("Rebuild the benchmark binaries:\n\n")
	builder.WriteString("```bash\n")
	builder.WriteString("cd " + filepath.Join(repoRoot(), "cli") + "\n")
	builder.WriteString("go build -trimpath -ldflags='-s -w' -o " + cfg.FastFNBinary + " .\n")
	builder.WriteString("CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o " + cfg.GuestInitBinary + " ./internal/firecrackerguest\n")
	builder.WriteString("```\n\n")
	builder.WriteString("Run the whole matrix:\n\n")
	builder.WriteString("```bash\n")
	builder.WriteString("cd " + filepath.Join(repoRoot(), "cli") + "\n")
	builder.WriteString("go run ./tools/image-matrix-bench\n")
	builder.WriteString("```\n\n")
	builder.WriteString("Run a single case:\n\n")
	builder.WriteString("```bash\n")
	builder.WriteString("cd " + filepath.Join(repoRoot(), "cli") + "\n")
	builder.WriteString("go run ./tools/image-matrix-bench --case flask-compose\n")
	builder.WriteString("```\n\n")
	builder.WriteString("## Firewall Example\n\n")
	builder.WriteString("Use `access.allow_hosts` and `access.allow_cidrs` on the public HTTP port you want to protect:\n\n")
	builder.WriteString("```json\n")
	builder.WriteString("{\n")
	builder.WriteString("  \"app\": {\n")
	builder.WriteString("    \"dockerfile\": \"./Dockerfile.fastfn\",\n")
	builder.WriteString("    \"context\": \".\",\n")
	builder.WriteString("    \"port\": 8000,\n")
	builder.WriteString("    \"routes\": [\"/*\"],\n")
	builder.WriteString("    \"access\": {\n")
	builder.WriteString("      \"allow_hosts\": [\"app.example.com\", \"*.bench.example.com\"],\n")
	builder.WriteString("      \"allow_cidrs\": [\"203.0.113.0/24\", \"2001:db8::/32\"]\n")
	builder.WriteString("    }\n")
	builder.WriteString("  }\n")
	builder.WriteString("}\n")
	builder.WriteString("```\n\n")
	builder.WriteString("HTTP requests must satisfy both conditions when both lists are present. TCP public ports only support `allow_cidrs`.\n")
	return builder.String()
}

func sourceLabel(tc matrixCase) string {
	if tc.Repo != nil {
		if tc.Repo.Subdir != "" {
			return "`repo:" + filepath.Base(tc.Repo.Subdir) + "`"
		}
		return "`repo`"
	}
	if tc.App.Image != "" {
		return "`registry`"
	}
	return "`generated`"
}

func shortRef(raw string) string {
	raw = strings.TrimSpace(raw)
	if len(raw) > 7 {
		return raw[:7]
	}
	return raw
}

func ensureRepo(cfg benchConfig, repo repoRef) (string, error) {
	if repo.LocalDir != "" {
		if ok, err := repoDirMatchesCommit(repo.LocalDir, repo.Commit); err == nil && ok {
			return repo.LocalDir, nil
		}
	}
	reposDir := filepath.Join(cfg.Workspace, "sources")
	if err := ensureDir(reposDir); err != nil {
		return "", err
	}
	targetDir := filepath.Join(reposDir, strings.TrimSuffix(filepath.Base(repo.URL), ".git"))
	if _, err := os.Stat(filepath.Join(targetDir, ".git")); errors.Is(err, os.ErrNotExist) {
		if err := runCmd("", nil, "git", "clone", repo.URL, targetDir); err != nil {
			return "", fmt.Errorf("clone %s: %w", repo.URL, err)
		}
	}
	if err := runCmd(targetDir, nil, "git", "fetch", "--all", "--tags"); err != nil {
		return "", fmt.Errorf("fetch %s: %w", repo.URL, err)
	}
	if err := runCmd(targetDir, nil, "git", "checkout", "--detach", repo.Commit); err != nil {
		return "", fmt.Errorf("checkout %s: %w", repo.Commit, err)
	}
	return targetDir, nil
}

func repoDirMatchesCommit(dir, commit string) (bool, error) {
	if commit == "" {
		return true, nil
	}
	output, err := exec.Command("git", "-C", dir, "rev-parse", "HEAD").CombinedOutput()
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(string(output)) == strings.TrimSpace(commit), nil
}

func copyDir(source, target string) error {
	return filepath.WalkDir(source, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		if strings.HasPrefix(rel, ".git"+string(os.PathSeparator)) || rel == ".git" {
			if entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		dst := filepath.Join(target, rel)
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return os.MkdirAll(dst, info.Mode())
		}
		if entry.Type()&os.ModeSymlink != 0 {
			linkTarget, err := os.Readlink(path)
			if err != nil {
				return err
			}
			return os.Symlink(linkTarget, dst)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if err := ensureDir(filepath.Dir(dst)); err != nil {
			return err
		}
		return os.WriteFile(dst, data, info.Mode())
	})
}

func writeJSON(path string, payload any) error {
	data, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(data, '\n'), 0o644)
}

func writeFile(path, content string) error {
	if err := ensureDir(filepath.Dir(path)); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(content), 0o644)
}

func ensureDir(path string) error {
	return os.MkdirAll(path, 0o755)
}

func runCmd(dir string, extraEnv map[string]string, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	cmd.Env = os.Environ()
	for key, value := range extraEnv {
		cmd.Env = append(cmd.Env, key+"="+value)
	}
	output, err := cmd.CombinedOutput()
	if err != nil {
		trimmed := strings.TrimSpace(string(output))
		if trimmed == "" {
			return err
		}
		return fmt.Errorf("%w: %s", err, trimmed)
	}
	return nil
}

func fetchURL(url, host string, timeout time.Duration) (int, string, error) {
	client := &http.Client{Timeout: timeout}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return 0, "", err
	}
	if host != "" {
		req.Host = host
	}
	resp, err := client.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return resp.StatusCode, "", err
	}
	return resp.StatusCode, string(body), nil
}

func pickAvailablePort(start int) (int, error) {
	if start < 1024 {
		start = 18080
	}
	for port := start; port < start+500; port++ {
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			continue
		}
		_ = ln.Close()
		return port, nil
	}
	return 0, fmt.Errorf("no free port near %d", start)
}

func stopProcess(cmd *exec.Cmd, done <-chan error) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	if cmd.ProcessState != nil && cmd.ProcessState.Exited() {
		return
	}
	_ = cmd.Process.Signal(syscall.SIGINT)
	select {
	case <-done:
	case <-time.After(25 * time.Second):
		_ = cmd.Process.Kill()
		<-done
	}
}

func samePIDSnapshots(left, right []workloadPIDSnapshot) bool {
	if len(left) != len(right) {
		return false
	}
	type key struct {
		Kind string
		Name string
	}
	leftMap := map[key]int{}
	for _, item := range left {
		leftMap[key{Kind: item.Kind, Name: item.Name}] = item.PID
	}
	for _, item := range right {
		if leftMap[key{Kind: item.Kind, Name: item.Name}] != item.PID {
			return false
		}
	}
	return true
}

func workloadHealthUp(payload map[string]any) bool {
	health := toStringAnyMap(payload["health"])
	if len(health) == 0 {
		return false
	}
	up, _ := health["up"].(bool)
	return up
}

func toStringAnyMap(raw any) map[string]any {
	typed, ok := raw.(map[string]any)
	if ok {
		return typed
	}
	typedString, ok := raw.(map[string]interface{})
	if ok {
		out := make(map[string]any, len(typedString))
		for key, value := range typedString {
			out[key] = value
		}
		return out
	}
	return map[string]any{}
}

func toInt(raw any) int {
	switch typed := raw.(type) {
	case int:
		return typed
	case int64:
		return int(typed)
	case float64:
		return int(typed)
	case json.Number:
		value, _ := typed.Int64()
		return int(value)
	default:
		return 0
	}
}

func trimSnippet(raw string) string {
	raw = strings.TrimSpace(raw)
	if len(raw) > 320 {
		return raw[:320]
	}
	return raw
}

func roundMS(value float64) float64 {
	return math.Round(value*100) / 100
}

func repoRoot() string {
	_, filename, _, ok := runtime.Caller(0)
	if !ok {
		return "."
	}
	return filepath.Clean(filepath.Join(filepath.Dir(filename), "..", "..", ".."))
}
