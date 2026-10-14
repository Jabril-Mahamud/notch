package internal

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"text/tabwriter"
)

// Kubectl runs kubectl against the notch cluster.
func Kubectl(args ...string) error {
	return Run("kubectl", append([]string{"--context", Context}, args...)...)
}

// KubectlOutput is Kubectl with captured stdout.
func KubectlOutput(args ...string) (string, error) {
	return Output("kubectl", append([]string{"--context", Context}, args...)...)
}

// CreateSecret writes (or overwrites) the source Secret the chart's
// ExternalSecret reads from. Rendered client-side then applied, so rerunning
// notch add rotates values instead of failing on "already exists".
// Values go in on stdin, not argv, so they don't show up in ps.
func CreateSecret(name string, keys, values []string) error {
	var env strings.Builder
	for i, k := range keys {
		fmt.Fprintf(&env, "%s=%s\n", k, values[i])
	}
	render := exec.Command("kubectl", "-n", "notch-secrets", "create", "secret", "generic",
		name+"-secrets", "--from-env-file=/dev/stdin", "--dry-run=client", "-o", "yaml")
	render.Stdin, render.Stderr = strings.NewReader(env.String()), os.Stderr
	manifest, err := render.Output()
	if err != nil {
		return fmt.Errorf("render secret %s-secrets: %w", name, err)
	}
	apply := exec.Command("kubectl", "--context", Context, "apply", "-f", "-")
	apply.Stdin, apply.Stdout, apply.Stderr = strings.NewReader(string(manifest)), os.Stdout, os.Stderr
	if err := apply.Run(); err != nil {
		return fmt.Errorf("apply secret %s-secrets: %w", name, err)
	}
	return nil
}

const (
	appsJSONPath    = `{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}`
	ingressJSONPath = `{range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.rules[0].host}{"\n"}{end}`
)

// List returns ArgoCD apps and every ingress in the cluster, as table text.
func List() (string, error) {
	apps, err := KubectlOutput("-n", "argocd", "get", "applications", "-o", "jsonpath="+appsJSONPath)
	if err != nil {
		return "", err
	}
	ingresses, err := KubectlOutput("get", "ingress", "-A", "-o", "jsonpath="+ingressJSONPath)
	if err != nil {
		return "", err
	}
	return FormatList(apps, ingresses), nil
}

// FormatList joins apps to ingresses by namespace: the chart puts each
// service in a namespace named after it. Unmatched ingresses list separately.
func FormatList(apps, ingresses string) string {
	urls := map[string]string{}
	var other [][3]string // ref, namespace, url
	for _, line := range lines(ingresses) {
		ref, host, _ := strings.Cut(line, " ")
		ns, _, _ := strings.Cut(ref, "/")
		urls[ns] = url(host)
		other = append(other, [3]string{ref, ns, url(host)})
	}

	var b strings.Builder
	w := tabwriter.NewWriter(&b, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "NAME\tSYNC\tHEALTH\tURL")
	seen := map[string]bool{}
	for _, line := range lines(apps) {
		f := append(strings.Split(line, "\t"), "", "")
		seen[f[0]] = true
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", f[0], dash(f[1]), dash(f[2]), dash(urls[f[0]]))
	}
	w.Flush()

	w = tabwriter.NewWriter(&b, 0, 4, 2, ' ', 0)
	header := false
	for _, o := range other {
		if seen[o[1]] {
			continue
		}
		if !header {
			fmt.Fprintln(w, "\nNON-ARGO INGRESS\tURL")
			header = true
		}
		fmt.Fprintf(w, "%s\t%s\n", o[0], dash(o[2]))
	}
	w.Flush()
	return b.String()
}

func lines(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return r == '\n' })
}

func url(host string) string {
	if host == "" {
		return ""
	}
	// Every chart Ingress has TLS (cert-manager); kind.yaml maps 127.0.0.1:443.
	return "https://" + host
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// Logs follows the service's Deployment; the chart names both after the service.
func Logs(service string) error {
	return Kubectl("-n", service, "logs", "deploy/"+service, "-f")
}
