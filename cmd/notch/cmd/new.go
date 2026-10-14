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

// Own var, not addAuth: a shared one would make true the default for notch add too.
var newAuth bool

func init() {
	// ponytail: platform plumbing only; the starter reading OIDC_* is a follow-up.
	newCmd.Flags().BoolVar(&newAuth, "auth", true, "register a Keycloak OIDC client and inject OIDC_* env")
	rootCmd.AddCommand(newCmd)
}

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
	addName, addPostgres, addAuth = name, true, newAuth
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
