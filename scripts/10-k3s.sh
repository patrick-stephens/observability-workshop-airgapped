#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[10-k3s]"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_LOCK="${REPO_ROOT}/versions.lock"
BUNDLE_DIR="${REPO_ROOT}/bundle"
K3S_BINARY="${BUNDLE_DIR}/tools/k3s"
K3S_IMAGES="${BUNDLE_DIR}/k3s-airgap-images-amd64.tar.zst"
K3S_INSTALL_PATH="/usr/local/bin/k3s"
K3S_SERVICE_PATH="/etc/systemd/system/k3s.service"
K3S_IMAGE_IMPORT_DIR="/var/lib/rancher/k3s/agent/images"
K3S_IMAGE_IMPORT_PATH="${K3S_IMAGE_IMPORT_DIR}/k3s-airgap-images-amd64.tar.zst"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
API_WAIT_SECONDS="${API_WAIT_SECONDS:-300}"

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

error() {
    log "ERROR: $*" >&2
}

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

verify_artifact() {
    local path="$1"
    local lock_key="$2"
    local expected
    expected="$(locked_field "$lock_key" 2 | sed 's/^sha256://')"
    if [[ ! -f "$path" ]]; then
        error "required offline artifact is missing: $path"
        return 1
    fi
    if ! printf '%s  %s\n' "$expected" "$path" | sha256sum --check --status; then
        error "checksum mismatch for $path"
        return 1
    fi
}

install_k3s_binary() {
    local expected_version installed_version
    expected_version="$(locked_field k3s 2)"
    verify_artifact "$K3S_BINARY" k3s-binary-amd64

    installed_version=""
    if [[ -x "$K3S_INSTALL_PATH" ]]; then
        installed_version="$("$K3S_INSTALL_PATH" --version | awk 'NR == 1 { print $3 }')"
    fi
    if [[ "$installed_version" == "$expected_version" ]]; then
        log "Locked K3S binary ${expected_version} is already installed"
        return
    fi

    log "Installing K3S ${expected_version}"
    install --mode 0755 "$K3S_BINARY" "$K3S_INSTALL_PATH"
    for command_name in kubectl crictl ctr; do
        local link_path="/usr/local/bin/${command_name}"
        if [[ ! -L "$link_path" || "$(readlink "$link_path")" != "$K3S_INSTALL_PATH" ]]; then
            ln --symbolic --force "$K3S_INSTALL_PATH" "$link_path"
        fi
    done
}

install_k3s_airgap_images() {
    verify_artifact "$K3S_IMAGES" k3s-airgap-images-amd64.tar.zst
    install --directory --mode 0755 "$K3S_IMAGE_IMPORT_DIR"

    if [[ -f "$K3S_IMAGE_IMPORT_PATH" ]] && cmp --silent "$K3S_IMAGES" "$K3S_IMAGE_IMPORT_PATH"; then
        log "K3S airgap image bundle is already staged"
        return
    fi

    log "Staging the locked K3S airgap image bundle"
    install --mode 0644 "$K3S_IMAGES" "$K3S_IMAGE_IMPORT_PATH"
}

write_k3s_service() {
    local temporary_file
    temporary_file="$(mktemp "${K3S_SERVICE_PATH}.tmp.XXXXXX")"
    cat > "$temporary_file" <<'EOF'
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
Wants=network-online.target
After=network-online.target

[Install]
WantedBy=multi-user.target

[Service]
Type=notify
EnvironmentFile=-/etc/default/%N
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStart=/usr/local/bin/k3s server --flannel-backend=none --disable-network-policy --disable-kube-proxy --disable=traefik --disable=servicelb --write-kubeconfig-mode=0644
EOF

    if [[ -f "$K3S_SERVICE_PATH" ]] && cmp --silent "$temporary_file" "$K3S_SERVICE_PATH"; then
        rm -f "$temporary_file"
        log "K3S systemd service is already configured"
        return 1
    fi

    install --mode 0644 "$temporary_file" "$K3S_SERVICE_PATH"
    rm -f "$temporary_file"
    log "Updated $K3S_SERVICE_PATH"
    return 0
}

wait_for_api() {
    local deadline=$((SECONDS + API_WAIT_SECONDS))
    while (( SECONDS < deadline )); do
        if "$K3S_INSTALL_PATH" kubectl --kubeconfig "$KUBECONFIG_PATH" get --raw=/readyz >/dev/null 2>&1 && "$K3S_INSTALL_PATH" kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes --output=name 2>/dev/null | grep --quiet '^node/'; then
            log "K3S API server and node registration are ready"
            return
        fi
        sleep 2
    done
    error "K3S API server did not become ready within ${API_WAIT_SECONDS}s"
    return 1
}

main() {
    local service_changed=0
    if [[ "$EUID" -ne 0 ]]; then
        error "run this script with sudo"
        exit 1
    fi
    if [[ ! -f "$VERSIONS_LOCK" ]]; then
        error "versions.lock not found at $VERSIONS_LOCK"
        exit 1
    fi

    install_k3s_binary
    install_k3s_airgap_images
    if write_k3s_service; then
        service_changed=1
    fi
    if (( service_changed == 1 )); then
        systemctl daemon-reload
    fi

    systemctl enable k3s
    if ! systemctl is-active --quiet k3s; then
        log "Starting K3S with flannel, network policy, kube-proxy, Traefik, and ServiceLB disabled"
        systemctl start k3s
    else
        log "K3S service is already active"
    fi
    wait_for_api
    "$K3S_INSTALL_PATH" kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes -o wide
}

main "$@"
