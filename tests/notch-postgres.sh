#!/usr/bin/env bash
set -euo pipefail
# Checks for the NotchPostgres API (addons/notch-postgres): XRD shape, and the
# CNPG composition rendered for real with `crossplane render` (runs the function
# in Docker). Needs yq; render needs docker + the crossplane CLI (mise install).
cd "$(dirname "$0")/.."

DIR=addons/notch-postgres
FAILED=0
check() { # description jq-expr yaml
  if echo "$3" | yq -s -e "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; FAILED=1; fi
}

XRD=$(cat "$DIR/xrd.yaml" 2>/dev/null || true)
check "XRD notch.dev with a namespaced NotchPostgres claim" \
  '.[0].spec.group == "notch.dev" and .[0].spec.names.kind == "XNotchPostgres" and .[0].spec.claimNames.kind == "NotchPostgres"' "$XRD"
check "XRD requires databaseName" \
  '.[0].spec.versions[0].schema.openAPIV3Schema.properties.spec.required == ["databaseName"]' "$XRD"
check "XRD exposes the keys the chart's PG* env reads" \
  '.[0].spec.connectionSecretKeys == ["endpoint","port","username","password"]' "$XRD"
check "XRD defaults to the CNPG composition" '.[0].spec.defaultCompositionRef.name == "notch-postgres-cnpg"' "$XRD"

WAVES=$(awk 'FNR == 1 { print "---" } 1' "$DIR"/*.yaml 2>/dev/null || true)
check "Function and XRD at wave 3, Composition at 4" \
  '[.[] | {(.kind): .metadata.annotations["argocd.argoproj.io/sync-wave"]}] | add == {"Function":"3","CompositeResourceDefinition":"3","Composition":"4"}' "$WAVES"

if ! command -v crossplane >/dev/null || ! docker info >/dev/null 2>&1; then
  echo "skip crossplane render (needs crossplane CLI + docker: mise install)"
  exit $FAILED
fi
OUT=$(crossplane render tests/fixtures/notch-postgres/xr.yaml "$DIR/composition-cnpg.yaml" "$DIR/function.yaml" 2>&1 || true)
check "renders one Role and one Database" \
  '[.[] | select(.apiVersion == "postgresql.sql.crossplane.io/v1alpha1") | .kind] | sort == ["Database","Role"]' "$OUT"
check "both on the shared CNPG provider config" \
  '[.[] | select(.kind == "Role" or .kind == "Database") | .spec.providerConfigRef.name] | unique == ["notch-shared-pg"]' "$OUT"
check "Postgres names come from databaseName (external-name)" \
  '[.[] | select(.kind == "Role" or .kind == "Database") | .metadata.annotations["crossplane.io/external-name"]] | unique == ["team-alpha-hello"]' "$OUT"
check "Database owned by the role" \
  '.[] | select(.kind == "Database") | .spec.forProvider.owner == "team-alpha-hello"' "$OUT"
check "Role can log in" '.[] | select(.kind == "Role") | .spec.forProvider.privileges.login == true' "$OUT"
check "Role creds go to a per-XR secret in crossplane-system" \
  '.[] | select(.kind == "Role") | .spec.writeConnectionSecretToRef == {"namespace":"crossplane-system","name":"1b2c3d4e-0000-0000-0000-000000000000-role"}' "$OUT"

exit $FAILED
