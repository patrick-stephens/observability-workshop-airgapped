#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[30-stack]"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

main() {
    if [[ "$EUID" -ne 0 ]]; then
        log "ERROR: run this script with sudo"
        exit 1
    fi

    log "Installing the offline Cilium and Tetragon foundation"
    "$SCRIPT_DIR/20-cilium.sh"
    log "Installing the offline observability stack"
    "$SCRIPT_DIR/21-observability.sh"
    log "Running cluster acceptance checks"
    "$SCRIPT_DIR/verify-cluster.sh"
    log "Running observability acceptance checks"
    "$SCRIPT_DIR/verify-observability.sh"
    log "Complete stack installation and verification succeeded"
}

main "$@"
