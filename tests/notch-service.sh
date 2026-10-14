#!/usr/bin/env bash
set -euo pipefail
# Lint and template assertions for charts/notch-service.
# Needs helm and yq (the jq wrapper: `yq -s` slurps every rendered doc).
cd "$(dirname "$0")/.."

CHART=charts/notch-service
FIX=tests/fixtures
FAILED=0

render() { # fixture-name -> rendered manifests on stdout
  helm template "$1" "$CHART" -f "$FIX/$1/service.yaml" -f "$FIX/$1/local/values.yaml"
}

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

helm lint "$CHART" -f "$FIX/hello/service.yaml" -f "$FIX/hello/local/values.yaml" >/dev/null && echo "ok   helm lint"

# Step 1: single container, brief's example
OUT=$(render hello)
for k in Namespace Deployment Service Ingress ExternalSecret NotchPostgres; do
  check "hello renders $k" "any(.[]; .kind == \"$k\")"
done
check "namespaced objects land in hello" \
  '[.[] | select(.kind != "Namespace") | .metadata.namespace] | all(. == "hello")'
check "every object labelled name + managed-by" \
  'all(.[]; .metadata.labels["app.kubernetes.io/name"] == "hello" and .metadata.labels["app.kubernetes.io/managed-by"] == "notch")'
check "no instance label in any selector" \
  '[.[] | (.spec.selector.matchLabels // .spec.selector // {}) | keys[]] | all(. != "app.kubernetes.io/instance")'
check "container port defaults from service port" \
  '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].ports == [{"name":"http","containerPort":8000,"protocol":"TCP"}]'
check "image from env values" \
  '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].image == "notch-hello:local"'
check "probes default to the first port" \
  '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0] | .readinessProbe.tcpSocket.port == "http" and .livenessProbe.tcpSocket.port == "http"'
check "envFrom the synced secrets" \
  '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].envFrom == [{"secretRef":{"name":"hello-secrets"}}]'
check "PG env from the db secret" \
  '.[] | select(.kind == "Deployment") | [.spec.template.spec.containers[0].env[] | select(.name == "PGHOST") | .valueFrom.secretKeyRef] == [{"name":"hello-db","key":"endpoint"}]'
check "ingress host has the port stripped" \
  '.[] | select(.kind == "Ingress") | .spec.rules[0].host == "hello.notch.localhost"'
check "ingress serves TLS for the stripped host from <service>-tls" \
  '.[] | select(.kind == "Ingress") | .spec.tls == [{"hosts":["hello.notch.localhost"],"secretName":"hello-tls"}]'
check "cert-manager issues the ingress cert from the notch CA" \
  '.[] | select(.kind == "Ingress") | .metadata.annotations["cert-manager.io/cluster-issuer"] == "notch-ca"'
check "single port routes /" \
  '.[] | select(.kind == "Ingress") | .spec.rules[0].http.paths == [{"path":"/","pathType":"Prefix","backend":{"service":{"name":"hello","port":{"name":"http"}}}}]'
check "ExternalSecret pulls each listed key from <service>-secrets" \
  '.[] | select(.kind == "ExternalSecret") | .spec.data == [{"secretKey":"APP_JWT_SECRET","remoteRef":{"key":"hello-secrets","property":"APP_JWT_SECRET"}}]'
check "postgres is a NotchPostgres claim, not raw provider-sql resources" \
  'all(.[]; .kind != "Database" and .kind != "Role") and ([.[] | select(.kind == "NotchPostgres") | .apiVersion] == ["notch.dev/v1alpha1"])'
check "claim names the database after the service" \
  '.[] | select(.kind == "NotchPostgres") | .metadata.name == "hello" and .spec.databaseName == "hello"'
check "claim writes creds to <service>-db in the service namespace" \
  '.[] | select(.kind == "NotchPostgres") | .spec.writeConnectionSecretToRef == {"name":"hello-db"}'
check "claim before the Deployment (negative sync wave)" \
  '.[] | select(.kind == "NotchPostgres") | .metadata.annotations["argocd.argoproj.io/sync-wave"] == "-1"'
check "sync waves under metadata.annotations" \
  '[.[] | select(.kind == "Namespace" or .kind == "ExternalSecret") | .metadata.annotations["argocd.argoproj.io/sync-wave"]] | all(. != null)'
check "every container exports traces to Tempo over OTLP/HTTP" \
  '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].env | any(.name == "OTEL_EXPORTER_OTLP_ENDPOINT" and .value == "http://tempo.tempo.svc:4318")'
check "trace service name is the service name" \
  '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].env | any(.name == "OTEL_SERVICE_NAME" and .value == "hello")'

check "no auth: no OIDC_* env" \
  '[.[] | select(.kind == "Deployment") | .spec.template.spec.containers[].env[].name | select(startswith("OIDC_"))] == []'

