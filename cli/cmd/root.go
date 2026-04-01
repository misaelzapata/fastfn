package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/misaelzapata/fastfn/cli/internal/process"
	"github.com/misaelzapata/fastfn/cli/internal/workloads"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var cfgFile string
var exitFn = os.Exit

var rootCmd = &cobra.Command{
	Use:   "fastfn",
	Short: "Build APIs from files (Python, Node, PHP, Lua by default; Rust/Go experimental)",
	Long: `FastFN builds HTTP APIs directly from files.

Use it for local development (fastfn dev) or production-style local runs
(fastfn run --native).

Defaults:
- If no directory is passed, current directory is used.
- If fastfn.json contains functions-dir, that path is used when directory is omitted.
- If fastfn.json contains public-base-url, OpenAPI uses that domain in servers[0].url.

Runtime status:
- Stable: python, node, php, lua
- Experimental (opt-in via FN_RUNTIMES): rust, go

Main commands:
- init: scaffold a new function
- dev: hot-reload development server (Docker by default, or --native)
- run: production mode (currently native)
- logs: stream runtime logs
- doctor: diagnostics for env/project/domains
- docs: open Swagger UI`,
	Example: `  fastfn init hello -t python
  fastfn dev .
  fastfn dev --native examples/functions/next-style
  fastfn logs --native --file error --lines 100
  fastfn doctor domains --domain api.example.com --json
  fastfn run --native .
  fastfn --config ./fastfn.json dev`,
}

func Execute() {
	if err := rootCmd.Execute(); err != nil {
		exitFn(1)
	}
}

func init() {
	cobra.OnInitialize(initConfig)
	rootCmd.PersistentFlags().StringVar(&cfgFile, "config", "", "Path to config file (default: ./fastfn.json)")
	// Enable `fastfn --version` in addition to `fastfn version`.
	rootCmd.Version = Version
	rootCmd.SetVersionTemplate("FastFN {{.Version}}\n")
}

func initConfig() {
	if cfgFile != "" {
		viper.SetConfigFile(cfgFile)
	} else {
		// Prefer JSON config to avoid format ambiguity.
		if _, err := os.Stat("fastfn.json"); err == nil {
			viper.SetConfigFile("fastfn.json")
		} else if _, err := os.Stat("fastfn.toml"); err == nil {
			// Backward compatibility for existing projects.
			viper.SetConfigFile("fastfn.toml")
		}
	}

	viper.AutomaticEnv()

	// If a config file is explicitly provided, fail fast on read/parse issues.
	if err := viper.ReadInConfig(); err != nil {
		if cfgFile != "" {
			fmt.Fprintf(os.Stderr, "Error: failed to read config file %q: %v\n", cfgFile, err)
			exitFn(1)
		}
	}
}

func configuredString(keys ...string) string {
	for _, key := range keys {
		if v := strings.TrimSpace(viper.GetString(key)); v != "" {
			return v
		}
	}
	return ""
}

func configuredFunctionsDir() string {
	return configuredString("functions-dir", "functions_dir", "functionsDir")
}

func configuredPublicBaseURL() string {
	return configuredString("public-base-url", "public_base_url", "publicBaseUrl")
}

func configuredProjectRoot() string {
	if cfgFile != "" {
		if absCfg, err := filepath.Abs(cfgFile); err == nil {
			return filepath.Dir(absCfg)
		}
		return filepath.Dir(cfgFile)
	}
	wd, err := os.Getwd()
	if err != nil {
		return "."
	}
	return wd
}

func projectConfigPath(dir string) string {
	dir = strings.TrimSpace(dir)
	if dir == "" {
		return ""
	}
	for _, name := range []string{"fastfn.json", "fastfn.toml"} {
		path := filepath.Join(dir, name)
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}
	return ""
}

