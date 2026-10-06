#!/usr/bin/env bash
set -euo pipefail

# Online-only convenience: Docker produces one saved image per release asset.
# Batch uploads can partially fail; upload individually, then retry only assets
# that remain missing. Authentication comes from gh's environment, never this file.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_NAME=publish-image-release SCRIPT_VERSION=1 SELFTEST_MODE=true
source "$ROOT_DIR/learner-vm/scripts/lib.sh"
TAG='' REPOSITORY='' IMAGES_FILE="$ROOT_DIR/content/extracted/external-images.txt"
OUT_DIR="$ROOT_DIR/dist/image-release" DRY_RUN=false REPLACE_EXISTING=false RETRIES=3
usage() {
    printf '%s\n' 'Usage: publish-image-release.sh --tag TAG --repo OWNER/NAME [--images-file PATH] [--out DIR] [--dry-run] [--replace-existing] [--retries N]'
}
die() { printf '[publish-image-release] ERROR: %s\n' "$*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --tag|--repo|--images-file|--out|--retries)
            (($# >= 2)) || die "missing value for $1"
            case "$1" in
                --tag) TAG="$2" ;; --repo) REPOSITORY="$2" ;;
                --images-file) IMAGES_FILE="$2" ;; --out) OUT_DIR="$2" ;; --retries) RETRIES="$2" ;;
            esac
            shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --replace-existing) REPLACE_EXISTING=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die '--tag is required (letters, digits, dot, underscore, dash)'
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die '--repo OWNER/NAME is required'
[[ "$RETRIES" =~ ^[1-9][0-9]*$ ]] || die '--retries must be a positive integer'
command -v gh >/dev/null 2>&1 || die 'Install GitHub CLI (gh) and configure gh authentication; no curl fallback is provided.'
[[ -r "$IMAGES_FILE" && -s "$IMAGES_FILE" ]] || die "image list is missing or empty: $IMAGES_FILE"
declare -a REFERENCES=() ASSETS=()
declare -A ASSET_REFERENCES=() RESULTS=() HASHES=() ATTEMPTS=() RELEASE_HASHES=()
while IFS= read -r reference || [[ -n "$reference" ]]; do
    reference="${reference%%#*}"
    reference="${reference//[[:space:]]/}"
    [[ -n "$reference" ]] || continue
    asset="$(image_asset_name "$reference")" || die "reference needs a pinned tag: $reference"
    canonical="$(image_canonical_reference "$reference")"
    printf 'mapping: %s -> %s\n' "$reference" "$asset"
    if [[ -n "${ASSET_REFERENCES[$asset]+x}" ]]; then
        [[ "${ASSET_REFERENCES[$asset]}" == "$canonical" ]] || die "filename collision between different images: $asset"
        continue
    fi
    ASSET_REFERENCES["$asset"]="$canonical"
    REFERENCES+=("$reference") ASSETS+=("$asset")
