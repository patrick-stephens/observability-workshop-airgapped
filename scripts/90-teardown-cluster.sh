#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[90-teardown-cluster]"
NAMESPACE="kube-system"
KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

error() {
    log "ERROR: $*" >&2
}

release_exists() {
    local release_name="$1"
    helm list --namespace "$NAMESPACE" --output json --kubeconfig "$KUBECONFIG_PATH" |
        jq -e --arg name "$release_name" 'any(.[]; .name == $name)' >/dev/null
}

uninstall_release() {
    local release_name="$1"
    if release_exists "$release_name"; then
        log "Uninstalling Helm release '$release_name' from namespace '$NAMESPACE'"
        helm uninstall "$release_name" \
            --namespace "$NAMESPACE" \
            --kubeconfig "$KUBECONFIG_PATH" \
            --no-hooks \
            --wait \
            --timeout 5m
    else
        log "Helm release '$release_name' is already absent"
    fi
}

main() {
    if [[ "$EUID" -ne 0 ]]; then
        error "run this script with sudo"
        exit 1
    fi
    if [[ ! -r "$KUBECONFIG_PATH" ]]; then
        error "K3S kubeconfig '$KUBECONFIG_PATH' is not readable"
        exit 1
    fi
    if ! command -v helm >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        error "helm and jq must be installed"
        exit 1
    fi

    uninstall_release tetragon
    uninstall_release cilium
    log "Tetragon and Cilium Helm releases are removed; K3S remains installed"
}

main "$@"
