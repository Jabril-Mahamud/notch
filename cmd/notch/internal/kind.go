package internal

import (
	"fmt"
	"os/exec"
	"path/filepath"
	"time"
)

const (
	Cluster = "notch"
	// Kind names the single node container <cluster>-control-plane (kind.yaml).
	Node = Cluster + "-control-plane"
	// kubectl calls pin the context so a paused notch never hits another cluster.
	Context = "kind-" + Cluster
)

// ClusterFor maps an environment to its Kind cluster (scripts/kind-up.sh).
func ClusterFor(env string) (string, error) {
	switch env {
	case "dev":
		return Cluster, nil
	case "staging":
		return Cluster + "-staging", nil
	}
	return "", fmt.Errorf("unknown environment %q (dev or staging)", env)
}

// Up runs kind-up.sh for env, which is idempotent and prints its URLs itself.
func Up(root, env string) error {
	if _, err := ClusterFor(env); err != nil {
		return err
	}
	return RunIn(root, filepath.Join(root, "scripts", "kind-up.sh"), env)
}

// Down deletes env's cluster. Dropping staging leaves its ArgoCD cluster
// secret in dev; kind-up rewrites it on the next notch up staging.
func Down(env string) error {
	name, err := ClusterFor(env)
	if err != nil {
		return err
	}
	return Run("kind", "delete", "cluster", "--name", name)
}

// Pause stops the node container: state survives, CPU and RAM come back.
func Pause() error {
	return Run("docker", "stop", Node)
}

// Resume starts the node, then reruns kind-up.sh: docker start resets the
// node's /etc/hosts, which the apiserver needs to reach the OIDC issuer.
func Resume(root string) error {
	if err := Run("docker", "start", Node); err != nil {
		return err
	}
	if err := waitAPI(time.Minute); err != nil {
		return err
	}
	if err := Kubectl("wait", "--for=condition=Ready", "node", "--all", "--timeout=120s"); err != nil {
		return err
	}
	return Up(root, "dev")
}

// waitAPI polls the API server: kubectl wait fails outright (connection
// refused) if called before the restarted apiserver is listening.
func waitAPI(timeout time.Duration) error {
	for end := time.Now().Add(timeout); time.Now().Before(end); time.Sleep(2 * time.Second) {
		if exec.Command("kubectl", "--context", Context, "get", "--raw", "/readyz").Run() == nil {
			return nil
		}
	}
	return fmt.Errorf("api server not reachable after %s", timeout)
}
