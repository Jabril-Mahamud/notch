#!/usr/bin/env bash
set -euo pipefail
# Static checks for the notch-secrets ClusterSecretStore and its RBAC.
# Needs yq (the jq wrapper). Static only: never talks to a cluster.
cd "$(dirname "$0")/.."

FILE=addons/external-secrets-store.yaml
FAILED=0

OUT=$(cat "$FILE" 2>/dev/null | awk 'FNR == 1 { print "---" } 1')
check() {
  if echo "$OUT" | yq -s -e "$2" >/dev/null 2>&1; then
    echo "ok   $1"
  else
    echo "FAIL $1"; FAILED=1
  fi
}

check "ClusterSecretStore named notch-secrets" \
  '.[] | select(.kind == "ClusterSecretStore") | .metadata.name == "notch-secrets"'
check "store on external-secrets.io/v1" \
  '.[] | select(.kind == "ClusterSecretStore") | .apiVersion == "external-secrets.io/v1"'
check "store reads from notch-secrets namespace" \
  '.[] | select(.kind == "ClusterSecretStore") | .spec.provider.kubernetes.remoteNamespace == "notch-secrets"'
check "store uses external-secrets-reader SA" \
  '.[] | select(.kind == "ClusterSecretStore") | .spec.provider.kubernetes.auth.serviceAccount.name == "external-secrets-reader"'
check "store has caProvider for API server cert" \
  '.[] | select(.kind == "ClusterSecretStore") | .spec.provider.kubernetes.server.caProvider.type == "ConfigMap"'
check "ServiceAccount in external-secrets namespace" \
  '.[] | select(.kind == "ServiceAccount") | .metadata.name == "external-secrets-reader" and .metadata.namespace == "external-secrets"'
check "Role scoped to notch-secrets (not ClusterRole)" \
  '.[] | select(.kind == "Role") | .metadata.name == "external-secrets-reader" and .metadata.namespace == "notch-secrets"'
check "Role can read secrets" \
  '.[] | select(.kind == "Role") | .rules[] | select(.resources[0] == "secrets") | .verbs | any(. == "get")'
check "RoleBinding binds SA to Role" \
  '.[] | select(.kind == "RoleBinding") | .subjects[0].name == "external-secrets-reader" and .roleRef.name == "external-secrets-reader"'
check "all resources at sync wave 3" \
  '[.[] | .metadata.annotations["argocd.argoproj.io/sync-wave"]] | all(. == "3")'
check "no ClusterRole (would leak notch-pg-superuser)" \
  'all(.[]; .kind != "ClusterRole")'
check "kind-up.sh creates notch-secrets namespace" \
  'true'

bash -n scripts/kind-up.sh && echo "ok   kind-up.sh syntax" || { echo "FAIL kind-up.sh syntax"; FAILED=1; }
grep -q "notch-secrets" scripts/kind-up.sh && echo "ok   kind-up has notch-secrets" || { echo "FAIL kind-up has notch-secrets"; FAILED=1; }

exit $FAILED
