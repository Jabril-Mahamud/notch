package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/Jabril-Mahamud/notch/cmd/notch/internal"
)

var listCmd = &cobra.Command{
	Use:   "list",
	Short: "Show services with sync status, health and URL",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		out, err := internal.List()
		if err != nil {
			return err
		}
		fmt.Print(out)
		return nil
	},
}

func init() { rootCmd.AddCommand(listCmd) }
