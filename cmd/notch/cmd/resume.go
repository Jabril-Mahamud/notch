package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/Jabril-Mahamud/notch/cmd/notch/internal"
)

var resumeCmd = &cobra.Command{
	Use:   "resume",
	Short: "Start a paused cluster and wait for it to be Ready",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		if err := internal.Resume(); err != nil {
			return err
		}
		fmt.Println("cluster resumed")
		return nil
	},
}

func init() { rootCmd.AddCommand(resumeCmd) }
