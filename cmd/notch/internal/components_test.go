package internal

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func mkdocker(t *testing.T, root, dir, expose string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(root, dir), "Dockerfile", "FROM scratch\nEXPOSE "+expose+"\n")
}

func names(cs []Component) []string {
	var out []string
	for _, c := range cs {
		out = append(out, c.Name+" "+c.Path)
	}
	return out
}

// journalist layout: frontend/ + backend/ at the root.
func TestFindComponentsTopLevel(t *testing.T) {
	root := t.TempDir()
	mkdocker(t, root, "frontend", "3001")
	mkdocker(t, root, "backend", "8001")
	cs, err := FindComponents(root)
	if err != nil {
		t.Fatal(err)
	}
	if got := names(cs); !reflect.DeepEqual(got, []string{"backend /api", "frontend /"}) {
		t.Errorf("components = %v", got)
	}
	if cs[0].Port != 8001 || cs[1].Port != 3001 {
		t.Errorf("ports = %d, %d; want 8001, 3001", cs[0].Port, cs[1].Port)
	}
}

// Burdens layout: apps/frontend + apps/backend; node_modules never counts.
func TestFindComponentsNested(t *testing.T) {
	root := t.TempDir()
	mkdocker(t, root, "apps/frontend", "3000")
	mkdocker(t, root, "apps/backend", "8000")
	mkdocker(t, root, "apps/frontend/node_modules/x", "1")
	cs, err := FindComponents(root)
	if err != nil {
		t.Fatal(err)
	}
	if got := names(cs); !reflect.DeepEqual(got, []string{"backend /api", "frontend /"}) {
		t.Errorf("components = %v", got)
	}
}

func TestFindComponentsNoneIsNotAnError(t *testing.T) {
	if cs, err := FindComponents(t.TempDir()); err != nil || len(cs) != 0 {
		t.Errorf("got %v, %v; want none", cs, err)
	}
}

func TestFindComponentsNeedsOneFrontendOneBackend(t *testing.T) {
	root := t.TempDir()
	mkdocker(t, root, "api", "8000")
	mkdocker(t, root, "worker", "9000")
	if _, err := FindComponents(root); err == nil {
		t.Error("want error without a frontend")
	}
}

func TestParseBuildArgs(t *testing.T) {
	got, err := ParseBuildArgs([]string{"frontend:NEXT_PUBLIC_API_URL=/api", "frontend:URL=http://x:1", "TOKEN=abc"})
	if err != nil {
		t.Fatal(err)
	}
	want := map[string][]string{"frontend": {"NEXT_PUBLIC_API_URL=/api", "URL=http://x:1"}, "": {"TOKEN=abc"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
	if _, err := ParseBuildArgs([]string{"novalue"}); err == nil {
		t.Error("want error without =")
	}
}
