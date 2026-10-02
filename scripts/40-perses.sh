#!/usr/bin/env bash
set -euo pipefail

# Runs Perses on the presenter host (outside the cluster) on http://localhost:8080 and applies dashboards/.
# Datasources point at localhost:9090/3100/3200, which scripts/41-perses-portforwards.sh provides.

LOG_PREFIX="[40-perses]"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_LOCK="${REPO_ROOT}/versions.lock"
DASHBOARDS_DIR="${REPO_ROOT}/dashboards"
CONTAINER_NAME="o11y-perses"
PERSES_URL="http://localhost:8080"
CONFIG_DIR="${HOME}/.cache/o11y-perses"
# Applied in this order: the project and its datasources must exist before the dashboards that reference them.
DASHBOARD_FILES=(project.yaml datasources.yaml overview.yaml network.yaml signals.yaml)

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

error() {
    log "ERROR: $*" >&2
}

locked_field() {
    local value
    value="$(awk -v key="$1" -v field="$2" '$1 == key { print $field; exit }' "$VERSIONS_LOCK")"
    if [[ -z "$value" ]]; then
        error "required lock entry '$1' is missing from versions.lock"
        return 1
    fi
    printf '%s\n' "$value"
}

write_config() {
    mkdir -p "$CONFIG_DIR"
    # Use the pinned image's built-in datasource and panel plugins so each plugin kind is loaded once.
    cat > "${CONFIG_DIR}/config.yaml" <<'EOF'
security:
  enable_auth: false
  readonly: false
database:
  file:
    folder: /perses
    extension: json
# Explore gives the presenter's Tempo and Loki tabs; neither backend ships a UI of its own.
frontend:
  explorer:
    enable: true
plugin:
  path: /tmp/perses-plugins
  archive_paths:
    - /etc/perses/plugins-archive
EOF
}

main() {
    local image file
    for tool in awk curl docker; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            error "required command '$tool' is not installed"
            exit 1
        fi
    done
    for file in "${DASHBOARD_FILES[@]}"; do
        if [[ ! -f "${DASHBOARDS_DIR}/${file}" ]]; then
            error "dashboard file ${DASHBOARDS_DIR}/${file} is missing"
            exit 1
        fi
    done
    image="$(locked_field image.perses 2)"
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        error "Perses image $image is not present locally; run scripts/05-capture-cluster-assets.sh on the build node"
        exit 1
    fi

    write_config
    log "Replacing any existing '$CONTAINER_NAME' container"
    docker rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true

    # Host networking lets the Perses proxy reach the host's port-forwards on localhost; the listen address keeps it local-only.
    docker run --detach \
        --name "$CONTAINER_NAME" \
        --network host \
        --pull never \
        --env HOME=/tmp \
        --tmpfs /perses:uid=65532,gid=65532 \
        --tmpfs /tmp:uid=65532,gid=65532 \
        --volume "${CONFIG_DIR}/config.yaml:/etc/perses/host-config.yaml:ro" \
        --volume "${DASHBOARDS_DIR}:/etc/perses/dashboards:ro" \
        "$image" \
        --config /etc/perses/host-config.yaml \
        --web.listen-address 127.0.0.1:8080 >/dev/null

    for ((attempt = 0; attempt < 60; attempt++)); do
        if curl --fail --silent --max-time 2 "${PERSES_URL}/api/v1/health" >/dev/null; then
            break
        fi
        sleep 1
    done
    if ! curl --fail --silent --max-time 2 "${PERSES_URL}/api/v1/health" >/dev/null; then
        docker logs --tail 30 "$CONTAINER_NAME" >&2 || true
        error "Perses did not become healthy at ${PERSES_URL}"
        exit 1
    fi

    docker exec "$CONTAINER_NAME" /bin/percli login "$PERSES_URL" >/dev/null
    for file in "${DASHBOARD_FILES[@]}"; do
        log "Applying dashboards/${file}"
        docker exec "$CONTAINER_NAME" /bin/percli apply --file "/etc/perses/dashboards/${file}" >/dev/null
    done
    log "Perses is ready: ${PERSES_URL}"
}

main "$@"
