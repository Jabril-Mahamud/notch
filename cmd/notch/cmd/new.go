package cmd

import (
	"fmt"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/Jabril-Mahamud/notch/cmd/notch/internal"
)

var newCmd = &cobra.Command{
	Use:   "new <name>",
	Short: "Scaffold a FastAPI + Next.js + Postgres app next to the notch repo and deploy it",
	Args:  cobra.ExactArgs(1),
	RunE:  runNew,
}

func init() { rootCmd.AddCommand(newCmd) }

func runNew(cmd *cobra.Command, args []string) error {
	name := args[0]
	if !internal.ValidName(name) {
		return fmt.Errorf("%q isn't a valid app name (lowercase letters, digits, dashes)", name)
	}
	root, err := internal.RepoRoot()
	if err != nil {
		return err
	}
	// Next to the notch repo, not inside it: the app is its own repo.
	dir := filepath.Join(filepath.Dir(root), name)
	if err := internal.Scaffold(dir, name); err != nil {
		return err
	}
	if err := initRepo(dir, name); err != nil {
		return err
	}
	fmt.Printf("scaffolded %s, deploying\n", dir)
	addName, addPostgres = name, true
	return runAdd(cmd, []string{dir})
}

func initRepo(dir, name string) error {
	for _, args := range [][]string{
		{"init", "-q", "-b", "main"},
		{"add", "."},
		{"commit", "-q", "-m", "feat: scaffold " + name + " with notch new"},
	} {
		if err := internal.RunIn(dir, "git", args...); err != nil {
			return err
		}
	}
	return nil
}
