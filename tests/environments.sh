#!/usr/bin/env bash
set -euo pipefail
# Static checks for environments: a staging Kind cluster driven by the dev
# cluster's ArgoCD. Branch per env (dev -> dev, main -> staging), apps fanned
# out by ApplicationSets over clusters. Needs yq (jq wrapper). Never talks to a cluster.
cd "$(dirname "$0")/.."

FAILED=0
check() { # description jq-expr yaml
  if echo "$3" | yq -e "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; FAILED=1; fi
}
grep_check() { # description pattern file
  if grep -qE -- "$2" "$3"; then echo "ok   $1"; else echo "FAIL $1"; FAILED=1; fi
}

KS=$(cat kind-staging.yaml 2>/dev/null || echo '{}')
check "staging https on 127.0.0.1:8443 (dev holds 443)" \
  '.nodes[0].extraPortMappings | any(.containerPort == 443 and .hostPort == 8443 and .listenAddress == "127.0.0.1")' "$KS"
check "staging http on 127.0.0.1:8081" \
  '.nodes[0].extraPortMappings | any(.containerPort == 80 and .hostPort == 8081 and .listenAddress == "127.0.0.1")' "$KS"
check "staging pulls from notch-registry too (certs.d)" '.containerdConfigPatches[0] | test("config_path")' "$KS"
check "staging node is ingress-ready" '.nodes[0].labels["ingress-ready"] == "true"' "$KS"

IN=$(cat addons/clusters/in-cluster.yaml 2>/dev/null || echo '{}')
check "in-cluster registered as env dev, tracking dev, values dir local" \
  '.metadata.labels["argocd.argoproj.io/secret-type"] == "cluster" and .metadata.labels["notch.dev/env"] == "dev" and .metadata.annotations["notch.dev/revision"] == "dev" and .metadata.annotations["notch.dev/values"] == "local" and .stringData.server == "https://kubernetes.default.svc"' "$IN"

SVC=$(cat addons/services.yaml)
check "services: matrix of env clusters x service dirs" \
  '.spec.generators[0].matrix.generators[0].clusters.selector.matchExpressions[0].key == "notch.dev/env" and .spec.generators[0].matrix.generators[1].git.directories[0].path == "services/*"' "$SVC"
check "services: each env lists services from its own branch" \
  '.spec.generators[0].matrix.generators[1].git.revision | test("notch.dev/revision")' "$SVC"
check "services: chart from the env's branch, deployed to the env's cluster" \
  '(.spec.template.spec.source.targetRevision | test("notch.dev/revision")) and (.spec.template.spec.destination.server | test("^\\{\\{ *\\.server *\\}\\}$"))' "$SVC"
check "services: env values overlay last" \
  '.spec.template.spec.source.helm.valueFiles[2] | test("notch.dev/values")' "$SVC"
check "services: dev apps keep their names, others get -<env>" \
  '.spec.template.metadata.name | test("eq .*notch.dev/env.*\"dev\"")' "$SVC"

ADD=$(cat addons/environments.yaml 2>/dev/null | awk 'FNR == 1 { print "---" } 1' | yq -s . 2>/dev/null || echo '[]')
check "env addons only target non-dev clusters" \
  '[.[] | .spec.generators[0].matrix.generators[0].clusters.selector.matchExpressions[0] | .operator == "NotIn" and .values == ["dev"]] | all' "$ADD"
# The cluster generator already sets name/server/values/metadata; a list key
# with the same name is shadowed in the matrix (every app became staging-staging).
check "env list elements don't reuse cluster generator keys" \
  '[.[] | .spec.generators[0].matrix.generators[1].list.elements[] | keys[]] | all(. != "name" and . != "server" and . != "values" and . != "metadata" and . != "nameNormalized")' "$ADD"
check "env addons: lean set, no observability or Keycloak" \
  '[.[] | .spec.generators[0].matrix.generators[1].list.elements[].addon] | sort == ["cert-manager","cert-manager-issuer","cloudnative-pg","crossplane","crossplane-provider-sql","external-secrets","external-secrets-store","infra","ingress-nginx","notch-postgres","reloader"]' "$ADD"
# The env addon list repeats chart versions: catch drift from addons/*.yaml.
for f in addons/ingress-nginx.yaml addons/cert-manager.yaml addons/cloudnative-pg.yaml addons/crossplane.yaml addons/external-secrets.yaml addons/reloader.yaml; do
  name=$(yq -r '.metadata.name' "$f"); ver=$(yq -r '.spec.source.targetRevision' "$f")
  check "env $name pinned to the same version as dev ($ver)" \
    "[.[] | .spec.generators[0].matrix.generators[1].list.elements[] | select(.addon == \"$name\") | .version] == [\"$ver\"]" "$ADD"
done

grep_check "kind-up takes an env (dev default)" '^ENV=\$\{1:-dev\}' scripts/kind-up.sh
grep_check "staging registers itself in dev's ArgoCD as env staging" 'notch.dev/env=staging' scripts/kind-up.sh
grep_check "staging tracks main unless STAGING_REVISION says otherwise" 'STAGING_REVISION:-main' scripts/kind-up.sh
grep_check "ArgoCD reaches staging over the kind network (--internal)" 'kind get kubeconfig --internal' scripts/kind-up.sh
grep_check "staging gets dev's notch-secrets (ExternalSecret sources)" 'get secret.* -n notch-secrets|-n notch-secrets get secret' scripts/kind-up.sh

for svc in hello demo; do
  check "$svc has a staging overlay on the staging host" \
    ".service.endpoints.internal.hosts == [\"$svc.staging.notch.localhost:8443\"]" "$(cat services/$svc/staging/values.yaml 2>/dev/null || echo '{}')"
done

exit $FAILED
