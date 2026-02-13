package cmd

import (
	"fmt"
	"log"
	"os/exec"
	"runtime"

	"github.com/spf13/cobra"
)

var docsCmd = &cobra.Command{
	Use:   "docs",
	Short: "Open the local documentation/Swagger UI",
	Run: func(cmd *cobra.Command, args []string) {
		url := "http://localhost:8080/docs"
		fmt.Printf("Opening %s...\n", url)
		
		var err error
		switch runtime.GOOS {
		case "linux":
			err = exec.Command("xdg-open", url).Start()
		case "windows":
			err = exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
		case "darwin":
			err = exec.Command("open", url).Start()
		default:
			err = fmt.Errorf("unsupported platform")
		}
		
		if err != nil {
			log.Fatalf("Failed to open browser: %v", err)
		}
	},
}

func init() {
	rootCmd.AddCommand(docsCmd)
}
