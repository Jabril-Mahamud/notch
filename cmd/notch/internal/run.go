package internal

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Run executes a command with the terminal attached, so long steps stream.
func Run(name string, args ...string) error {
	return RunIn("", name, args...)
}

// RunIn is Run with a working directory.
func RunIn(dir, name string, args ...string) error {
	c := exec.Command(name, args...)
	c.Dir = dir
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := c.Run(); err != nil {
		return fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), err)
	}
	return nil
}

// Output executes a command and returns its trimmed stdout.
func Output(name string, args ...string) (string, error) {
	c := exec.Command(name, args...)
	c.Stderr = os.Stderr
	out, err := c.Output()
	if err != nil {
		return "", fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), err)
	}
	return strings.TrimSpace(string(out)), nil
}

// RepoRoot finds the notch repo from the current directory. up and add need
// it for scripts/ and services/, wherever the binary was installed.
func RepoRoot() (string, error) {
	root, err := Output("git", "rev-parse", "--show-toplevel")
	if err == nil {
		if _, err = os.Stat(filepath.Join(root, "platform.yaml")); err == nil {
			return root, nil
		}
	}
	return "", fmt.Errorf("run notch from inside the notch repo")
}
