#!/usr/bin/env bash
set -euo pipefail

# Verifies that bundle/manifest.json, bundle/oci/, and charts/ agree; needs only bash, coreutils, tar, and jq so it also runs on the replay node.

LOG_PREFIX="[91-verify-bundle]"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHARTS_DIR="${REPO_ROOT}/charts"
BUNDLE_DIR="${REPO_ROOT}/bundle"
MANIFEST_JSON="${BUNDLE_DIR}/manifest.json"
MISSING=()

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

add_missing() {
    MISSING+=("$1")
}

blob_path() {
    printf '%s/blobs/sha256/%s\n' "$1" "${2#sha256:}"
}

# Checks the config and every layer referenced by one image manifest.
check_image_manifest_blobs() {
    local layout_dir="$1"
    local manifest_digest="$2"
    local reference="$3"
    local manifest_file blob_digest
    manifest_file="$(blob_path "$layout_dir" "$manifest_digest")"
    if [[ ! -f "$manifest_file" ]]; then
        add_missing "image $reference: manifest blob $manifest_digest is missing"
        return
    fi
    while IFS= read -r blob_digest; do
        if [[ ! -f "$(blob_path "$layout_dir" "$blob_digest")" ]]; then
            add_missing "image $reference: blob $blob_digest referenced by $manifest_digest is missing"
        fi
    done < <(jq -r '.config.digest, (.layers // [])[].digest' "$manifest_file")
}

check_image() {
    local reference="$1"
    local digest="$2"
    local oci_layout="$3"
    local layout_dir="${BUNDLE_DIR}/${oci_layout}"
    local top_blob media_type child_digest

    if [[ ! -d "$layout_dir" ]]; then
        add_missing "image $reference: OCI layout bundle/${oci_layout} is missing"
        return
    fi
    if [[ ! -f "${layout_dir}/oci-layout" || ! -f "${layout_dir}/index.json" ]]; then
        add_missing "image $reference: bundle/${oci_layout} is not an OCI layout (oci-layout or index.json missing)"
        return
    fi
    if ! jq -e --arg digest "$digest" 'any(.manifests[]; .digest == $digest)' "${layout_dir}/index.json" >/dev/null; then
        add_missing "image $reference: bundle/${oci_layout}/index.json does not reference $digest"
        return
    fi

    top_blob="$(blob_path "$layout_dir" "$digest")"
    if [[ ! -f "$top_blob" ]]; then
        add_missing "image $reference: manifest blob $digest is missing"
        return
    fi
    if [[ "$(sha256sum "$top_blob" | awk '{ print $1 }')" != "${digest#sha256:}" ]]; then
        add_missing "image $reference: manifest blob $digest does not match its digest"
        return
    fi

    media_type="$(jq -r '.mediaType // empty' "$top_blob")"
    case "$media_type" in
        application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json)
            while IFS= read -r child_digest; do
                check_image_manifest_blobs "$layout_dir" "$child_digest" "$reference"
            done < <(jq -r '.manifests[].digest' "$top_blob")
            ;;
        *)
            check_image_manifest_blobs "$layout_dir" "$digest" "$reference"
            ;;
    esac
}

# Reads name and version from the top-level Chart.yaml without needing helm.
chart_identity() {
    local chart_archive="$1"
    local top_directory chart_yaml name version
    top_directory="$(tar --list --gzip --file "$chart_archive" | head -n 1)"
    top_directory="${top_directory%%/*}"
    chart_yaml="$(tar --extract --gzip --to-stdout --file "$chart_archive" "${top_directory}/Chart.yaml")"
    name="$(awk '/^name:/ { print $2; exit }' <<< "$chart_yaml" | tr -d "\"'")"
    version="$(awk '/^version:/ { print $2; exit }' <<< "$chart_yaml" | tr -d "\"'")"
    printf '%s %s\n' "$name" "$version"
}

check_charts() {
    local chart_archive name version chart_count=0
    for chart_archive in "$CHARTS_DIR"/*.tgz; do
        [[ -f "$chart_archive" ]] || continue
        chart_count=$((chart_count + 1))
        read -r name version <<< "$(chart_identity "$chart_archive")"
        if ! jq -e --arg name "$name" --arg version "$version" 'any(.charts[]; .name == $name and .version == $version)' "$MANIFEST_JSON" >/dev/null; then
            add_missing "chart $name $version (charts/$(basename "$chart_archive")) is not recorded in bundle/manifest.json"
        fi
    done
    if (( chart_count == 0 )); then
        add_missing "no chart archives found in charts/"
    fi
}

main() {
    local reference digest oci_layout image_count chart_count
    for tool in awk jq sha256sum tar; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log "ERROR: required command '$tool' is not installed" >&2
            exit 1
        fi
    done
    if [[ ! -f "$MANIFEST_JSON" ]]; then
        log "ERROR: bundle/manifest.json is missing; run scripts/90-capture.sh on the build node" >&2
        exit 1
    fi

    while IFS=$'\t' read -r reference digest oci_layout; do
        check_image "$reference" "$digest" "$oci_layout"
    done < <(jq -r '.images[] | [.reference, .oci_digest, .oci_layout] | @tsv' "$MANIFEST_JSON")
    check_charts

    if (( ${#MISSING[@]} > 0 )); then
        log "ERROR: bundle is incomplete; missing:" >&2
        printf '%s\n' "${MISSING[@]/#/${LOG_PREFIX}   - }" >&2
        exit 1
    fi

    image_count="$(jq '.images | length' "$MANIFEST_JSON")"
    chart_count="$(jq '.charts | length' "$MANIFEST_JSON")"
    log "✓ bundle complete: ${image_count} images in bundle/oci, ${chart_count} charts recorded, git $(jq -r '.git_sha[0:12]' "$MANIFEST_JSON")"
}

main "$@"
