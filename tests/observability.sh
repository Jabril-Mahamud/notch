#!/usr/bin/env bash
set -euo pipefail
# Static checks that logs reach Loki, traces reach Tempo, and Grafana reads both.
# Needs yq (the jq wrapper). Static only: never talks to a cluster.
cd "$(dirname "$0")/.."

FAILED=0
ALLOY=$(cat addons/alloy.yaml 2>/dev/null || true)
KPS=$(cat addons/kube-prometheus-stack.yaml)
TEMPO=$(cat addons/tempo.yaml 2>/dev/null || true)

check() { # description jq-expr yaml
  if echo "$3" | yq -e "$2" >/dev/null 2>&1; then
    echo "ok   $1"
  else
    echo "FAIL $1"; FAILED=1
  fi
}

VALUES='.spec.source.helm.valuesObject'
check "alloy Application from grafana charts" \
  '.kind == "Application" and .spec.source.chart == "alloy" and .spec.source.repoURL == "https://grafana.github.io/helm-charts"' "$ALLOY"
check "alloy pinned to a chart version" \
  '.spec.source.targetRevision | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")' "$ALLOY"
check "alloy syncs after loki (wave 5)" \
  '.metadata.annotations["argocd.argoproj.io/sync-wave"] == "5"' "$ALLOY"
check "alloy is a single-replica deployment (API tailing would duplicate per node)" \
  "$VALUES.controller.type == \"deployment\" and $VALUES.controller.replicas == 1" "$ALLOY"
check "alloy tails pods via the API" \
  "$VALUES.alloy.configMap.content | test(\"loki.source.kubernetes\")" "$ALLOY"
check "alloy labels streams by namespace" \
  "$VALUES.alloy.configMap.content | test(\"target_label *= *\\\"namespace\\\"\")" "$ALLOY"
check "alloy pushes to loki-gateway" \
  "$VALUES.alloy.configMap.content | test(\"http://loki-gateway.loki.svc/loki/api/v1/push\")" "$ALLOY"
check "grafana has a Loki datasource on loki-gateway" \
  "$VALUES.grafana.additionalDataSources[] | select(.type == \"loki\") | .url == \"http://loki-gateway.loki.svc\"" "$KPS"
check "tempo Application from grafana charts" \
  '.kind == "Application" and .spec.source.chart == "tempo" and .spec.source.repoURL == "https://grafana.github.io/helm-charts"' "$TEMPO"
check "tempo pinned to a chart version" \
  '.spec.source.targetRevision | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")' "$TEMPO"
check "tempo syncs with the other backends (wave 4)" \
  '.metadata.annotations["argocd.argoproj.io/sync-wave"] == "4"' "$TEMPO"
check "tempo has somewhere writable for traces" \
  "$VALUES.extraVolumes[] | select(.name == \"data\") | .emptyDir != null" "$TEMPO"
check "grafana has a Tempo datasource on port 3200" \
  "$VALUES.grafana.additionalDataSources[] | select(.type == \"tempo\") | .url == \"http://tempo.tempo.svc:3200\"" "$KPS"

exit $FAILED
