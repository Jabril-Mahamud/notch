#!/usr/bin/env bash
set -euo pipefail
# Static checks for TLS: cert-manager addon, the notch-ca ClusterIssuer, and the
# CA that kind-up.sh creates. Needs yq (the jq wrapper). Never talks to a cluster.
cd "$(dirname "$0")/.."

FAILED=0
check() { # description jq-expr file
  if yq -s -e "$2" "$3" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; FAILED=1; fi
}
grep_check() { # description pattern file
  if grep -qE -- "$2" "$3"; then echo "ok   $1"; else echo "FAIL $1"; FAILED=1; fi
}

APP=addons/cert-manager.yaml
check "cert-manager from jetstack, pinned" \
  '.[0].spec.source.repoURL == "https://charts.jetstack.io" and .[0].spec.source.chart == "cert-manager" and (.[0].spec.source.targetRevision | test("^v[0-9]"))' "$APP"
check "cert-manager installs its CRDs" '.[0].spec.source.helm.valuesObject.crds.enabled == true' "$APP"
check "cert-manager at wave 2, before services" '.[0].metadata.annotations["argocd.argoproj.io/sync-wave"] == "2"' "$APP"

ISSUER=addons/cert-manager-issuer.yaml
check "ClusterIssuer notch-ca signs with the notch-ca secret" \
  '.[0].kind == "ClusterIssuer" and .[0].metadata.name == "notch-ca" and .[0].spec.ca.secretName == "notch-ca"' "$ISSUER"
check "issuer after the CRDs (wave 3)" '.[0].metadata.annotations["argocd.argoproj.io/sync-wave"] == "3"' "$ISSUER"

grep_check "kind-up creates the CA once, outside the repo" 'NOTCH_HOME/ca/ca\.crt' scripts/kind-up.sh
grep_check "CA is a CA (basicConstraints)" 'basicConstraints=critical,CA:TRUE' scripts/kind-up.sh
grep_check "kind-up loads it as the notch-ca secret in cert-manager" \
  'cert-manager create secret tls notch-ca' scripts/kind-up.sh

exit $FAILED
