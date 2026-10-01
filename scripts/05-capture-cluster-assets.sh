#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[05-capture-cluster-assets]"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_LOCK="${REPO_ROOT}/versions.lock"
BUNDLE_DIR="${REPO_ROOT}/bundle"
TOOLS_DIR="${BUNDLE_DIR}/tools"
CHARTS_DIR="${REPO_ROOT}/charts"
HELM_REPOSITORY="${CHART_REPO_CILIUM:-https://helm.cilium.io}"
GRAFANA_HELM_REPOSITORY="${CHART_REPO_GRAFANA:-https://grafana.github.io/helm-charts}"
OPEN_TELEMETRY_HELM_REPOSITORY="${CHART_REPO_OPENTELEMETRY:-https://open-telemetry.github.io/opentelemetry-helm-charts}"
PERSES_HELM_REPOSITORY="${CHART_REPO_PERSES:-https://perses.github.io/helm-charts}"
PROMETHEUS_HELM_REPOSITORY="${CHART_REPO_PROMETHEUS:-https://prometheus-community.github.io/helm-charts}"
FLUENT_HELM_REPOSITORY="${CHART_REPO_FLUENT_BIT:-https://fluent.github.io/helm-charts}"
GITHUB_RELEASE_BASE_URL="${GITHUB_RELEASE_BASE_URL:-https://github.com}"
HELM_BINARY_BASE_URL="${HELM_BINARY_BASE_URL:-https://get.helm.sh}"
K3S_RELEASE_BASE_URL="${K3S_RELEASE_BASE_URL:-https://github.com/k3s-io/k3s/releases/download}"
CAPTURE_TEMP_MANIFEST=""

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

error() {
    log "ERROR: $*" >&2
}

cleanup() {
    if [[ -n "$CAPTURE_TEMP_MANIFEST" ]]; then
        rm -f "$CAPTURE_TEMP_MANIFEST"
    fi
}

trap cleanup EXIT

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "required command '$1' is not installed; run scripts/00-host-prereqs.sh first"
        return 1
    fi
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

download_verified() {
    local target="$1"
    local url="$2"
    local checksum="$3"
    local temporary_file="${target}.download.$$"

    if [[ -f "$target" ]]; then
        if printf '%s  %s\n' "$checksum" "$target" | sha256sum --check --status; then
            log "Verified cached asset $(basename "$target")"
            return
        fi
        error "cached asset checksum mismatch: $target"
        return 1
    fi

    log "Downloading $(basename "$target")"
    curl --fail --location --retry 3 --output "$temporary_file" "$url"
    if ! printf '%s  %s\n' "$checksum" "$temporary_file" | sha256sum --check --status; then
        rm -f "$temporary_file"
        error "download checksum mismatch: $url"
        return 1
    fi
    mv "$temporary_file" "$target"
}

ensure_chart() {
    local chart_name="$1" repository
    local version_key="chart.${chart_name}"
    local version archive installed_version
    version="$(locked_field "$version_key" 2)"
    archive="${CHARTS_DIR}/${chart_name}-${version}.tgz"

    if [[ -f "$archive" ]]; then
        installed_version="$(helm show chart "$archive" | sed -n 's/^version: //p' | head -n 1)"
        if [[ "$installed_version" != "$version" ]]; then
            error "vendored chart $archive has version '$installed_version', expected '$version'"
            return 1
        fi
        log "Verified vendored chart $(basename "$archive")"
        return
    fi

    case "$chart_name" in
        cilium|tetragon) repository="$HELM_REPOSITORY" ;;
        fluent-bit-collector) repository="$FLUENT_HELM_REPOSITORY" ;;
        kube-prometheus-stack) repository="$PROMETHEUS_HELM_REPOSITORY" ;;
        loki|pyroscope|tempo) repository="$GRAFANA_HELM_REPOSITORY" ;;
        opentelemetry-collector) repository="$OPEN_TELEMETRY_HELM_REPOSITORY" ;;
        perses) repository="$PERSES_HELM_REPOSITORY" ;;
        *) error "no Helm repository configured for chart '$chart_name'"; return 1 ;;
    esac
    log "Capturing $chart_name chart version $version"
    helm pull --repo "$repository" "$chart_name" --version "$version" --destination "$CHARTS_DIR"
}

