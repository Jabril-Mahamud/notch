#!/usr/bin/env bash
set -euo pipefail
# Static checks for kind.yaml and the registry wiring in kind-up.sh.
# Changing kind.yaml means recreating the cluster, so this pins what it must carry.
# Needs yq (the jq wrapper). Static only: never talks to a cluster.
cd "$(dirname "$0")/.."

FAILED=0
OUT=$(cat kind.yaml 2>/dev/null || true)
check() { # description jq-expr [yaml]
  if echo "${3:-$OUT}" | yq -e "$2" >/dev/null 2>&1; then
    echo "ok   $1"
  else
    echo "FAIL $1"; FAILED=1
  fi
}
grep_check() { # description pattern file
  if grep -qE -- "$2" "$3"; then echo "ok   $1"; else echo "FAIL $1"; FAILED=1; fi
}

NODE='.nodes[0]'
check "containerd reads registry hosts from certs.d" \
  '.containerdConfigPatches[0] | test("config_path = \"/etc/containerd/certs.d\"")'
check "host 8080 -> ingress http" \
  "$NODE.extraPortMappings | any(.containerPort == 80 and .hostPort == 8080)"
check "127.0.0.1:443 -> ingress https" \
  "$NODE.extraPortMappings | any(.containerPort == 443 and .hostPort == 443 and .listenAddress == \"127.0.0.1\")"
check "auth config dir mounted into the node" \
  "$NODE.extraMounts | any(.containerPath == \"/etc/notch/auth\" and (.hostPath | test(\"@NOTCH_HOME@/auth\")))"

KUBEADM=$(echo "$OUT" | yq -r "$NODE.kubeadmConfigPatches[0]" 2>/dev/null || true)
check "apiserver reads a structured authentication config" \
  '.apiServer.extraArgs["authentication-config"] == "/etc/notch/auth/config.yaml"' "$KUBEADM"
check "apiserver pod mounts the auth dir" \
  '.apiServer.extraVolumes | any(.hostPath == "/etc/notch/auth" and .mountPath == "/etc/notch/auth")' "$KUBEADM"

grep_check "kind-up names the registry notch-registry" \
  '^REGISTRY=notch-registry$' scripts/kind-up.sh
grep_check "kind-up starts it on 127.0.0.1:5001" \
  'docker run .*-p 127\.0\.0\.1:5001:5000 .*--name "\$REGISTRY"' scripts/kind-up.sh
grep_check "kind-up joins the registry to the kind network" \
  'docker network connect kind "\$REGISTRY"' scripts/kind-up.sh
grep_check "kind-up maps localhost:5001 to notch-registry in the node" \
  'certs\.d/localhost:5001' scripts/kind-up.sh
grep_check "CLI pushes to the same registry" \
  'Registry = "localhost:5001"' cmd/notch/internal/image.go

# *.notch.localhost resolves to ::1 inside the cluster: pods and the apiserver
# would never reach the ingress (OIDC issuer, apps calling their own public URL).
grep_check "kind-up rewrites *.notch.localhost to the ingress controller in CoreDNS" \
  'rewrite name regex .*notch.*localhost.* ingress-nginx-controller\.ingress-nginx\.svc\.cluster\.local' scripts/kind-up.sh
grep_check "kind-up points the node (apiserver) at the ingress for keycloak.notch.localhost" \
  'keycloak\.notch\.localhost.*/etc/hosts|/etc/hosts.*keycloak\.notch\.localhost' scripts/kind-up.sh
grep_check "notch resume reruns kind-up (docker start resets /etc/hosts)" \
  'func Resume\(root string\)' cmd/notch/internal/kind.go

# OIDC: kind-up writes the apiserver's JWT authenticator (reloaded live).
grep_check "apiserver trusts the Keycloak notch realm" \
  'url: https://keycloak\.notch\.localhost/realms/notch' scripts/kind-up.sh
grep_check "tokens must be for the kubernetes client" 'audiences: \[kubernetes\]' scripts/kind-up.sh
grep_check "users and groups get an oidc: prefix (can't collide with system:)" \
  'groups: \{ claim: groups, prefix: "oidc:" \}' scripts/kind-up.sh
grep_check "CA is written before the auth config that embeds it" \
  '.' <(awk '/ca\/ca\.crt" \]/ {ca=NR} /AuthenticationConfiguration/ {auth=NR} END {if (ca && auth && ca < auth) print "ordered"}' scripts/kind-up.sh)
OUT=$(cat addons/oidc-rbac.yaml 2>/dev/null || true)
check "notch-admins group is cluster-admin" \
  '.kind == "ClusterRoleBinding" and .roleRef.name == "cluster-admin" and .subjects == [{"kind":"Group","name":"oidc:notch-admins","apiGroup":"rbac.authorization.k8s.io"}]'

exit $FAILED
