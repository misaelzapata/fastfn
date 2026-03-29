package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

// Populated at build time via -ldflags (see cli/.goreleaser.yaml).
var (
	Version = "dev"
	Commit  = "none"
	Date    = "unknown"
)

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Print the version number",
	Run: func(cmd *cobra.Command, args []string) {
		// Keep output stable for scripts and Homebrew formula tests.
		fmt.Printf("FastFN %s\n", Version)
	},
}

func init() {
	rootCmd.AddCommand(versionCmd)
}
