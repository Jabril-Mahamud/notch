#!/usr/bin/env bash
set -euo pipefail
# Bring up a Notch environment on Kind. Safe to re-run.
#   kind-up.sh          dev: the management cluster (ArgoCD, Keycloak, observability)
#   kind-up.sh staging  a lean cluster, deployed by dev's ArgoCD from main
# Tear down: notch down [env]
cd "$(dirname "$0")/.."

ENV=${1:-dev}
case "$ENV" in
  dev) CLUSTER=notch KIND_CONFIG=kind.yaml ;;
  staging) CLUSTER=notch-staging KIND_CONFIG=kind-staging.yaml ;;
  *) echo "unknown env $ENV (dev or staging)" >&2; exit 1 ;;
esac
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

# Step 3 (dev): apiserver auth config: kubectl logs in through Keycloak. Rewritten on
# every run and reloaded live by the apiserver (structured auth config), so no
# cluster recreate. Usernames are emails, prefixed oidc: like groups, so a
# Keycloak group can never pose as a system: one.
[ -f "$NOTCH_HOME/ca/ca.crt" ] || { echo "no CA at $NOTCH_HOME/ca/ca.crt" >&2; exit 1; }
if [ "$ENV" = dev ]; then
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
fi

# Step 4: cluster
if ! kind get clusters | grep -qx "$CLUSTER"; then
  CFG=$(mktemp)
  sed "s|@NOTCH_HOME@|$NOTCH_HOME|" "$KIND_CONFIG" > "$CFG"
  kind create cluster --name "$CLUSTER" --config "$CFG"
  rm -f "$CFG"
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

# Staging: register with dev's ArgoCD, copy secrets, done. Everything else
# (ArgoCD, Keycloak, observability, OIDC routing) lives on dev only.
if [ "$ENV" = staging ]; then
  # ExternalSecret sources: notch add writes them to dev; rerun this after one.
  # ponytail: staging shares dev's secret values. Per-env secrets (notch add
  # --env) when an env needs its own.
  kubectl --context kind-notch -n notch-secrets get secret -o json |
    python3 -c 'import sys,json; d=json.load(sys.stdin); [m.pop(k,None) for i in d["items"] for m in [i["metadata"]] for k in ("uid","resourceVersion","creationTimestamp","managedFields","annotations","ownerReferences")]; print(json.dumps(d))' |
    kubectl -n notch-secrets apply -f - >/dev/null
  # ArgoCD runs in dev's node; it reaches staging's apiserver over the kind
  # network by container name, not the host's 127.0.0.1 port (--internal).
  KCFG=$(kind get kubeconfig --internal --name "$CLUSTER")
  field() { yq -r "$1" <<<"$KCFG"; }
  kubectl --context kind-notch -n argocd create secret generic cluster-staging \
    --from-literal=name=staging --from-literal=server="$(field '.clusters[0].cluster.server')" \
    --from-literal=config="$(printf '{"tlsClientConfig":{"caData":"%s","certData":"%s","keyData":"%s"}}' \
      "$(field '.clusters[0].cluster["certificate-authority-data"]')" \
      "$(field '.users[0].user["client-certificate-data"]')" "$(field '.users[0].user["client-key-data"]')")" \
    --dry-run=client -o yaml | kubectl --context kind-notch apply -f - >/dev/null
  # Branch and values dir this env deploys (see addons/services.yaml). main =
  # promotion by merge; STAGING_REVISION=dev previews dev on staging.
  kubectl --context kind-notch -n argocd label secret cluster-staging --overwrite \
    argocd.argoproj.io/secret-type=cluster notch.dev/env=staging >/dev/null
  kubectl --context kind-notch -n argocd annotate secret cluster-staging --overwrite \
    notch.dev/revision="${STAGING_REVISION:-main}" notch.dev/values=staging >/dev/null
  kubectl config use-context kind-notch >/dev/null
  cat <<EOF

Staging is up, deployed by dev's ArgoCD from ${STAGING_REVISION:-main}:
  kubectl -n argocd get applications | grep staging
  https://<service>.staging.notch.localhost:8443  (curl --cacert $NOTCH_HOME/ca/ca.crt)
EOF
  exit 0
fi

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

# SSO client secrets for ArgoCD and Grafana, from keycloak.env. ArgoCD only
# resolves $<secret>:<key> references in secrets labelled part-of=argocd.
# shellcheck disable=SC1091
. "$NOTCH_HOME/keycloak.env"
for ns in argocd monitoring; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
kubectl -n argocd create secret generic argocd-oidc --from-literal=clientSecret="$ARGOCD_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n argocd label secret argocd-oidc --overwrite app.kubernetes.io/part-of=argocd >/dev/null
kubectl -n monitoring create secret generic grafana-oidc --from-literal=clientSecret="$GRAFANA_CLIENT_SECRET" \
  --from-file=ca.crt="$NOTCH_HOME/ca/ca.crt" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Step 7: ArgoCD bootstrap; addons from platform.yaml come through it later.
# Upgraded every run so values changes land; same values = no rollout.
OIDC=$(mktemp)
trap 'rm -f "${CFG:-}" "$OIDC"' EXIT
cat > "$OIDC" <<EOF
name: Keycloak
issuer: https://keycloak.notch.localhost/realms/notch
clientID: argocd
clientSecret: \$argocd-oidc:clientSecret
requestedScopes: [openid, profile, email]
rootCA: |
$(sed 's/^/  /' "$NOTCH_HOME/ca/ca.crt")
EOF
helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm -n argocd \
  --version "$ARGOCD_VERSION" -f clusters/argocd-values.yaml --set-file 'configs.cm.oidc\.config'="$OIDC" --wait >/dev/null

# Step 8: root app pointing ArgoCD at this repo
kubectl apply -f clusters/kind.yaml
# The ingress URL needs ingress-nginx, cert-manager and Keycloak, which take
# minutes to sync; port-forward works now. 80 because server.insecure (TLS ends
# at the ingress), 8090 because kind.yaml holds host 8080. Admin, since SSO
# redirects to argocd.notch.localhost.
cat <<EOF

ArgoCD is up; addons are syncing (ingress, Keycloak take a few minutes). Watch now:
  kubectl -n argocd port-forward svc/argocd-server 8090:80   then http://localhost:8090
  user admin, password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

EOF

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

# Step 10: Keycloak clients for auth: true services. The realm import on every
# Keycloak start wipes them, so they're re-created every run.
scripts/app-clients.sh

cat <<EOF

Notch is up. Watch:   kubectl -n argocd get applications -w
Apps, once synced:    https://<service>.notch.localhost  (trust: curl --cacert $NOTCH_HOME/ca/ca.crt)

ArgoCD / Grafana:     https://argocd.notch.localhost, https://grafana.notch.localhost
  use the Keycloak button (ArgoCD's username/password form is its local admin only)
  users:    jabril (admin), alice (team-alpha), bob (team-beta)
  password: grep NOTCH_USER_PASSWORD $NOTCH_HOME/keycloak.env
ArgoCD break-glass:   username/password form, user admin
  password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
Keycloak console:     https://keycloak.notch.localhost/admin, user admin
  password: grep KEYCLOAK_ADMIN_PASSWORD $NOTCH_HOME/keycloak.env
EOF
