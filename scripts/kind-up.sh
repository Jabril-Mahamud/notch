#!/usr/bin/env bash
set -euo pipefail
# Bring up Notch on a local Kind cluster. Safe to re-run.
# Tear down: kind delete cluster --name notch
cd "$(dirname "$0")/.."

CLUSTER=notch
ARGOCD_VERSION=10.9.2
REGISTRY=notch-registry
# Outside the repo so it survives notch down and fresh clones: auth config now, CA next.
NOTCH_HOME=${NOTCH_HOME:-$HOME/.config/notch}

# Step 1: registry. Outlives the cluster on purpose: images survive notch down/up.
docker inspect "$REGISTRY" >/dev/null 2>&1 ||
  docker run -d --restart=always -p 127.0.0.1:5001:5000 --name "$REGISTRY" registry:2 >/dev/null
docker start "$REGISTRY" >/dev/null

# Step 2: local CA for TLS (cert-manager's notch-ca issuer) and OIDC (the
# apiserver trusts Keycloak's cert through it). Kept across notch down/up so it
# only has to be trusted once.
if [ ! -f "$NOTCH_HOME/ca/ca.crt" ]; then
  mkdir -p "$NOTCH_HOME/ca" && chmod 700 "$NOTCH_HOME/ca"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -subj "/CN=notch local CA" -keyout "$NOTCH_HOME/ca/ca.key" -out "$NOTCH_HOME/ca/ca.crt" \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null
fi

# Step 3: apiserver auth config: kubectl logs in through Keycloak. Rewritten on
# every run and reloaded live by the apiserver (structured auth config), so no
# cluster recreate. Usernames are emails, prefixed oidc: like groups, so a
# Keycloak group can never pose as a system: one.
[ -f "$NOTCH_HOME/ca/ca.crt" ] || { echo "no CA at $NOTCH_HOME/ca/ca.crt" >&2; exit 1; }
mkdir -p "$NOTCH_HOME/auth"
# Write then rename: the apiserver watches the file, and a truncate-then-write
# lets it read an empty config ("empty config data").
cat > "$NOTCH_HOME/auth/config.yaml.tmp" <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: AuthenticationConfiguration
jwt:
  - issuer:
      url: https://keycloak.notch.localhost/realms/notch
      audiences: [kubernetes]
      certificateAuthority: |
$(sed 's/^/        /' "$NOTCH_HOME/ca/ca.crt")
    claimMappings:
      username: { claim: email, prefix: "oidc:" }
      groups: { claim: groups, prefix: "oidc:" }
EOF
mv "$NOTCH_HOME/auth/config.yaml.tmp" "$NOTCH_HOME/auth/config.yaml"

# Step 4: cluster
if ! kind get clusters | grep -qx "$CLUSTER"; then
  CFG=$(mktemp)
  trap 'rm -f "$CFG"' EXIT
  sed "s|@NOTCH_HOME@|$NOTCH_HOME|" kind.yaml > "$CFG"
  kind create cluster --name "$CLUSTER" --config "$CFG"
fi
kubectl config use-context "kind-$CLUSTER"

# Step 5: pods pull localhost:5001/<image> through notch-registry on the kind
# network. Same name the host pushes to, so values.yaml refs work on both sides.
docker network connect kind "$REGISTRY" 2>/dev/null || true
docker exec -i "$CLUSTER-control-plane" sh -c \
  'mkdir -p /etc/containerd/certs.d/localhost:5001 && cat > /etc/containerd/certs.d/localhost:5001/hosts.toml' <<EOF
[host."http://$REGISTRY:5000"]
EOF

# Step 6: postgres superuser. CNPG bootstraps from it and provider-sql connects
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

# cert-manager's notch-ca ClusterIssuer signs with this; apply so a new CA replaces the old.
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n cert-manager create secret tls notch-ca \
  --cert="$NOTCH_HOME/ca/ca.crt" --key="$NOTCH_HOME/ca/ca.key" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Keycloak credentials: generated once, kept with the CA so a recreated cluster
# keeps the same logins and client secrets. The realm reads them as ${VAR}s.
if [ ! -f "$NOTCH_HOME/keycloak.env" ]; then
  (umask 077; cat > "$NOTCH_HOME/keycloak.env" <<EOF
KEYCLOAK_ADMIN_PASSWORD=$(openssl rand -hex 16)
NOTCH_USER_PASSWORD=$(openssl rand -hex 12)
ARGOCD_CLIENT_SECRET=$(openssl rand -hex 24)
GRAFANA_CLIENT_SECRET=$(openssl rand -hex 24)
EOF
  )
fi
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n keycloak create secret generic keycloak-secrets --from-env-file="$NOTCH_HOME/keycloak.env" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Step 7: ArgoCD bootstrap; addons from platform.yaml come through it later
if ! helm status argocd -n argocd >/dev/null 2>&1; then
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo
  helm install argocd argo/argo-cd -n argocd --create-namespace --version "$ARGOCD_VERSION" --wait
fi

# Step 8: root app pointing ArgoCD at this repo
kubectl apply -f clusters/kind.yaml

# Step 9: *.notch.localhost resolves to ::1 off the host, so in-cluster callers
# never reach the ingress. The OIDC issuer URL must be the same string for the
# browser, pods and the apiserver, so route the name to the ingress controller.
# ponytail: Kind only. Cloud environments get real DNS and none of this.
echo "waiting for ingress-nginx (OIDC issuer routing)..."
for _ in $(seq 60); do
  INGRESS_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  [ -n "$INGRESS_IP" ] && break
  sleep 5
done
[ -n "$INGRESS_IP" ] || { echo "ingress-nginx never came up" >&2; exit 1; }
# Pods: CoreDNS (kubeadm-owned, not ArgoCD's). Its reload plugin picks this up in ~30s.
COREFILE=$(kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}')
if ! grep -q notch.localhost <<<"$COREFILE"; then
  COREFILE=$(sed 's|^    ready$|    ready\n    rewrite name regex (.+)\\.notch\\.localhost\\.$ ingress-nginx-controller.ingress-nginx.svc.cluster.local. answer auto|' <<<"$COREFILE")
  kubectl -n kube-system create cm coredns --from-literal=Corefile="$COREFILE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi
# Apiserver: host network, so it uses the node's resolver, not CoreDNS. Docker
# rewrites /etc/hosts on every container start, hence notch resume reruns this.
docker exec "$CLUSTER-control-plane" sh -c \
  "grep -v ' keycloak.notch.localhost\$' /etc/hosts > /tmp/hosts; echo '$INGRESS_IP keycloak.notch.localhost' >> /tmp/hosts; cat /tmp/hosts > /etc/hosts"

cat <<EOF

Notch is up. Watch:   kubectl -n argocd get applications -w
ArgoCD UI:            kubectl -n argocd port-forward svc/argocd-server 8443:443  (https://localhost:8443, user admin)
Password:             kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
Apps, once synced:    https://<service>.notch.localhost  (trust: curl --cacert $NOTCH_HOME/ca/ca.crt)
Logins (Keycloak):    jabril (admin), alice (team-alpha), bob (team-beta); password: NOTCH_USER_PASSWORD in $NOTCH_HOME/keycloak.env
EOF
