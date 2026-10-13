package cmd

import (
	"github.com/spf13/cobra"

	"github.com/Jabril-Mahamud/notch/cmd/notch/internal"
)

var logsCmd = &cobra.Command{
	Use:   "logs <service>",
	Short: "Follow a service's logs",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return internal.Logs(args[0])
	},
}

func init() { rootCmd.AddCommand(logsCmd) }
