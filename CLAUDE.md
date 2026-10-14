# Notch — repo guidelines

## What this is
A self-hosted k8s deployment platform. Point it at a repo (or `notch new` one), it ships. Built on ArgoCD, cert-manager, Crossplane, CloudNativePG, ExternalSecrets, ingress-nginx, kube-prometheus-stack, Loki, Tempo, and Railpack. Local Kind only for now.

## Vocabulary (mirrors Yalla)
- **Platform** — top-level grouping, has addons + cluster config (`platform.yaml`)
- **Service** — one deployable thing (`services/<name>/service.yaml`)
- **Environment** — deployment target (local, dev, demo, staging, prod) — per-env `values.yaml`
- **Tenant** — isolated team with own namespace, RBAC, quotas, network policies
- **Addons** — platform infrastructure (ArgoCD, Crossplane, etc.)
- **Deployment flow** — phased promotion between environments

## Repo structure
```
platform.yaml                 ← platform definition, addons, cluster config
clusters/kind.yaml            ← root app (tracks dev), applied by kind-up.sh
addons/                       ← one ArgoCD Application per addon, sync-waved
  services.yaml               ← ApplicationSet: services/* → charts/notch-service
  tenants.yaml                ← ApplicationSet: tenants/* → charts/notch-tenant
  tenant-services.yaml        ← ApplicationSet: tenants/*/services/* into the tenant ns
  notch-postgres/             ← NotchPostgres XRD + CNPG Composition (services claim a DB)
services/<name>/              ← service.yaml + local/values.yaml (written by notch add)
tenants/<team>/               ← platform.yaml (+ services/<svc>/)
charts/notch-service/         ← renders a service (Deployment, Ingress, DB, ExternalSecret)
charts/notch-tenant/          ← renders a tenant (ns, RBAC, quota, netpol)
cmd/notch/                    ← the CLI (cobra); internal/templates/ = notch new starter
scripts/kind-up.sh            ← cluster bring-up (notch up): registry, auth config, kind, ArgoCD
kind.yaml                     ← node config; changes mean recreating the cluster
tests/*.sh                    ← static helm/yq assertions; tests/e2e/ = kuttl (live)
mise.toml                     ← railpack + kuttl versions
.claude/gotchas.md            ← what broke (gitignored)
```

## Workflow
- Feature branch → PR into `dev` → merge after tests pass. ArgoCD tracks `dev`, so live tests need the push.
- Phase release: `dev` → `main` PR, reviewed by Jabril, squash merged, then `main` merged back into `dev`.
- Before merging: `tests/*.sh`, `go test ./...` in `cmd/notch`, and `tests/e2e.sh` on a running cluster.

## Rules
- Conventional commits, imperative, lowercase: `feat: add kind-up script`
- No AI attribution anywhere — commits, comments, PRs. All work appears as written by the repo owner.
- One logical change per commit. No dumps.
- Tests first (TDD): write the test, watch it fail, implement.
- Gotchas go in `.claude/gotchas.md` the moment something breaks.
- Comment the WHY, not the WHAT.
- Local first: the whole stack is feature-complete on Kind (Phase 3) before any cloud code (Civo/EKS, Phase 4). Phase 3 is accepted by onboarding own apps (journalist) locally with `notch add`; they move to the cloud in Phase 5.
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

## v2 gotchas
1. kuttl `script:` runs via `sh -c`: without `set -e` only the last line counts, and `! cmd` never trips `set -e`. Expected failures: `if cmd; then exit 1; fi`
2. Quota on `requests.*`/`limits.*` rejects pods without them: the tenant LimitRange fills defaults. Over-quota tests must set a limit too, or the LimitRange rejects first
3. Cluster-scoped names (Postgres databases/roles, provider-sql MRs, ArgoCD apps, notch-secrets source secrets) collide across tenants: tenant services get a `<tenant>-` prefix (`notch.id`)
4. k8s only expands `$(VAR)` from env entries earlier in the list: platform env first, container env last, overriding by name (duplicates break SSA)
5. Images go to `notch-registry` (`localhost:5001`) with commit-sha tags; a rebuild commits the new tag, never reuses one. Pods resolve `localhost:5001` via the node's `certs.d` hosts.toml (kind-up.sh), which containerd ignores without the `config_path` patch in kind.yaml
6. `pack` (buildpacks) can't export into Docker's containerd image store: Railpack + buildx instead
7. `go:embed` drops dotfiles without `all:`: `public/.gitkeep` vanishes and Next.js `COPY public` fails
8. SQLAlchemy 2.1 maps `postgresql://` to psycopg 3: templates install `psycopg[binary]`
9. The apiserver reads a structured AuthenticationConfiguration from `~/.config/notch/auth/config.yaml` (mounted by kind.yaml) and reloads it live: OIDC changes there, not in kind.yaml
10. Every service Ingress has TLS, so ingress-nginx 308s `http://...:8080` to https: test with `curl --cacert ~/.config/notch/ca/ca.crt https://<host>/`, not plain http (`curl -sf` on a 308 passes vacuously)
11. Services get Postgres via a namespaced `NotchPostgres` claim (addons/notch-postgres); composed names are generated, so `crossplane.io/external-name` carries the real DB/role name. A recreated `<service>-db` needs Reloader's `reloadOnCreate`, or pods keep a dead password

## Reference
- Vault plan: `~/Documents/openclaw/Projects/k8/Notch/Notch.md`
- Yalla reference (READ ONLY): `/mnt/hdd/projects/work/yalla/`
- v1 repos (archived on GitHub): `Jabril-Mahamud/notch`, `Jabril-Mahamud/notch-gitops`
- Test apps; images survive `notch down` in the registry, so after a fresh `notch up` rerun these only to restore secrets:
  - hello, a public starter: `notch add https://github.com/heroku/node-js-getting-started --name hello --postgres --secret SESSION_SECRET`
  - demo, scaffolded by `notch new` (todos + Open-Meteo weather): `notch add https://github.com/Jabril-Mahamud/notch-demo --name demo --postgres`
- Goal: use the CLI like any customer: `notch new`, or `notch add` on any GitHub repo or starter. Dockerfile optional (Railpack builds the rest)
