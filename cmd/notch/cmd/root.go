package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var rootCmd = &cobra.Command{
	Use:   "notch",
	Short: "Run the Notch platform on a local Kind cluster",
	// Errors are printed once by Execute; cobra's usage dump buries them.
	SilenceUsage:  true,
	SilenceErrors: true,
}

// Execute runs the CLI and exits 1 on any error.
func Execute() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "notch:", err)
		os.Exit(1)
	}
}