check "DATABASE_URL built from the PG vars (the common convention)" \
  '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].env | any(.name == "DATABASE_URL" and .value == "postgresql://$(PGUSER):$(PGPASSWORD)@$(PGHOST):$(PGPORT)/$(PGDATABASE)")'
check "DATABASE_URL after the vars it expands (k8s only expands earlier ones)" \
  '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].env | (map(.name) | index("DATABASE_URL")) > (map(.name) | index("PGPASSWORD"))'
OUT=$(helm template hello "$CHART" -f "$FIX/hello/service.yaml" -f "$FIX/hello/local/values.yaml" \
  --set 'service.deployment.containers.app.env[0].name=DATABASE_URL' \
  --set 'service.deployment.containers.app.env[0].value=postgresql+asyncpg://x')
check "container env overrides a platform var by name, no duplicates" \
  '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].env | ([.[] | select(.name == "DATABASE_URL") | .value] == ["postgresql+asyncpg://x"])'
OUT=$(helm template hello "$CHART" -f "$FIX/hello/service.yaml" -f "$FIX/hello/local/values.yaml" \
  --set 'service.deployment.containers.app.env[0].name=EXTRA' \
  --set 'service.deployment.containers.app.env[0].value=$(PGHOST)')
check "container env comes after platform env, so it can use \$(PGHOST)" \
  '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].env | (map(.name) | index("EXTRA")) > (map(.name) | index("PGHOST"))'

# Step 3: tenant service. The tenant chart owns the namespace; anything
# cluster-scoped or in the shared secrets namespace gets a <tenant>- prefix so
# two tenants can both run a "hello".
OUT=$(helm template hello "$CHART" -f "$FIX/hello/service.yaml" -f "$FIX/hello/local/values.yaml" --set namespace=team-alpha)
check "tenant service renders no Namespace" \
  'all(.[]; .kind != "Namespace")'
check "namespaced objects land in the tenant namespace" \
  '[.[] | .metadata.namespace] | all(. == "team-alpha")'
check "database name prefixed with the tenant (Postgres is shared)" \
  '.[] | select(.kind == "NotchPostgres") | .spec.databaseName == "team-alpha-hello"'
check "db claim lives in the tenant namespace (creds land next to it)" \
  '.[] | select(.kind == "NotchPostgres") | .metadata.namespace == "team-alpha"'
check "PGDATABASE is the prefixed database" \
  '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].env | any(.name == "PGDATABASE" and .value == "team-alpha-hello")'
check "source secret prefixed in notch-secrets" \
  '.[] | select(.kind == "ExternalSecret") | .spec.data[0].remoteRef.key == "team-alpha-hello-secrets" and .spec.target.name == "hello-secrets"'

# auth: true gets Keycloak OIDC env (full checks in tests/app-oidc.sh)
OUT=$(render auth-app)
check "auth service gets OIDC_ISSUER" \
  '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].env | any(.name == "OIDC_ISSUER")'

# Step 2: two containers, path split
OUT=$(render web)
check "web has two containers" \
  '.[] | select(.kind == "Deployment") | [.spec.template.spec.containers[].name] == ["backend","frontend"]'
check "ingress splits by path" \
  '.[] | select(.kind == "Ingress") | [.spec.rules[0].http.paths[] | [.path, .backend.service.port.name]] == [["/","http-frontend"],["/api","http-backend"]]'
check "service targets named container ports" \
  '.[] | select(.kind == "Service") | [.spec.ports[].targetPort] == ["frontend","backend"]'
check "OTel env reaches containers without postgres too" \
  '[.[] | select(.kind == "Deployment") | .spec.template.spec.containers[].env | any(.name == "OTEL_SERVICE_NAME")] | all'
check "explicit probe kept" \
  '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].readinessProbe.httpGet.path == "/health"'
check "no postgres, no secrets: no NotchPostgres or ExternalSecret" \
  'all(.[]; .kind != "NotchPostgres" and .kind != "ExternalSecret")'

# Step 3: guard rails
must_fail "duplicate port names across containers" "used by more than one container" \
  -f "$FIX/web/service.yaml" -f "$FIX/web/local/values.yaml" \
  --set 'service.deployment.containers.backend.ports[0].name=frontend'
must_fail "missing image" "image.ref is required" -f "$FIX/hello/service.yaml"
must_fail "multi-port ingress without paths" "needs a path" \
  -f "$FIX/hello/service.yaml" -f "$FIX/hello/local/values.yaml" \
  --set 'service.ports[1].name=metrics' --set 'service.ports[1].port=9090' --set 'service.ports[0].name=http' --set 'service.ports[0].port=8000'

exit $FAILED
