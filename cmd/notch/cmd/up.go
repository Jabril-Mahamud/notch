package cmd

import (
	"github.com/spf13/cobra"

	"github.com/Jabril-Mahamud/notch/cmd/notch/internal"
)

var upCmd = &cobra.Command{
	Use:   "up",
	Short: "Create the Kind cluster and bootstrap the platform",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		root, err := internal.RepoRoot()
		if err != nil {
			return err
		}
		return internal.Up(root)
	},
}

func init() { rootCmd.AddCommand(upCmd) }
