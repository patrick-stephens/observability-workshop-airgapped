#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[preflight]"
KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
OBSERVABILITY_NAMESPACE="observability"
DEMO_NAMESPACE="demo"
MISSING=()

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

add_missing() {
    MISSING+=("$1")
}

check_registry() {
    local status
    status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
        --connect-timeout 3 --max-time 5 http://registry.lab.local:5000/v2/ || true)"
    [[ "$status" == 200 || "$status" == 401 ]]
}

check_daemonset_ready() {
    kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace kube-system get daemonset cilium -o json |
        jq -e '.status.desiredNumberScheduled > 0 and .status.numberReady == .status.desiredNumberScheduled and .status.numberAvailable == .status.desiredNumberScheduled' >/dev/null
}

check_service_ready() {
    local service="$1"
    local port="$2"
    local path="$3"
    local address
    address="$(kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$OBSERVABILITY_NAMESPACE" get service "$service" -o jsonpath='{.spec.clusterIP}')" || return 1
    [[ -n "$address" ]] || return 1
    curl --fail --silent --show-error --connect-timeout 3 --max-time 10 "http://${address}:${port}${path}" >/dev/null
}

check_perses_ready() {
    check_service_ready perses 8080 /api/v1/health
}

check_demo_pods() {
    local pods
    pods="$(kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$DEMO_NAMESPACE" get pods -o json)" || return 1
    jq -e '
        (.items | length > 0) and
        all(.items[];
            .status.phase == "Running" and
            ((.status.containerStatuses // []) | length > 0) and
            all(.status.containerStatuses[]; .ready == true)
        )
    ' <<< "$pods" >/dev/null
}

check_demo_services() {
    local service
    for service in frontend api backend; do
        kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$DEMO_NAMESPACE" get service "$service" >/dev/null || return 1
    done
}

check_loadgen() {
    local pods
    pods="$(kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$DEMO_NAMESPACE" get pods --selector role=loadgen -o json)" || return 1
    jq -e '
        (.items | length > 0) and
        any(.items[];
            .status.phase == "Running" and
            all(.status.containerStatuses[]?; .ready == true)
        )
    ' <<< "$pods" >/dev/null
}

main() {
    if [[ ! -r "$KUBECONFIG_PATH" ]]; then
        log "ERROR: kubeconfig '$KUBECONFIG_PATH' is not readable"
        exit 1
    fi
    for tool in curl jq kubectl; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log "ERROR: required command '$tool' is not installed"
            exit 1
        fi
    done

    check_registry || add_missing "local registry registry.lab.local:5000 is unreachable"
    check_daemonset_ready || add_missing "Cilium agent DaemonSet is not fully ready"
    check_service_ready kube-prometheus-stack-prometheus 9090 /-/ready || add_missing "Prometheus is not ready"
    check_service_ready loki 3100 /ready || add_missing "Loki is not ready"
    check_service_ready tempo 3200 /ready || add_missing "Tempo is not ready"
    check_perses_ready || add_missing "Perses is not reachable at /api/v1/health"
    check_demo_pods || add_missing "demo namespace is missing or contains pods that are not Running and ready"
    check_demo_services || add_missing "one or more demo Services (frontend, api, backend) are missing"
    check_loadgen || add_missing "loadgen Job has no Running and ready pod"

    if (( ${#MISSING[@]} > 0 )); then
        printf '%s\n' "${MISSING[@]/#/${LOG_PREFIX} missing: }" >&2
        exit 1
    fi

    "$(dirname "${BASH_SOURCE[0]}")/break.sh" baseline >/dev/null
    log "✓ preflight passed — demo ready"
}

main "$@"
