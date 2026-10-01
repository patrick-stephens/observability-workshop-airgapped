#!/usr/bin/env bash
set -euo pipefail

# Background port-forwards that give the host-side Perses its datasources on localhost.

LOG_PREFIX="[41-perses-portforwards]"
KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
PID_DIR="/tmp/perses-pf"
NAMESPACE="observability"

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

error() {
    log "ERROR: $*" >&2
}

stop_existing() {
    local name="$1"
    local pid_file="${PID_DIR}/${name}.pid"
    local pid
    if [[ -f "$pid_file" ]]; then
        pid="$(cat "$pid_file")"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log "Stopping existing $name port-forward (PID $pid)"
            kill "$pid" 2>/dev/null || true
            for ((attempt = 0; attempt < 20; attempt++)); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
        fi
        rm -f "$pid_file"
    fi
}

start_forward() {
    local name="$1"
    local service="$2"
    local ports="$3"
    local local_port="${ports%%:*}"
    local log_file="${PID_DIR}/${name}.log"
    local pid

    stop_existing "$name"
    # setsid and nohup detach the forward so it outlives this script and the terminal or SSH session that started it.
    setsid nohup kubectl --kubeconfig "$KUBECONFIG_PATH" port-forward "svc/${service}" "$ports" \
        --namespace "$NAMESPACE" --address 127.0.0.1 >"$log_file" 2>&1 < /dev/null &
    pid=$!
    printf '%s\n' "$pid" > "${PID_DIR}/${name}.pid"

    for ((attempt = 0; attempt < 50; attempt++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            cat "$log_file" >&2
            error "$name port-forward exited"
            return 1
        fi
        if (exec 3<>"/dev/tcp/127.0.0.1/${local_port}") 2>/dev/null; then
            log "$name: localhost:${local_port} -> svc/${service} (PID $pid)"
            return 0
        fi
        sleep 0.1
    done
    error "$name port-forward did not open localhost:${local_port}"
    return 1
}

main() {
    if [[ ! -r "$KUBECONFIG_PATH" ]]; then
        error "kubeconfig '$KUBECONFIG_PATH' is not readable"
        exit 1
    fi
    if ! command -v kubectl >/dev/null 2>&1; then
        error "required command 'kubectl' is not installed"
        exit 1
    fi
    mkdir -p "$PID_DIR"

    start_forward prometheus prometheus-operated 9090:9090
    # loki-gateway's Service listens on 80; local port 3100 keeps Loki's conventional port for the Perses datasource.
    start_forward loki loki-gateway 3100:80
    start_forward tempo tempo 3200:3200
}

main "$@"
