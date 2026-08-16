# notch

The cluster definition and the shared Helm chart every Notch service is deployed
with. No application code, no environment values — those live in the two sibling
repos.

| Repo | Holds |
|---|---|
| **notch** (this one) | `cluster.yaml`, the `notch-app` chart |
| [notch-gitops](https://github.com/Jabril-Mahamud/notch-gitops) | ArgoCD root, addons, Crossplane resources, per-service values |
| [notch-fe-app](https://github.com/Jabril-Mahamud/notch-fe-app) | The Notch application: FastAPI backend, Next.js frontend, CI |

## cluster.yaml

```bash
eksctl create cluster -f cluster.yaml
```

`notch-mgmt`, eu-west-1, Kubernetes 1.33. Choices worth knowing before you change
anything:

- **NAT gateway disabled and nodes in public subnets.** This is what keeps the
  cluster off a ~£30/mo NAT bill. Private nodes would need one.
- **Spot t3/t3a.medium**, desired 2, max 4.
- **IRSA, two roles.** `notch-eso` for external-secrets, read-only and scoped to
  the `notch/*` prefix in Secrets Manager. `notch-crossplane-aws` for the AWS
  provider, `roleOnly` because Crossplane creates that service account itself
  from the DeploymentRuntimeConfig in notch-gitops.
- **EBS CSI driver addon.** EKS ≥1.23 does not ship it, and CloudNativePG cannot
  bind a PersistentVolume without it.

eksctl must run before ArgoCD syncs the addons: external-secrets is installed
with `serviceAccount.create=false` and reuses the SA eksctl made.

## The notch-app chart

One chart for every service. A service is a set of values files, not a new chart.

Values are layered by the ApplicationSet in notch-gitops, later wins:

```
envs/<env>/services.common.yaml     every service in an env
services/<name>/service.yaml        one service, every env
services/<name>/<env>/values.yaml   one service, one env
```

Renders a Deployment, and conditionally a Service, Ingress and ExternalSecret.

### Container shape

```yaml
service:
  deployment:
    containers:
      <name>:
        image: { ref: <required>, pullPolicy: IfNotPresent }
        ports: [{ name, containerPort, protocol }]
        env: { KEY: value }
        envSecrets: { ENV_NAME: { name: <secret>, key: <key> } }
        secrets: [<secret names for envFrom>]   # default: [<service>-secrets]
        resources: {}
        securityContext: {}
        livenessProbe: {}
        readinessProbe: {}
```

`service.deployment.containers` is empty in `values.yaml` on purpose. Helm deep
merges maps, so any container declared there would be injected into every
service on top of the ones it declares.

### Things the chart will fail loudly about

Rendering stops rather than producing something broken:

- `service.name` or `global.env` missing — a values file is unreachable or
  misnamed
- `containers` empty — the Deployment would have no containers
- a container with no `image.ref`
- `ingress.enabled` with no `host`, or with no `rules`
- a service port or ingress rule with no name

### Two details that bite

- **`app.kubernetes.io/instance` is excluded from the selector labels.** It is
  ArgoCD's default `instanceLabelKey`, so ArgoCD overwrites it and the
  Deployment's selector stops matching its own pods.
- **The reloader annotation covers both routes into a container**, `envFrom`
  secrets and `secretKeyRef` ones. Miss the second and a rotated database
  password never restarts the pod using it.

### Secrets

`externalSecret.enabled` (default true) syncs
`notch/<env>/apps/<name>/*` from AWS Secrets Manager into `<name>-secrets`, with
the prefix stripped from the key. `creationPolicy: Owner`, so external-secrets
fully owns that Secret — anything written by Crossplane goes in its own secret
and is wired per-container through `envSecrets`.

### Non-root

Services set `podSecurityContext.runAsNonRoot: true`. The kubelet cannot resolve
a username to a UID, so an image whose `USER` is a name fails the same way one
with no `USER` at all does: `CreateContainerConfigError`. Image `USER`
directives must be numeric.
