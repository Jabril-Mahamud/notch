# Notch — repo guidelines

## What this is
A self-hosted k8s deployment platform. Point it at a repo, it ships. Built on ArgoCD, Crossplane, CloudNativePG, ExternalSecrets, ingress-nginx, kube-prometheus-stack, and Loki.

## Vocabulary (mirrors Yalla)
- **Platform** — top-level grouping, has addons + cluster config (`platform.yaml`)
- **Service** — one deployable thing (`services/<name>/service.yaml`)
- **Environment** — deployment target (local, dev, demo, staging, prod) — per-env `values.yaml`
- **Tenant** — isolated team with own namespace, RBAC, quotas, network policies
- **Addons** — platform infrastructure (ArgoCD, Crossplane, etc.)
- **Deployment flow** — phased promotion between environments

## Repo structure
```
platform.yaml              ← platform definition, addons, cluster config
tenants/                   ← multi-tenant (Phase 2)
services/                  ← platform-level services (Phase 1)
charts/notch-service/      ← the Helm chart that renders services
scripts/kind-up.sh         ← cluster bring-up
cmd/notch/                 ← the CLI
tests/                     ← helm lint, template assertions, kuttl
.claude/gotchas.md         ← what broke (gitignored)
```

## Rules
- Conventional commits, imperative, lowercase: `feat: add kind-up script`
- No AI attribution anywhere — commits, comments, PRs. All work appears as written by the repo owner.
- One logical change per commit. No dumps.
- Tests first (TDD): write the test, watch it fail, implement.
- Gotchas go in `.claude/gotchas.md` the moment something breaks.
- Comment the WHY, not the WHAT.
- No EKS code until Phase 3. Kind only.
- Use Yalla vocabulary in all docs and code.
- README is public-facing — no mention of "learning project" or "interview prep".

## v1 gotchas (bake these in, don't rediscover)
1. Sync-wave annotation at document root is silently pruned — must be under `metadata.annotations`
2. Roots need `directory.recurse: true` or subfolders never sync (still shows Synced)
3. Image `USER` must be numeric or `runAsNonRoot` gives `CreateContainerConfigError`
4. Crossplane managed resources need explicit `providerConfigRef`, else they wait for `default`
5. Use `xpkg.crossplane.io`, not `xpkg.upbound.io` (stale tags). Crossplane pinned 1.x.
6. provider-sql wants `endpoint`, CNPG writes `host` — kind-up.sh puts `endpoint`/`port` in the superuser secret
7. `app.kubernetes.io.instance` stays out of selectors (ArgoCD overwrites; selectors immutable)
8. Containers are a map, not a list (Helm replaces lists)
9. Big CRDs need `ServerSideApply=true`
10. Container port names are pod-wide — two containers naming a port `http` collides
11. ArgoCD "Healthy" can mean "never applied" — check OutOfSync apps
12. Failed auto-sync isn't retried until revision changes — fix the spec AND hit Sync

## Reference
- Vault plan: `~/Documents/openclaw/Projects/k8/Notch/Notch.md`
- Yalla reference (READ ONLY): `/mnt/hdd/projects/work/yalla/`
- v1 repos (archived): `/mnt/hdd/projects/k8/notch/{notch-v1,notch-gitops-v1,notch-hello-v1}/`
