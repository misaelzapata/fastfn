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

	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"
)

var dryRun bool


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

		// 1. Resolve absolute path
		targetDir := "."
		if len(args) > 0 {
			targetDir = args[0]
		}
		absPath, err := filepath.Abs(targetDir)
		if err != nil {
			log.Fatalf("Failed to resolve absolute path: %v", err)
		}

		// 2. Scan for functions to determine volume mounts
		mounts := scanForMounts(absPath)
		if len(mounts) == 0 {
			log.Printf("Warning: No 'fn.config.json' found in %s or subdirectories.\n", absPath)
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
		dockerCmd := exec.Command("docker", "compose", "-f", "-", "up")
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

// scanForMounts returns a list of "hostPath:containerPath" strings
func scanForMounts(rootPath string) []string {
	var mounts []string

	// Check if root is a function
	if isFunction(rootPath) {
		rt, name := getFunctionDetails(rootPath)
		mounts = append(mounts, fmt.Sprintf("%s:/app/srv/fn/functions/%s/%s", rootPath, rt, name))
		return mounts
	}

	// Check subdirectories
	entries, err := os.ReadDir(rootPath)
	if err != nil {
		log.Printf("Warning: cannot read dir %s: %v", rootPath, err)
		return nil
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		fullPath := filepath.Join(rootPath, entry.Name())
		if isFunction(fullPath) {
			rt, _ := getFunctionDetails(fullPath)
			// Use the folder name as the function name
			mounts = append(mounts, fmt.Sprintf("%s:/app/srv/fn/functions/%s/%s", fullPath, rt, entry.Name()))
		} else {
			// Check recursively one level down (legacy project/runtime/func structure)
			subEntries, _ := os.ReadDir(fullPath)
			for _, sub := range subEntries {
				if sub.IsDir() && isFunction(filepath.Join(fullPath, sub.Name())) {
					rt, _ := getFunctionDetails(filepath.Join(fullPath, sub.Name()))
					mounts = append(mounts, fmt.Sprintf("%s:/app/srv/fn/functions/%s/%s", filepath.Join(fullPath, sub.Name()), rt, sub.Name()))
				}
			}
		}
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
}
