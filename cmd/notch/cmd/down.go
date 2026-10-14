package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/Jabril-Mahamud/notch/cmd/notch/internal"
)

var downCmd = &cobra.Command{
	Use:   "down [dev|staging]",
	Short: "Delete an environment's Kind cluster (default dev)",
	Args:  cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		if err := internal.Down(envArg(args)); err != nil {
			return err
		}
		fmt.Println("cluster deleted")
		return nil
	},
}

func init() { rootCmd.AddCommand(downCmd) }
