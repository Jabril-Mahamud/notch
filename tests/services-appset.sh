#!/usr/bin/env bash
set -euo pipefail
# Static checks for the services ApplicationSet and the root app's branch.
# Needs yq (the jq wrapper). Static only: never talks to a cluster.
cd "$(dirname "$0")/.."

FILE=addons/services.yaml
FAILED=0

OUT=$(cat "$FILE" 2>/dev/null || true)
check() { # description jq-expr [yaml]
  if echo "${3:-$OUT}" | yq -e "$2" >/dev/null 2>&1; then
    echo "ok   $1"
  else
    echo "FAIL $1"; FAILED=1
  fi
}

check "ApplicationSet named services in argocd" \
  '.kind == "ApplicationSet" and .metadata.name == "services" and .metadata.namespace == "argocd"'
check "syncs after platform infra (wave 7)" \
  '.metadata.annotations["argocd.argoproj.io/sync-wave"] == "7"'
check "git generator over services/*" \
  '.spec.generators[0].git.directories[0].path == "services/*"'
check "generator tracks dev (notch add pushes there)" \
  '.spec.generators[0].git.revision == "dev"'
check "app named after the service" \
  '.spec.template.metadata.name == "{{.path.basename}}"'
check "renders charts/notch-service from dev" \
  '.spec.template.spec.source.path == "charts/notch-service" and .spec.template.spec.source.targetRevision == "dev"'
check "values: service.yaml then local/values.yaml" \
  '.spec.template.spec.source.helm.valueFiles == ["../../services/{{.path.basename}}/service.yaml", "../../services/{{.path.basename}}/local/values.yaml"]'
check "deploys into a namespace named after the service" \
  '.spec.template.spec.destination.namespace == "{{.path.basename}}"'
check "auto-sync with prune and self-heal" \
  '.spec.template.spec.syncPolicy.automated.prune and .spec.template.spec.syncPolicy.automated.selfHeal'
check "retries failed syncs (Database CRD may land late)" \
  '.spec.template.spec.syncPolicy.retry.limit > 0'
check "root app tracks dev, not HEAD (= main)" \
  '.spec.source.targetRevision == "dev"' "$(cat clusters/kind.yaml)"

exit $FAILED
