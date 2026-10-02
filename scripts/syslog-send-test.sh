#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[syslog-send-test]"
KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="observability"
SERVICE="fluent-bit-syslog"
LOCAL_PORT="${SYSLOG_TEST_LOCAL_PORT:-15140}"
LOKI_URL="${LOKI_URL:-http://localhost:3100}"
PORT_FORWARD_LOG=""
PORT_FORWARD_PID=""

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

error() {
    log "ERROR: $*" >&2
}

cleanup() {
    if [[ -n "$PORT_FORWARD_PID" ]]; then
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
        wait "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
    if [[ -n "$PORT_FORWARD_LOG" ]]; then
        rm -f "$PORT_FORWARD_LOG"
    fi
}

main() {
    local marker timestamp line response start_time end_time attempt
    for tool in curl date jq kubectl nc; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            error "required command '$tool' is not installed"
            return 1
        fi
    done
    if [[ ! -r "$KUBECONFIG_PATH" ]]; then
        error "kubeconfig '$KUBECONFIG_PATH' is not readable; run with sudo or set KUBECONFIG"
        return 1
    fi
    if ! kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$NAMESPACE" get service "$SERVICE" >/dev/null; then
        error "Service ${NAMESPACE}/${SERVICE} is missing"
        return 1
    fi

    PORT_FORWARD_LOG="$(mktemp)"
    kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$NAMESPACE" port-forward \
        --address 127.0.0.1 "service/${SERVICE}" "${LOCAL_PORT}:5140" >"$PORT_FORWARD_LOG" 2>&1 &
    PORT_FORWARD_PID=$!
    for ((attempt = 0; attempt < 50; attempt++)); do
        if ! kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
            cat "$PORT_FORWARD_LOG" >&2
            error "port-forward exited before opening localhost:${LOCAL_PORT}"
            return 1
        fi
        if grep -q "Forwarding from 127.0.0.1:${LOCAL_PORT}" "$PORT_FORWARD_LOG"; then
            break
        fi
        sleep 0.1
    done
    if ! grep -q "Forwarding from 127.0.0.1:${LOCAL_PORT}" "$PORT_FORWARD_LOG"; then
        cat "$PORT_FORWARD_LOG" >&2
        error "port-forward did not open localhost:${LOCAL_PORT}"
        return 1
    fi

    marker="syslog-preflight-$(date +%s%N)"
    start_time="$(date -u --date='1 minute ago' '+%Y-%m-%dT%H:%M:%SZ')"
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')"
    line="<134>1 ${timestamp} syslog-test syslog-send-test 1 PREFLIGHT [demo@32473 contact=\"submarine\" bearing=\"045\" range_nm=\"12\" confidence=\"high\"] ${marker}"
    if ! printf '%s\n' "$line" | nc -N -w 3 127.0.0.1 "$LOCAL_PORT"; then
        error "failed to send the RFC5424 test line"
        return 1
    fi

    sleep 5
    for ((attempt = 0; attempt < 6; attempt++)); do
        end_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        if response="$(curl --fail --silent --show-error --max-time 5 --get \
            --data-urlencode "query={source=\"syslog\"} |= \"${marker}\"" \
            --data-urlencode "start=${start_time}" \
            --data-urlencode "end=${end_time}" \
            --data-urlencode direction=backward \
            --data-urlencode limit=100 \
            "${LOKI_URL}/loki/api/v1/query_range")" &&
            jq -e --arg marker "$marker" \
                '.data.result[]?.values[]?[1]? | strings | contains($marker)' <<< "$response" >/dev/null; then
            log "✓ syslog path working"
            return 0
        fi
        (( attempt == 5 )) || sleep 1
    done

    error "Loki did not return marker '$marker' for {source=\"syslog\"}"
    return 1
}

trap cleanup EXIT
main "$@"
