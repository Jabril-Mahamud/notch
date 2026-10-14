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

// Up runs kind-up.sh, which is idempotent and prints the ArgoCD/app URLs itself.
func Up(root string) error {
	return RunIn(root, filepath.Join(root, "scripts", "kind-up.sh"))
}

func Down() error {
	return Run("kind", "delete", "cluster", "--name", Cluster)
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
	return Up(root)
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
