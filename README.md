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
