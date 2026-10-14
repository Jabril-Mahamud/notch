#!/usr/bin/env bash
set -euo pipefail
# Static checks for ArgoCD and Grafana SSO through Keycloak, with roles from the
# groups claim. Needs yq (the jq wrapper). Static only: never talks to a cluster.
cd "$(dirname "$0")/.."

FAILED=0
check() { # description jq-expr yaml
  if echo "$3" | yq -e "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; FAILED=1; fi
}
grep_check() { # description pattern file
  if grep -qE -- "$2" "$3"; then echo "ok   $1"; else echo "FAIL $1"; FAILED=1; fi
}

ARGO=$(cat clusters/argocd-values.yaml 2>/dev/null || echo '{}')
check "ArgoCD knows its public URL (OIDC redirect)" '.configs.cm.url == "https://argocd.notch.localhost"' "$ARGO"
check "ArgoCD RBAC: notch-admins group is admin" '.configs.rbac["policy.csv"] | test("g, notch-admins, role:admin")' "$ARGO"
check "ArgoCD RBAC: everyone else read-only" '.configs.rbac["policy.default"] == "role:readonly"' "$ARGO"
check "ArgoCD RBAC reads the groups claim" '.configs.rbac.scopes == "[groups]"' "$ARGO"
check "ArgoCD serves plain http behind a TLS ingress" \
  '.configs.params["server.insecure"] == true and .server.ingress.enabled == true and .server.ingress.hostname == "argocd.notch.localhost" and .server.ingress.tls == true and .server.ingress.annotations["cert-manager.io/cluster-issuer"] == "notch-ca"' "$ARGO"
grep_check "kind-up renders ArgoCD's oidc.config with the notch CA as rootCA" 'rootCA: \|' scripts/kind-up.sh
grep_check "ArgoCD client secret comes from a part-of=argocd secret, not git" 'clientSecret: .*argocd-oidc:clientSecret' scripts/kind-up.sh
grep_check "kind-up labels argocd-oidc part-of argocd (ArgoCD only reads those)" 'label secret argocd-oidc .*app.kubernetes.io/part-of=argocd' scripts/kind-up.sh
grep_check "kind-up upgrades ArgoCD every run" '^helm upgrade --install argocd ' scripts/kind-up.sh
grep_check "with clusters/argocd-values.yaml" '-f clusters/argocd-values.yaml' scripts/kind-up.sh

KPS=$(yq '.spec.source.helm.valuesObject.grafana' addons/kube-prometheus-stack.yaml)
OAUTH=$(echo "$KPS" | yq '.["grafana.ini"]["auth.generic_oauth"]')
check "Grafana logs in through Keycloak's notch realm" \
  '.enabled == true and .client_id == "grafana" and (.auth_url | startswith("https://keycloak.notch.localhost/realms/notch/"))' "$OAUTH"
check "Grafana role from groups: notch-admins Admin, else Viewer" \
  '.role_attribute_path == "contains(groups[*], '"'"'notch-admins'"'"') && '"'"'Admin'"'"' || '"'"'Viewer'"'"'"' "$OAUTH"
check "Grafana verifies Keycloak with the notch CA and reads the secret from a file" \
  '.tls_client_ca == "/etc/secrets/grafana-oidc/ca.crt" and .client_secret == "$__file{/etc/secrets/grafana-oidc/clientSecret}"' "$OAUTH"
check "Grafana mounts grafana-oidc (made by kind-up)" \
  '.extraSecretMounts | any(.secretName == "grafana-oidc" and .mountPath == "/etc/secrets/grafana-oidc")' "$KPS"
check "Grafana root_url + TLS ingress" \
  '.["grafana.ini"].server.root_url == "https://grafana.notch.localhost" and .ingress.enabled == true and .ingress.hosts == ["grafana.notch.localhost"] and .ingress.annotations["cert-manager.io/cluster-issuer"] == "notch-ca"' "$KPS"
grep_check "kind-up creates grafana-oidc in monitoring" '-n monitoring create secret generic grafana-oidc' scripts/kind-up.sh

exit $FAILED
