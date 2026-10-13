#!/usr/bin/env bash
set -euo pipefail
# Bring up Notch on a local Kind cluster. Safe to re-run.
# Tear down: kind delete cluster --name notch
cd "$(dirname "$0")/.."

CLUSTER=notch
ARGOCD_VERSION=10.9.2

# Step 1: cluster
kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --config kind.yaml
kubectl config use-context "kind-$CLUSTER"

# Step 2: namespaces ArgoCD expects to exist, and the postgres superuser. CNPG bootstraps from it and provider-sql connects
# with it, so endpoint/port live here too (provider-sql wants endpoint; CNPG has none).
# Only created when missing: regenerating would lock provider-sql out of an initialised DB.
kubectl create namespace platform-db --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Source namespace for the notch-secrets ClusterSecretStore:
#   kubectl -n notch-secrets create secret generic <service>-secrets --from-literal=KEY=value
kubectl create namespace notch-secrets --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n platform-db get secret notch-pg-superuser >/dev/null 2>&1 ||
  kubectl -n platform-db create secret generic notch-pg-superuser \
    --type=kubernetes.io/basic-auth \
    --from-literal=username=postgres \
    --from-literal="password=$(openssl rand -hex 24)" \
    --from-literal=endpoint=notch-pg-rw.platform-db.svc.cluster.local \
    --from-literal=port=5432

# Step 3: ArgoCD bootstrap; addons from platform.yaml come through it later
if ! helm status argocd -n argocd >/dev/null 2>&1; then
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo
  helm install argocd argo/argo-cd -n argocd --create-namespace --version "$ARGOCD_VERSION" --wait
fi

# Step 4: root app pointing ArgoCD at this repo
kubectl apply -f clusters/kind.yaml

cat <<EOF

Notch is up. Watch:   kubectl -n argocd get applications -w
ArgoCD UI:            kubectl -n argocd port-forward svc/argocd-server 8443:443  (https://localhost:8443, user admin)
Password:             kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
Apps, once synced:    http://notch.localhost:8080
EOF
