#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[verify-installer]"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE_REFERENCES="${REPO_ROOT}/bundle/image-references-amd64.txt"
STORAGE_LOG="/var/log/o11y-storage-selector.log"
DURING_INSTALL=false
MISSING=()

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

add_missing() {
    MISSING+=("$1")
}

main() {
    local argument unit reference tagged_reference
    for argument in "$@"; do
        case "$argument" in
            --during-install) DURING_INSTALL=true ;;
            -h|--help)
                printf 'Usage: %s [--during-install]\n' "$0"
                return 0
                ;;
            *)
                log "ERROR: unknown argument '$argument'" >&2
                return 2
                ;;
        esac
    done

    if [[ "$EUID" -ne 0 ]]; then
        log "ERROR: run with sudo: sudo $0" >&2
        return 1
    fi
    if [[ "$DURING_INSTALL" == false && ! -f /var/lib/o11y-installer/complete ]]; then
        add_missing "installer completion marker is absent; first-boot setup has not completed"
    fi
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        if [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]]; then
            log "Ubuntu ${VERSION_ID} detected"
        else
            add_missing "expected Ubuntu 24.04, found ${PRETTY_NAME:-unknown}"
        fi
    else
        add_missing "/etc/os-release is unavailable"
    fi

    for unit in docker.service ssh.service k3s.service o11y-presenter.service; do
        if systemctl is-active --quiet "$unit"; then
            log "service active: $unit"
        else
            add_missing "service is not active: $unit"
        fi
    done
    if [[ "$DURING_INSTALL" == false ]] && ! systemctl is-active --quiet o11y-installer.service; then
        add_missing "one-shot installer service is not active"
    fi
    if [[ -s "$STORAGE_LOG" ]]; then
        log "storage selection decision recorded: $STORAGE_LOG"
    else
        add_missing "installer storage selector log is missing or empty: $STORAGE_LOG"
    fi
    if [[ ! -s "$IMAGE_REFERENCES" ]]; then
        add_missing "pinned Docker reference list is missing or empty: $IMAGE_REFERENCES"
    else
        while IFS= read -r reference; do
            [[ -n "$reference" ]] || continue
            tagged_reference="${reference%@sha256:*}"
            if docker image inspect "$tagged_reference" >/dev/null 2>&1; then
                log "Docker image available: $reference"
            else
                add_missing "Docker image missing from the local store: $reference"
            fi
        done < "$IMAGE_REFERENCES"
    fi

    if (( ${#MISSING[@]} > 0 )); then
        printf '%s\n' "${MISSING[@]/#/${LOG_PREFIX} missing: }" >&2
        return 1
    fi

    log "Running the offline cluster and demo preflight"
    "${SCRIPT_DIR}/95-preflight-offline.sh"
    log "✓ installer verification passed"
}

main "$@"
