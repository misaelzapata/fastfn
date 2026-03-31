package cmd

import (
	"fmt"
	"log"
	"os"
	"path/filepath"

	"github.com/misaelzapata/fastfn/cli/internal/process"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var runNativeMode bool
var runForceURL bool
var runHotReload bool
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
	Short: "Run with production defaults",
	Long: `Start FastFN with production-oriented defaults:
- hot reload enabled by default (disable with FN_HOT_RELOAD=0 or config hot-reload: false)
- file watcher follows hot reload setting
- TLS verification enabled

At the moment, production mode is supported through --native.`,
	Example: `  fastfn run --native .
  fastfn run --native --hot-reload .
  FN_HOT_RELOAD=1 fastfn run --native .
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
		imageWorkloads, _, err := configuredImageWorkloads()
		if err != nil {
			runFatalf("Invalid apps/services config: %v", err)
			return
		}
		if runForceURL {
			_ = os.Setenv("FN_FORCE_URL", "1")
			fmt.Println("force-url enabled (will allow config/policy routes to override existing URLs)")
		}

		// Resolve hot-reload: flag > env > config > default (true)
		hotReload := true
		if runHotReload {
			// Explicit --hot-reload flag always wins
			hotReload = true
		} else if envVal := os.Getenv("FN_HOT_RELOAD"); envVal != "" {
			hotReload = envVal != "0" && envVal != "false" && envVal != "off" && envVal != "no"
		} else if viper.IsSet("hot-reload") {
			hotReload = viper.GetBool("hot-reload")
		}
		if hotReload {
			fmt.Println("Hot reload enabled (file changes will trigger handler reload)")
		} else {
			fmt.Println("Hot reload disabled")
		}

		targetDir := resolveRunTargetDir(args)

		absPath, err := runAbsFn(targetDir)
		if err != nil {
			runFatalf("Failed to resolve path: %v", err)
			return
		}
		if os.Getenv("FN_PUBLIC_BASE_URL") == "" {
			if baseURL := configuredPublicBaseURL(); baseURL != "" {
				_ = os.Setenv("FN_PUBLIC_BASE_URL", baseURL)
				fmt.Printf("Using public base URL from config: %s\n", baseURL)
			}
		}
		if _, err := os.Stat(absPath); os.IsNotExist(err) {
			runFatalf("Directory not found: %s", absPath)
			return
		}

		if runNativeMode {
			fmt.Println("Starting FastFN in PRODUCTION (Native) mode...")
			fmt.Printf("Functions root: %s\n", absPath)

			err := runProcessRunner(process.RunConfig{
				ProjectDir: configuredProjectRoot(),
				FnDir:      absPath,
				HotReload:  hotReload,
				VerifyTLS:  true,
				Watch:      hotReload,
				Workloads:  imageWorkloads,
			})
			if err != nil {
				runFatalf("Native run failed: %v", err)
				return
			}
		} else {
			runFatal("Docker production mode currently requires building an image. Use --native to run bare metal production.")
			return
		}
	},
}

func init() {
	rootCmd.AddCommand(runCmd)
	runCmd.Flags().BoolVar(&runNativeMode, "native", false, "Run on host (required; Docker production mode is not wired yet)")
	runCmd.Flags().BoolVar(&runForceURL, "force-url", false, "Allow config/policy routes to override existing mapped URLs (unsafe; prefer fixing route conflicts)")
	runCmd.Flags().BoolVar(&runHotReload, "hot-reload", false, "Force-enable hot reload (default: enabled; disable with FN_HOT_RELOAD=0)")
}
