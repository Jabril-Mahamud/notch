package internal

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"testing"
)

func TestImageRef(t *testing.T) {
	if got := ImageRef("hello", "abc1234"); got != "localhost:5001/hello:abc1234" {
		t.Errorf("ImageRef = %q", got)
	}
}

func gitRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	write(t, dir, "app.py", "print(1)\n")
	for _, args := range [][]string{
		{"init", "-q"}, {"add", "."},
		{"-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"},
	} {
		if out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	return dir
}

func TestImageTagCleanRepoIsSha(t *testing.T) {
	dir := gitRepo(t)
	sha, _ := Output("git", "-C", dir, "rev-parse", "--short", "HEAD")
	if got := ImageTag(dir); got != sha {
		t.Errorf("ImageTag = %q, want %q", got, sha)
	}
}

// Same sha with different content would reuse a tag: dirty trees get a timestamp.
func TestImageTagDirtyRepoIsUnique(t *testing.T) {
	dir := gitRepo(t)
	write(t, dir, "app.py", "print(2)\n")
	sha, _ := Output("git", "-C", dir, "rev-parse", "--short", "HEAD")
	if got := ImageTag(dir); !regexp.MustCompile(`^` + sha + `-\d{14}$`).MatchString(got) {
		t.Errorf("ImageTag = %q, want %s-<timestamp>", got, sha)
	}
}

func TestImageTagWithoutGit(t *testing.T) {
	if got := ImageTag(t.TempDir()); !regexp.MustCompile(`^build-\d{14}$`).MatchString(got) {
		t.Errorf("ImageTag = %q, want build-<timestamp>", got)
	}
}

func TestSetImageRefs(t *testing.T) {
	path := filepath.Join(t.TempDir(), "values.yaml")
	before := `service:
  deployment:
    containers:
      backend:
        image:
          ref: demo-backend:local
        env:
          - name: KEEP
            value: me
      frontend:
        image:
          ref: localhost:5001/demo-frontend:old
`
	write(t, filepath.Dir(path), "values.yaml", before)
	changed, err := SetImageRefs(path, map[string]string{
		"demo-backend":  "localhost:5001/demo-backend:new",
		"demo-frontend": "localhost:5001/demo-frontend:new",
	})
	if err != nil || !changed {
		t.Fatalf("SetImageRefs = %v, %v", changed, err)
	}
	got, _ := os.ReadFile(path)
	want := regexp.MustCompile(`ref: localhost:5001/demo-backend:new\n        env:\n          - name: KEEP\n            value: me\n[\s\S]*ref: localhost:5001/demo-frontend:new\n$`)
	if !want.Match(got) {
		t.Errorf("values.yaml:\n%s", got)
	}
}

func TestSetImageRefsUnchanged(t *testing.T) {
	path := filepath.Join(t.TempDir(), "values.yaml")
	write(t, filepath.Dir(path), "values.yaml", "ref: localhost:5001/hello:abc\n")
	if changed, err := SetImageRefs(path, map[string]string{"hello": "localhost:5001/hello:abc"}); changed || err != nil {
		t.Errorf("SetImageRefs = %v, %v; want no change", changed, err)
	}
}

// "demo" must not rewrite "demo-backend", or a monorepo's refs cross.
func TestSetImageRefsMatchesWholeName(t *testing.T) {
	path := filepath.Join(t.TempDir(), "values.yaml")
	write(t, filepath.Dir(path), "values.yaml", "ref: demo-backend:local\n")
	if _, err := SetImageRefs(path, map[string]string{"demo": "localhost:5001/demo:x"}); err == nil {
		t.Error("want error: no ref for image demo")
	}
}
