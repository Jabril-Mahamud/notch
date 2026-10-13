package internal

import (
	"fmt"
	"io/fs"
	"path/filepath"
	"sort"
	"strings"
)

// Component is one buildable directory of a monorepo; each becomes a container.
type Component struct {
	Name string // directory name, also the container name
	Dir  string
	Port int
	Path string // ingress path: "/" for the frontend, "/api" for the backend
}

var (
	frontendNames = map[string]bool{"frontend": true, "web": true, "ui": true, "client": true}
	skipDirs      = map[string]bool{"node_modules": true, ".git": true, "vendor": true, ".venv": true}
)

// FindComponents finds Dockerfiles up to two levels below root (frontend/,
// apps/backend/...). None found is fine: the caller builds the root instead.
// ponytail: one frontend at / plus one backend at /api, the shape of a typical
// full-stack starter. Add a --component flag when an app needs another split.
func FindComponents(root string) ([]Component, error) {
	var cs []Component
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || !d.IsDir() || path == root {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		if skipDirs[d.Name()] || strings.Count(rel, string(filepath.Separator)) > 1 {
			return filepath.SkipDir
		}
		if !HasDockerfile(path) {
			return nil
		}
		port, err := DetectPort(path)
		cs = append(cs, Component{Name: d.Name(), Dir: path, Port: port})
		return err
	})
	if err != nil || len(cs) == 0 {
		return nil, err
	}
	sort.Slice(cs, func(i, j int) bool { return cs[i].Name < cs[j].Name })
	return cs, assignPaths(cs)
}

func assignPaths(cs []Component) error {
	var fe, be []string
	for i := range cs {
		if frontendNames[cs[i].Name] {
			cs[i].Path, fe = "/", append(fe, cs[i].Name)
		} else {
			cs[i].Path, be = "/api", append(be, cs[i].Name)
		}
	}
	if len(fe) != 1 || len(be) != 1 {
		return fmt.Errorf("notch add handles one frontend (%s) plus one backend; found frontends %v, others %v",
			"frontend|web|ui|client", fe, be)
	}
	return nil
}

// ParseBuildArgs splits "component:KEY=VALUE" flags per component; a bare
// "KEY=VALUE" goes to "" (a single-image repo).
func ParseBuildArgs(flags []string) (map[string][]string, error) {
	out := map[string][]string{}
	for _, f := range flags {
		key, val, ok := strings.Cut(f, "=")
		if !ok {
			return nil, fmt.Errorf("build arg %q: want [component:]KEY=VALUE", f)
		}
		comp, key, found := strings.Cut(key, ":")
		if !found {
			comp, key = "", comp
		}
		out[comp] = append(out[comp], key+"="+val)
	}
	return out, nil
}