ensure_helm_binary() {
    local version checksum archive temporary_directory
    version="$(locked_field helm-archive 2)"
    checksum="$(locked_field helm-archive 3 | sed 's/^sha256://')"
    archive="${TOOLS_DIR}/helm-${version}-linux-amd64.tar.gz"
    download_verified "$archive" "${HELM_BINARY_BASE_URL}/helm-${version}-linux-amd64.tar.gz" "$checksum"
    if [[ -x "${TOOLS_DIR}/helm" ]] && "${TOOLS_DIR}/helm" version --short | grep --fixed-strings --quiet "$version"; then
        log "Pinned Helm ${version} is already unpacked"
        return
    fi
    temporary_directory="$(mktemp -d)"
    tar --extract --gzip --file "$archive" --directory "$temporary_directory" linux-amd64/helm
    install --mode 0755 "${temporary_directory}/linux-amd64/helm" "${TOOLS_DIR}/helm"
    rm -rf "$temporary_directory"
}

ensure_cli_binary() {
    local lock_key="$1"
    local asset_name="$2"
    local binary_name="$3"
    local repository="$4"
    local version checksum archive temporary_directory
    version="$(locked_field "$lock_key" 2)"
    checksum="$(locked_field "$lock_key" 3 | sed 's/^sha256://')"
    archive="${TOOLS_DIR}/${asset_name}"
    download_verified "$archive" "${GITHUB_RELEASE_BASE_URL}/${repository}/releases/download/${version}/${asset_name}" "$checksum"
    if [[ -x "${TOOLS_DIR}/${binary_name}" ]]; then
        local installed_version_output
        if [[ "$binary_name" == cilium ]]; then
            installed_version_output="$("${TOOLS_DIR}/${binary_name}" version --client 2>&1 || true)"
        else
            installed_version_output="$("${TOOLS_DIR}/${binary_name}" version 2>&1 || true)"
        fi
        if grep --fixed-strings --quiet "$version" <<< "$installed_version_output"; then
            log "Pinned ${binary_name} ${version} is already unpacked"
            return
        fi
    fi
    temporary_directory="$(mktemp -d)"
    tar --extract --gzip --file "$archive" --directory "$temporary_directory" "$binary_name"
    install --mode 0755 "${temporary_directory}/${binary_name}" "${TOOLS_DIR}/${binary_name}"
    rm -rf "$temporary_directory"
}

ensure_loadgen_image() {
    local image_reference tagged_reference expected_digest actual_digest metadata_file builder_name builder_image buildkit_image
    image_reference="$(locked_field image.hey-loadgen 2)"
    tagged_reference="${image_reference%@sha256:*}"
    expected_digest="${image_reference##*@}"
    builder_image="${HEY_BUILDER_IMAGE:-$(locked_field build-image.hey-builder 2)}"
    buildkit_image="${BUILDKIT_IMAGE:-$(locked_field build-image.buildkit 2)}"
    builder_name="observability-workshop-hey"
    metadata_file="$(mktemp)"

    log "Creating pinned BuildKit builder '$builder_name' for the load-generator image"
    docker buildx rm "$builder_name" >/dev/null 2>&1 || true
    docker buildx create --name "$builder_name" --driver docker-container --driver-opt "image=$buildkit_image" >/dev/null

    log "Building pinned hey load-generator image"
    if ! docker buildx build \
        --builder "$builder_name" \
        --no-cache \
        --platform linux/amd64 \
        --build-arg SOURCE_DATE_EPOCH=0 \
        --build-arg "GO_BUILDER_IMAGE=$builder_image" \
        --metadata-file "$metadata_file" \
        --tag "$tagged_reference" \
        --load \
        "${REPO_ROOT}/images/hey"; then
        rm -f "$metadata_file"
        return 1
    fi

    actual_digest="$(jq -r '."containerimage.digest" // empty' "$metadata_file")"
    rm -f "$metadata_file"
    if [[ "$actual_digest" != "$expected_digest" ]]; then
        error "built hey image digest '$actual_digest' does not match versions.lock '$expected_digest'"
        return 1
    fi
    log "Verified load-generator image digest $actual_digest"
}