done < "$IMAGES_FILE"
((${#ASSETS[@]} > 0)) || die 'image list has no references after comments/blank lines'
if [[ "$DRY_RUN" == true ]]; then
    for index in "${!ASSETS[@]}"; do
        printf 'WOULD: docker pull %q\n' "${REFERENCES[$index]}"
        printf 'WOULD: docker save -o %q %q\n' "$OUT_DIR/${ASSETS[$index]}" "${REFERENCES[$index]}"
    done
    printf 'WOULD: gh release view %q --repo %q || gh release create %q --repo %q --notes "" --latest=false\n' "$TAG" "$REPOSITORY" "$TAG" "$REPOSITORY"
    for asset in "${ASSETS[@]}"; do
        printf 'WOULD: %s; gh release upload %q %q --repo %q --clobber (up to %s attempts, backoff 1s/2s/4s)\n' "$(if [[ "$REPLACE_EXISTING" == true ]]; then printf 'replace existing'; else printf 'skip existing'; fi)" "$TAG" "$OUT_DIR/$asset" "$REPOSITORY" "$RETRIES"
    done
    printf 'WOULD: gh api repos/%s/releases/tags/%s --jq '\''.assets[].name'\''; retry only missing assets; re-check\n' "$REPOSITORY" "$TAG"
    printf 'Connected-machine download pattern: https://github.com/%s/releases/download/%s/<asset>\n' "$REPOSITORY" "$TAG"
    printf 'Dry-run: no client calls, directories, pulls, saves, uploads, or release changes.\n'
    exit 0
fi
command -v docker >/dev/null 2>&1 || die 'Install Docker on the connected publishing machine.'
mkdir -p "$OUT_DIR"
TEMP_ASSET=''
trap '[[ -z "$TEMP_ASSET" ]] || rm -f -- "$TEMP_ASSET"' EXIT
for index in "${!ASSETS[@]}"; do
    asset="${ASSETS[$index]}"
    docker pull "${REFERENCES[$index]}" || die "Docker pull failed: ${REFERENCES[$index]}"
    TEMP_ASSET="$(mktemp "$OUT_DIR/.$asset.XXXXXX")"
    docker save -o "$TEMP_ASSET" "${REFERENCES[$index]}" || die "Docker save failed: $asset"
    [[ -s "$TEMP_ASSET" ]] || die "generated asset is empty: $asset"
    mv -- "$TEMP_ASSET" "$OUT_DIR/$asset"
    TEMP_ASSET=''
    HASHES["$asset"]="$(sha256sum "$OUT_DIR/$asset" | awk '{print $1}')"
    RESULTS["$asset"]='created'
done
for asset in "${ASSETS[@]}"; do [[ -s "$OUT_DIR/$asset" ]] || die "asset missing before upload: $asset"; done
if ! gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    gh release create "$TAG" --repo "$REPOSITORY" --notes "" --latest=false || die 'could not create release'
fi
list_assets() { gh api "repos/$REPOSITORY/releases/tags/$TAG" --jq '.assets[].name'; }
remote_assets="$(list_assets)" || die 'could not enumerate existing release assets'
upload_asset() {
    local asset="$1" attempt delay=1
    for ((attempt=1; attempt<=RETRIES; attempt++)); do
        ATTEMPTS["$asset"]=$((${ATTEMPTS[$asset]:-0} + 1))
        if gh release upload "$TAG" "$OUT_DIR/$asset" --repo "$REPOSITORY" --clobber; then
            if ((${ATTEMPTS[$asset]} > 1)); then RESULTS["$asset"]='uploaded after retry'; else RESULTS["$asset"]='uploaded'; fi
            return 0
        fi
        if ((attempt < RETRIES)); then sleep "$delay"; delay=$((delay * 2)); fi
    done
    RESULTS["$asset"]='upload failed; awaiting missing-asset check'
    return 1
}
for asset in "${ASSETS[@]}"; do
    if [[ "$REPLACE_EXISTING" == false ]] && grep -Fxq "$asset" <<< "$remote_assets"; then
        RESULTS["$asset"]='skipped (existing)'
    else
        if upload_asset "$asset"; then :; else :; fi
    fi
done
remote_assets="$(list_assets)" || die 'could not enumerate assets after upload pass'
for asset in "${ASSETS[@]}"; do
    if ! grep -Fxq "$asset" <<< "$remote_assets"; then
        if upload_asset "$asset"; then :; else :; fi
    fi
done
remote_assets="$(list_assets)" || die 'could not enumerate assets after retry pass'
remote_digests="$(gh api "repos/$REPOSITORY/releases/tags/$TAG" --jq '.assets[] | select(.digest != null) | [.name, .digest] | @tsv')" || die 'could not read release asset digests'
while IFS=$'\t' read -r asset digest; do
    if [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then RELEASE_HASHES["$asset"]="${digest#sha256:}"; fi
done <<< "$remote_digests"
missing=0
for index in "${!ASSETS[@]}"; do
    asset="${ASSETS[$index]}"
    if ! grep -Fxq "$asset" <<< "$remote_assets"; then RESULTS["$asset"]='still missing'; ((missing += 1)); fi
    hash="${HASHES[$asset]}" hash_note=''
    if [[ "${RESULTS[$asset]}" == 'skipped (existing)' ]]; then
        if [[ -n "${RELEASE_HASHES[$asset]:-}" ]]; then hash="${RELEASE_HASHES[$asset]}"; hash_note=' (existing release asset digest)';
        else hash_note=' (new local file only; existing release digest unavailable; do not pin a download with this hash)'; fi
    fi
    printf '%s -> %s | created local asset; %s | SHA-256 %s%s\n' "${REFERENCES[$index]}" "$asset" "${RESULTS[$asset]}" "$hash" "$hash_note"
done
printf 'Connected-machine download pattern: https://github.com/%s/releases/download/%s/<asset>\n' "$REPOSITORY" "$TAG"
printf 'If any asset is still missing, this is a release-side failure, not a VM-side one; retry manually with gh release upload.\n'
((missing == 0))
