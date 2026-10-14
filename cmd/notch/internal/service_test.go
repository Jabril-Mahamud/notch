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

// Starters off GitHub often ship no Dockerfile: the stack still picks the port.
func TestDetectPortWithoutDockerfile(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "package.json", "{}")
	if p, err := DetectPort(dir); p != 3000 || err != nil {
		t.Errorf("port = %d, %v; want 3000", p, err)
	}
}

func TestHasDockerfile(t *testing.T) {
	dir := t.TempDir()
	if HasDockerfile(dir) {
		t.Error("empty dir has no Dockerfile")
	}
	write(t, dir, "Dockerfile", "FROM scratch\n")
	if !HasDockerfile(dir) {
		t.Error("want Dockerfile found")
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
	dir, err := WriteService(root, Service{Name: "hello", Port: 8000, Tag: "abc1234", Postgres: true, Secrets: []string{"APP_JWT_SECRET"}})
	if err != nil {
		t.Fatal(err)
	}
	svc, _ := os.ReadFile(filepath.Join(dir, "service.yaml"))
	vals, _ := os.ReadFile(filepath.Join(dir, "local", "values.yaml"))
	// PORT: buildpack-style starters listen on $PORT, not a fixed port.
	for _, want := range []string{"name: hello", "port: 8000", "postgres: true", "- APP_JWT_SECRET", "- name: PORT\n            value: \"8000\""} {
		if !strings.Contains(string(svc), want) {
			t.Errorf("service.yaml missing %q:\n%s", want, svc)
		}
	}
	for _, want := range []string{"hello.notch.localhost:8080", "ref: localhost:5001/hello:abc1234"} {
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
	mono := Service{Name: "mono", Tag: "abc1234", Postgres: true, Components: []Component{
		{Name: "backend", Port: 8001, Path: "/api"}, {Name: "frontend", Port: 3001, Path: "/"}}}
	for _, s := range []Service{{Name: "plain", Port: 3000, Tag: "abc1234"}, {Name: "full", Port: 8000, Tag: "abc1234", Postgres: true, Secrets: []string{"A", "B"}}, mono} {
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

func TestWriteServiceComponents(t *testing.T) {
	dir, err := WriteService(t.TempDir(), Service{Name: "journal", Tag: "abc1234", Components: []Component{
		{Name: "backend", Port: 8001, Path: "/api"}, {Name: "frontend", Port: 3001, Path: "/"}}})
	if err != nil {
		t.Fatal(err)
	}
	svc, _ := os.ReadFile(filepath.Join(dir, "service.yaml"))
	vals, _ := os.ReadFile(filepath.Join(dir, "local", "values.yaml"))
	for _, want := range []string{"name: http-backend", "path: /api", "targetPort: frontend", "containerPort: 3001", "value: \"8001\""} {
		if !strings.Contains(string(svc), want) {
			t.Errorf("service.yaml missing %q:\n%s", want, svc)
		}
	}
	for _, want := range []string{"ref: localhost:5001/journal-backend:abc1234", "ref: localhost:5001/journal-frontend:abc1234"} {
		if !strings.Contains(string(vals), want) {
			t.Errorf("values.yaml missing %q:\n%s", want, vals)
		}
	}
}

// Staging deploys what main has, so a new service needs its overlay from day one.
func TestWriteServiceStagingOverlay(t *testing.T) {
	dir, err := WriteService(t.TempDir(), Service{Name: "hello", Port: 8000, Tag: "abc1234"})
	if err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(dir, "staging", "values.yaml"))
	if !strings.Contains(string(got), "- hello.staging.notch.localhost:8443") || strings.Contains(string(got), "ref:") {
		t.Errorf("staging overlay should set only the staging host:\n%s", got)
	}
}
