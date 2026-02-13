package cmd

import (
	"log"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/spf13/cobra"
)

var logsCmd = &cobra.Command{
	Use:   "logs",
	Short: "View logs from the running stack",
	Run: func(cmd *cobra.Command, args []string) {
		composePath := "docker-compose.yml"
		if _, err := os.Stat(composePath); os.IsNotExist(err) {
			composePath = "../docker-compose.yml"
			if _, err := os.Stat(composePath); os.IsNotExist(err) {
				log.Fatal("Could not find docker-compose.yml")
			}
		}

		// docker compose logs -f
		dockerCmd := exec.Command("docker", "compose", "-f", composePath, "logs", "-f")
		dockerCmd.Stdout = os.Stdout
		dockerCmd.Stderr = os.Stderr
		dockerCmd.Dir = filepath.Dir(composePath)

		if err := dockerCmd.Run(); err != nil {
			log.Fatalf("Failed to attach logs: %v", err)
		}
	},
}

func init() {
	rootCmd.AddCommand(logsCmd)
}