func resolveTargetProjectRoot(absPath string) string {
	if cfgFile != "" {
		return configuredProjectRoot()
	}
	current := filepath.Clean(strings.TrimSpace(absPath))
	if current == "" {
		return configuredProjectRoot()
	}
	original := current
	for {
		if projectConfigPath(current) != "" {
			return current
		}
		parent := filepath.Dir(current)
		if parent == current {
			return original
		}
		current = parent
	}
}

func configuredSettingsForProject(projectDir string) (map[string]any, error) {
	projectDir = filepath.Clean(strings.TrimSpace(projectDir))
	if cfgFile != "" || filepath.Clean(configuredProjectRoot()) == projectDir {
		return viper.AllSettings(), nil
	}

	configPath := projectConfigPath(projectDir)
	if configPath == "" {
		return map[string]any{}, nil
	}

	projectViper := viper.New()
	projectViper.SetConfigFile(configPath)
	if err := projectViper.ReadInConfig(); err != nil {
		return nil, err
	}
	return projectViper.AllSettings(), nil
}

func configuredRuntimeDaemons() (string, bool) {
	if raw := configuredString("runtime-daemons", "runtime_daemons", "runtimeDaemons"); raw != "" {
		return raw, true
	}

	for _, key := range []string{"runtime-daemons", "runtime_daemons", "runtimeDaemons"} {
		raw := viper.Get(key)
		if raw == nil {
			continue
		}
		if value, ok := normalizeRuntimeDaemonConfigValue(raw); ok {
			return value, true
		}
	}

	for _, key := range []string{"runtime.daemons", "runtime-daemons.daemons"} {
		raw := viper.Get(key)
		if raw == nil {
			continue
		}
		if value, ok := normalizeRuntimeDaemonConfigValue(raw); ok {
			return value, true
		}
	}

	return "", false
}

func configuredRuntimeBinaries() (map[string]string, bool) {
	for _, key := range []string{"runtime-binaries", "runtime_binaries", "runtimeBinaries"} {
		raw := viper.Get(key)
		if raw == nil {
			continue
		}
		if value, ok := process.NormalizeBinaryConfigValue(raw); ok {
			return value, true
		}
	}

	for _, key := range []string{"runtime.binaries", "runtime-binaries.binaries"} {
		raw := viper.Get(key)
		if raw == nil {
			continue
		}
		if value, ok := process.NormalizeBinaryConfigValue(raw); ok {
			return value, true
		}
	}

	return nil, false
}

func configuredImageWorkloads() (workloads.Config, bool, error) {
	var cfg workloads.Config

	apps, appsSet, err := workloads.NormalizeAppSpecs(viper.Get("apps"))
	if err != nil {
		return cfg, false, err
	}
	services, servicesSet, err := workloads.NormalizeServiceSpecs(viper.Get("services"))
	if err != nil {
		return cfg, false, err
	}
	cfg.Apps = apps
	cfg.Services = services
	return cfg, appsSet || servicesSet, nil
}

func configuredImageWorkloadsFor(projectDir, fnDir string) (workloads.Config, bool, error) {
	settings, err := configuredSettingsForProject(projectDir)
	if err != nil {
		return workloads.Config{}, false, err
	}
	return workloads.LoadConfigured(projectDir, fnDir, settings)
}

