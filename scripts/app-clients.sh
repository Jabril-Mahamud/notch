#!/usr/bin/env bash
set -euo pipefail
# Keycloak clients for auth: true services, and their OIDC_CLIENT_SECRET in
# notch-secrets (the chart's ExternalSecret syncs it). The realm re-imports on
# every Keycloak start and drops these, so kind-up reruns this every notch up;
# notch add --auth runs it for the new service.
#   app-clients.sh                  every auth service in services/ and tenants/
#   app-clients.sh <service-dir>... just these
# ponytail: a Keycloak restart outside notch up/resume drops the clients until
# the next run. Move this into a postStart hook if that bites.
cd "$(dirname "$0")/.."

NOTCH_HOME=${NOTCH_HOME:-$HOME/.config/notch}
# Not keycloak.env: that feeds keycloak-secrets, which has Reloader, so a new
# key would restart Keycloak and wipe the clients this just made.
SECRETS=$NOTCH_HOME/app-clients.env
KC=(kubectl --context kind-notch)

client_json() { # id secret hosts -> Keycloak client representation
  jq -n --arg id "$1" --arg secret "$2" --arg hosts "$3" '
    ($hosts | split("\n") | map(select(. != "") | "https://" + .)) as $urls | {
      clientId: $id, enabled: true, publicClient: false, secret: $secret,
      standardFlowEnabled: true, directAccessGrantsEnabled: false, serviceAccountsEnabled: false,
      redirectUris: ($urls | map(. + "/*")), webOrigins: $urls,
      protocolMappers: [{
        name: "groups", protocol: "openid-connect", protocolMapper: "oidc-group-membership-mapper",
        config: {"claim.name": "groups", "full.path": "false", "id.token.claim": "true",
                 "access.token.claim": "true", "userinfo.token.claim": "true"}}]}'
}

client() { # service-dir
  local dir=${1%/} id var secret hosts
  id=$(yq -r '.service.name' "$dir/service.yaml")
  # Realm clients are global: tenant services get the chart's notch.id prefix
  if [[ $dir == tenants/*/services/* ]]; then id=$(cut -d/ -f2 <<<"$dir")-$id; fi
  case $id in kubernetes|argocd|grafana) echo "skipping $dir: $id is a platform client" >&2; return ;; esac

  # Kept across notch down/up, so a recreated client keeps its secret
  var=$(tr a-z- A-Z_ <<<"$id")_CLIENT_SECRET
  grep -q "^$var=" "$SECRETS" 2>/dev/null ||
    (umask 077; echo "$var=$(openssl rand -hex 24)" >> "$SECRETS")
  secret=$(sed -n "s/^$var=//p" "$SECRETS")

  # Merge patch, not apply: notch add client-side applies the app's own keys
  # here, and a server-side apply takes those fields over and drops them.
  # Values on stdin, out of ps.
  if "${KC[@]}" -n notch-secrets get secret "$id-secrets" >/dev/null 2>&1; then
    jq -nc --arg s "$secret" '{stringData: {OIDC_CLIENT_SECRET: $s}}' |
      "${KC[@]}" -n notch-secrets patch secret "$id-secrets" --type merge --patch-file /dev/stdin >/dev/null
  else
    printf 'OIDC_CLIENT_SECRET=%s\n' "$secret" |
      "${KC[@]}" -n notch-secrets create secret generic "$id-secrets" --from-env-file=/dev/stdin >/dev/null
  fi

  # Ingress hosts: local drops Kind's :8080 (the browser comes in on 443), staging keeps :8443
  hosts=$(yq -r '.service.endpoints.internal.hosts[]?' "$dir"/*/values.yaml | sed 's/:8080$//')
  # kcadm runs in the pod: plain http to itself, and the admin password never leaves the cluster
  client_json "$id" "$secret" "$hosts" | "${KC[@]}" -n keycloak exec -i deploy/keycloak -- sh -c '
    kc() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config; }
    kc config credentials --server http://localhost:8080 --realm master \
      --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1
    uuid=$(kc get clients -r notch -q clientId="$1" --fields id --format csv --noquotes)
    if [ -n "$uuid" ]; then kc update "clients/$uuid" -r notch -f -; else kc create clients -r notch -f - >/dev/null; fi
  ' sh "$id"
  echo "keycloak client $id"
}

if [ $# -eq 0 ]; then
  for f in services/*/service.yaml tenants/*/services/*/service.yaml; do
    if [ -f "$f" ] && [ "$(yq -r '.service.auth' "$f")" = true ]; then set -- "$@" "$(dirname "$f")"; fi
  done
  [ $# -gt 0 ] || exit 0
fi

# Fresh notch up: ArgoCD syncs Keycloak minutes after kind-up applies the root app
echo "waiting for keycloak (app clients)..."
for _ in $(seq 120); do
  "${KC[@]}" -n keycloak get deploy keycloak >/dev/null 2>&1 && break
  sleep 5
done
"${KC[@]}" -n keycloak rollout status deploy/keycloak --timeout=10m >/dev/null

for dir in "$@"; do client "$dir"; done
