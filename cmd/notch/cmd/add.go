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
	addAuth     bool
	addName     string
	addBuildArg []string
)

var addCmd = &cobra.Command{
	Use:   "add <repo-or-path>",
	Short: "Build a repo (Dockerfile or auto-detected), push it to the notch registry and deploy it as a service",
	Long: `Build a repo (Dockerfile or auto-detected), push it to the notch registry and deploy it as a service.

Images are tagged with the source's commit sha. Rerunning on an existing
service rebuilds, and commits the new tag to dev if the source moved, so
ArgoCD rolls the pods. Pass --secret again to recreate secrets on a fresh cluster.`,
	Args: cobra.ExactArgs(1),
	RunE: runAdd,
}

func init() {
	addCmd.Flags().StringArrayVar(&addSecrets, "secret", nil, "secret env var the service needs (repeatable); value is prompted")
	addCmd.Flags().BoolVar(&addPostgres, "postgres", false, "provision a Postgres database for the service")
	addCmd.Flags().BoolVar(&addAuth, "auth", false, "register a Keycloak OIDC client and inject OIDC_* env")
	addCmd.Flags().StringVar(&addName, "name", "", "service name (default: from the repo name)")
	addCmd.Flags().StringArrayVar(&addBuildArg, "build-arg", nil, "docker build arg, [component:]KEY=VALUE (repeatable), e.g. frontend:NEXT_PUBLIC_API_URL=/api")
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
	// Both paths commit: a new service, or a rebuild's new image tag.
	if err := internal.OnDev(root); err != nil {
		return err
	}
	refs, err := buildWithSecrets(svc, src)
	if err != nil {
		return err
	}
	if exists {
		return redeploy(root, dir, svc, refs)
	}
	if _, err := internal.WriteService(root, svc); err != nil {
		return err
	}
	// Before the push, so OIDC_CLIENT_SECRET is there when ESO first syncs.
	if svc.Auth {
		if err := internal.AppClients(root, dir); err != nil {
			return err
		}
	}
	if err := internal.Publish(root, dir, "feat: add "+svc.Name+" service"); err != nil {
		return err
	}
	fmt.Printf("service %s deploying, run `notch list` to check status\n", svc.Name)
	return nil
}

// redeploy points an existing service at the images just pushed. Same tag
// (source unchanged, e.g. rerun after notch up to restore secrets) = no commit.
func redeploy(root, dir string, svc internal.Service, refs map[string]string) error {
	changed, err := internal.SetImageRefs(filepath.Join(root, dir, "local", "values.yaml"), refs)
	if err != nil {
		return err
	}
	if !changed {
		fmt.Printf("service %s already runs %s\n", svc.Name, svc.Tag)
		return nil
	}
	if err := internal.Publish(root, dir, "chore: deploy "+svc.Name+" "+svc.Tag); err != nil {
		return err
	}
	fmt.Printf("service %s rolling out %s, run `notch list` to check status\n", svc.Name, svc.Tag)
	return nil
}

func buildWithSecrets(svc internal.Service, src string) (map[string]string, error) {
	// Prompt before the slow build so nobody has to babysit it.
	values, err := promptSecrets(svc.Secrets)
	if err != nil {
		return nil, err
	}
	refs, err := build(svc, src)
	if err != nil || len(svc.Secrets) == 0 {
		return refs, err
	}
	return refs, internal.CreateSecret(svc.Name, svc.Secrets, values)
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

// build pushes one image per component, or one for the whole repo, and
// returns image name -> ref.
func build(svc internal.Service, src string) (map[string]string, error) {
	args, err := internal.ParseBuildArgs(addBuildArg)
	if err != nil {
		return nil, err
	}
	if len(svc.Components) == 0 {
		ref := internal.ImageRef(svc.Name, svc.Tag)
		return map[string]string{svc.Name: ref}, internal.BuildAndPush(ref, src, args[""])
	}
	known := map[string]bool{}
	var names []string
	for _, c := range svc.Components {
		known[c.Name] = true
		names = append(names, c.Name)
	}
	for comp := range args {
		if !known[comp] {
			return nil, fmt.Errorf("--build-arg for %q, but the components are %v", comp, names)
		}
	}
	refs := map[string]string{}
	for _, c := range svc.Components {
		image := svc.Name + "-" + c.Name
		refs[image] = internal.ImageRef(image, svc.Tag)
		if err := internal.BuildAndPush(refs[image], c.Dir, args[c.Name]); err != nil {
			return nil, err
		}
	}
	return refs, nil
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
	// No root Dockerfile: a monorepo (frontend/ + backend/) or a Railpack build.
	var comps []internal.Component
	if !internal.HasDockerfile(src) {
		if comps, err = internal.FindComponents(src); err != nil {
			return internal.Service{}, err
		}
	}
	for _, k := range addSecrets {
		if !internal.ValidSecretKey(k) {
			return internal.Service{}, fmt.Errorf("secret %q isn't a valid env var name", k)
		}
	}
	return internal.Service{Name: name, Port: port, Tag: internal.ImageTag(src), Postgres: addPostgres, Auth: addAuth, Secrets: addSecrets, Components: comps}, nil
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
