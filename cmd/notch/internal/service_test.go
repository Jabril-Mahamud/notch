package internal

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestNameFrom(t *testing.T) {
	cases := map[string]string{
		"https://github.com/acme/My_App.git": "my-app",
		"git@github.com:acme/hello.git":      "hello",
		"./apps/web/":                        "web",
		"/src/api.v2":                        "api-v2",
	}
	for src, want := range cases {
		got, err := NameFrom(src)
		if err != nil || got != want {
			t.Errorf("NameFrom(%q) = %q, %v; want %q", src, got, err, want)
		}
	}
}

func TestNameFromDot(t *testing.T) {
	// Tests run in the package dir, so "." is .../internal.
	if got, err := NameFrom("."); got != "internal" {
		t.Errorf("NameFrom(\".\") = %q, %v; want internal", got, err)
	}
}

func TestNameFromRejectsInvalid(t *testing.T) {
	if _, err := NameFrom("/src/-bad-"); err == nil {
		t.Error("want error for name that isn't a DNS label")
	}
}

func TestIsRemote(t *testing.T) {
	for src, want := range map[string]bool{
		"https://github.com/a/b": true, "git@github.com:a/b.git": true, "./b": false, "/abs/b": false,
	} {
		if IsRemote(src) != want {
			t.Errorf("IsRemote(%q) != %v", src, want)
		}
	}
}

func TestDetectPortNeedsDockerfile(t *testing.T) {
	if _, err := DetectPort(t.TempDir()); err == nil {
		t.Error("want error without Dockerfile")
	}
}

func TestDetectPortFromExpose(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "Dockerfile", "FROM python\n  expose 9000/tcp\n")
	write(t, dir, "package.json", "{}")
	if p, _ := DetectPort(dir); p != 9000 {
		t.Errorf("port = %d, want 9000", p)
	}
}

func TestDetectPortFromStack(t *testing.T) {
	for marker, want := range map[string]int{"package.json": 3000, "requirements.txt": 8000, "pyproject.toml": 8000, "go.mod": 8080, "Cargo.toml": 8080} {
		dir := t.TempDir()
		write(t, dir, "Dockerfile", "FROM scratch\n")
		write(t, dir, marker, "")
		if p, _ := DetectPort(dir); p != want {
			t.Errorf("%s: port = %d, want %d", marker, p, want)
		}
	}
}

func TestValidSecretKey(t *testing.T) {
	if !ValidSecretKey("APP_JWT_SECRET") || ValidSecretKey("bad-key") || ValidSecretKey("1X") {
		t.Error("secret keys must be env var names")
	}
}

func TestWriteService(t *testing.T) {
	root := t.TempDir()
	dir, err := WriteService(root, Service{Name: "hello", Port: 8000, Postgres: true, Secrets: []string{"APP_JWT_SECRET"}})
	if err != nil {
		t.Fatal(err)
	}
	svc, _ := os.ReadFile(filepath.Join(dir, "service.yaml"))
	vals, _ := os.ReadFile(filepath.Join(dir, "local", "values.yaml"))
	for _, want := range []string{"name: hello", "port: 8000", "postgres: true", "- APP_JWT_SECRET"} {
		if !strings.Contains(string(svc), want) {
			t.Errorf("service.yaml missing %q:\n%s", want, svc)
		}
	}
	for _, want := range []string{"hello.notch.localhost:8080", "ref: hello:local"} {
		if !strings.Contains(string(vals), want) {
			t.Errorf("values.yaml missing %q:\n%s", want, vals)
		}
	}
}

func TestWriteServiceRefusesExisting(t *testing.T) {
	root := t.TempDir()
	s := Service{Name: "hello", Port: 8000}
	if _, err := WriteService(root, s); err != nil {
		t.Fatal(err)
	}
	if _, err := WriteService(root, s); err == nil {
		t.Error("want error when services/hello exists")
	}
}

// The generated files are only useful if the chart accepts them.
func TestWriteServiceRendersWithChart(t *testing.T) {
	if _, err := exec.LookPath("helm"); err != nil {
		t.Skip("helm not installed")
	}
	for _, s := range []Service{{Name: "plain", Port: 3000}, {Name: "full", Port: 8000, Postgres: true, Secrets: []string{"A", "B"}}} {
		dir, err := WriteService(t.TempDir(), s)
		if err != nil {
			t.Fatal(err)
		}
		out, err := exec.Command("helm", "template", s.Name, "../../../charts/notch-service",
			"-f", filepath.Join(dir, "service.yaml"), "-f", filepath.Join(dir, "local", "values.yaml")).CombinedOutput()
		if err != nil {
			t.Fatalf("%s: helm template: %v\n%s", s.Name, err, out)
		}
	}
}
