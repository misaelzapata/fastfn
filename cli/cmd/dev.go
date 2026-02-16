package cmd

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/misaelzapata/fastfn/cli/internal/discovery"
	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"
)

var dryRun bool
var devForceURL bool
var devBuild bool

func resolveDevTargetDir(args []string) string {
	if len(args) > 0 {
		return args[0]
	}
	if path := configuredFunctionsDir(); path != "" {
		return path
	}
	return "."
}

func checkSystemRequirements() {
	// 1. Check for docker binary
	if _, err := exec.LookPath("docker"); err != nil {
		log.Fatal("Error: Docker is not installed or not in your PATH.\nPlease install Docker: https://docs.docker.com/get-docker/")
	}

	// 2. Check if Docker Daemon is running
	cmd := exec.Command("docker", "info")
	if err := cmd.Run(); err != nil {
		log.Fatal("Error: Docker Daemon is not running.\nPlease start Docker Desktop or the docker daemon.")
	}
}

// findProjectRoot looks for docker-compose.yml starting from startPath and moving up
func findProjectRoot(startPath string) (string, error) {
	current := startPath
	for {
		if _, err := os.Stat(filepath.Join(current, "docker-compose.yml")); err == nil {
			return current, nil
		}
		
		parent := filepath.Dir(current)
		if parent == current {
			return "", fmt.Errorf("could not find docker-compose.yml in any parent directory")
		}
		current = parent
	}
}

var devCmd = &cobra.Command{
	Use:   "dev [dir]",
	Short: "Start development environment with hot-reload",
	Args:  cobra.MaximumNArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		// 0. Pre-flight checks
		checkSystemRequirements()

		applyConfiguredOpenAPIIncludeInternal(func(includeInternal bool) {
			fmt.Printf("Using openapi-include-internal from config: %t\n", includeInternal)
		})
		applyConfiguredForceURL(func(forceURL bool) {
			fmt.Printf("Using force-url from config: %t\n", forceURL)
		})
		if devForceURL {
			_ = os.Setenv("FN_FORCE_URL", "1")
			fmt.Println("force-url enabled (will allow config/policy routes to override existing URLs)")
		}

		// 1. Resolve absolute path
		targetDir := resolveDevTargetDir(args)
		absPath, err := filepath.Abs(targetDir)
		if err != nil {
			log.Fatalf("Failed to resolve absolute path: %v", err)
		}

		// 2. Resolve volume mounts
		mounts := scanForMounts(absPath)
		if len(mounts) == 0 {
			log.Fatalf("Invalid functions directory: %s", absPath)
		}

		// 3. Find docker-compose.yml (recursively up)
		projectRoot, err := findProjectRoot(absPath)
		var composePath string

		if err == nil {
			// Local repo case
			composePath = filepath.Join(projectRoot, "docker-compose.yml")
			fmt.Printf("Found local docker-compose.yml at: %s\n", projectRoot)
		} else {
			// Portable case (Homebrew): Generate temporary compose file
			fmt.Println("No local docker-compose.yml found. Using portable mode...")
			
			// For now, fail as we need the image to exist
			log.Fatal("Portable mode requires 'ghcr.io/fastfn/runtime' image which is not yet published.\nPlease run from within the repo.")
			
			/* FUTURE IMPLEMENTATION:
			tempDir, err := os.MkdirTemp("", "fastfn-dev-*")
			if err != nil {
				log.Fatalf("Failed to create temp dir: %v", err)
			}
			defer os.RemoveAll(tempDir) // cleanup on exit

			genPath, err := templates.GenerateDockerCompose(tempDir, absPath)
			if err != nil {
				log.Fatalf("Failed to generate docker-compose.yml: %v", err)
			}
			composePath = genPath
			projectRoot = tempDir 
			*/
		}
		
		fmt.Printf("Using configuration from: %s\n", composePath)

		// 4. Parse YAML
		data, err := os.ReadFile(composePath)
		if err != nil {
			log.Fatalf("Failed to read docker-compose.yml: %v", err)
		}

		var compose map[string]interface{}
		if err := yaml.Unmarshal(data, &compose); err != nil {
			log.Fatalf("Failed to parse docker-compose.yml: %v", err)
		}

		// 5. Apply volumes
		services, ok := compose["services"].(map[string]interface{})
		if !ok {
			log.Fatal("Invalid docker-compose.yml: no services")
		}
		openresty, ok := services["openresty"].(map[string]interface{})
		if !ok {
			log.Fatal("Invalid docker-compose.yml: no openresty service")
		}
		
		volumes, ok := openresty["volumes"].([]interface{})
		if !ok {
			volumes = []interface{}{}
		}
		
		// Filter out existing /app/srv/fn/functions mounts
		newVolumes := []interface{}{}
		for _, v := range volumes {
			vStr, ok := v.(string)
			if ok && strings.Contains(vStr, "/app/srv/fn/functions") {
				continue
			}
			newVolumes = append(newVolumes, v)
		}
		
		// Add our calculated mounts
		for _, m := range mounts {
			newVolumes = append(newVolumes, m)
			fmt.Printf("Mounting '%s' -> '%s'\n", strings.Split(m, ":")[0], strings.Split(m, ":")[1])
		}
		openresty["volumes"] = newVolumes

		// Apply optional env toggles.
		if strings.TrimSpace(os.Getenv("FN_FORCE_URL")) != "" {
			envRaw := openresty["environment"]
			envMap, ok := envRaw.(map[string]interface{})
			if !ok || envMap == nil {
				envMap = map[string]interface{}{}
			}
			envMap["FN_FORCE_URL"] = os.Getenv("FN_FORCE_URL")
			openresty["environment"] = envMap
		}
		
		// Encode back to YAML
		modifiedYAML, err := yaml.Marshal(compose)
		if err != nil {
			log.Fatalf("Failed to generate modified YAML: %v", err)
		}

		if dryRun {
			fmt.Println("# Dry Run: Generated Docker Compose configuration")
			fmt.Println(string(modifiedYAML))
			return
		}

		// 6. Run docker compose
		dockerArgs := []string{"compose", "-f", "-", "up"}
		if devBuild {
			dockerArgs = append(dockerArgs, "--build")
		}
		dockerCmd := exec.Command("docker", dockerArgs...)
		dockerCmd.Stdin = bytes.NewReader(modifiedYAML)
		dockerCmd.Stdout = os.Stdout
		dockerCmd.Stderr = os.Stderr
		
		// Set working dir to where the original compose file is
		dockerCmd.Dir = filepath.Dir(composePath)

		fmt.Println("Starting FastFn dev server...")
		if err := dockerCmd.Run(); err != nil {
			log.Fatalf("Docker run failed: %v", err)
		}
	},
}

