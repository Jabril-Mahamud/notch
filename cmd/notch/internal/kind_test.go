package internal

import "testing"

func TestClusterFor(t *testing.T) {
	for env, want := range map[string]string{"dev": "notch", "staging": "notch-staging"} {
		if got, err := ClusterFor(env); got != want || err != nil {
			t.Errorf("ClusterFor(%q) = %q, %v; want %q", env, got, err, want)
		}
	}
	if _, err := ClusterFor("prod"); err == nil {
		t.Error("want error for an env kind-up doesn't know")
	}
}
