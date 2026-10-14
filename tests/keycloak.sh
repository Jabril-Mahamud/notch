#!/usr/bin/env bash
set -euo pipefail
# Static checks for Keycloak (addons/keycloak): realm groups, users, clients and
# the groups claim, and no secrets in git. Needs yq (jq wrapper) and jq.
cd "$(dirname "$0")/.."

DIR=addons/keycloak
FAILED=0
check() { # description jq-expr json
  if echo "$3" | jq -e "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; FAILED=1; fi
}

DOCS=$(awk 'FNR == 1 { print "---" } 1' "$DIR"/*.yaml 2>/dev/null | yq -s . 2>/dev/null || echo '[]')
REALM=$(echo "$DOCS" | jq -r '.[] | select(.kind == "ConfigMap" and .metadata.name == "keycloak-realm") | .data["notch-realm.json"]' 2>/dev/null || true)
[ -n "$REALM" ] || REALM='{}'

check "realm notch, enabled" '.realm == "notch" and .enabled == true' "$REALM"
check "groups: notch-admins and one per tenant" '[.groups[].name] | sort == ["notch-admins","team-alpha","team-beta"]' "$REALM"
check "jabril is a notch-admin" '.users[] | select(.username == "jabril") | .groups == ["/notch-admins"]' "$REALM"
check "alice in team-alpha, bob in team-beta" \
  '([.users[] | select(.username == "alice") | .groups] == [["/team-alpha"]]) and ([.users[] | select(.username == "bob") | .groups] == [["/team-beta"]])' "$REALM"
check "users have verified emails (username claim)" 'all(.users[]; .emailVerified == true and (.email | endswith("@notch.localhost")))' "$REALM"
check "clients: kubernetes, argocd, grafana" '[.clients[].clientId] | sort == ["argocd","grafana","kubernetes"]' "$REALM"
check "every client puts groups in its tokens (short names, not paths)" \
  'all(.clients[]; any(.protocolMappers[]; .protocolMapper == "oidc-group-membership-mapper" and .config["claim.name"] == "groups" and .config["full.path"] == "false" and .config["id.token.claim"] == "true"))' "$REALM"
check "kubernetes is public (kubelogin), redirects to localhost" \
  '.clients[] | select(.clientId == "kubernetes") | .publicClient == true and (.redirectUris | any(startswith("http://localhost:8000")))' "$REALM"
check "argocd and grafana are confidential with placeholder secrets" \
  '[.clients[] | select(.clientId != "kubernetes") | .publicClient == false and (.secret | test("^\\$\\{[A-Z_]+\\}$"))] == [true,true]' "$REALM"
check "no literal passwords: every credential is an env placeholder" \
  'all(.users[].credentials[]; .value | test("^\\$\\{[A-Z_]+\\}$"))' "$REALM"

check "Keycloak image pinned, imports the realm on start" \
  '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0] | (.image | test("^quay.io/keycloak/keycloak:[0-9]")) and (.args | index("--import-realm") != null)' "$DOCS"
check "hostname is the issuer host" \
  '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "KC_HOSTNAME") | .value == "https://keycloak.notch.localhost"' "$DOCS"
check "secrets come from keycloak-secrets (made by kind-up)" \
  '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].envFrom == [{"secretRef":{"name":"keycloak-secrets"}}]' "$DOCS"
check "Ingress serves keycloak.notch.localhost over TLS from notch-ca" \
  '.[] | select(.kind == "Ingress") | .metadata.annotations["cert-manager.io/cluster-issuer"] == "notch-ca" and .spec.tls[0].hosts == ["keycloak.notch.localhost"]' "$DOCS"
check "all at wave 4 (after the issuer)" '[.[] | .metadata.annotations["argocd.argoproj.io/sync-wave"]] | unique == ["4"]' "$DOCS"

if grep -qE 'NOTCH_HOME/keycloak\.env' scripts/kind-up.sh && grep -q 'create secret generic keycloak-secrets' scripts/kind-up.sh; then
  echo "ok   kind-up generates keycloak.env once and loads keycloak-secrets"
else
  echo "FAIL kind-up generates keycloak.env once and loads keycloak-secrets"; FAILED=1
fi

exit $FAILED
