#!/usr/bin/env bash
set -euo pipefail

# Replay node only, after `sudo scripts/30-stack.sh --offline`: proves the node is airgapped and the demo is ready.

LOG_PREFIX="[95-preflight-offline]"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST_JSON="${REPO_ROOT}/bundle/manifest.json"
REGISTRY_URL="http://registry.lab.local:5000"
MISSING=()

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

add_missing() {
    MISSING+=("$1")
}

# A default route is what would carry traffic to the internet; an airgapped node must have none for IPv4 or IPv6.
check_no_internet_route() {
    local family routes
    for family in -4 -6; do
        routes="$(ip "$family" route show default 2>/dev/null || true)"
        if [[ -n "$routes" ]]; then
            add_missing "IPv${family#-} default route present (${routes//$'\n'/; }); the node can reach the internet"
        fi
    done
    if ip -4 route get 1.1.1.1 >/dev/null 2>&1; then
        add_missing "IPv4 route to public address 1.1.1.1 exists via $(ip -4 route get 1.1.1.1 | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1); exit }')"
    fi
}

check_registry_images() {
    local status repository digest reference served=0
    status="$(curl --silent --output /dev/null --write-out '%{http_code}' --connect-timeout 3 --max-time 5 "${REGISTRY_URL}/v2/" || true)"
    if [[ "$status" != 200 ]]; then
        add_missing "local registry ${REGISTRY_URL} is unreachable (HTTP ${status:-none})"
        return
    fi
    if [[ ! -f "$MANIFEST_JSON" ]]; then
        add_missing "bundle/manifest.json is missing, so registry contents cannot be checked"
        return
    fi
    while IFS=$'\t' read -r reference repository digest; do
        status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
            --head \
            --header 'Accept: application/vnd.oci.image.index.v1+json' \
            --header 'Accept: application/vnd.oci.image.manifest.v1+json' \
            --header 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
            --header 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
            "${REGISTRY_URL}/v2/${repository}/manifests/${digest}" || true)"
        if [[ "$status" == 200 ]]; then
            served=$((served + 1))
        else
            add_missing "local registry does not serve $reference (HTTP ${status:-none})"
        fi
    done < <(jq -r '.images[] | [.reference, .registry_repository, .oci_digest] | @tsv' "$MANIFEST_JSON")
    REGISTRY_IMAGE_COUNT="$served"
}

check_demo_preflight() {
    local output
    if ! output="$("${SCRIPT_DIR}/preflight.sh" 2>&1)"; then
        while IFS= read -r line; do
            add_missing "demo readiness: ${line#\[preflight\] }"
        done <<< "$output"
    fi
}

main() {
    REGISTRY_IMAGE_COUNT=0
    for tool in awk curl ip jq kubectl; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log "ERROR: required command '$tool' is not installed" >&2
            exit 1
        fi
    done

    check_no_internet_route
    check_registry_images
    check_demo_preflight

    if (( ${#MISSING[@]} > 0 )); then
        printf '%s\n' "${MISSING[@]/#/${LOG_PREFIX} missing: }" >&2
        exit 1
    fi
    log "✓ offline preflight passed — no internet route, registry serves ${REGISTRY_IMAGE_COUNT} bundle images, demo ready"
}

main "$@"
