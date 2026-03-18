package cmd

import (
	"fmt"
	"log"
	"os/exec"
	"runtime"

	"github.com/spf13/cobra"
)

var docsGOOS = runtime.GOOS
var docsExecCommand = exec.Command
var docsFatalf = log.Fatalf

var docsCmd = &cobra.Command{
	Use:   "docs",
	Short: "Open the local documentation/Swagger UI",
	Run: func(cmd *cobra.Command, args []string) {
		url := "http://localhost:8080/docs"
		fmt.Printf("Opening %s...\n", url)

		var err error
		switch docsGOOS {
		case "linux":
			err = docsExecCommand("xdg-open", url).Start()
		case "windows":
			err = docsExecCommand("rundll32", "url.dll,FileProtocolHandler", url).Start()
		case "darwin":
			err = docsExecCommand("open", url).Start()
		default:
			err = fmt.Errorf("unsupported platform")
		}

		if err != nil {
			docsFatalf("Failed to open browser: %v", err)
		}
	},
}

func init() {
	rootCmd.AddCommand(docsCmd)
}
