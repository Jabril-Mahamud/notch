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

exit $FAILED
