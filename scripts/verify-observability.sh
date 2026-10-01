#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[verify-observability]"
KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="observability"
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

check_release_pods() {
    local release_name="$1"
    local pods
    pods="$(kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$NAMESPACE" get pods -l "app.kubernetes.io/instance=${release_name}" -o json)" || return 1
    jq -e '
        (.items | length > 0) and
        all(.items[];
            .status.phase == "Running" and
            ((.status.containerStatuses // []) | length > 0) and
            all(.status.containerStatuses[]; .ready == true)
        )
    ' <<< "$pods" >/dev/null
}

check_service() {
    kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$NAMESPACE" get service "$1" >/dev/null
}

check_fluent_bit_config() {
    kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$NAMESPACE" get configmap \
        -l app.kubernetes.io/instance=fluent-bit -o json |
        jq -e '[.items[].data[]? | select(contains("loki-gateway.observability.svc.cluster.local"))] | length > 0' >/dev/null
}

check_hubble_monitor() {
    kubectl --kubeconfig "$KUBECONFIG_PATH" get servicemonitor -A -o json |
        jq -e '
            [.items[] | select(.metadata.name == "cilium-hubble")]
            | length == 1
            and .[0].spec.selector.matchLabels["k8s-app"] == "hubble"
            and .[0].spec.endpoints[0].port == "hubble-metrics"
        ' >/dev/null
}

check_hubble_metric() {
    local prometheus_ip response
    prometheus_ip="$(kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace "$NAMESPACE" get service kube-prometheus-stack-prometheus -o jsonpath='{.spec.clusterIP}')" || return 1
    response="$(curl --fail --silent --show-error --get "http://${prometheus_ip}:9090/api/v1/query" --data-urlencode 'query=hubble_http_requests_total')" || return 1
    jq -e '.status == "success" and (.data.result | length > 0)' <<< "$response" >/dev/null
}

check_alert_resources() {
    kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace demo get prometheusrule demo-hubble-alerts -o json |
        jq -e '.metadata.labels.release == "kps" and ([.spec.groups[].rules[] | select(.alert == "DemoHighErrorRate" and .for == "1m")] | length > 0)' >/dev/null || return 1
    kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace demo get alertmanagerconfig demo-local-webhook -o json |
        jq -e '
            .metadata.labels.alertmanagerConfig == "workshop" and
            .spec.route.receiver == "echo" and
            .spec.route.groupBy == ["alertname", "namespace"] and
            ([.spec.receivers[].webhookConfigs[].url] | any(. == "http://echo-sink.demo.svc.cluster.local:8080/alerts"))
        ' >/dev/null
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
    for tool in curl jq kubectl; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log "ERROR: required command '$tool' is not installed"
            exit 1
        fi
    done

    for release in kube-prometheus-stack loki tempo pyroscope otel-collector fluent-bit perses; do
        if check_release_pods "$release"; then
            pass "${release} pods are running and ready"
        else
            fail "${release} pods are missing or not ready"
        fi
    done

    for service in kube-prometheus-stack-prometheus loki-gateway tempo perses otel-collector-opentelemetry-collector; do
        if check_service "$service"; then
            pass "Service '${service}' exists"
        else
            fail "Service '${service}' is missing"
        fi
    done

    if check_fluent_bit_config; then
        pass "Fluent Bit collector configuration forwards logs to Loki"
    else
        fail "Fluent Bit collector Loki configuration is missing"
    fi

    if check_hubble_monitor; then
        pass "Hubble metrics ServiceMonitor is configured"
    else
        fail "Hubble metrics ServiceMonitor is missing or incorrect"
    fi

    if check_hubble_metric; then
        pass "Hubble HTTP request series is present in Prometheus"
    else
        fail "Hubble HTTP request series is missing from Prometheus"
    fi

    if check_alert_resources; then
        pass "PrometheusRule and local AlertmanagerConfig are selected"
    else
        fail "PrometheusRule or AlertmanagerConfig is missing or misconfigured"
    fi

    if kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace demo wait --for=condition=Available deployment/echo-sink --timeout=30s >/dev/null; then
        pass "local Alertmanager JSON echo sink is available"
    else
        fail "local Alertmanager JSON echo sink is not available"
    fi

    if kubectl --kubeconfig "$KUBECONFIG_PATH" --namespace demo get service echo-sink >/dev/null; then
        pass "local Alertmanager webhook Service exists"
    else
        fail "local Alertmanager webhook Service is missing"
    fi

    log "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
    (( FAIL_COUNT == 0 ))
}

main "$@"
