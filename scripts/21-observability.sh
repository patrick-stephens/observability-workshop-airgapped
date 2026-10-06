#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[21-observability]"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_LOCK="${REPO_ROOT}/versions.lock"
CHARTS_DIR="${REPO_ROOT}/charts"
VALUES_DIR="${REPO_ROOT}/values"
NAMESPACE="observability"
KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

error() {
    log "ERROR: $*" >&2
}

locked_field() {
    local key="$1"
    local field="$2"
    local value
    value="$(awk -v key="$key" -v field="$field" '$1 == key { print $field; exit }' "$VERSIONS_LOCK")"
    if [[ -z "$value" ]]; then
        error "required lock entry '$key' is missing from versions.lock"
        return 1
    fi
    printf '%s\n' "$value"
}

release_state() {
    local release_name="$1"
    local expected_chart="$2"
    local release_json chart_name release_status
    release_json="$(helm list --namespace "$NAMESPACE" --output json --kubeconfig "$KUBECONFIG_PATH" | jq -c --arg name "$release_name" '[.[] | select(.name == $name)] | first // empty')"
    if [[ -z "$release_json" ]]; then
        return 1
    fi
    chart_name="$(jq -r '.chart' <<< "$release_json")"
    release_status="$(jq -r '.status' <<< "$release_json")"
    if [[ "$chart_name" != "$expected_chart" ]]; then
        error "release '$release_name' uses '$chart_name'; expected '$expected_chart'"
        return 2
    fi
    if [[ "$release_status" == pending-install || "$release_status" == failed ]]; then
        log "Removing incomplete release '$release_name' with status '$release_status'"
        helm uninstall "$release_name" --namespace "$NAMESPACE" --kubeconfig "$KUBECONFIG_PATH" --no-hooks --wait --timeout 5m
        return 1
    fi
    if [[ "$release_status" != deployed ]]; then
        error "release '$release_name' is in status '$release_status'"
        return 2
    fi
    return 0
}

install_chart() {
    local release_name="$1"
    local chart_name="$2"
    local values_name="${3:-$release_name}"
    local wait_for_ready="${4:-true}"
    local lock_key="chart.${chart_name}"
    local chart_version chart_archive values_file state
    chart_version="$(locked_field "$lock_key" 2)"
    chart_archive="${CHARTS_DIR}/${chart_name}-${chart_version}.tgz"
    values_file="${VALUES_DIR}/${values_name}.yaml"
    if [[ ! -f "$chart_archive" || ! -f "$values_file" ]]; then
        error "missing chart or values for release '$release_name'"
        return 1
    fi

    state=0
    release_state "$release_name" "${chart_name}-${chart_version}" || state=$?
    case "$state" in
        0) ;;
        1) ;;
        *) return "$state" ;;
    esac

    log "Upgrading or installing ${chart_name}-${chart_version} as '$release_name'"
    local -a helm_args=(upgrade --install "$release_name" "$chart_archive" \
        --namespace "$NAMESPACE" \
        --kubeconfig "$KUBECONFIG_PATH" \
        --values "$values_file")
    if [[ "$wait_for_ready" == true ]]; then
        helm_args+=(--wait --timeout 10m)
    fi
    helm "${helm_args[@]}"
}

# Pyroscope's v2 metastore can wedge with "non-monotonic log entries" after a disk write stall, and only a restart
# recovers it (grafana/pyroscope#5432). Apply the probe before waiting for readiness so bootstrap can recover too.
ensure_pyroscope_liveness() {
    log "Ensuring the Pyroscope liveness probe restarts a wedged metastore"
    kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$NAMESPACE" patch statefulset pyroscope --type strategic --patch '
{"spec": {"template": {"spec": {"containers": [{
  "name": "pyroscope",
  "livenessProbe": {
    "httpGet": {"path": "/ready", "port": "http2"},
    "initialDelaySeconds": 120,
    "periodSeconds": 10,
    "timeoutSeconds": 5,
    "failureThreshold": 12
  }
}]}}}}' >/dev/null
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
    for tool in awk helm jq kubectl; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            error "required command '$tool' is not installed"
            exit 1
        fi
    done

    kubectl --kubeconfig "$KUBECONFIG_PATH" create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f - >/dev/null

    install_chart kube-prometheus-stack kube-prometheus-stack
    install_chart loki loki
    install_chart tempo tempo
    install_chart pyroscope pyroscope pyroscope false
    ensure_pyroscope_liveness
    kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$NAMESPACE" rollout status statefulset/pyroscope --timeout=10m
    install_chart otel-collector opentelemetry-collector opentelemetry-collector
    kubectl --kubeconfig "$KUBECONFIG_PATH" create namespace demo --dry-run=client -o yaml |
        kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f - >/dev/null
    kubectl --kubeconfig "$KUBECONFIG_PATH" label namespace demo alertmanagerConfig=enabled --overwrite >/dev/null
    install_chart fluent-bit fluent-bit-collector
    install_chart perses perses
    if [[ -d "${REPO_ROOT}/manifests" ]]; then
        # chaos-*.yaml are demo breaks applied only by scripts/break.sh; the loadgen Job is created by scripts/reset.sh.
        local manifest
        for manifest in "${REPO_ROOT}"/manifests/*.yaml; do
            [[ "$(basename "$manifest")" == chaos-* || "$(basename "$manifest")" == loadgen.yaml ]] && continue
            kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f "$manifest"
        done
    fi
    log "Observability stack is deployed in namespace '$NAMESPACE'"
}

main "$@"
