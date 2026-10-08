#!/usr/bin/env bash
set -euo pipefail

# Online-only publisher: per-image archives or a checksum-verified split bundle.
# Bundle releases stay draft until remote asset digests and sizes are verified.
# Authentication comes from gh's environment, never this file.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_NAME=publish-image-release SCRIPT_VERSION=4 SELFTEST_MODE=true
source "$ROOT_DIR/learner-vm/scripts/lib.sh"
TAG='' REPOSITORY='' IMAGES_FILE="$ROOT_DIR/content/extracted/external-images.txt"
IMAGES_FILE_EXPLICIT=false
OUT_DIR="$ROOT_DIR/dist/image-release" DRY_RUN=false REPLACE_EXISTING=false RETRIES=3
BUNDLE='' PART_BYTES=1900000000
BUNDLE_SOURCE="$ROOT_DIR/dist/learner-dependencies-java17-r7"
BUNDLE_SOURCE_EXPLICIT=false IMAGE_ONLY=false
usage() {
    printf '%s\n' 'Usage: publish-image-release.sh --tag TAG --repo OWNER/NAME [--bundle-source DIR | --bundle ARCHIVE | --image-only | --images-file PATH] [--out DIR] [--dry-run] [--replace-existing] [--retries N] [--part-bytes N]'
}
die() { printf '[publish-image-release] ERROR: %s\n' "$*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --tag|--repo|--images-file|--out|--retries|--bundle|--part-bytes|--bundle-source)
            (($# >= 2)) || die "missing value for $1"
            case "$1" in
                --tag) TAG="$2" ;; --repo) REPOSITORY="$2" ;;
                --images-file) IMAGES_FILE="$2"; IMAGES_FILE_EXPLICIT=true ;; --out) OUT_DIR="$2" ;; --retries) RETRIES="$2" ;;
                --bundle) BUNDLE="$2" ;; --part-bytes) PART_BYTES="$2" ;;
                --bundle-source) BUNDLE_SOURCE="$2"; BUNDLE_SOURCE_EXPLICIT=true ;;
            esac
            shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --image-only) IMAGE_ONLY=true; shift ;;
        --replace-existing) REPLACE_EXISTING=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die '--tag is required (letters, digits, dot, underscore, dash)'
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die '--repo OWNER/NAME is required'
[[ "$RETRIES" =~ ^[1-9][0-9]*$ ]] || die '--retries must be a positive integer'
command -v gh >/dev/null 2>&1 || die 'Install GitHub CLI (gh) and configure gh authentication; no curl fallback is provided.'
[[ "$BUNDLE_SOURCE_EXPLICIT" == false || ( -z "$BUNDLE" && "$IMAGE_ONLY" == false && "$IMAGES_FILE_EXPLICIT" == false ) ]] || die '--bundle-source cannot be combined with an archive or image-only mode'
[[ -z "$BUNDLE" || "$IMAGE_ONLY" == false ]] || die '--bundle cannot be combined with --image-only'
create_bundle() {
    local source_files checksum_files expected
    [[ "$REPLACE_EXISTING" == false ]] || die 'automatic bundle mode cannot use --replace-existing'
    [[ "$PART_BYTES" =~ ^[1-9][0-9]{0,9}$ ]] && ((PART_BYTES <= 2000000000)) || die '--part-bytes must be between 1 and 2000000000'
    BUNDLE="$OUT_DIR/learner-dependencies-$TAG.tar.gz"
    if [[ "$DRY_RUN" == true ]]; then
        printf 'WOULD: pack offline-verified capture directory %s into %s and generate its trusted checksum\n' "$BUNDLE_SOURCE" "$BUNDLE"
        printf 'WOULD: verify, split and publish through a draft release after remote digest verification\n'
        printf 'Dry-run: no capture, client calls, directories, archives, uploads, or release changes.\n'
        return 0
    fi
    [[ -d "$BUNDLE_SOURCE" && -s "$BUNDLE_SOURCE/manifest.json" ]] || die 'verified capture directory is missing; run capture and offline validation first'
    BUNDLE_SOURCE="$(cd "$BUNDLE_SOURCE" && pwd -P)"
    if [[ -e "$BUNDLE" || -e "$BUNDLE.sha256" ]]; then
        [[ -s "$BUNDLE" && -s "$BUNDLE.sha256" && -s "$BUNDLE_SOURCE/SHA256SUMS" ]] || die 'automatic bundle output is incomplete; choose a new --out directory'
        expected="$(awk 'NR == 1 {print $1}' "$BUNDLE.sha256")"
        python3 "$ROOT_DIR/learner-vm/dependency_bundle.py" verify --archive "$BUNDLE" --sha256 "$expected"
        if ! tar -xOzf "$BUNDLE" learner-dependencies/SHA256SUMS | cmp -s - "$BUNDLE_SOURCE/SHA256SUMS"; then die 'capture inventory changed; choose a new --out directory'; fi
        [[ -z "$(find "$BUNDLE_SOURCE" ! -type d ! -type f -print -quit)" ]] || die 'capture directory contains links or special files'
        source_files="$(find "$BUNDLE_SOURCE" -type f ! -path "$BUNDLE_SOURCE/SHA256SUMS" -printf '\n' | wc -l)"
        checksum_files="$(wc -l < "$BUNDLE_SOURCE/SHA256SUMS")"
        ((source_files == checksum_files)) || die 'capture file inventory changed; choose a new --out directory'
        if ! (cd "$BUNDLE_SOURCE" && sha256sum --check --status SHA256SUMS); then die 'capture contents changed; choose a new --out directory'; fi
        printf '[publish-image-release] Reusing automatic bundle; capture contents match the sealed archive.\n'
    else
        python3 "$ROOT_DIR/learner-vm/dependency_bundle.py" pack --source "$BUNDLE_SOURCE" --output "$BUNDLE"
    fi
}
publish_bundle() {
    local name expected stage asset actual draft attempt uploaded size remote_hash
    local -a parts=() assets=()
    [[ "$IMAGES_FILE_EXPLICIT" == false && "$REPLACE_EXISTING" == false ]] || die 'bundle mode cannot use --images-file or --replace-existing'
    [[ "$PART_BYTES" =~ ^[1-9][0-9]{0,9}$ ]] && ((PART_BYTES <= 2000000000)) || die '--part-bytes must be between 1 and 2000000000'
    [[ -s "$BUNDLE" && -s "$BUNDLE.sha256" ]] || die 'bundle archive and trusted .sha256 sidecar are required'
    name="$(basename "$BUNDLE")"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.tar\.gz$ ]] || die 'bundle filename must be a simple .tar.gz asset name'
    expected="$(awk 'NR == 1 {print $1}' "$BUNDLE.sha256")"
    [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || die 'bundle sidecar requires a trusted SHA-256'
    if [[ "$DRY_RUN" == true ]]; then
        printf 'WOULD: verify bundle %s against %s; split into parts of at most %s bytes\n' "$BUNDLE" "$expected" "$PART_BYTES"
        printf 'WOULD: generate part checksums, inventories and reassembly instructions in %s\n' "$OUT_DIR"
        printf 'WOULD: upload to a draft %s release in %s; verify every remote digest before publishing with latest=false\n' "$TAG" "$REPOSITORY"
        printf 'Dry-run: no client calls, directories, splits, uploads, or release changes.\n'
        return 0
    fi
    for tool in python3 jq tar split sha256sum git; do command -v "$tool" >/dev/null 2>&1 || die "required bundle publication tool is missing: $tool"; done
    python3 "$ROOT_DIR/learner-vm/dependency_bundle.py" verify --archive "$BUNDLE" --sha256 "$expected"
    mkdir -p "$OUT_DIR"
    stage="$(mktemp -d "$OUT_DIR/.bundle-release.XXXXXX")"
    trap "rm -rf -- $(printf '%q' "$stage")" EXIT
    split --bytes="$PART_BYTES" --numeric-suffixes=0 --suffix-length=3 "$BUNDLE" "$stage/$name.part"
    parts=("$stage/$name.part"[0-9][0-9][0-9])
    [[ -s "${parts[0]}" ]] || die 'bundle split produced no parts'
    : > "$stage/parts.jsonl"
    for asset in "${parts[@]}"; do
        actual="$(sha256sum "$asset" | awk '{print $1}')"
        size="$(stat -c '%s' "$asset")"
        jq -n --arg name "${asset##*/}" --arg sha256 "$actual" --argjson bytes "$size" '{name:$name, sha256:$sha256, bytes:$bytes}' >> "$stage/parts.jsonl"
    done
    jq -s --arg archive "$name" --arg sha256 "$expected" --argjson part_bytes "$PART_BYTES" '{schema:1, archive:$archive, sha256:$sha256, part_bytes:$part_bytes, parts:.}' "$stage/parts.jsonl" > "$stage/bundle-publication.json"
    printf '%s  %s\n' "$expected" "$name" > "$stage/$name.sha256"
    tar -xOzf "$BUNDLE" learner-dependencies/manifest.json > "$stage/bundle-inventory.json"
    tar -xOzf "$BUNDLE" learner-dependencies/lab-files-inventory.json > "$stage/lab-files-inventory.json"
    tar -xOzf "$BUNDLE" learner-dependencies/generic-checksums.txt > "$stage/generic-checksums.txt"
    {
        printf '# Reassemble the Learner Bundle\n\nDownload all parts and metadata into one directory, then run:\n\n```bash\nsha256sum --check SHA256SUMS\ncat'
        for asset in "${parts[@]}"; do printf ' %q' "${asset##*/}"; done
        printf ' > %q\nsha256sum --check %q\n```\n\nVerify the reassembled archive with learner-vm/dependency_bundle.py before import.\n' "$name" "$name.sha256"
    } > "$stage/REASSEMBLE.md"
    assets=("${parts[@]}" "$stage/$name.sha256" "$stage/bundle-publication.json" "$stage/bundle-inventory.json" "$stage/lab-files-inventory.json" "$stage/generic-checksums.txt" "$stage/REASSEMBLE.md")
    : > "$stage/SHA256SUMS"
    for asset in "${assets[@]}"; do printf '%s  %s\n' "$(sha256sum "$asset" | awk '{print $1}')" "${asset##*/}" >> "$stage/SHA256SUMS"; done
    assets+=("$stage/SHA256SUMS")
    for asset in "${assets[@]}"; do cp "$asset" "$OUT_DIR/${asset##*/}"; done
    printf 'Verified lab image, package-cache and generic-download bundle.\n\nDownload every split part and metadata asset, then follow REASSEMBLE.md.\n\nOS packages/media and k3s bootstrap prerequisites are separate.\nExact RHEL 8.6 provisioning and k3s acceptance are not certified by this release.\n' > "$stage/RELEASE-NOTES.md"
    if draft="$(gh release view "$TAG" --repo "$REPOSITORY" --json isDraft --jq '.isDraft' 2>/dev/null)"; then
        [[ "$draft" == true || "$draft" == false ]] || die 'could not determine existing release visibility'
    else
        gh release create "$TAG" --repo "$REPOSITORY" --target "$(git -C "$ROOT_DIR" rev-parse HEAD)" --title "$TAG Lab Dependencies" --notes-file "$stage/RELEASE-NOTES.md" --draft --latest=false || die 'could not create draft release'
        draft=true
    fi
    gh api "repos/$REPOSITORY/releases/tags/$TAG" > "$stage/remote.json" || die 'could not inspect release assets'
    for asset in "${assets[@]}"; do
        actual="$(sha256sum "$asset" | awk '{print $1}')"
        remote_hash="$(jq -r --arg name "${asset##*/}" '.assets[] | select(.name == $name) | .digest // "unavailable"' "$stage/remote.json")"
        if [[ -n "$remote_hash" ]]; then
            [[ "$remote_hash" == "sha256:$actual" ]] || die "existing release asset digest mismatch: ${asset##*/}"
            continue
        fi
        [[ "$draft" == true ]] || die "published release is missing ${asset##*/}; refusing to modify it"
        uploaded=false
        for ((attempt=1; attempt<=RETRIES; attempt++)); do
            if gh release upload "$TAG" "$asset" --repo "$REPOSITORY"; then uploaded=true; break; fi
        done
        [[ "$uploaded" == true ]] || die "upload failed; release remains draft: ${asset##*/}"
    done
    gh api "repos/$REPOSITORY/releases/tags/$TAG" > "$stage/remote.json" || die 'could not verify uploaded assets; release remains draft'
    for asset in "${assets[@]}"; do
        actual="$(sha256sum "$asset" | awk '{print $1}')"
        size="$(stat -c '%s' "$asset")"
        jq -e --arg name "${asset##*/}" --arg digest "sha256:$actual" --argjson size "$size" '[.assets[] | select(.name == $name and .digest == $digest and .size == $size)] | length == 1' "$stage/remote.json" >/dev/null || die "remote asset verification failed; release remains draft: ${asset##*/}"
    done
    if [[ "$draft" == true ]]; then gh release edit "$TAG" --repo "$REPOSITORY" --draft=false --latest=false || die 'assets verified but release could not be published'; fi
    printf '[publish-image-release] Verified bundle release: https://github.com/%s/releases/tag/%s\n' "$REPOSITORY" "$TAG"
}
if [[ -z "$BUNDLE" && "$IMAGE_ONLY" == false && "$IMAGES_FILE_EXPLICIT" == false ]]; then
    create_bundle
    if [[ "$DRY_RUN" == true ]]; then exit 0; fi
fi
if [[ -n "$BUNDLE" ]]; then publish_bundle; exit 0; fi
[[ -r "$IMAGES_FILE" && -s "$IMAGES_FILE" ]] || die "image list is missing or empty: $IMAGES_FILE"
declare -a REFERENCES=() ASSETS=()
declare -A ASSET_REFERENCES=() RESULTS=() HASHES=() ATTEMPTS=() RELEASE_HASHES=()
add_reference() {
    local reference="$1" asset canonical
    reference="${reference%%#*}"
    reference="${reference//[[:space:]]/}"
    [[ -n "$reference" ]] || return 0
    asset="$(image_asset_name "$reference")" || die "reference needs a pinned tag: $reference"
    canonical="$(image_canonical_reference "$reference")"
    printf 'mapping: %s -> %s\n' "$reference" "$asset"
    if [[ -n "${ASSET_REFERENCES[$asset]+x}" ]]; then
        [[ "${ASSET_REFERENCES[$asset]}" == "$canonical" ]] || die "filename collision between different images: $asset"
        return 0
    fi
    ASSET_REFERENCES["$asset"]="$canonical"
    REFERENCES+=("$reference") ASSETS+=("$asset")
}
while IFS= read -r reference || [[ -n "$reference" ]]; do
    add_reference "$reference"
done < "$IMAGES_FILE"
if [[ "$IMAGES_FILE_EXPLICIT" == false ]]; then
    command -v jq >/dev/null 2>&1 || die 'Install jq to include recorded lab build bases in the default release.'
    commands_file="$ROOT_DIR/content/extracted/commands.json"
    [[ -r "$commands_file" && -s "$commands_file" ]] || die "build metadata is missing or empty: $commands_file"
    if base_references="$(jq -r '[.[] | .labs[]? | .commands[]? | select(.type == "build")] as $builds | [$builds[] | .tag // empty] as $local_tags | $builds[] | .base_images[]? | select(. != "scratch" and (startswith("localhost/") | not)) | . as $base | select($local_tags | index($base) | not)' "$commands_file")"; then
        while IFS= read -r reference || [[ -n "$reference" ]]; do
            add_reference "$reference"
        done <<< "$base_references"
    else
        die 'Could not read recorded build bases; regenerate commands.json before publishing.'
    fi
fi
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
