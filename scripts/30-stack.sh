#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[30-stack]"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSIONS_LOCK="${REPO_ROOT}/versions.lock"
CHARTS_DIR="${REPO_ROOT}/charts"
BUNDLE_DIR="${REPO_ROOT}/bundle"
MANIFEST_JSON="${BUNDLE_DIR}/manifest.json"
IMAGES_TXT="${REPO_ROOT}/images.txt"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
LOCAL_REGISTRY_PUSH="127.0.0.1:5000"
OFFLINE=0
OFFLINE_HELM_DIR=""

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

error() {
    log "ERROR: $*" >&2
}

cleanup() {
    if [[ -n "$OFFLINE_HELM_DIR" ]]; then
        rm -rf "$OFFLINE_HELM_DIR"
    fi
}

trap cleanup EXIT

usage() {
    printf 'Usage: sudo %s [--offline]\n' "$0"
    printf '  --offline  install only from bundle/ and charts/, seed the local registry, and refuse remote access\n'
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

# Expands short Docker Hub names so that "registry:2.8.3" and "docker.io/library/registry:2.8.3" compare equal.
normalize_image() {
    local reference="${1%@sha256:*}"
    local first_component="${reference%%/*}"
    if [[ "$reference" != */* ]]; then
        reference="docker.io/library/${reference}"
    elif [[ "$first_component" != *.* && "$first_component" != *:* && "$first_component" != localhost ]]; then
        reference="docker.io/${reference}"
    fi
    if [[ "${reference##*/}" != *:* ]]; then
        reference="${reference}:latest"
    fi
    printf '%s\n' "$reference"
}

resolve_locked_image() {
    local wanted locked_key locked_reference
    wanted="$(normalize_image "$1")"
    while read -r locked_key locked_reference _; do
        [[ "$locked_key" == image.* ]] || continue
        if [[ "$(normalize_image "$locked_reference")" == "$wanted" ]]; then
            printf '%s\n' "$locked_reference"
            return 0
        fi
    done < "$VERSIONS_LOCK"
    error "running image '$1' is not pinned by tag and digest in versions.lock"
    return 1
}

# Every non-local destination is sent to a closed local port, so any accidental download fails fast instead of leaving the node.
enable_offline_guards() {
    local node_ip
    node_ip="$(kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
    export HTTP_PROXY="http://127.0.0.1:9"
    export HTTPS_PROXY="http://127.0.0.1:9"
    export http_proxy="$HTTP_PROXY"
    export https_proxy="$HTTPS_PROXY"
    export NO_PROXY="localhost,127.0.0.1,::1,registry.lab.local,${node_ip},.svc,.cluster.local,10.42.0.0/16,10.43.0.0/16"
    export no_proxy="$NO_PROXY"

    # An empty Helm home means no chart repository or OCI registry login exists to fall back on.
    OFFLINE_HELM_DIR="$(mktemp -d)"
    : > "${OFFLINE_HELM_DIR}/repositories.yaml"
    export HELM_REPOSITORY_CONFIG="${OFFLINE_HELM_DIR}/repositories.yaml"
    export HELM_REPOSITORY_CACHE="${OFFLINE_HELM_DIR}/cache"
    export HELM_REGISTRY_CONFIG="${OFFLINE_HELM_DIR}/registry.json"
    export HELM_CACHE_HOME="${OFFLINE_HELM_DIR}/cache-home"
    export HELM_CONFIG_HOME="${OFFLINE_HELM_DIR}/config-home"
    export HELM_DATA_HOME="${OFFLINE_HELM_DIR}/data-home"
    log "Offline mode: Helm has no repositories and all non-local HTTP(S) goes to a closed port"
}

check_vendored_charts() {
    local chart_key chart_version chart_name missing=0
    while read -r chart_key chart_version _; do
        [[ "$chart_key" == chart.* ]] || continue
        chart_name="${chart_key#chart.}"
        if [[ ! -f "${CHARTS_DIR}/${chart_name}-${chart_version}.tgz" ]]; then
            error "offline mode refuses to fetch chart ${chart_name} ${chart_version}; charts/${chart_name}-${chart_version}.tgz is missing"
            missing=1
        fi
    done < "$VERSIONS_LOCK"
    return "$missing"
}

# Pushes every bundle/oci layout to the in-cluster registry using skopeo from the imported image archive.
seed_local_registry() {
    local skopeo_reference reference digest oci_layout repository tag status
    skopeo_reference="$(locked_field image.skopeo 2)"
    skopeo_reference="${skopeo_reference%@sha256:*}"

    while IFS=$'\t' read -r reference digest oci_layout repository tag; do
        status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
            --head \
            --header 'Accept: application/vnd.oci.image.index.v1+json' \
            --header 'Accept: application/vnd.oci.image.manifest.v1+json' \
            --header 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
            --header 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
            "http://${LOCAL_REGISTRY_PUSH}/v2/${repository}/manifests/${digest}" || true)"
        if [[ "$status" == 200 ]]; then
            log "Local registry already serves $reference"
            continue
        fi
        log "Seeding local registry with $reference"
        # ctr run replaces the image entrypoint, so the skopeo binary is named explicitly; /dev/null keeps it off the loop's stdin.
        k3s ctr --namespace k8s.io run --rm --net-host \
            --mount "type=bind,src=${BUNDLE_DIR}/oci,dst=/oci,options=rbind:ro" \
            "$skopeo_reference" "o11y-registry-seed-$$" \
            skopeo copy --all --preserve-digests --dest-tls-verify=false \
            "oci:/oci/${oci_layout#oci/}:${reference%@sha256:*}" \
            "docker://${LOCAL_REGISTRY_PUSH}/${repository}:${tag}" < /dev/null
    done < <(jq -r '.images[] | [.reference, .oci_digest, .oci_layout, .registry_repository, .tag] | @tsv' "$MANIFEST_JSON")
}

# images.txt feeds scripts/90-capture.sh; K3S's own rancher images come from the K3S airgap archive and are not listed.
write_images_txt() {
    local temporary_file running_image
    temporary_file="$(mktemp)"
    printf '%s\n' '# Every image running after scripts/30-stack.sh, resolved to its versions.lock pin. Written by scripts/30-stack.sh; do not edit.' > "$temporary_file"
    while IFS= read -r running_image; do
        [[ -n "$running_image" ]] || continue
        if [[ "$(normalize_image "$running_image")" == docker.io/rancher/* ]]; then
            continue
        fi
        resolve_locked_image "$running_image"
    done < <(kubectl --kubeconfig "$KUBECONFIG_PATH" get pods --all-namespaces -o json |
        jq -r '.items[].spec | ((.initContainers // []) + .containers + (.ephemeralContainers // []))[].image' | sort -u) |
        sort -u >> "$temporary_file"
    install --mode 0644 "$temporary_file" "$IMAGES_TXT"
    rm -f "$temporary_file"
    log "Wrote $(grep -cv '^#' "$IMAGES_TXT") resolved images to images.txt"
}

main() {
    while (( $# > 0 )); do
        case "$1" in
            --offline) OFFLINE=1 ;;
            -h|--help) usage; exit 0 ;;
            *) error "unknown argument '$1'"; usage >&2; exit 1 ;;
        esac
        shift
    done

    if [[ "$EUID" -ne 0 ]]; then
        log "ERROR: run this script with sudo"
        exit 1
    fi

    if (( OFFLINE == 1 )); then
        for tool in curl jq k3s kubectl; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                error "required command '$tool' is not installed"
                exit 1
            fi
        done
        export KUBECONFIG="$KUBECONFIG_PATH"
        enable_offline_guards
        check_vendored_charts
        log "Verifying the OCI bundle before installing anything"
        "$SCRIPT_DIR/91-verify-bundle.sh"
    fi

    log "Installing the offline Cilium and Tetragon foundation"
    "$SCRIPT_DIR/20-cilium.sh"
    if (( OFFLINE == 1 )); then
        seed_local_registry
    fi
    log "Installing the offline observability stack"
    "$SCRIPT_DIR/21-observability.sh"
    write_images_txt
    log "Running cluster acceptance checks"
    "$SCRIPT_DIR/verify-cluster.sh"
    log "Running observability acceptance checks"
    "$SCRIPT_DIR/verify-observability.sh"
    log "Complete stack installation and verification succeeded"
}

main "$@"
