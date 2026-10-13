package cmd

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/Jabril-Mahamud/notch/cmd/notch/internal"
)

var (
	addSecrets  []string
	addPostgres bool
)

var addCmd = &cobra.Command{
	Use:   "add <repo-or-path>",
	Short: "Build a repo, load it into Kind and deploy it as a service",
	Args:  cobra.ExactArgs(1),
	RunE:  runAdd,
}

func init() {
	addCmd.Flags().StringArrayVar(&addSecrets, "secret", nil, "secret env var the service needs (repeatable); value is prompted")
	addCmd.Flags().BoolVar(&addPostgres, "postgres", false, "provision a Postgres database for the service")
	rootCmd.AddCommand(addCmd)
}

func runAdd(cmd *cobra.Command, args []string) error {
	root, err := internal.RepoRoot()
	if err != nil {
		return err
	}
	if err := internal.OnDev(root); err != nil {
		return err
	}
	src, cleanup, err := source(args[0])
	if err != nil {
		return err
	}
	defer cleanup()

	svc, err := describe(args[0], src)
	if err != nil {
		return err
	}
	// Prompt before the slow build so nobody has to babysit it.
	values, err := promptSecrets(svc.Secrets)
	if err != nil {
		return err
	}
	if err := internal.BuildAndLoad(svc.Name, src); err != nil {
		return err
	}
	if _, err := internal.WriteService(root, svc); err != nil {
		return err
	}
	if len(svc.Secrets) > 0 {
		if err := internal.CreateSecret(svc.Name, svc.Secrets, values); err != nil {
			return err
		}
	}
	if err := internal.Publish(root, filepath.Join("services", svc.Name), "feat: add "+svc.Name+" service"); err != nil {
		return err
	}
	fmt.Printf("service %s deploying, run `notch list` to check status\n", svc.Name)
	return nil
}

// source returns a local directory for the repo, cloning remotes.
func source(arg string) (string, func(), error) {
	if !internal.IsRemote(arg) {
		return arg, func() {}, nil
	}
	dir, err := internal.Clone(arg)
	if err != nil {
		return "", nil, err
	}
	return dir, func() { os.RemoveAll(dir) }, nil
}

func describe(arg, src string) (internal.Service, error) {
	name, err := internal.NameFrom(arg)
	if err != nil {
		return internal.Service{}, err
	}
	port, err := internal.DetectPort(src)
	if err != nil {
		return internal.Service{}, err
	}
	for _, k := range addSecrets {
		if !internal.ValidSecretKey(k) {
			return internal.Service{}, fmt.Errorf("secret %q isn't a valid env var name", k)
		}
	}
	return internal.Service{Name: name, Port: port, Postgres: addPostgres, Secrets: addSecrets}, nil
}

// ponytail: input echoes. Swap in golang.org/x/term ReadPassword if that matters.
func promptSecrets(keys []string) ([]string, error) {
	in := bufio.NewReader(os.Stdin)
	values := make([]string, len(keys))
	for i, k := range keys {
		fmt.Printf("%s: ", k)
		line, err := in.ReadString('\n')
		if err != nil {
			return nil, fmt.Errorf("reading %s: %w", k, err)
		}
		values[i] = strings.TrimRight(line, "\r\n")
	}
	return values, nil
}
