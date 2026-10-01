#!/usr/bin/env bash
set -euo pipefail

# A Job's pod template is immutable, so restarting the load generator is always delete-then-create.

LOG_PREFIX="[loadgen-restart]"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
LOADGEN_MANIFEST="${REPO_ROOT}/manifests/loadgen.yaml"

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

main() {
    if [[ ! -r "$KUBECONFIG_PATH" ]]; then
        log "ERROR: kubeconfig '$KUBECONFIG_PATH' is not readable" >&2
        exit 1
    fi
    # Foreground cascade returns only after the old pod is gone, so the readiness wait below cannot match it.
    kubectl --kubeconfig "$KUBECONFIG_PATH" delete --filename "$LOADGEN_MANIFEST" \
        --ignore-not-found --cascade=foreground --wait=true --timeout=30s >/dev/null
    kubectl --kubeconfig "$KUBECONFIG_PATH" create --filename "$LOADGEN_MANIFEST" >/dev/null
    kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace demo wait \
        --for=condition=Ready pod --selector role=loadgen --timeout=30s >/dev/null
    log "loadgen Job recreated and its pod is Running"
}

main "$@"
