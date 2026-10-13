#!/usr/bin/env bash
set -euo pipefail
# Structural validation for PR 5: DB provisioning via Crossplane.
# No cluster needed — validates YAML fields with yq and checks kind-up.sh syntax.
cd "$(dirname "$0")/.."

INFRA=addons/infra
FAILED=0

# check <description> <file> <yq-expression>
check() {
  local desc=$1 file=$INFRA/$2 expr=$3
  if yq -s -e "$expr" < "$file" >/dev/null 2>&1; then
    echo "ok   $desc"
  else
    echo "FAIL $desc"; FAILED=1
  fi
}

# --- CNPG cluster ---
CNPG=cnpg-cluster.yaml
check "CNPG is kind Cluster" "$CNPG" '.[0].kind == "Cluster"'
check "CNPG name is notch-pg" "$CNPG" '.[0].metadata.name == "notch-pg"'
check "CNPG namespace is platform-db" "$CNPG" '.[0].metadata.namespace == "platform-db"'
check "CNPG sync wave 5" "$CNPG" '.[0].metadata.annotations["argocd.argoproj.io/sync-wave"] == "5"'
check "CNPG prune disabled" "$CNPG" '.[0].metadata.annotations["argocd.argoproj.io/sync-options"] == "Prune=false"'
check "CNPG single instance" "$CNPG" '.[0].spec.instances == 1'
check "CNPG superuser access enabled" "$CNPG" '.[0].spec.enableSuperuserAccess == true'
check "CNPG superuser secret name" "$CNPG" '.[0].spec.superuserSecret.name == "notch-pg-superuser"'
check "CNPG storage 1Gi" "$CNPG" '.[0].spec.storage.size == "1Gi"'

# --- ProviderConfig ---
PC=pg-provider-config.yaml
check "ProviderConfig kind" "$PC" '.[0].kind == "ProviderConfig"'
check "ProviderConfig name notch-shared-pg" "$PC" '.[0].metadata.name == "notch-shared-pg"'
check "ProviderConfig sync wave 6" "$PC" '.[0].metadata.annotations["argocd.argoproj.io/sync-wave"] == "6"'
check "ProviderConfig connection secret name" "$PC" '.[0].spec.credentials.connectionSecretRef.name == "notch-pg-provider-config"'
check "ProviderConfig connection secret namespace" "$PC" '.[0].spec.credentials.connectionSecretRef.namespace == "platform-db"'
check "ProviderConfig sslMode require" "$PC" '.[0].spec.sslMode == "require"'
check "ProviderConfig group is postgresql.sql.crossplane.io" "$PC" '.[0].apiVersion == "postgresql.sql.crossplane.io/v1alpha1"'

# --- ExternalSecret (host → endpoint rename) ---
ES=pg-superuser-externalsecret.yaml
check "ExternalSecret kind" "$ES" '.[0].kind == "ExternalSecret"'
check "ExternalSecret name notch-pg-provider-config" "$ES" '.[0].metadata.name == "notch-pg-provider-config"'
check "ExternalSecret namespace platform-db" "$ES" '.[0].metadata.namespace == "platform-db"'
check "ExternalSecret sync wave 6" "$ES" '.[0].metadata.annotations["argocd.argoproj.io/sync-wave"] == "6"'
check "ExternalSecret targets notch-pg-provider-config" "$ES" '.[0].spec.target.name == "notch-pg-provider-config"'
check "ExternalSecret uses ClusterSecretStore" "$ES" '.[0].spec.secretStoreRef.kind == "ClusterSecretStore"'
check "ExternalSecret store name notch-secrets" "$ES" '.[0].spec.secretStoreRef.name == "notch-secrets"'
check "ExternalSecret renames host to endpoint" "$ES" \
  '.[0].spec.data | any(.[]; .secretKey == "endpoint" and .remoteRef.property == "host")'
