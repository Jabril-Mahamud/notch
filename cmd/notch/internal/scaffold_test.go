package internal

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestScaffold(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "todo")
	if err := Scaffold(dir, "todo"); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{
		"backend/Dockerfile", "backend/app/main.py", "backend/requirements.txt",
		"frontend/Dockerfile", "frontend/package.json", "frontend/app/page.tsx",
		// git drops empty dirs and embed drops dotfiles without all:, which is
		// how a Next.js Dockerfile ends up copying a public/ that isn't there.
		"frontend/public/.gitkeep",
		".gitignore", "README.md",
	} {
		if _, err := os.Stat(filepath.Join(dir, f)); err != nil {
			t.Errorf("missing %s", f)
		}
	}
	readme, _ := os.ReadFile(filepath.Join(dir, "README.md"))
	if !strings.Contains(string(readme), "# todo") || strings.Contains(string(readme), "__NAME__") {
		t.Errorf("README not rendered for todo:\n%s", readme)
	}
}

// The scaffold must be something notch add builds as a monorepo, no flags needed.
func TestScaffoldIsAMonorepo(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "todo")
	if err := Scaffold(dir, "todo"); err != nil {
		t.Fatal(err)
	}
	cs, err := FindComponents(dir)
	if err != nil || len(cs) != 2 || cs[0].Path != "/api" || cs[1].Path != "/" {
		t.Errorf("components = %+v, %v; want backend /api + frontend /", cs, err)
	}
}

func TestScaffoldRefusesExisting(t *testing.T) {
	dir := t.TempDir()
	if err := Scaffold(dir, "todo"); err == nil {
		t.Error("want error when the target dir exists")
	}
}