type FnConfig struct {
	Runtime string `json:"runtime"`
	Name    string `json:"name"`
}

func mountProjectRoot(rootPath string) []string {
	return []string{fmt.Sprintf("%s:/app/srv/fn/functions", rootPath)}
}

// scanForMounts returns a list of "hostPath:containerPath" strings.
// Dual/hybrid behavior:
// - file-based routes: mount root to preserve route discovery.
// - fn.config functions: mount per runtime+function path.
// - mixed projects: include both mount styles.
func scanForMounts(rootPath string) []string {
	info, err := os.Stat(rootPath)
	if err != nil || !info.IsDir() {
		return nil
	}

	functions, err := discovery.Scan(rootPath, nil)
	if err != nil || len(functions) == 0 {
		return mountProjectRoot(rootPath)
	}

	hasConfig := false
	hasNonConfig := false
	for _, fn := range functions {
		if fn.HasConfig {
			hasConfig = true
		} else {
			hasNonConfig = true
		}
	}

	mounts := make([]string, 0, len(functions))
	seen := map[string]struct{}{}

	if hasNonConfig {
		rootMount := fmt.Sprintf("%s:/app/srv/fn/functions", rootPath)
		mounts = append(mounts, rootMount)
		seen[rootMount] = struct{}{}
	}

	if hasConfig {
		for _, fn := range functions {
			if !fn.HasConfig {
				continue
			}
			rt := strings.TrimSpace(fn.Runtime)
			if rt == "" {
				rt = "node"
			}
			name := strings.TrimSpace(fn.Name)
			if name == "" {
				name = filepath.Base(fn.Path)
			}
			hostPath := fn.Path
			if hostPath == "" {
				hostPath = rootPath
			}
			mount := fmt.Sprintf("%s:/app/srv/fn/functions/%s/%s", hostPath, rt, name)
			if _, ok := seen[mount]; ok {
				continue
			}
			seen[mount] = struct{}{}
			mounts = append(mounts, mount)
		}
	}

	if len(mounts) == 0 {
		return mountProjectRoot(rootPath)
	}

	return mounts
}

func isFunction(path string) bool {
	_, err := os.Stat(filepath.Join(path, "fn.config.json"))
	return err == nil
}

func getFunctionDetails(path string) (string, string) {
	data, err := os.ReadFile(filepath.Join(path, "fn.config.json"))
	if err != nil {
		return "node", filepath.Base(path)
	}
	var cfg FnConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return "node", filepath.Base(path)
	}
	if cfg.Runtime == "" {
		cfg.Runtime = "node"
	}
	if cfg.Name == "" {
		cfg.Name = filepath.Base(path)
	}
	return cfg.Runtime, cfg.Name
}

func init() {
	rootCmd.AddCommand(devCmd)
	devCmd.Flags().BoolVar(&dryRun, "dry-run", false, "Print generated docker-compose config without running")
	devCmd.Flags().BoolVar(&devForceURL, "force-url", false, "Allow config/policy routes to override existing mapped URLs (unsafe; prefer fixing route conflicts)")
	devCmd.Flags().BoolVar(&devBuild, "build", false, "Build the runtime image before starting the dev server (slower)")
}
