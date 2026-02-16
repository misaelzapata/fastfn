package cmd

import (
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var cfgFile string

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
		os.Exit(1)
	}
}

func init() {
	cobra.OnInitialize(initConfig)
	rootCmd.PersistentFlags().StringVar(&cfgFile, "config", "", "Path to config file (default: ./fastfn.json)")
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
			os.Exit(1)
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
