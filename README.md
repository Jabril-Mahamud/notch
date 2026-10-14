# Notch

Self-hosted k8s deployment platform with built-in CI/CD.

Point it at a repo, or let it scaffold one: it builds, ships, routes, and provisions a database. Drive it from the CLI.

## Quick start

Needs Docker, kind, kubectl, helm, Go and [mise](https://mise.jdx.dev/) (`mise install` once for railpack and kuttl).

```bash
go build -o bin/notch ./cmd/notch/
notch up                    # bring up the cluster + platform
notch new <name>            # scaffold a FastAPI + Next.js + Postgres app and deploy it
notch add <repo>            # deploy any repo or GitHub starter, Dockerfile optional
notch list                  # see what's running
notch logs <service>        # tail a service
notch tenant create <team>  # isolated namespace + scoped kubeconfig
notch pause / resume / down # stop, restart or delete the cluster
```

Apps are served at `http://<name>.notch.localhost:8080`.

## How it works

1. `notch add` builds the image, loads it into the cluster and pushes `services/<name>/` to the `dev` branch of this repo
2. ArgoCD detects the change and syncs
3. The chart renders: Deployment, Service, Ingress, DB claim, ExternalSecret
4. Crossplane provisions a Postgres DB per service
5. ingress-nginx routes traffic to your app
6. Prometheus, Loki and Tempo behind Grafana give you metrics, logs and traces

## New apps

`notch new todo` writes a FastAPI + Next.js + Postgres starter to `../todo` (its own git repo), then deploys it with `notch add`. The backend serves `/api` and reads `DATABASE_URL`; the frontend calls `/api` on the same host, so there's nothing to configure.

[notch-demo](https://github.com/Jabril-Mahamud/notch-demo) started this way: a todo list in Postgres plus live weather from Open-Meteo.

## Any repo

`notch add <path-or-git-url> [--name N] [--postgres] [--secret KEY ...] [--build-arg [component:]KEY=VALUE ...]`

- **Dockerfile at the root**: built as is.
- **No Dockerfile**: [Railpack](https://railpack.com/) detects the stack and start command (Node, Python, Go, ...). The container gets `PORT`.
- **Monorepo**: `frontend/` + `backend/` (or `apps/frontend` + `apps/backend`), each with a Dockerfile, become one service: frontend at `/`, backend at `/api`, same host. Frontends that bake the API URL in at build time get it with `--build-arg frontend:NEXT_PUBLIC_API_URL=/api`.

Secrets are prompted and synced through ExternalSecrets. Services with `postgres: true` get `DATABASE_URL` plus the `PG*` vars; a container's own `env` in `service.yaml` overrides them by name and can use `$(PGUSER)` etc., e.g. for a `postgresql+asyncpg://` scheme.

Rerunning `notch add` on an existing service rebuilds and reloads its image (e.g. after `notch down` / `up`); `--secret` again rotates values.

## Tenants

A tenant is a team with its own namespace, RBAC, quota and network policies on the shared cluster.

```bash
notch tenant create team-alpha                 # pushes tenants/team-alpha/, writes team-alpha.kubeconfig
export KUBECONFIG=$PWD/team-alpha.kubeconfig   # edit rights in team-alpha only, 24h token
```

Tenant services live in `tenants/<tenant>/services/<svc>/` (same `service.yaml` + `local/values.yaml` as platform services) and deploy into the tenant's namespace. Quota defaults are in `charts/notch-tenant/values.yaml`; override any key under `tenant.quota` in the tenant's `platform.yaml`.

## Stack

- **ArgoCD**: GitOps sync
- **Crossplane + provider-sql**: per-service Postgres
- **CloudNativePG**: in-cluster Postgres
- **ExternalSecrets** + **Reloader**: secrets, with restarts on change
- **ingress-nginx**: routing
- **kube-prometheus-stack**: metrics + dashboards
- **Loki** + **Alloy**: log aggregation
- **Tempo**: distributed tracing (apps get `OTEL_*` env injected)
- **Railpack**: builds repos without a Dockerfile

## Tests

```bash
for t in tests/*.sh; do [ "$t" = tests/e2e.sh ] || bash "$t"; done  # static: chart + addon assertions
(cd cmd/notch && go test ./...)                                      # CLI
tests/e2e.sh                                                         # kuttl, against a running cluster
```

## License

Apache 2.0