capture_images() {
    local image_key image_reference
    local -a image_references=()
    local -a tagged_references=()
    local reference_manifest="${BUNDLE_DIR}/image-references-amd64.txt"
    local image_archive="${BUNDLE_DIR}/container-images-amd64.tar"
    local image_checksum="${image_archive}.sha256"
    local temporary_manifest
    temporary_manifest="$(mktemp)"
    CAPTURE_TEMP_MANIFEST="$temporary_manifest"

    while read -r image_key image_reference _; do
        [[ "$image_key" == image.* ]] || continue
        if [[ "$image_reference" != *@sha256:* || "$image_reference" != *:*@sha256:* ]]; then
            error "image lock entry '$image_key' must contain both a tag and sha256 digest"
            return 1
        fi
        image_references+=("$image_reference")
    done < "$VERSIONS_LOCK"

    if (( ${#image_references[@]} == 0 )); then
        error "no image.* pins found in versions.lock"
        return 1
    fi

    printf '%s\n' "${image_references[@]}" > "$temporary_manifest"
    if [[ "${FORCE_CAPTURE:-0}" != 1 && -f "$image_archive" && -f "$image_checksum" && -f "$reference_manifest" ]] && cmp --silent "$temporary_manifest" "$reference_manifest" && (cd "$BUNDLE_DIR" && sha256sum --check --status "$(basename "$image_checksum")"); then
        rm -f "$temporary_manifest"
        CAPTURE_TEMP_MANIFEST=""
        log "Verified cached container image archive"
        return
    fi

    for image_reference in "${image_references[@]}"; do
        local image_key_for_reference
        image_key_for_reference="$(awk -v reference="$image_reference" '$1 ~ /^image\./ && $2 == reference { print $1; exit }' "$VERSIONS_LOCK")"
        local pull_reference="$image_reference"
        if [[ "$image_key_for_reference" == image.hey-loadgen ]]; then
            tagged_reference="${image_reference%@sha256:*}"
            docker image inspect "$tagged_reference" >/dev/null
            log "Using reproducibly built pinned image $image_reference"
            tagged_references+=("$tagged_reference")
            continue
        fi
        log "Pulling pinned image $image_reference"
        if [[ -n "${IMAGE_REGISTRY_PREFIX:-}" ]]; then
            pull_reference="${IMAGE_REGISTRY_PREFIX%/}/${image_reference#*/}"
        fi
        docker pull --platform linux/amd64 "$pull_reference"
        tagged_reference="${image_reference%@sha256:*}"
        docker image tag "$pull_reference" "$tagged_reference"
        tagged_references+=("$tagged_reference")
    done

    log "Saving pinned images for offline import"
    docker save --output "$image_archive" "${tagged_references[@]}"
    mv "$temporary_manifest" "$reference_manifest"
    CAPTURE_TEMP_MANIFEST=""
    (cd "$BUNDLE_DIR" && sha256sum "$(basename "$image_archive")" > "$(basename "$image_checksum")")
}

main() {
    require_tool awk
    require_tool curl
    require_tool docker
    require_tool jq
    require_tool helm
    require_tool install
    require_tool sha256sum
    require_tool tar
    docker buildx version >/dev/null
    mkdir -p "$BUNDLE_DIR" "$TOOLS_DIR" "$CHARTS_DIR"
    rm -f -- "${BUNDLE_DIR}"/image-references-amd64.txt.tmp.*

    local k3s_version k3s_release_url
    k3s_version="$(locked_field k3s 2)"
    k3s_release_url="${K3S_RELEASE_BASE_URL}/${k3s_version//+/%2B}"

    download_verified \
        "${TOOLS_DIR}/k3s" \
        "${k3s_release_url}/k3s" \
        "$(locked_field k3s-binary-amd64 2 | sed 's/^sha256://')"
    chmod 0755 "${TOOLS_DIR}/k3s"
    download_verified \
        "${BUNDLE_DIR}/k3s-airgap-images-amd64.tar.zst" \
        "${k3s_release_url}/k3s-airgap-images-amd64.tar.zst" \
        "$(locked_field k3s-airgap-images-amd64.tar.zst 2 | sed 's/^sha256://')"

    ensure_helm_binary
    ensure_cli_binary cilium-cli cilium-linux-amd64.tar.gz cilium cilium/cilium-cli
    ensure_cli_binary hubble-cli hubble-linux-amd64.tar.gz hubble cilium/hubble
    ensure_chart cilium
    ensure_chart tetragon
    ensure_chart fluent-bit-collector
    ensure_chart kube-prometheus-stack
    ensure_chart loki
    ensure_chart tempo
    ensure_chart pyroscope
    ensure_chart opentelemetry-collector
    ensure_chart perses
    ensure_loadgen_image
    capture_images

    local checksum_temporary
    checksum_temporary="$(mktemp)"
    log "Writing checksums for all captured bundle files"
    # bundle/oci, manifest.json, README.md, and the archive belong to 90-capture.sh and 91-verify-bundle.sh, not this checksum list.
    (cd "$BUNDLE_DIR" && find . -path ./oci -prune -o -type f ! -name SHA256SUMS ! -name manifest.json ! -name README.md ! -name 'o11y-demo-*.tar.gz*' -print0 | sort -z | xargs -0 sha256sum) > "$checksum_temporary"
    if [[ -f "${BUNDLE_DIR}/SHA256SUMS" ]] && cmp --silent "$checksum_temporary" "${BUNDLE_DIR}/SHA256SUMS"; then
        log "Bundle checksum manifest is unchanged"
    else
        install --mode 0644 "$checksum_temporary" "${BUNDLE_DIR}/SHA256SUMS"
    fi
    rm -f "$checksum_temporary"
    log "Offline cluster assets are ready under $BUNDLE_DIR and $CHARTS_DIR"
}

main "$@"
