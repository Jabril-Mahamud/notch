package internal

import (
	"strings"
	"testing"
)

func TestFormatList(t *testing.T) {
	apps := "hello\tSynced\tHealthy\nroot\tOutOfSync\t\n"
	ingresses := "hello/hello hello.notch.localhost\nmisc/grafana grafana.localhost\nmisc/prom prom.localhost\n"
	out := FormatList(apps, ingresses)

	for _, want := range []string{
		"https://hello.notch.localhost",
		"OutOfSync",
		"misc/grafana",
		"https://grafana.localhost",
		"https://prom.localhost",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if strings.Count(out, "hello.notch.localhost") != 1 {
		t.Errorf("argo-managed ingress listed twice:\n%s", out)
	}
}

func TestFormatListEmpty(t *testing.T) {
	if out := FormatList("", ""); !strings.Contains(out, "NAME") {
		t.Errorf("want header even with no apps:\n%s", out)
	}
}
