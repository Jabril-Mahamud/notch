#!/usr/bin/env bash
set -euo pipefail
# Template assertions for app OIDC: auth: true services get OIDC_* env pointing
# at Keycloak, with the client secret synced through ESO. Needs helm and yq.
cd "$(dirname "$0")/.."

CHART=charts/notch-service
FIX=tests/fixtures
FAILED=0
AUTH=(-f "$FIX/auth-app/service.yaml" -f "$FIX/auth-app/local/values.yaml")
WEB=(-f "$FIX/web/service.yaml" -f "$FIX/web/local/values.yaml")

check() { # description jq-expression (must be true over the slurped docs)
  if echo "$OUT" | yq -s -e "$2" >/dev/null 2>&1; then
    echo "ok   $1"
  else
    echo "FAIL $1"; FAILED=1
  fi
}

must_fail() { # description expected-error helm-template-args...
  local desc=$1 want=$2; shift 2
  local err
  if err=$(helm template x "$CHART" "$@" 2>&1); then
    echo "FAIL $desc (rendered)"; FAILED=1
  elif [[ $err == *"$want"* ]]; then
    echo "ok   $desc"
  else
    echo "FAIL $desc (got: $err)"; FAILED=1
  fi
}

ENV='.[] | select(.kind == "Deployment") | .spec.template.spec.containers'
oidc() { echo "$ENV | length > 0 and all([\"OIDC_ISSUER\",\"OIDC_CLIENT_ID\",\"OIDC_CLIENT_SECRET\"] - (.env | map(.name)) == [])"; }
var() { echo "$ENV[0].env[] | select(.name == \"$1\")"; }

OUT=$(helm template auth-app "$CHART" "${AUTH[@]}")
check "every container gets OIDC_ISSUER, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET" "$(oidc)"
check "issuer is Keycloak's notch realm" \
  "$(var OIDC_ISSUER) | .value == \"https://keycloak.notch.localhost/realms/notch\""
check "client id is the service name" "$(var OIDC_CLIENT_ID) | .value == \"auth-app\""
check "client secret from the synced <service>-secrets" \
  "$(var OIDC_CLIENT_SECRET) | .valueFrom.secretKeyRef == {\"name\":\"auth-app-secrets\",\"key\":\"OIDC_CLIENT_SECRET\"}"
check "ExternalSecret pulls OIDC_CLIENT_SECRET" \
  '.[] | select(.kind == "ExternalSecret") | .spec.data | any(.secretKey == "OIDC_CLIENT_SECRET" and .remoteRef.key == "auth-app-secrets")'

OUT=$(helm template auth-app "$CHART" "${AUTH[@]}" --set namespace=team-alpha)
check "tenant client id is tenant-prefixed (realm clients are global)" \
  "$(var OIDC_CLIENT_ID) | .value == \"team-alpha-auth-app\""

OUT=$(helm template auth-app "$CHART" "${AUTH[@]}" \
  --set 'service.deployment.containers.app.env[0].name=OIDC_CLIENT_ID' \
  --set 'service.deployment.containers.app.env[0].value=custom')
check "container env overrides an OIDC var by name, no duplicates" \
  "[$(var OIDC_CLIENT_ID) | .value] == [\"custom\"]"

OUT=$(helm template web "$CHART" "${WEB[@]}" --set service.auth=true --set 'service.secrets[0]=OIDC_CLIENT_SECRET')
check "two containers: both get OIDC_*" "$(oidc)"

OUT=$(helm template hello "$CHART" -f "$FIX/hello/service.yaml" -f "$FIX/hello/local/values.yaml")
check "no auth: no OIDC_* env" "[$ENV[].env[].name | select(startswith(\"OIDC_\"))] == []"

must_fail "auth without OIDC_CLIENT_SECRET in secrets" "auth needs OIDC_CLIENT_SECRET in secrets" \
  "${WEB[@]}" --set service.auth=true

exit $FAILED
