package cmd

import (
	"log"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/spf13/cobra"
)

var runCmd = &cobra.Command{
	Use:   "run [dir]",
	Short: "Start in production mode (no hot-reload)",
	Args:  cobra.MaximumNArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		// Just run docker compose up without modification
		// We assume the user has built images or we are just running the stack
		// For now, let's keep it simple: just up the stack
		
		composePath := "docker-compose.yml"
		if _, err := os.Stat(composePath); os.IsNotExist(err) {
			composePath = "../docker-compose.yml"
			if _, err := os.Stat(composePath); os.IsNotExist(err) {
				log.Fatal("Could not find docker-compose.yml")
			}
		}

		dockerCmd := exec.Command("docker", "compose", "-f", composePath, "up")
		dockerCmd.Stdout = os.Stdout
		dockerCmd.Stderr = os.Stderr
		dockerCmd.Dir = filepath.Dir(composePath)
		
		log.Println("Starting FastFn in production mode...")
		if err := dockerCmd.Run(); err != nil {
			log.Fatalf("Production run failed: %v", err)
		}
	},
}

func init() {
	rootCmd.AddCommand(runCmd)
}
