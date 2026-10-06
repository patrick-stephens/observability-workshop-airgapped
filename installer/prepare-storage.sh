#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/o11y-storage-selector.log"
APT_WORK="/tmp/o11y-storage-apt"
APT_SOURCE="${APT_WORK}/sources.list"
PYTHON_YAML_VERSION="${1:-}"
AUTOINSTALL_FILE="${2:-/autoinstall.yaml}"
APT_OPTIONS=(
    -o "Dir::Etc::sourcelist=${APT_SOURCE}"
    -o Dir::Etc::sourceparts=-
    -o "Dir::State::lists=${APT_WORK}/lists"
    -o "Dir::Cache::archives=${APT_WORK}/archives/"
    -o APT::Get::List-Cleanup=0
)

log() {
    printf '[installer-storage] %s\n' "$*" | tee -a "$LOG_FILE"
}

fallback() {
    local message="$1"
    log "$message; leaving disk selection interactive."
    return 0
}

main() {
    if [[ ! "$PYTHON_YAML_VERSION" =~ ^[0-9A-Za-z.+:~_-]+$ ]]; then
        fallback "the pinned python3-yaml version is missing or malformed"
        return
    fi
    mkdir -p "${APT_WORK}/lists/partial" "${APT_WORK}/archives/partial"
    printf 'deb [trusted=yes] file:/cdrom/offline-apt ./\n' > "$APT_SOURCE"
    log "Preparing the YAML parser from the ISO's local package repository."
    if ! apt-get "${APT_OPTIONS[@]}" update >>"$LOG_FILE" 2>&1; then
        fallback "could not read the ISO's local APT repository"
        tail -n 20 "$LOG_FILE"
        return
    fi
    if ! apt-get "${APT_OPTIONS[@]}" install --yes --no-install-recommends "python3-yaml=${PYTHON_YAML_VERSION}" >>"$LOG_FILE" 2>&1; then
        fallback "could not install the pinned YAML parser from the ISO"
        tail -n 20 "$LOG_FILE"
        return
    fi
    if ! python3 /cdrom/installer/select-storage.py "$AUTOINSTALL_FILE" >>"$LOG_FILE" 2>&1; then
        fallback "the storage selector failed"
        tail -n 20 "$LOG_FILE"
        return
    fi
}

main "$@"
