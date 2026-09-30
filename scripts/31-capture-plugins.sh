#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[31-capture-plugins]"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_LOCK="${REPO_ROOT}/versions.lock"
PLUGIN_DIR="${REPO_ROOT}/bundle/perses-plugins"
TEMP_MANIFEST=""
PERSES_PLUGIN_BASE_URL_VALUE="${PERSES_PLUGIN_BASE_URL:-https://github.com/perses/plugins/releases/download}"

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

error() {
    log "ERROR: $*" >&2
}

cleanup() {
    if [[ -n "$TEMP_MANIFEST" ]]; then
        rm -f "$TEMP_MANIFEST"
    fi
}

trap cleanup EXIT

locked_field() {
    local key="$1"
    local field="$2"
    local value
    value="$(awk -v key="$key" -v field="$field" '$1 == key { print $field; exit }' "$VERSIONS_LOCK")"
    if [[ -z "$value" ]]; then
        error "required lock entry '$key' is missing from versions.lock"
        return 1
    fi
    printf '%s\n' "$value"
}

capture_plugin() {
    local lock_key="$1"
    local plugin="$2"
    local asset_name="$3"
    local version checksum target temporary_file url
    version="$(locked_field "$lock_key" 2)"
    checksum="$(locked_field "$lock_key" 3 | sed 's/^sha256://')"
    target="${PLUGIN_DIR}/${asset_name}"
    url="${PERSES_PLUGIN_BASE_URL_VALUE}/${plugin}/${version}/${asset_name}"

    if [[ -f "$target" ]]; then
        if printf '%s  %s\n' "$checksum" "$target" | sha256sum --check --status; then
            log "Verified cached plugin $asset_name"
            return
        fi
        error "cached plugin checksum mismatch: $target"
        return 1
    fi

    temporary_file="${target}.download.$$"
    log "Downloading Perses plugin ${plugin}/${version}"
    curl --fail --location --retry 3 --output "$temporary_file" "$url"
    if ! printf '%s  %s\n' "$checksum" "$temporary_file" | sha256sum --check --status; then
        rm -f "$temporary_file"
        error "plugin checksum mismatch: $asset_name"
        return 1
    fi
    mv "$temporary_file" "$target"
}

main() {
    for tool in awk curl sha256sum; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            error "required command '$tool' is not installed"
            exit 1
        fi
    done
    if [[ ! -f "$VERSIONS_LOCK" ]]; then
        error "versions.lock not found at $VERSIONS_LOCK"
        exit 1
    fi
    mkdir -p "$PLUGIN_DIR"

    capture_plugin capture.perses-plugin-prometheus prometheus "Prometheus-0.54.0.tar.gz"
    capture_plugin capture.perses-plugin-loki loki "Loki-0.6.0.tar.gz"
    capture_plugin capture.perses-plugin-tempo tempo "Tempo-0.54.0.tar.gz"

    TEMP_MANIFEST="$(mktemp)"
    (cd "$PLUGIN_DIR" && sha256sum -- ./*.tar.gz) > "$TEMP_MANIFEST"
    if [[ -f "${PLUGIN_DIR}/SHA256SUMS" ]] && cmp --silent "$TEMP_MANIFEST" "${PLUGIN_DIR}/SHA256SUMS"; then
        log "Perses plugin checksum manifest is unchanged"
    else
        install --mode 0644 "$TEMP_MANIFEST" "${PLUGIN_DIR}/SHA256SUMS"
    fi
    TEMP_MANIFEST=""
    log "Perses plugins are captured under $PLUGIN_DIR"
}

main "$@"
