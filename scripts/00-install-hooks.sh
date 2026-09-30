#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[hooks]"

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

for tool in pre-commit; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log "ERROR: required tool '$tool' is not installed"
        exit 1
    fi
done

log "Validating the repository pre-commit configuration"
pre-commit validate-config
log "Installing repository hooks and their pinned environments"
pre-commit install-hooks

if git config --get core.hooksPath >/dev/null 2>&1; then
    log "Custom Git hooks path is configured; leaving it unchanged"
else
    pre-commit install
fi

log "Repository hook environments are installed"