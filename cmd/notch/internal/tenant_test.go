package internal

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteTenant(t *testing.T) {
	dir, err := WriteTenant(t.TempDir(), "team-gamma")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := os.ReadFile(filepath.Join(dir, "platform.yaml"))
	if !strings.Contains(string(body), "tenant:\n  name: team-gamma\n") {
		t.Errorf("platform.yaml = %q; want tenant.name team-gamma", body)
	}
}

func TestWriteTenantRejectsInvalidName(t *testing.T) {
	if _, err := WriteTenant(t.TempDir(), "Team_Gamma"); err == nil {
		t.Error("want error for name that isn't a DNS label")
	}
}

func TestWriteTenantRefusesExisting(t *testing.T) {
	root := t.TempDir()
	if _, err := WriteTenant(root, "team-gamma"); err != nil {
		t.Fatal(err)
	}
	if _, err := WriteTenant(root, "team-gamma"); err == nil {
		t.Error("want error when the tenant already exists")
	}
}

func TestKubeconfig(t *testing.T) {
	out := Kubeconfig("team-gamma", "https://127.0.0.1:6443", "Q0E=", "/home/x/.config/notch/ca/ca.crt")
	for _, want := range []string{
		"server: https://127.0.0.1:6443",
		"certificate-authority-data: Q0E=",
		// A Keycloak login via kubelogin, not a stored token: the file holds no secret.
		"command: kubelogin",
		"- --oidc-issuer-url=https://keycloak.notch.localhost/realms/notch",
		"- --oidc-client-id=kubernetes",
		"- --certificate-authority=/home/x/.config/notch/ca/ca.crt",
		// Default namespace: plain `kubectl get pods` lands in the tenant's own.
		"namespace: team-gamma",
		"current-context: notch-team-gamma",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("kubeconfig missing %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "token:") {
		t.Errorf("kubeconfig must not carry a token:\n%s", out)
	}
}
