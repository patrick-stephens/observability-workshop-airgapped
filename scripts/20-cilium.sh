#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[20-cilium]"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_LOCK="${REPO_ROOT}/versions.lock"
BUNDLE_DIR="${REPO_ROOT}/bundle"
TOOLS_DIR="${BUNDLE_DIR}/tools"
CHARTS_DIR="${REPO_ROOT}/charts"
VALUES_DIR="${REPO_ROOT}/values"
NAMESPACE="kube-system"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

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

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "required command '$1' is not installed"
        return 1
    fi
}

verify_bundle_checksums() {
    if [[ ! -f "${BUNDLE_DIR}/SHA256SUMS" ]]; then
        error "bundle checksum manifest is missing; run scripts/05-capture-cluster-assets.sh on the build node"
        return 1
    fi
    (cd "$BUNDLE_DIR" && sha256sum --check SHA256SUMS)
}

install_locked_cli() {
    local lock_key="$1"
    local tool_name="$2"
    local version
    version="$(locked_field "$lock_key" 2)"
    if [[ ! -x "${TOOLS_DIR}/${tool_name}" ]]; then
        error "captured tool is missing: ${TOOLS_DIR}/${tool_name}"
        return 1
    fi
    if [[ -x "/usr/local/bin/${tool_name}" ]] && cmp --silent "${TOOLS_DIR}/${tool_name}" "/usr/local/bin/${tool_name}"; then
        log "Pinned ${tool_name} ${version} is already installed"
        return
    fi
    install --mode 0755 "${TOOLS_DIR}/${tool_name}" "/usr/local/bin/${tool_name}"
    log "Installed ${tool_name} ${version}"
}

release_state() {
    local release_name="$1"
    local expected_chart="$2"
    local release_json chart_name release_status
    release_json="$(helm list --namespace "$NAMESPACE" --output json --kubeconfig "$KUBECONFIG_PATH" | jq -c --arg name "$release_name" '[.[] | select(.name == $name)] | first // empty')"
    if [[ -z "$release_json" ]]; then
        return 1
    fi
    chart_name="$(jq -r '.chart' <<< "$release_json")"
    release_status="$(jq -r '.status' <<< "$release_json")"
    if [[ "$chart_name" != "$expected_chart" ]]; then
        error "release '$release_name' exists as chart '$chart_name' with status '$release_status'; expected deployed '$expected_chart'"
        return 2
    fi
    if [[ "$release_status" == pending-install || "$release_status" == failed ]]; then
        log "Removing incomplete release '$release_name' with status '$release_status' before retry"
        helm uninstall "$release_name" \
            --namespace "$NAMESPACE" \
            --kubeconfig "$KUBECONFIG_PATH" \
            --no-hooks \
            --wait \
            --timeout 5m
        return 1
    fi
    if [[ "$release_status" != deployed ]]; then
        error "release '$release_name' is in status '$release_status'; refusing to replace it"
        return 2
    fi
    return 0
}

import_images_if_needed() {
    if [[ ! -f "${BUNDLE_DIR}/container-images-amd64.tar" || ! -f "${BUNDLE_DIR}/container-images-amd64.tar.sha256" ]]; then
        error "captured container image archive is missing"
        return 1
    fi
    (cd "$BUNDLE_DIR" && sha256sum --check container-images-amd64.tar.sha256)

    local image_reference
    local images_present=1
    local containerd_references
    containerd_references="$(k3s ctr --namespace k8s.io images list --quiet)"
    while IFS= read -r image_reference; do
        if ! grep --fixed-strings --line-regexp --quiet "$image_reference" <<< "$containerd_references"; then
            images_present=0
            break
        fi
    done < "${BUNDLE_DIR}/image-references-amd64.txt"
    if (( images_present == 1 )); then
        log "All locked container images are already imported"
        return
    fi

    log "Importing captured images into the K3S containerd image store"
    k3s ctr --namespace k8s.io images import --digests --local "${BUNDLE_DIR}/container-images-amd64.tar"
    containerd_references="$(k3s ctr --namespace k8s.io images list --quiet)"
    while IFS= read -r image_reference; do
        local tagged_reference="${image_reference%@sha256:*}"
        if grep --fixed-strings --line-regexp --quiet "$tagged_reference" <<< "$containerd_references"; then
            log "Creating local digest alias for $tagged_reference"
            k3s ctr --namespace k8s.io images tag --force "$tagged_reference" "$image_reference"
        fi
    done < "${BUNDLE_DIR}/image-references-amd64.txt"

    containerd_references="$(k3s ctr --namespace k8s.io images list --quiet)"
    while IFS= read -r image_reference; do
        if ! grep --fixed-strings --line-regexp --quiet "$image_reference" <<< "$containerd_references"; then
            error "containerd import did not produce the required pinned image reference '$image_reference'"
            return 1
        fi
    done < "${BUNDLE_DIR}/image-references-amd64.txt"
}

install_chart() {
    local release_name="$1"
    local chart_name="$2"
    local chart_version="$3"
    local values_file="$4"
    local wait_for_ready="${5:-true}"
    local chart_archive="${CHARTS_DIR}/${chart_name}-${chart_version}.tgz"
    local state

    if [[ ! -f "$chart_archive" ]]; then
        error "vendored Helm chart is missing: $chart_archive"
        return 1
    fi
    if [[ ! -f "$values_file" ]]; then
        error "Helm values file is missing: $values_file"
        return 1
    fi

    state=0
    release_state "$release_name" "${chart_name}-${chart_version}" || state=$?
    case "$state" in
        0)
            log "Release '$release_name' already uses ${chart_name}-${chart_version}; no changes needed"
            return
            ;;
        1)
            ;;
        *)
            return "$state"
            ;;
    esac

    log "Installing ${chart_name}-${chart_version} as release '$release_name'"
    local -a helm_args=(install "$release_name" "$chart_archive" \
        --namespace "$NAMESPACE" \
        --kubeconfig "$KUBECONFIG_PATH" \
        --values "$values_file")
    if [[ "$wait_for_ready" == true ]]; then
        helm_args+=(--wait --timeout 10m)
    fi
    helm "${helm_args[@]}"
}

main() {
    local cilium_chart_version tetragon_chart_version
    if [[ "$EUID" -ne 0 ]]; then
        error "run this script with sudo"
        exit 1
    fi
    if [[ ! -f "$VERSIONS_LOCK" ]]; then
        error "versions.lock not found at $VERSIONS_LOCK"
        exit 1
    fi
    if [[ ! -f "$KUBECONFIG_PATH" ]]; then
        error "K3S kubeconfig not found; run scripts/10-k3s.sh first"
        exit 1
    fi
    export KUBECONFIG="$KUBECONFIG_PATH"

    require_tool kubectl
    require_tool k3s
    require_tool sha256sum
    require_tool jq
    verify_bundle_checksums

    install_locked_cli helm-archive helm
    install_locked_cli cilium-cli cilium
    install_locked_cli hubble-cli hubble
    require_tool helm
    cilium_chart_version="$(locked_field chart.cilium 2)"
    tetragon_chart_version="$(locked_field chart.tetragon 2)"

    import_images_if_needed
    install_chart cilium cilium "$cilium_chart_version" "${VALUES_DIR}/cilium.yaml"
    install_chart tetragon tetragon "$tetragon_chart_version" "${VALUES_DIR}/tetragon.yaml" false

    # k8sServiceHost/k8sServicePort are mandatory because Cilium cannot reach the API server before kube-proxy exists without them.
    /usr/local/bin/cilium status --kubeconfig "$KUBECONFIG_PATH" --wait --wait-duration 5m
}

main "$@"
