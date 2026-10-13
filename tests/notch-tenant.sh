#!/usr/bin/env bash
set -euo pipefail
# Template assertions for charts/notch-tenant and the tenants ApplicationSet.
# Needs helm and yq (the jq wrapper). Static only: never talks to a cluster.
cd "$(dirname "$0")/.."

CHART=charts/notch-tenant
FAILED=0

check() { # description jq-expression (must be true over the slurped docs)
  if echo "$OUT" | yq -s -e "$2" >/dev/null 2>&1; then
    echo "ok   $1"
  else
    echo "FAIL $1"; FAILED=1
  fi
}

helm lint "$CHART" -f tenants/team-alpha/platform.yaml >/dev/null && echo "ok   helm lint" || { echo "FAIL helm lint"; FAILED=1; }
OUT=$(helm template team-alpha "$CHART" -f tenants/team-alpha/platform.yaml 2>/dev/null || true)

# Step 1: namespace + RBAC
check "tenant namespace labelled as a tenant" \
  '.[] | select(.kind == "Namespace") | .metadata.name == "team-alpha" and .metadata.labels["notch.dev/tenant"] == "team-alpha"'
check "namespace syncs before everything else" \
  '.[] | select(.kind == "Namespace") | .metadata.annotations["argocd.argoproj.io/sync-wave"] == "-1"'
check "deployer ServiceAccount in the tenant namespace" \
  '.[] | select(.kind == "ServiceAccount") | .metadata.name == "team-alpha-deployer" and .metadata.namespace == "team-alpha"'
check "RoleBinding (not ClusterRoleBinding) to the built-in edit role" \
  '.[] | select(.kind == "RoleBinding") | .metadata.namespace == "team-alpha" and .roleRef == {"apiGroup":"rbac.authorization.k8s.io","kind":"ClusterRole","name":"edit"}'
check "binding subject is the deployer" \
  '.[] | select(.kind == "RoleBinding") | .subjects == [{"kind":"ServiceAccount","name":"team-alpha-deployer","namespace":"team-alpha"}]'
check "nothing cluster-scoped besides the namespace" \
  'all(.[]; .kind == "Namespace" or .metadata.namespace == "team-alpha")'

# Step 2: quotas
check "ResourceQuota caps requests, memory limits and object counts" \
  '.[] | select(.kind == "ResourceQuota") | .spec.hard | has("requests.cpu") and has("requests.memory") and has("limits.memory") and has("pods")'
check "no LoadBalancer or NodePort services (Kind has no LB; ingress is the way in)" \
  '.[] | select(.kind == "ResourceQuota") | .spec.hard["services.loadbalancers"] == "0" and .spec.hard["services.nodeports"] == "0"'
check "LimitRange defaults every container (quota rejects pods without them)" \
  '.[] | select(.kind == "LimitRange") | .spec.limits[0] | .type == "Container" and .defaultRequest.cpu and .defaultRequest.memory and .default.memory'
check "no CPU limit default (throttling, not protection)" \
  '.[] | select(.kind == "LimitRange") | .spec.limits[0].default | has("cpu") | not'

# Step 3: network policies
NP='.[] | select(.kind == "NetworkPolicy")'
check "default-deny ingress for every pod" \
  "[$NP | select(.spec.podSelector == {} and .spec.policyTypes == [\"Ingress\"] and (.spec.ingress // []) == [])] | length == 1"
check "pods in the tenant namespace reach each other" \
  "[$NP | .spec.ingress[]?.from[]? | select(.podSelector == {} and (has(\"namespaceSelector\") | not))] | length == 1"
for ns in ingress-nginx monitoring; do
  check "ingress allowed from $ns" \
    "[$NP | .spec.ingress[]?.from[]?.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]] | any(. == \"$ns\")"
done
check "egress left open (DB, Tempo, DNS live outside the namespace)" \
  "[$NP | .spec.policyTypes[]] | all(. == \"Ingress\")"

OUT=$(helm template team-alpha "$CHART" -f tenants/team-alpha/platform.yaml --set tenant.quota.pods=3 2>/dev/null || true)
check "platform.yaml overrides a single quota key, keeps the rest" \
  '.[] | select(.kind == "ResourceQuota") | .spec.hard.pods == "3" and .spec.hard["requests.cpu"] != null'

# The ApplicationSet that renders tenants/*
OUT=$(cat addons/tenants.yaml 2>/dev/null || true)
check "tenants ApplicationSet over tenants/* on dev" \
  '.[0] | .kind == "ApplicationSet" and .spec.generators[0].git.directories[0].path == "tenants/*" and .spec.generators[0].git.revision == "dev"'
check "app named tenant-<name>, rendering charts/notch-tenant" \
  '.[0] | .spec.template.metadata.name == "tenant-{{.path.basename}}" and .spec.template.spec.source.path == "charts/notch-tenant"'
check "values from tenants/<name>/platform.yaml" \
  '.[0] | .spec.template.spec.source.helm.valueFiles == ["../../tenants/{{.path.basename}}/platform.yaml"]'
check "auto-sync with prune and self-heal" \
  '.[0] | .spec.template.spec.syncPolicy.automated.prune and .spec.template.spec.syncPolicy.automated.selfHeal'

exit $FAILED
