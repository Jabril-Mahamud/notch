package cmd

import (
	"github.com/spf13/cobra"

	"github.com/Jabril-Mahamud/notch/cmd/notch/internal"
)

var upCmd = &cobra.Command{
	Use:   "up [dev|staging]",
	Short: "Create an environment's Kind cluster and bootstrap it (default dev)",
	Args:  cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		root, err := internal.RepoRoot()
		if err != nil {
			return err
		}
		return internal.Up(root, envArg(args))
	},
}

func init() { rootCmd.AddCommand(upCmd) }

// envArg is the optional environment argument of up/down.
func envArg(args []string) string {
	if len(args) == 0 {
		return "dev"
	}
	return args[0]
}
