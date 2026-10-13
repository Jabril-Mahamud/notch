package internal

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// Clone shallow-clones a repo into a temp dir; the caller removes it.
func Clone(url string) (string, error) {
	dir, err := os.MkdirTemp("", "notch-src-")
	if err != nil {
		return "", err
	}
	if err := Run("git", "clone", "--depth", "1", url, dir); err != nil {
		os.RemoveAll(dir)
		return "", err
	}
	return dir, nil
}

func ImageRef(name string) string { return name + ":local" }

// The plan format moves with railpack; keep this in step with mise.toml.
const railpackFrontend = "ghcr.io/railwayapp/railpack-frontend:v0.40.1"

// BuildAndLoad builds <name>:local and side-loads it: Kind nodes can't pull
// from the host's docker daemon. buildArgs are KEY=VALUE, Dockerfile builds only.
func BuildAndLoad(name, dir string, buildArgs []string) error {
	var err error
	switch {
	case HasDockerfile(dir):
		err = dockerBuild(name, dir, buildArgs)
	case len(buildArgs) > 0:
		err = fmt.Errorf("--build-arg needs a Dockerfile in %s; Railpack builds take none", dir)
	default:
		err = railpackBuild(name, dir)
	}
	if err != nil {
		return err
	}
	return Run("kind", "load", "docker-image", ImageRef(name), "--name", Cluster)
}

func dockerBuild(name, dir string, buildArgs []string) error {
	args := []string{"build", "-t", ImageRef(name)}
	for _, a := range buildArgs {
		args = append(args, "--build-arg", a)
	}
	return Run("docker", append(args, dir)...)
}

// railpackBuild detects the stack and start command, then builds through
// Railpack's BuildKit frontend. ponytail: chosen over Cloud Native Buildpacks
// because pack can't export into Docker's containerd image store; this is
// plain buildx, so it works wherever docker build does.
func railpackBuild(name, dir string) error {
	if _, err := exec.LookPath("railpack"); err != nil {
		return fmt.Errorf("no Dockerfile in %s and railpack isn't installed: run `mise install` in the notch repo", dir)
	}
	// Plan goes to a temp dir so a local source tree isn't touched.
	tmp, err := os.MkdirTemp("", "notch-plan-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	plan := filepath.Join(tmp, "railpack-plan.json")
	if err := Run("railpack", "prepare", dir, "--plan-out", plan); err != nil {
		return err
	}
	return Run("docker", "buildx", "build", "--load", "-t", ImageRef(name),
		"--build-arg", "BUILDKIT_SYNTAX="+railpackFrontend, "-f", plan, dir)
}
