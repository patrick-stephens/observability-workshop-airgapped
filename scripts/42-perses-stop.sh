#!/usr/bin/env bash
set -euo pipefail

# Teardown for scripts/40-perses.sh and scripts/41-perses-portforwards.sh.

LOG_PREFIX="[42-perses-stop]"
PID_DIR="/tmp/perses-pf"
CONTAINER_NAME="o11y-perses"

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

main() {
    local name pid
    for name in prometheus loki tempo; do
        if [[ -f "${PID_DIR}/${name}.pid" ]]; then
            pid="$(cat "${PID_DIR}/${name}.pid")"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid"
                log "Stopped $name port-forward (PID $pid)"
            fi
            rm -f "${PID_DIR}/${name}.pid" "${PID_DIR}/${name}.log"
        fi
    done
    if command -v docker >/dev/null 2>&1 && docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        docker rm --force "$CONTAINER_NAME" >/dev/null
        log "Removed container $CONTAINER_NAME"
    fi
}

main "$@"
