#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[reset]"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
APP_MANIFEST_DIR="${REPO_ROOT}/manifests/app"

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

error() {
    log "ERROR: $*" >&2
}

main() {
    local required_file
    local -a required_files=(
        "${APP_MANIFEST_DIR}/backend.yaml"
        "${APP_MANIFEST_DIR}/api.yaml"
        "${APP_MANIFEST_DIR}/frontend.yaml"
        "${APP_MANIFEST_DIR}/servicemonitor.yaml"
        "${REPO_ROOT}/manifests/loadgen.yaml"
        "${REPO_ROOT}/manifests/alert-rules.yaml"
        "${REPO_ROOT}/manifests/alertmanager-config.yaml"
        "${REPO_ROOT}/manifests/echo-sink-config.yaml"
        "${REPO_ROOT}/manifests/echo-sink-service.yaml"
        "${REPO_ROOT}/manifests/echo-sink.yaml"
    )
    local -a missing_files=()

    if [[ "$EUID" -ne 0 ]]; then
        error "run this script with sudo"
        exit 1
    fi
    if [[ ! -r "$KUBECONFIG_PATH" ]]; then
        error "K3S kubeconfig '$KUBECONFIG_PATH' is not readable"
        exit 1
    fi
    if ! command -v kubectl >/dev/null 2>&1; then
        error "required command 'kubectl' is not installed"
        exit 1
    fi

    for required_file in "${required_files[@]}"; do
        if [[ ! -f "$required_file" ]]; then
            missing_files+=("$required_file")
        fi
    done
    if (( ${#missing_files[@]} > 0 )); then
        error "demo deployment prerequisites are missing; refusing to delete namespace demo"
        printf '%s\n' "${missing_files[@]}" >&2
        return 1
    fi

    log "Deleting the demo namespace and its previous beat state"
    kubectl --kubeconfig "$KUBECONFIG_PATH" delete namespace demo \
        --ignore-not-found=true --wait=true --timeout=15s
    kubectl --kubeconfig "$KUBECONFIG_PATH" create namespace demo --dry-run=client -o yaml |
        kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f - >/dev/null
    kubectl --kubeconfig "$KUBECONFIG_PATH" label namespace demo alertmanagerConfig=enabled --overwrite >/dev/null

    log "Applying demo app services and metrics monitor"
    for manifest in backend.yaml api.yaml frontend.yaml servicemonitor.yaml; do
        kubectl --kubeconfig "$KUBECONFIG_PATH" apply --filename "${APP_MANIFEST_DIR}/${manifest}" >/dev/null
    done
    log "Applying the load generator"
    kubectl --kubeconfig "$KUBECONFIG_PATH" apply --filename "${REPO_ROOT}/manifests/loadgen.yaml" >/dev/null
    log "Applying alerting resources and echo sink"
    for manifest in alert-rules.yaml alertmanager-config.yaml echo-sink-config.yaml echo-sink-service.yaml echo-sink.yaml; do
        kubectl --kubeconfig "$KUBECONFIG_PATH" apply --filename "${REPO_ROOT}/manifests/${manifest}" >/dev/null
    done

    log "Returning the demo to baseline"
    "$REPO_ROOT/scripts/break.sh" baseline
    log "Demo namespace reset to beat 0"
}

main "$@"