func normalizeRuntimeDaemonConfigValue(raw any) (string, bool) {
	if raw == nil {
		return "", false
	}
	if s, ok := raw.(string); ok {
		value := strings.TrimSpace(s)
		return value, value != ""
	}

	var source map[string]any
	switch typed := raw.(type) {
	case map[string]any:
		source = typed
	case map[any]any:
		source = map[string]any{}
		for key, value := range typed {
			source[strings.TrimSpace(fmt.Sprint(key))] = value
		}
	default:
		return "", false
	}

	if len(source) == 0 {
		return "", false
	}

	order := []string{"node", "python", "php", "rust", "go", "lua"}
	seen := map[string]bool{}
	parts := make([]string, 0, len(source))
	appendPart := func(runtimeName string) {
		rawCount, ok := source[runtimeName]
		if !ok {
			return
		}
		var count int
		switch value := rawCount.(type) {
		case int:
			count = value
		case int64:
			count = int(value)
		case float64:
			count = int(value)
		case string:
			parsed, err := strconv.Atoi(strings.TrimSpace(value))
			if err != nil {
				return
			}
			count = parsed
		default:
			return
		}
		if count < 1 {
			return
		}
		seen[runtimeName] = true
		parts = append(parts, fmt.Sprintf("%s=%d", runtimeName, count))
	}

	for _, runtimeName := range order {
		appendPart(runtimeName)
	}
	extras := make([]string, 0)
	for runtimeName := range source {
		if !seen[runtimeName] {
			extras = append(extras, runtimeName)
		}
	}
	sort.Strings(extras)
	for _, runtimeName := range extras {
		appendPart(runtimeName)
	}

	if len(parts) == 0 {
		return "", false
	}
	return strings.Join(parts, ","), true
}

func configuredBool(keys ...string) (bool, bool) {
	for _, key := range keys {
		if viper.IsSet(key) {
			return viper.GetBool(key), true
		}
	}
	return false, false
}

func boolEnvValue(v bool) string {
	if v {
		return "1"
	}
	return "0"
}

func configuredOpenAPIIncludeInternal() (bool, bool) {
	return configuredBool(
		"openapi-include-internal",
		"openapi_include_internal",
		"openapiIncludeInternal",
		"openapi.include-internal",
		"openapi.include_internal",
		"openapi.includeInternal",
		"swagger-include-admin",
		"swagger_include_admin",
		"swaggerIncludeAdmin",
		"swagger.include-admin",
		"swagger.include_admin",
		"swagger.includeAdmin",
	)
}

func applyConfiguredOpenAPIIncludeInternal(onApplied func(value bool)) {
	if strings.TrimSpace(os.Getenv("FN_OPENAPI_INCLUDE_INTERNAL")) != "" {
		return
	}
	if includeInternal, ok := configuredOpenAPIIncludeInternal(); ok {
		_ = os.Setenv("FN_OPENAPI_INCLUDE_INTERNAL", boolEnvValue(includeInternal))
		if onApplied != nil {
			onApplied(includeInternal)
		}
	}
}

func configuredForceURL() (bool, bool) {
	return configuredBool(
		"force-url",
		"force_url",
		"forceUrl",
		"force.url",
	)
}

func applyConfiguredForceURL(onApplied func(value bool)) {
	if strings.TrimSpace(os.Getenv("FN_FORCE_URL")) != "" {
		return
	}
	if forceURL, ok := configuredForceURL(); ok {
		_ = os.Setenv("FN_FORCE_URL", boolEnvValue(forceURL))
		if onApplied != nil {
			onApplied(forceURL)
		}
	}
}

func applyConfiguredRuntimeDaemons(onApplied func(value string)) {
	if strings.TrimSpace(os.Getenv("FN_RUNTIME_DAEMONS")) != "" {
		return
	}
	if value, ok := configuredRuntimeDaemons(); ok {
		_ = os.Setenv("FN_RUNTIME_DAEMONS", value)
		if onApplied != nil {
			onApplied(value)
		}
	}
}

func applyConfiguredRuntimeBinaries(onApplied func(envVar, value string)) {
	configured, ok := configuredRuntimeBinaries()
	if !ok || len(configured) == 0 {
		return
	}

	envVars := make([]string, 0, len(configured))
	for envVar := range configured {
		envVars = append(envVars, envVar)
	}
	sort.Strings(envVars)

	for _, envVar := range envVars {
		if strings.TrimSpace(os.Getenv(envVar)) != "" {
			continue
		}
		value := configured[envVar]
		_ = os.Setenv(envVar, value)
		if onApplied != nil {
			onApplied(envVar, value)
		}
	}
}
