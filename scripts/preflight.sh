#!/usr/bin/env bash
# Originated in prompt 5; prompt 7 added the host Perses, port-forward, OTLP metric, and webhook assertions.
set -euo pipefail

LOG_PREFIX="[preflight]"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
OBSERVABILITY_NAMESPACE="observability"
DEMO_NAMESPACE="demo"
PORT_FORWARD_PID_DIR="/tmp/perses-pf"
# localhost:8080 is the host Perses, so the frontend webhook receiver is reached through its own port-forward.
FRONTEND_LOCAL_PORT=18081
WEBHOOK_PAYLOAD="${SCRIPT_DIR}/preflight-test-payload.json"
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
    kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$DEMO_NAMESPACE" get job loadgen >/dev/null 2>&1 || return 1
    pods="$(kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$DEMO_NAMESPACE" get pods --selector role=loadgen -o json)" || return 1
    jq -e '
        (.items | length > 0) and
        any(.items[];
            .status.phase == "Running" and
            all(.status.containerStatuses[]?; .ready == true)
        )
    ' <<< "$pods" >/dev/null
}

check_host_perses() {
    # Perses v0.54 serves health at /api/v1/health; /api/health returns 404.
    curl --fail --silent --max-time 5 http://localhost:8080/api/v1/health >/dev/null
}

# Posts a synthetic firing alert, checks it reaches /status, then resolves it so the UI banner is left clear.
check_webhook_receiver() {
    local forward_pid forward_log result=0 base="http://127.0.0.1:${FRONTEND_LOCAL_PORT}"
    forward_log="$(mktemp)"
    kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$DEMO_NAMESPACE" port-forward \
        --address 127.0.0.1 service/frontend "${FRONTEND_LOCAL_PORT}:8080" >"$forward_log" 2>&1 &
    forward_pid=$!
    for ((attempt = 0; attempt < 30; attempt++)); do
        curl --fail --silent --max-time 1 "${base}/readyz" >/dev/null && break
        sleep 0.2
    done

    curl -fsS -X POST "${base}/webhook/alertmanager" \
        -H 'Content-Type: application/json' \
        -d @"$WEBHOOK_PAYLOAD" >/dev/null || result=1
    if (( result == 0 )); then
        curl -fsS "${base}/status" | grep -q 'PreflightTest' || result=1
    fi
    jq '.status = "resolved" | .alerts[].status = "resolved"' "$WEBHOOK_PAYLOAD" |
        curl -fsS -X POST "${base}/webhook/alertmanager" -H 'Content-Type: application/json' -d @- >/dev/null || true

    kill "$forward_pid" 2>/dev/null || true
    wait "$forward_pid" 2>/dev/null || true
    rm -f "$forward_log"
    return "$result"
}

check_port_forwards() {
    local name pid
    for name in prometheus loki tempo; do
        [[ -f "${PORT_FORWARD_PID_DIR}/${name}.pid" ]] || return 1
        pid="$(cat "${PORT_FORWARD_PID_DIR}/${name}.pid")"
        if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
    done
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
    check_loadgen || add_missing "loadgen Job is missing or has no Running and ready pod"
    check_host_perses || add_missing "host Perses is not responding at http://localhost:8080/api/v1/health (run scripts/40-perses.sh)"
    check_port_forwards || add_missing "one or more Perses port-forwards in ${PORT_FORWARD_PID_DIR} are not running (run scripts/41-perses-portforwards.sh)"
    [[ -r "$WEBHOOK_PAYLOAD" ]] || add_missing "synthetic webhook payload ${WEBHOOK_PAYLOAD} is missing"

    if (( ${#MISSING[@]} > 0 )); then
        printf '%s\n' "${MISSING[@]/#/${LOG_PREFIX} missing: }" >&2
        exit 1
    fi

    curl -fsS 'http://localhost:9090/api/v1/query?query=torpedoes_detected_total' \
        | grep -q '"value"' || {
            echo "✗ torpedoes_detected_total not in Prometheus — OTLP metrics path broken"
            exit 1
        }

    check_webhook_receiver || {
        echo "✗ frontend webhook receiver did not accept the synthetic PreflightTest alert or show it in /status"
        exit 1
    }

    "$(dirname "${BASH_SOURCE[0]}")/break.sh" baseline >/dev/null
    log "✓ preflight passed — demo ready"
}

main "$@"
