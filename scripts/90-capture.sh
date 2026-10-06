#!/usr/bin/env bash
set -euo pipefail

# Build node only: produces bundle/oci/, bundle/manifest.json, and bundle/o11y-demo-<date>-<gitsha>.tar.gz.
# This is the only script, together with 05-capture-cluster-assets.sh and 31-capture-plugins.sh, that may use the network.

LOG_PREFIX="[90-capture]"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_LOCK="${REPO_ROOT}/versions.lock"
IMAGES_TXT="${REPO_ROOT}/images.txt"
CHARTS_DIR="${REPO_ROOT}/charts"
VALUES_DIR="${REPO_ROOT}/values"
MANIFESTS_DIR="${REPO_ROOT}/manifests"
BUNDLE_DIR="${REPO_ROOT}/bundle"
OCI_DIR="${BUNDLE_DIR}/oci"
MANIFEST_JSON="${BUNDLE_DIR}/manifest.json"
KUBE_VERSION="v1.32.10"
LOADGEN_BUILDER="observability-workshop-hey"
WORK_DIR=""

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

error() {
    log "ERROR: $*" >&2
}

cleanup() {
    if [[ -n "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
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

# Prints the tag@digest pin from versions.lock for a discovered image, or fails if the image is not pinned.
resolve_locked_image() {
    local discovered="$1"
    local wanted locked_key locked_reference
    wanted="$(normalize_image "$discovered")"
    while read -r locked_key locked_reference _; do
        [[ "$locked_key" == image.* ]] || continue
        if [[ "$(normalize_image "$locked_reference")" == "$wanted" ]]; then
            if [[ "$discovered" == *@sha256:* && "${discovered##*@}" != "${locked_reference##*@}" ]]; then
                error "image '$discovered' has a digest that differs from versions.lock entry '$locked_reference'"
                return 1
            fi
            printf '%s\n' "$locked_reference"
            return 0
        fi
    done < "$VERSIONS_LOCK"
    error "image '$discovered' is not pinned by tag and digest in versions.lock"
    return 1
}

oci_layout_name() {
    local reference="${1%@sha256:*}"
    reference="${reference//\//_}"
    printf '%s\n' "${reference//:/_}"
}

# Registry path used when the replay node seeds registry.lab.local:5000; images already named for that registry keep their path.
registry_repository() {
    local reference="${1%@sha256:*}"
    reference="${reference%:*}"
    if [[ "$reference" == registry.lab.local:5000/* ]]; then
        printf '%s\n' "${reference#registry.lab.local:5000/}"
    else
        printf '%s\n' "$reference"
    fi
}

chart_render_settings() {
    # Prints "<release> <namespace> <values file>" using the same names as 20-cilium.sh and 21-observability.sh.
    case "$1" in
        cilium) printf '%s\n' "cilium kube-system cilium.yaml" ;;
        tetragon) printf '%s\n' "tetragon kube-system tetragon.yaml" ;;
        kube-prometheus-stack) printf '%s\n' "kube-prometheus-stack observability kube-prometheus-stack.yaml" ;;
        loki) printf '%s\n' "loki observability loki.yaml" ;;
        tempo) printf '%s\n' "tempo observability tempo.yaml" ;;
        pyroscope) printf '%s\n' "pyroscope observability pyroscope.yaml" ;;
        opentelemetry-collector) printf '%s\n' "otel-collector observability opentelemetry-collector.yaml" ;;
        fluent-bit-collector) printf '%s\n' "fluent-bit observability fluent-bit.yaml" ;;
        perses) printf '%s\n' "perses observability perses.yaml" ;;
        *)
            error "chart '$1' has no render settings; add it to chart_render_settings in scripts/90-capture.sh"
            return 1
            ;;
    esac
}

# Prints every image string in a multi-document YAML file.
# `.. | .image?` walks every object, so containers, initContainers, ephemeralContainers, and CR spec.image fields are all covered.
# Operators also receive images as flags (for example --prometheus-config-reloader=<image>), so container args are scanned too.
# --thanos-default-base-image is skipped: it is only used if a Thanos sidecar or ruler is configured, and none is.
extract_images_from_yaml() {
    local yaml_file="$1"
    yq -r '
        .. | objects |
        (.image? | select(type == "string")),
        ((.args? // [])[]? | select(type == "string")
            | capture("^--(?<flag>[A-Za-z0-9-]+)=(?<image>[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+:[A-Za-z0-9._-]+(@sha256:[a-f0-9]{64})?)$")?
            | select(.flag != "thanos-default-base-image")
            | .image)
    ' "$yaml_file"
}

collect_chart_images() {
    local discovered_file="$1"
    local charts_file="$2"
    local chart_archive chart_name chart_version settings release namespace values_file rendered_file

    for chart_archive in "$CHARTS_DIR"/*.tgz; do
        [[ -f "$chart_archive" ]] || continue
        chart_name="$(helm show chart "$chart_archive" | sed -n 's/^name: //p' | head -n 1)"
        chart_version="$(helm show chart "$chart_archive" | sed -n 's/^version: //p' | head -n 1)"
        settings="$(chart_render_settings "$chart_name")"
        read -r release namespace values_file <<< "$settings"
        if [[ ! -f "${VALUES_DIR}/${values_file}" ]]; then
            error "values file '${VALUES_DIR}/${values_file}' for chart '$chart_name' is missing"
            return 1
        fi

        # Hooks are the usual miss: `helm install` runs pre/post-install Jobs and `helm test` Pods that `kubectl get pods` never shows.
        # `helm template` renders hook and test resources by default, so this deliberately never passes --no-hooks or --skip-tests.
        # --api-versions enables templates gated on the Prometheus Operator and Cilium CRDs, which exist on the real cluster.
        log "Rendering $chart_name $chart_version with values/${values_file}"
        rendered_file="${WORK_DIR}/render-${chart_name}.yaml"
        helm template "$release" "$chart_archive" \
            --namespace "$namespace" \
            --values "${VALUES_DIR}/${values_file}" \
            --kube-version "$KUBE_VERSION" \
            --api-versions monitoring.coreos.com/v1 \
            --api-versions cilium.io/v2 \
            > "$rendered_file"
        extract_images_from_yaml "$rendered_file" | sed "s|\$|\tchart:${chart_name}|" >> "$discovered_file"
        printf '%s\t%s\t%s\n' "$chart_name" "$chart_version" "$(basename "$chart_archive")" >> "$charts_file"
    done

    if [[ ! -s "$charts_file" ]]; then
        error "no vendored charts found in $CHARTS_DIR; run scripts/05-capture-cluster-assets.sh first"
        return 1
    fi
}

collect_images_txt() {
    local discovered_file="$1"
    local line
    if [[ ! -f "$IMAGES_TXT" ]]; then
        error "$IMAGES_TXT is missing; it is written by scripts/30-stack.sh on a validation node and committed"
        return 1
    fi
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -n "$line" ]] || continue
        printf '%s\timages.txt\n' "$line" >> "$discovered_file"
    done < "$IMAGES_TXT"
}

collect_demo_app_images() {
    local discovered_file="$1"
    local manifest_file
    while IFS= read -r -d '' manifest_file; do
        extract_images_from_yaml "$manifest_file" | sed "s|\$|\tmanifest:${manifest_file#"${REPO_ROOT}/"}|" >> "$discovered_file"
    done < <(find "$MANIFESTS_DIR" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z)
}

# The replay node runs skopeo from the bundle to seed the local registry, so it ships even though no chart or manifest uses it.
collect_tooling_images() {
    local discovered_file="$1"
    printf '%s\ttooling:registry-seed\n' "$(locked_field image.skopeo 2)" >> "$discovered_file"
}

run_skopeo() {
    docker run --rm \
        --user "$(id -u):$(id -g)" \
        --env HOME=/tmp \
        --volume "${OCI_DIR}:/oci" \
        --volume "${WORK_DIR}:/work:ro" \
        "$(locked_field image.skopeo 2)" \
        "$@"
}

layout_has_digest() {
    local layout_dir="$1"
    local digest="$2"
    [[ -f "${layout_dir}/index.json" && -f "${layout_dir}/blobs/sha256/${digest#sha256:}" ]] &&
        jq -e --arg digest "$digest" 'any(.manifests[]; .digest == $digest)' "${layout_dir}/index.json" >/dev/null
}

# Prints "<build context> <Dockerfile>" for images built locally instead of pulled; matches 05-capture-cluster-assets.sh.
local_image_source() {
    case "$1" in
        "$(locked_field image.hey-loadgen 2)") printf '%s %s\n' "${REPO_ROOT}/images/hey" "${REPO_ROOT}/images/hey/Dockerfile" ;;
        "$(locked_field image.demo-app 2)") printf '%s %s\n' "${REPO_ROOT}/app" "${REPO_ROOT}/images/app/Dockerfile" ;;
        *) return 1 ;;
    esac
}

build_local_oci_archive() {
    local reference="$1"
    local archive="$2"
    local expected_digest="${reference##*@}"
    local metadata_file="${WORK_DIR}/local-image-metadata.json"
    local actual_digest build_context dockerfile
    read -r build_context dockerfile <<< "$(local_image_source "$reference")"

    # 05-capture-cluster-assets.sh has already created this pinned BuildKit builder and verified the image digest.
    log "Exporting the reproducible ${reference%@sha256:*} image as an OCI archive"
    docker buildx build \
        --builder "$LOADGEN_BUILDER" \
        --platform linux/amd64 \
        --provenance=false \
        --sbom=false \
        --build-arg SOURCE_DATE_EPOCH=0 \
        --build-arg "GO_BUILDER_IMAGE=$(locked_field build-image.hey-builder 2)" \
        --metadata-file "$metadata_file" \
        --file "$dockerfile" \
        --output "type=oci,dest=${archive}" \
        "$build_context"
    actual_digest="$(jq -r '."containerimage.digest" // empty' "$metadata_file")"
    if [[ "$actual_digest" != "$expected_digest" ]]; then
        error "OCI export of ${reference%@sha256:*} has digest '$actual_digest'; versions.lock expects '$expected_digest'"
        return 1
    fi
}

# Prints the single manifest digest recorded in a layout's index.json.
layout_digest() {
    jq -r 'if (.manifests | length) == 1 then .manifests[0].digest else empty end' "$1/index.json" 2>/dev/null || true
}

# Copies one image and prints "<reference>\t<digest stored in the OCI layout>" to the digests file.
# Docker-format sources (for example the cilium-envoy manifest list) must be converted to OCI media types to be stored in an
# OCI layout, which changes their digest; skopeo still verifies the download against the locked digest because it pulls by digest.
# SOURCE_DIGEST inside each layout records which locked digest the layout was produced from, so re-runs can trust the cache.
copy_image_to_oci() {
    local reference="$1"
    local digests_file="$2"
    local layout_name layout_dir tagged_reference digest source_reference oci_digest
    layout_name="$(oci_layout_name "$reference")"
    layout_dir="${OCI_DIR}/${layout_name}"
    tagged_reference="${reference%@sha256:*}"
    digest="${reference##*@}"

    oci_digest="$(layout_digest "$layout_dir")"
    if [[ -n "$oci_digest" && -f "${layout_dir}/SOURCE_DIGEST" && "$(cat "${layout_dir}/SOURCE_DIGEST")" == "$digest" ]] &&
        layout_has_digest "$layout_dir" "$oci_digest"; then
        log "Verified cached OCI layout for $reference"
        printf '%s\t%s\n' "$reference" "$oci_digest" >> "$digests_file"
        return
    fi
    rm -rf "${OCI_DIR:?}/${layout_name}"

    if local_image_source "$reference" >/dev/null; then
        build_local_oci_archive "$reference" "${WORK_DIR}/local-image-oci.tar"
        source_reference="oci-archive:/work/local-image-oci.tar"
    else
        source_reference="docker://${tagged_reference%:*}@${digest}"
        if [[ -n "${IMAGE_REGISTRY_PREFIX:-}" ]]; then
            source_reference="docker://${IMAGE_REGISTRY_PREFIX%/}/${tagged_reference#*/}"
            source_reference="${source_reference%:*}@${digest}"
        fi
    fi

    log "Copying $reference into bundle/oci/${layout_name}"
    run_skopeo copy --all --retry-times 3 \
        "$source_reference" "oci:/oci/${layout_name}:${tagged_reference}"
    oci_digest="$(layout_digest "$layout_dir")"
    if [[ -z "$oci_digest" ]] || ! layout_has_digest "$layout_dir" "$oci_digest"; then
        error "OCI layout bundle/oci/${layout_name} was not written completely"
        return 1
    fi
    if [[ "$oci_digest" != "$digest" ]]; then
        log "Converted Docker manifest $digest to OCI manifest $oci_digest"
    fi
    printf '%s\n' "$digest" > "${layout_dir}/SOURCE_DIGEST"
    printf '%s\t%s\n' "$reference" "$oci_digest" >> "$digests_file"
}

prune_stale_layouts() {
    local expected_file="$1"
    local layout_dir
    for layout_dir in "$OCI_DIR"/*; do
        [[ -d "$layout_dir" ]] || continue
        if ! grep --fixed-strings --line-regexp --quiet "$(basename "$layout_dir")" "$expected_file"; then
            log "Removing stale OCI layout $(basename "$layout_dir")"
            rm -rf "$layout_dir"
        fi
    done
}

write_manifest_json() {
    local images_file="$1"
    local charts_file="$2"
    local created="$3"
    local git_sha="$4"
    local git_dirty="$5"
    local archive_name="$6"
    local digests_file="$7"
    local charts_json images_json chart_name chart_version chart_file chart_sha reference sources oci_digest

    charts_json="${WORK_DIR}/charts.jsonl"
    images_json="${WORK_DIR}/images.jsonl"
    : > "$charts_json"
    : > "$images_json"

    while IFS=$'\t' read -r chart_name chart_version chart_file; do
        chart_sha="$(sha256sum "${CHARTS_DIR}/${chart_file}" | awk '{ print $1 }')"
        jq -cn --arg name "$chart_name" --arg version "$chart_version" --arg archive "charts/${chart_file}" --arg sha256 "$chart_sha" \
            '{name: $name, version: $version, archive: $archive, sha256: $sha256}' >> "$charts_json"
    done < "$charts_file"

    while IFS=$'\t' read -r reference sources; do
        oci_digest="$(awk -F '\t' -v reference="$reference" '$1 == reference { print $2; exit }' "$digests_file")"
        jq -cn \
            --arg reference "$reference" \
            --arg digest "${reference##*@}" \
            --arg oci_digest "$oci_digest" \
            --arg oci_layout "oci/$(oci_layout_name "$reference")" \
            --arg registry_repository "$(registry_repository "$reference")" \
            --arg tag "$(sed 's/@sha256:.*//; s/.*://' <<< "$reference")" \
            --arg sources "$sources" \
            '{reference: $reference, digest: $digest, oci_digest: $oci_digest, oci_layout: $oci_layout, registry_repository: $registry_repository, tag: $tag, sources: ($sources | split(","))}' >> "$images_json"
    done < "$images_file"

    jq -n \
        --arg created "$created" \
        --arg git_sha "$git_sha" \
        --argjson git_dirty "$git_dirty" \
        --arg archive "$archive_name" \
        --slurpfile charts "$charts_json" \
        --slurpfile images "$images_json" \
        '{schema_version: 1, created: $created, git_sha: $git_sha, git_dirty: $git_dirty, archive: $archive, charts: $charts, images: $images}' \
        > "${MANIFEST_JSON}.tmp"
    mv "${MANIFEST_JSON}.tmp" "$MANIFEST_JSON"
}

write_archive() {
    local archive_name="$1"
    local old_archive
    for old_archive in "$BUNDLE_DIR"/o11y-demo-*.tar.gz; do
        [[ -f "$old_archive" && "$(basename "$old_archive")" != "$archive_name" ]] || continue
        log "Removing previous archive $(basename "$old_archive")"
        rm -f "$old_archive"
    done

    log "Writing bundle/${archive_name}"
    tar --create \
        --use-compress-program 'gzip -1' \
        --file "${BUNDLE_DIR}/${archive_name}.tmp" \
        --directory "$REPO_ROOT" \
        --sort=name \
        --owner=0 --group=0 --numeric-owner \
        --exclude='bundle/o11y-demo-*.tar.gz*' \
        --exclude='bundle/o11y-demo-installer-amd64.iso*' \
        README.md versions.lock images.txt docs scripts installer charts values manifests dashboards bundle
    mv "${BUNDLE_DIR}/${archive_name}.tmp" "${BUNDLE_DIR}/${archive_name}"
    (cd "$BUNDLE_DIR" && sha256sum "$archive_name" > "${archive_name}.sha256")
}

main() {
    local discovered_file charts_file resolved_file images_file layouts_file digests_file
    local discovered source locked created date_stamp git_sha git_short git_dirty archive_name

    for tool in awk docker git gzip helm jq sha256sum sort tar yq; do
        require_tool "$tool"
    done
    docker buildx version >/dev/null
    if ! git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
        error "$REPO_ROOT is not a git checkout with a commit; the bundle must record a git SHA"
        exit 1
    fi

    log "Capturing K3S, tools, charts, and the docker image archive"
    "${REPO_ROOT}/scripts/05-capture-cluster-assets.sh"

    WORK_DIR="$(mktemp -d)"
    mkdir -p "$OCI_DIR"
    discovered_file="${WORK_DIR}/discovered.tsv"
    charts_file="${WORK_DIR}/charts.tsv"
    resolved_file="${WORK_DIR}/resolved.tsv"
    images_file="${WORK_DIR}/images.tsv"
    layouts_file="${WORK_DIR}/layouts.txt"
    digests_file="${WORK_DIR}/oci-digests.tsv"
    : > "$discovered_file"
    : > "$charts_file"
    : > "$resolved_file"

    collect_chart_images "$discovered_file" "$charts_file"
    collect_images_txt "$discovered_file"
    collect_demo_app_images "$discovered_file"
    collect_tooling_images "$discovered_file"

    while IFS=$'\t' read -r discovered source; do
        [[ -n "$discovered" ]] || continue
        locked="$(resolve_locked_image "$discovered")"
        printf '%s\t%s\n' "$locked" "$source" >> "$resolved_file"
    done < "$discovered_file"

    # One row per pinned image, with every place it was discovered joined by commas.
    sort -u "$resolved_file" |
        awk -F '\t' '{ if ($1 in sources) sources[$1] = sources[$1] "," $2; else { order[++count] = $1; sources[$1] = $2 } }
            END { for (i = 1; i <= count; i++) printf "%s\t%s\n", order[i], sources[order[i]] }' > "$images_file"
    log "Resolved $(wc -l < "$images_file") unique pinned images"

    cut -f 1 "$images_file" | while IFS= read -r locked; do
        oci_layout_name "$locked"
    done > "$layouts_file"
    prune_stale_layouts "$layouts_file"

    : > "$digests_file"
    while IFS=$'\t' read -r locked _; do
        copy_image_to_oci "$locked" "$digests_file"
    done < "$images_file"

    created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    date_stamp="$(date -u +%Y%m%d)"
    git_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    git_short="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)"
    git_dirty=false
    if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
        git_dirty=true
        log "WARNING: the working tree has uncommitted changes; manifest.json records git_dirty=true"
    fi
    archive_name="o11y-demo-${date_stamp}-${git_short}.tar.gz"

    write_manifest_json "$images_file" "$charts_file" "$created" "$git_sha" "$git_dirty" "$archive_name" "$digests_file"
    write_archive "$archive_name"
    log "Bundle ready: bundle/${archive_name} with $(jq '.images | length' "$MANIFEST_JSON") images and $(jq '.charts | length' "$MANIFEST_JSON") charts"
}

main "$@"
