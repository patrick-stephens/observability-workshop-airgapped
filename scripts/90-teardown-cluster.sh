#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[90-teardown-cluster]"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

error() {
    log "ERROR: $*" >&2
}

release_exists() {
    local release_name="$1"
    local namespace="$2"
    helm list --namespace "$namespace" --output json --kubeconfig "$KUBECONFIG_PATH" |
        jq -e --arg name "$release_name" 'any(.[]; .name == $name)' >/dev/null
}

uninstall_release() {
    local release_name="$1"
    local namespace="$2"
    if release_exists "$release_name" "$namespace"; then
        log "Uninstalling Helm release '$release_name' from namespace '$namespace'"
        helm uninstall "$release_name" \
            --namespace "$namespace" \
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
    if ! command -v helm >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v kubectl >/dev/null 2>&1; then
        error "helm, jq, and kubectl must be installed"
        exit 1
    fi

    for manifest in alertmanager-config.yaml alert-rules.yaml echo-sink.yaml echo-sink-service.yaml echo-sink-config.yaml; do
        if [[ -f "${REPO_ROOT}/manifests/${manifest}" ]]; then
            log "Removing alerting resources from ${manifest}"
            kubectl --kubeconfig "$KUBECONFIG_PATH" delete --filename "${REPO_ROOT}/manifests/${manifest}" --ignore-not-found
        fi
    done

    for release in perses fluent-bit otel-collector pyroscope tempo loki kube-prometheus-stack; do
        uninstall_release "$release" observability
    done
    for release in tetragon cilium; do
        uninstall_release "$release" kube-system
    done
    log "Observability, Tetragon, and Cilium Helm releases are removed; K3S remains installed"
}

main "$@"
