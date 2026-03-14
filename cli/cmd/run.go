package cmd

import (
	"fmt"
	"log"
	"os"
	"path/filepath"

	"github.com/misaelzapata/fastfn/cli/internal/process"
	"github.com/spf13/cobra"
)

var runNativeMode bool
var runForceURL bool
var runProcessRunner = process.RunNative
var runFatalf = log.Fatalf
var runFatal = log.Fatal
var runAbsFn = filepath.Abs

func resolveRunTargetDir(args []string) string {
	if len(args) > 0 {
		return args[0]
	}
	if path := configuredFunctionsDir(); path != "" {
		return path
	}
	return "."
}

var runCmd = &cobra.Command{
	Use:   "run [dir]",
	Short: "Run with production defaults (no hot reload)",
	Long: `Start FastFN with production-oriented defaults:
- hot reload disabled
- file watcher disabled
- TLS verification enabled

At the moment, production mode is supported through --native.`,
	Example: `  fastfn run --native .
  fastfn run --native examples/functions/next-style
  FN_HOST_PORT=8081 fastfn run --native .`,
	Args: cobra.MaximumNArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		applyConfiguredOpenAPIIncludeInternal(func(includeInternal bool) {
			fmt.Printf("Using OpenAPI internal visibility from config: %t\n", includeInternal)
		})
		applyConfiguredForceURL(func(forceURL bool) {
			fmt.Printf("Using force-url from config: %t\n", forceURL)
		})
		applyConfiguredRuntimeDaemons(func(value string) {
			fmt.Printf("Using runtime-daemons from config: %s\n", value)
		})
		applyConfiguredRuntimeBinaries(func(envVar, value string) {
			fmt.Printf("Using runtime binary from config: %s=%s\n", envVar, value)
		})
		if runForceURL {
			_ = os.Setenv("FN_FORCE_URL", "1")
			fmt.Println("force-url enabled (will allow config/policy routes to override existing URLs)")
		}

		targetDir := resolveRunTargetDir(args)

		absPath, err := runAbsFn(targetDir)
		if err != nil {
			runFatalf("Failed to resolve path: %v", err)
		}
		if os.Getenv("FN_PUBLIC_BASE_URL") == "" {
			if baseURL := configuredPublicBaseURL(); baseURL != "" {
				_ = os.Setenv("FN_PUBLIC_BASE_URL", baseURL)
				fmt.Printf("Using public base URL from config: %s\n", baseURL)
			}
		}
		if _, err := os.Stat(absPath); os.IsNotExist(err) {
			runFatalf("Directory not found: %s", absPath)
		}

		if runNativeMode {
			fmt.Println("Starting FastFN in PRODUCTION (Native) mode...")
			fmt.Printf("Functions root: %s\n", absPath)

			err := runProcessRunner(process.RunConfig{
				FnDir:     absPath,
				HotReload: false,
				VerifyTLS: true,
				Watch:     false,
			})
			if err != nil {
				runFatalf("Native run failed: %v", err)
			}
		} else {
			runFatal("Docker production mode currently requires building an image. Use --native to run bare metal production.")
		}
	},
}

func init() {
	rootCmd.AddCommand(runCmd)
	runCmd.Flags().BoolVar(&runNativeMode, "native", false, "Run on host (required; Docker production mode is not wired yet)")
	runCmd.Flags().BoolVar(&runForceURL, "force-url", false, "Allow config/policy routes to override existing mapped URLs (unsafe; prefer fixing route conflicts)")
}
