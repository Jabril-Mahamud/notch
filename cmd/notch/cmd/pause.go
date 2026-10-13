package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/Jabril-Mahamud/notch/cmd/notch/internal"
)

var pauseCmd = &cobra.Command{
	Use:   "pause",
	Short: "Stop the cluster node, keeping its state",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		if err := internal.Pause(); err != nil {
			return err
		}
		fmt.Println("cluster paused, run `notch resume` to bring it back")
		return nil
	},
}

func init() { rootCmd.AddCommand(pauseCmd) }
