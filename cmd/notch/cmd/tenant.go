package cmd

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/Jabril-Mahamud/notch/cmd/notch/internal"
)

var tenantCmd = &cobra.Command{
	Use:   "tenant",
	Short: "Manage tenants: isolated namespaces with RBAC, quotas and network policies",
}

var tenantCreateCmd = &cobra.Command{
	Use:   "create <name>",
	Short: "Create a tenant and write its scoped kubeconfig (rerun to refresh the token)",
	Args:  cobra.ExactArgs(1),
	RunE:  runTenantCreate,
}

func init() {
	tenantCmd.AddCommand(tenantCreateCmd)
	rootCmd.AddCommand(tenantCmd)
}

func runTenantCreate(cmd *cobra.Command, args []string) error {
	name := args[0]
	root, err := internal.RepoRoot()
	if err != nil {
		return err
	}
	if err := ensureTenant(root, name); err != nil {
		return err
	}
	if err := internal.WaitForTenant(name); err != nil {
		return err
	}
	cfg, err := internal.TenantKubeconfig(name)
	if err != nil {
		return err
	}
	// *.kubeconfig is gitignored: this file holds a live token.
	path := filepath.Join(root, name+".kubeconfig")
	if err := os.WriteFile(path, []byte(cfg), 0o600); err != nil {
		return err
	}
	fmt.Printf("tenant %s ready, token valid 24h:\n  export KUBECONFIG=%s\n", name, path)
	return nil
}

// ensureTenant writes and pushes tenants/<name>/ unless it's already there.
func ensureTenant(root, name string) error {
	if _, err := os.Stat(filepath.Join(root, "tenants", name)); err == nil {
		fmt.Printf("tenant %s exists, refreshing its kubeconfig\n", name)
		return nil
	}
	if err := internal.OnDev(root); err != nil {
		return err
	}
	if _, err := internal.WriteTenant(root, name); err != nil {
		return err
	}
	return internal.Publish(root, filepath.Join("tenants", name), "feat: add "+name+" tenant")
}
