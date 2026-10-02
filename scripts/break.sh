#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[break]"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="demo"
CHAOS_POLICY="${REPO_ROOT}/manifests/chaos-dns-block.yaml"
LOCAL_PORT=18080

log() {
    printf '%s %s %s\n' "$LOG_PREFIX" "$(date --utc --iso-8601=seconds)" "$*"
}

error() {
    log "ERROR: $*" >&2
}

set_service_mode() {
    local service="$1"
    local mode="$2"
    local port_forward_log port_forward_pid ready=0
    port_forward_log="$(mktemp)"

    kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$NAMESPACE" port-forward \
        --address 127.0.0.1 "service/${service}" "${LOCAL_PORT}:8080" >"$port_forward_log" 2>&1 &
    port_forward_pid=$!

    for ((attempt = 0; attempt < 30; attempt++)); do
        if ! kill -0 "$port_forward_pid" 2>/dev/null; then
            cat "$port_forward_log" >&2
            rm -f "$port_forward_log"
            error "port-forward for service '$service' exited before becoming ready"
            return 1
        fi
        if curl --fail --silent --max-time 1 "http://127.0.0.1:${LOCAL_PORT}/readyz" >/dev/null; then
            ready=1
            break
        fi
        sleep 0.1
    done

    if (( ready == 0 )); then
        kill "$port_forward_pid" 2>/dev/null || true
        wait "$port_forward_pid" 2>/dev/null || true
        cat "$port_forward_log" >&2
        rm -f "$port_forward_log"
        error "service '$service' did not become reachable through port-forward"
        return 1
    fi

    if ! curl --fail --silent --show-error --max-time 5 \
        "http://127.0.0.1:${LOCAL_PORT}/chaos?mode=${mode}" >/dev/null; then
        kill "$port_forward_pid" 2>/dev/null || true
        wait "$port_forward_pid" 2>/dev/null || true
        cat "$port_forward_log" >&2
        rm -f "$port_forward_log"
        error "failed to set '$service' chaos mode to '$mode'"
        return 1
    fi

    kill "$port_forward_pid" 2>/dev/null || true
    wait "$port_forward_pid" 2>/dev/null || true
    rm -f "$port_forward_log"
}

reset_modes() {
    local service
    for service in frontend api backend; do
        set_service_mode "$service" ok
    done
    kubectl --kubeconfig "$KUBECONFIG_PATH" delete \
        --filename "$CHAOS_POLICY" --ignore-not-found >/dev/null
}

main() {
    local action="${1:-}"
    if [[ "$EUID" -ne 0 ]]; then
        error "run this script with sudo"
        exit 1
    fi
    if [[ ! -r "$KUBECONFIG_PATH" ]]; then
        error "K3S kubeconfig '$KUBECONFIG_PATH' is not readable"
        exit 1
    fi
    for tool in curl kubectl; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            error "required command '$tool' is not installed"
            exit 1
        fi
    done

    case "$action" in
        latency)
            set_service_mode backend slow
            log "backend latency enabled; inspect request latency in Perses and traces in Tempo"
            ;;
        errors)
            set_service_mode backend error
            log "backend HTTP 500 errors enabled; inspect Hubble and DemoHighErrorRate in Prometheus/Alertmanager"
            ;;
        dns)
            kubectl --kubeconfig "$KUBECONFIG_PATH" apply --filename "$CHAOS_POLICY" >/dev/null
            log "DNS egress denied for app=api; inspect DROPPED DNS flows in Hubble"
            ;;
        torpedo)
            # A signal generator, not a failure: requests keep returning 200 while torpedoes.detected spikes.
            set_service_mode backend torpedo
            log "backend: torpedo contacts spiking — no request impact"
            ;;
        ok)
            reset_modes
            log "all app chaos modes (including backend torpedo) reset and DNS deny removed; confirm Hubble flows are allowed"
            ;;
        baseline)
            reset_modes
            "${REPO_ROOT}/scripts/loadgen-restart.sh"
            log "baseline restored and load generator restarted; confirm steady Hubble flows"
            ;;
        *)
            error "usage: $0 <latency|errors|dns|torpedo|ok|baseline>"
            exit 2
            ;;
    esac
}

main "$@"
