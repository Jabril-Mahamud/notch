#!/usr/bin/env bash
set -euo pipefail
# Live kuttl suite: needs a running cluster (`notch up`) with hello deployed.
# Static checks live in the other tests/*.sh; this one talks to the cluster.
cd "$(dirname "$0")/.."

KUTTL=${KUTTL:-kubectl-kuttl}
command -v "$KUTTL" >/dev/null || { echo "kuttl not found: run mise install in the repo, or set KUTTL" >&2; exit 1; }
kubectl config current-context | grep -qx kind-notch || { echo "current context is not kind-notch" >&2; exit 1; }

exec "$KUTTL" test --config tests/e2e/kuttl-test.yaml
