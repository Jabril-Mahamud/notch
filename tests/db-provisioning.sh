#!/usr/bin/env bash
set -euo pipefail
# Assertions for the shared Postgres layer: addons/infra + the kind-up superuser secret.
# Needs yq (the jq wrapper). Static only: never talks to a cluster.
cd "$(dirname "$0")/.."

FAILED=0

docs() { # files... -> one YAML stream; a file without a leading --- would merge into the previous doc
  awk 'FNR == 1 { print "---" } 1' "$@" 2>/dev/null || true
}

check() { # description jq-expression (must be true over the slurped docs)
  if echo "$OUT" | yq -s -e "$2" >/dev/null 2>&1; then
    echo "ok   $1"
  else
    echo "FAIL $1"; FAILED=1
  fi
}

# Step 1: CNPG cluster and provider config
OUT=$(docs addons/infra/*.yaml)
check "Cluster notch-pg in platform-db, 1 instance, 1Gi, default storage class" \
  '.[] | select(.kind == "Cluster") | .metadata.name == "notch-pg" and .metadata.namespace == "platform-db" and .spec.instances == 1 and .spec.storage.size == "1Gi" and .spec.storage.storageClass == null'
check "Cluster bootstraps from notch-pg-superuser" \
  '.[] | select(.kind == "Cluster") | .spec.superuserSecret.name == "notch-pg-superuser" and .spec.enableSuperuserAccess == true'
check "Cluster is wave 5 and never pruned" \
  '.[] | select(.kind == "Cluster") | .metadata.annotations["argocd.argoproj.io/sync-wave"] == "5" and .metadata.annotations["argocd.argoproj.io/sync-options"] == "Prune=false"'
check "ProviderConfig notch-shared-pg reads the superuser secret directly" \
  '.[] | select(.kind == "ProviderConfig") | .apiVersion == "postgresql.sql.crossplane.io/v1alpha1" and .metadata.name == "notch-shared-pg" and .spec.credentials.connectionSecretRef == {"namespace":"platform-db","name":"notch-pg-superuser"}'
check "ProviderConfig is wave 6" \
  '.[] | select(.kind == "ProviderConfig") | .metadata.annotations["argocd.argoproj.io/sync-wave"] == "6"'
check "no ExternalSecret: kind-up writes endpoint itself" \
  'all(.[]; .kind != "ExternalSecret")'

# Step 2: one notch-shared-pg across all addons, or ArgoCD fights itself
OUT=$(docs addons/*.yaml addons/infra/*.yaml)
check "exactly one notch-shared-pg ProviderConfig" \
  '[.[] | select(.kind == "ProviderConfig" and .metadata.name == "notch-shared-pg")] | length == 1'

# Step 3: kind-up owns the superuser secret
KIND_UP=scripts/kind-up.sh
if bash -n "$KIND_UP"; then echo "ok   kind-up parses"; else echo "FAIL kind-up parses"; FAILED=1; fi
for want in 'get secret notch-pg-superuser' \
  'endpoint=notch-pg-rw.platform-db.svc.cluster.local' 'port=5432'; do
  if grep -qF -- "$want" "$KIND_UP"; then echo "ok   kind-up has $want"; else echo "FAIL kind-up has $want"; FAILED=1; fi
done

exit $FAILED
