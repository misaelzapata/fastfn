package cmd

import (
	"os"

	"github.com/spf13/cobra"
)

var rootCmd = &cobra.Command{
	Use:   "fastfn",
	Short: "FastFn CLI - The fastest path to serverless functions",
	Long:  `FastFn is a comprehensive CLI for developing, testing, and deploying serverless functions with the FastFn runtime.`,
}

func Execute() {
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}
