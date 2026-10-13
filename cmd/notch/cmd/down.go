package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/Jabril-Mahamud/notch/cmd/notch/internal"
)

var downCmd = &cobra.Command{
	Use:   "down",
	Short: "Delete the Kind cluster",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		if err := internal.Down(); err != nil {
			return err
		}
		fmt.Println("cluster deleted")
		return nil
	},
}

func init() { rootCmd.AddCommand(downCmd) }
