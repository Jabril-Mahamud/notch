#!/usr/bin/env bash
set -euo pipefail
# Live kuttl suite: needs `notch up` and `notch up staging`, with hello deployed.
# Static checks live in the other tests/*.sh; this one talks to the cluster.
cd "$(dirname "$0")/.."

KUTTL=${KUTTL:-kubectl-kuttl}
command -v "$KUTTL" >/dev/null || { echo "kuttl not found: run mise install in the repo, or set KUTTL" >&2; exit 1; }
kubectl config current-context | grep -qx kind-notch || { echo "current context is not kind-notch" >&2; exit 1; }
kind get clusters | grep -qx notch-staging || { echo "no staging cluster: notch up staging (tests/e2e/staging)" >&2; exit 1; }

exec "$KUTTL" test --config tests/e2e/kuttl-test.yaml
