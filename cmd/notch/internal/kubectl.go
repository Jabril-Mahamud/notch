package internal

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// Kubectl runs kubectl against the notch cluster.
func Kubectl(args ...string) error {
	return Run("kubectl", append([]string{"--context", Context}, args...)...)
}

// KubectlOutput is Kubectl with captured stdout.
func KubectlOutput(args ...string) (string, error) {
	return Output("kubectl", append([]string{"--context", Context}, args...)...)
}

// CreateSecret writes the source Secret the chart's ExternalSecret reads from.
// Values go in on stdin, not argv, so they don't show up in ps.
func CreateSecret(name string, keys, values []string) error {
	c := exec.Command("kubectl", "--context", Context, "-n", "notch-secrets",
		"create", "secret", "generic", name+"-secrets", "--from-env-file=/dev/stdin")
	var env strings.Builder
	for i, k := range keys {
		fmt.Fprintf(&env, "%s=%s\n", k, values[i])
	}
	c.Stdin = strings.NewReader(env.String())
	c.Stdout, c.Stderr = os.Stdout, os.Stderr
	if err := c.Run(); err != nil {
		return fmt.Errorf("create secret %s-secrets: %w", name, err)
	}
	return nil
}
