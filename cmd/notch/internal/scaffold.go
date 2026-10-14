package internal

import (
	"embed"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// all: keeps dotfiles (.gitignore, public/.gitkeep). Without it embed drops
// them, git never sees public/, and the Next.js Dockerfile's COPY fails.
//
//go:embed all:templates/fastapi-nextjs
var starter embed.FS

const starterRoot = "templates/fastapi-nextjs"

// Scaffold writes the FastAPI + Next.js starter into dir, with __NAME__
// replaced. ponytail: one stack; add a --stack flag and a folder per stack
// when there's a second one.
func Scaffold(dir, name string) error {
	if _, err := os.Stat(dir); err == nil {
		return fmt.Errorf("%s already exists", dir)
	}
	return fs.WalkDir(starter, starterRoot, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		body, err := starter.ReadFile(path)
		if err != nil {
			return err
		}
		out := filepath.Join(dir, strings.TrimPrefix(path, starterRoot+"/"))
		if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
			return err
		}
		return os.WriteFile(out, []byte(strings.ReplaceAll(string(body), "__NAME__", name)), 0o644)
	})
}
