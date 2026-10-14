package internal

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"time"
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

// Registry is the notch-registry container (scripts/kind-up.sh). The same
// name works from the host (docker push) and from the node: containerd maps it
// to notch-registry:5000 on the kind network (certs.d/localhost:5001/hosts.toml).
const Registry = "localhost:5001"

func ImageRef(name, tag string) string { return Registry + "/" + name + ":" + tag }

// ImageTag is the source's short commit sha. Tags are immutable, so a new
// commit means a new ref in values.yaml and ArgoCD rolls the pods; no restart.
// Uncommitted changes (or no git) add a timestamp, else two builds share a tag.
func ImageTag(dir string) string {
	stamp := time.Now().UTC().Format("20060102150405")
	sha, err := exec.Command("git", "-C", dir, "rev-parse", "--short", "HEAD").Output()
	if err != nil {
		return "build-" + stamp
	}
	tag := string(sha[:len(sha)-1])
	if dirty, _ := exec.Command("git", "-C", dir, "status", "--porcelain").Output(); len(dirty) > 0 {
		tag += "-" + stamp
	}
	return tag
}

// SetImageRefs points each image's `ref:` line in a values file at a new ref,
// image name -> ref. Line edits, not a re-render, so hand edits survive. Old
// unprefixed refs (hello:local) match too. Reports whether the file changed.
func SetImageRefs(path string, refs map[string]string) (bool, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return false, err
	}
	out := body
	for image, ref := range refs {
		// Anchored on "/" or "ref: " so demo never matches demo-backend.
		re := regexp.MustCompile(`(?m)^(\s*ref:\s*)(?:\S+/)?` + regexp.QuoteMeta(image) + `:\S+$`)
		if !re.Match(out) {
			return false, fmt.Errorf("%s: no image ref for %s", path, image)
		}
		out = re.ReplaceAll(out, []byte("${1}"+ref))
	}
	if string(out) == string(body) {
		return false, nil
	}
	return true, os.WriteFile(path, out, 0o644)
}

// The plan format moves with railpack; keep this in step with mise.toml.
const railpackFrontend = "ghcr.io/railwayapp/railpack-frontend:v0.40.1"

// BuildAndPush builds ref and pushes it to the notch registry, where the
// cluster pulls it like any cloud registry. buildArgs are KEY=VALUE,
// Dockerfile builds only.
func BuildAndPush(ref, dir string, buildArgs []string) error {
	var err error
	switch {
	case HasDockerfile(dir):
		err = dockerBuild(ref, dir, buildArgs)
	case len(buildArgs) > 0:
		err = fmt.Errorf("--build-arg needs a Dockerfile in %s; Railpack builds take none", dir)
	default:
		err = railpackBuild(ref, dir)
	}
	if err != nil {
		return err
	}
	if err := Run("docker", "push", ref); err != nil {
		return fmt.Errorf("%w (is notch-registry running? notch up starts it)", err)
	}
	return nil
}

func dockerBuild(ref, dir string, buildArgs []string) error {
	args := []string{"build", "-t", ref}
	for _, a := range buildArgs {
		args = append(args, "--build-arg", a)
	}
	return Run("docker", append(args, dir)...)
}

// railpackBuild detects the stack and start command, then builds through
// Railpack's BuildKit frontend. ponytail: chosen over Cloud Native Buildpacks
// because pack can't export into Docker's containerd image store; this is
// plain buildx, so it works wherever docker build does.
func railpackBuild(ref, dir string) error {
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
	return Run("docker", "buildx", "build", "--load", "-t", ref,
		"--build-arg", "BUILDKIT_SYNTAX="+railpackFrontend, "-f", plan, dir)
}
