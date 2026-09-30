#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[verify-cluster]"
KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="kube-system"
PASS_COUNT=0
FAIL_COUNT=0

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    log "PASS: $*"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    log "FAIL: $*"
}

check_daemonset_ready() {
    local daemonset="$1"
    local output
    output="$(kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$NAMESPACE" get daemonset "$daemonset" -o json)" || return 1
    jq -e '
        .status.desiredNumberScheduled > 0 and
        .status.numberReady == .status.desiredNumberScheduled and
        .status.numberAvailable == .status.desiredNumberScheduled
    ' <<< "$output" >/dev/null
}

check_hubble_relay() {
    kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$NAMESPACE" wait \
        --for=condition=Available deployment/hubble-relay --timeout=120s >/dev/null || return 1
    kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$NAMESPACE" get endpointslice \
        --selector kubernetes.io/service-name=hubble-relay -o json |
        jq -e '[.items[].endpoints[]? | select(.conditions.ready == true)] | length > 0' >/dev/null || return 1
    /usr/local/bin/hubble status \
        --port-forward \
        --kubeconfig "$KUBECONFIG_PATH" \
        --kube-namespace "$NAMESPACE" \
        --port-forward-port 4245 \
        --timeout 10s
}

check_hubble_ui_service() {
    kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$NAMESPACE" get service hubble-ui >/dev/null
}

check_cilium_status() {
    /usr/local/bin/cilium status --kubeconfig "$KUBECONFIG_PATH" --wait --wait-duration 5m
}

check_kube_proxy_absent() {
    local pod_list
    if kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$NAMESPACE" get daemonset kube-proxy >/dev/null 2>&1; then
        return 1
    fi
    pod_list="$(kubectl --kubeconfig "$KUBECONFIG_PATH" get pods --all-namespaces -o json)" || return 1
    if jq -e '[.items[] | select(.metadata.name | test("kube-proxy"))] | length > 0' <<< "$pod_list" >/dev/null; then
        return 1
    fi
    if pgrep --exact kube-proxy >/dev/null 2>&1; then
        return 1
    fi
    systemctl cat k3s | grep --quiet -- '--disable-kube-proxy'
}

main() {
    if [[ "$EUID" -ne 0 ]]; then
        log "ERROR: run this script with sudo"
        exit 1
    fi
    if [[ ! -r "$KUBECONFIG_PATH" ]]; then
        log "ERROR: kubeconfig '$KUBECONFIG_PATH' is not readable"
        exit 1
    fi

    if check_daemonset_ready cilium; then
        pass "Cilium agent DaemonSet has all pods ready"
    else
        fail "Cilium agent DaemonSet is missing or not fully ready"
    fi

    if check_hubble_relay; then
        pass "Hubble relay is deployed and reachable over gRPC"
    else
        fail "Hubble relay is not deployed or reachable"
    fi

    if check_hubble_ui_service; then
        pass "Hubble UI Service exists"
    else
        fail "Hubble UI Service is missing"
    fi

    if check_daemonset_ready tetragon; then
        pass "Tetragon DaemonSet has all pods ready"
    else
        fail "Tetragon DaemonSet is missing or not fully ready"
    fi

    if check_cilium_status; then
        pass "cilium status exits successfully"
    else
        fail "cilium status reported an error"
    fi

    if check_kube_proxy_absent; then
        pass "kube-proxy DaemonSet, pods, and process are absent; K3S disables kube-proxy"
    else
        fail "kube-proxy is still configured or running"
    fi

    log "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
    (( FAIL_COUNT == 0 ))
}

main "$@"
