package internal

import "os"

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

// BuildAndLoad builds the image and side-loads it: Kind nodes can't pull from
// the host's docker daemon.
func BuildAndLoad(name, dir string) error {
	if err := Run("docker", "build", "-t", ImageRef(name), dir); err != nil {
		return err
	}
	return Run("kind", "load", "docker-image", ImageRef(name), "--name", Cluster)
}
