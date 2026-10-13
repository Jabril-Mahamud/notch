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
	addName     string
)

var addCmd = &cobra.Command{
	Use:   "add <repo-or-path>",
	Short: "Build a repo (Dockerfile or auto-detected), load it into Kind and deploy it as a service",
	Long: `Build a repo (Dockerfile or auto-detected), load it into Kind and deploy it as a service.

Rerunning on an existing service rebuilds and reloads its image, e.g. after
notch down/up. Pass --secret again to recreate secrets on a fresh cluster.`,
	Args: cobra.ExactArgs(1),
	RunE: runAdd,
}

func init() {
	addCmd.Flags().StringArrayVar(&addSecrets, "secret", nil, "secret env var the service needs (repeatable); value is prompted")
	addCmd.Flags().BoolVar(&addPostgres, "postgres", false, "provision a Postgres database for the service")
	addCmd.Flags().StringVar(&addName, "name", "", "service name (default: from the repo name)")
	rootCmd.AddCommand(addCmd)
}

func runAdd(cmd *cobra.Command, args []string) error {
	root, err := internal.RepoRoot()
	if err != nil {
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
	dir := filepath.Join("services", svc.Name)
	_, statErr := os.Stat(filepath.Join(root, dir))
	exists := statErr == nil
	// Only a new service commits; a rebuild works from any branch.
	if !exists {
		if err := internal.OnDev(root); err != nil {
			return err
		}
	}
	if err := buildWithSecrets(svc, src); err != nil {
		return err
	}
	if exists {
		fmt.Printf("service %s exists, image rebuilt and loaded\n", svc.Name)
		// On a fresh cluster the Deployment may not exist yet; it starts on the new image anyway.
		_ = internal.Restart(svc.Name)
		return nil
	}
	if _, err := internal.WriteService(root, svc); err != nil {
		return err
	}
	if err := internal.Publish(root, dir, "feat: add "+svc.Name+" service"); err != nil {
		return err
	}
	fmt.Printf("service %s deploying, run `notch list` to check status\n", svc.Name)
	return nil
}

func buildWithSecrets(svc internal.Service, src string) error {
	// Prompt before the slow build so nobody has to babysit it.
	values, err := promptSecrets(svc.Secrets)
	if err != nil {
		return err
	}
	if err := internal.BuildAndLoad(svc.Name, src); err != nil {
		return err
	}
	if len(svc.Secrets) == 0 {
		return nil
	}
	return internal.CreateSecret(svc.Name, svc.Secrets, values)
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
	if addName != "" {
		name, err = addName, nil
		if !internal.ValidName(name) {
			err = fmt.Errorf("%q isn't a valid service name (lowercase letters, digits, dashes)", name)
		}
	}
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