check "ExternalSecret has port mapping" "$ES" \
  '.[0].spec.data | any(.[]; .secretKey == "port" and .remoteRef.property == "port")'
check "ExternalSecret has username mapping" "$ES" \
  '.[0].spec.data | any(.[]; .secretKey == "username" and .remoteRef.property == "username")'
check "ExternalSecret has password mapping" "$ES" \
  '.[0].spec.data | any(.[]; .secretKey == "password" and .remoteRef.property == "password")'
check "ExternalSecret has database mapping" "$ES" \
  '.[0].spec.data | any(.[]; .secretKey == "database" and .remoteRef.property == "database")'
check "ExternalSecret has sslmode mapping" "$ES" \
  '.[0].spec.data | any(.[]; .secretKey == "sslmode" and .remoteRef.property == "sslmode")'

# --- ClusterSecretStore ---
SS=notch-secret-store.yaml
check "ClusterSecretStore kind" "$SS" '.[0].kind == "ClusterSecretStore"'
check "ClusterSecretStore name notch-secrets" "$SS" '.[0].metadata.name == "notch-secrets"'
check "ClusterSecretStore sync wave 3" "$SS" '.[0].metadata.annotations["argocd.argoproj.io/sync-wave"] == "3"'
check "ClusterSecretStore provider is kubernetes" "$SS" '.[0].spec.provider.kubernetes != null'
check "ClusterSecretStore reads from platform-db" "$SS" '.[0].spec.provider.kubernetes.remoteRef.namespace == "platform-db"'
check "ClusterSecretStore SA is external-secrets" "$SS" '.[0].spec.provider.kubernetes.auth.serviceAccount.name == "external-secrets"'

# --- kind-up.sh ---
if bash -n scripts/kind-up.sh 2>&1; then
  echo "ok   kind-up.sh syntax valid"
else
  echo "FAIL kind-up.sh syntax error"; FAILED=1
fi

if grep -q "notch-pg-superuser" scripts/kind-up.sh; then
  echo "ok   kind-up.sh creates notch-pg-superuser secret"
else
  echo "FAIL kind-up.sh missing notch-pg-superuser secret creation"; FAILED=1
fi

if grep -q "platform-db" scripts/kind-up.sh; then
  echo "ok   kind-up.sh creates platform-db namespace"
else
  echo "FAIL kind-up.sh missing platform-db namespace creation"; FAILED=1
fi

# Guard: only create if missing (regenerating locks provider-sql out)
if grep -q "get secret notch-pg-superuser" scripts/kind-up.sh; then
  echo "ok   kind-up.sh guards against recreating secret"
else
  echo "FAIL kind-up.sh should check if secret exists before creating"; FAILED=1
fi

# --- Cross-file consistency ---
# ProviderConfig references the ExternalSecret's target secret
PC_SECRET=$(yq -r -s '.[0].spec.credentials.connectionSecretRef.name' < "$INFRA/pg-provider-config.yaml")
ES_TARGET=$(yq -r -s '.[0].spec.target.name' < "$INFRA/pg-superuser-externalsecret.yaml")
if [ "$PC_SECRET" = "$ES_TARGET" ]; then
  echo "ok   ProviderConfig secret ref matches ExternalSecret target ($PC_SECRET)"
else
  echo "FAIL ProviderConfig references '$PC_SECRET' but ExternalSecret targets '$ES_TARGET'"; FAILED=1
fi

# CNPG superuser secret name matches what kind-up.sh creates
CNPG_SECRET=$(yq -r -s '.[0].spec.superuserSecret.name' < "$INFRA/cnpg-cluster.yaml")
if grep -q "create secret generic $CNPG_SECRET" scripts/kind-up.sh; then
  echo "ok   kind-up.sh creates the secret CNPG expects ($CNPG_SECRET)"
else
  echo "FAIL kind-up.sh does not create $CNPG_SECRET which CNPG expects"; FAILED=1
fi

exit $FAILED
