# Notch

Self-hosted k8s deployment platform with built-in CI/CD.

Point it at a repo — it builds, ships, routes, and provisions a database. Drive it from the CLI.

## Quick start

```bash
notch up          # bring up the cluster + platform
notch add <repo>  # deploy an app
notch list        # see what's running
notch tenant create <team>  # isolated namespace + scoped kubeconfig
```

## How it works

1. Push a `service.yaml` to the gitops repo (or run `notch add`)
2. ArgoCD detects the change and syncs
3. The chart renders: Deployment, Service, Ingress, DB claim, ExternalSecret
4. Crossplane provisions a Postgres DB per service
5. ingress-nginx routes traffic to your app
6. Prometheus, Loki and Tempo behind Grafana give you metrics, logs and traces

## Tenants

A tenant is a team with its own namespace, RBAC, quota and network policies on the shared cluster.

```bash
notch tenant create team-alpha       # pushes tenants/team-alpha/, writes team-alpha.kubeconfig
export KUBECONFIG=$PWD/team-alpha.kubeconfig   # edit rights in team-alpha only, 24h token
```

Tenant services live in `tenants/<tenant>/services/<svc>/` (same `service.yaml` + `local/values.yaml` as platform services) and deploy into the tenant's namespace. Quota defaults are in `charts/notch-tenant/values.yaml`; override any key under `tenant.quota` in the tenant's `platform.yaml`.

## Stack

- **ArgoCD** — GitOps sync
- **Crossplane + provider-sql** — per-service Postgres
- **CloudNativePG** — in-cluster Postgres
- **ExternalSecrets** — secrets management
- **ingress-nginx** — routing + TLS
- **kube-prometheus-stack** — metrics + dashboards
- **Loki** — log aggregation
- **Alloy** — ships pod logs to Loki
- **Tempo** — distributed tracing (apps get `OTEL_*` env injected)

## License

Apache 2.0
