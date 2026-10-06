#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUBLISHER="$ROOT_DIR/scripts/dev/publish-image-release.sh"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_ROOT"' EXIT
export MOCK_EVENTS="$TEMP_ROOT/events" MOCK_UPLOADS="$TEMP_ROOT/uploads"
export MOCK_REMOTE_ASSETS="$TEMP_ROOT/remote-assets"
export MOCK_ALWAYS_FAIL=false MOCK_CREATE_RELEASE=false MOCK_EMPTY_ASSET=false
FAIL_ASSET='persesdev-perses-v0.54.0.tar'
export FAIL_ASSET
printf 'docker.io/library/busybox:1.36\ndocker.io/persesdev/perses:v0.54.0\n' > "$TEMP_ROOT/images.txt"
printf 'library-busybox-1.36.tar\n' > "$MOCK_REMOTE_ASSETS"
docker() {
    printf 'docker %s\n' "$*" >> "$MOCK_EVENTS"
    case "$1" in
        pull) return 0 ;;
        save)
            [[ "$2" == -o ]]
            if [[ "$MOCK_EMPTY_ASSET" == true ]]; then : > "$3";
            else printf 'mock Docker archive for %s\n' "$4" > "$3"; fi ;;
        *) return 1 ;;
    esac
}
gh() {
    printf 'gh %s\n' "$*" >> "$MOCK_EVENTS"
    case "$1:$2" in
        release:view) [[ "$MOCK_CREATE_RELEASE" == false ]] ;;
        release:create) [[ "$*" == *'--notes  --latest=false'* ]] ;;
        release:upload)
            local asset attempts
            asset="${4##*/}"
            printf '%s\n' "$asset" >> "$MOCK_UPLOADS"
            attempts="$(grep -Fc "$asset" "$MOCK_UPLOADS")"
            if [[ "$asset" == "$FAIL_ASSET" ]] && { [[ "$MOCK_ALWAYS_FAIL" == true ]] || ((attempts <= 3)); }; then
                return 1
            fi
            printf '%s\n' "$asset" >> "$MOCK_REMOTE_ASSETS" ;;
        api:*)
            if [[ "$4" == '.assets[].name' ]]; then cat "$MOCK_REMOTE_ASSETS";
            else printf 'library-busybox-1.36.tar\tsha256:%064d\n' 0; fi ;;
        *) return 1 ;;
    esac
}
sleep() { printf 'mock backoff %s\n' "$1" >> "$MOCK_EVENTS"; }
export -f docker gh sleep

bash "$PUBLISHER" --tag fixture --repo fixture/repository --out "$TEMP_ROOT/dry" --dry-run > "$TEMP_ROOT/dry.log"
[[ ! -e "$MOCK_EVENTS" && ! -e "$TEMP_ROOT/dry" ]]
[[ "$(grep -c '^WOULD: docker save ' "$TEMP_ROOT/dry.log")" -eq 11 ]]
grep -F 'mapping: prom/prometheus:v3.13.1 -> prom-prometheus-v3.13.1.tar' "$TEMP_ROOT/dry.log"
bash "$PUBLISHER" --tag fixture --repo fixture/repository --out "$TEMP_ROOT/dry" --dry-run > "$TEMP_ROOT/dry-again.log"
cmp "$TEMP_ROOT/dry.log" "$TEMP_ROOT/dry-again.log"
printf 'publisher dry-run PASS: actual inventory, deterministic naming, deduplicated aliases, zero client calls/files/directories\n'

bash "$PUBLISHER" --tag fixture --repo fixture/repository --images-file "$TEMP_ROOT/images.txt" --out "$TEMP_ROOT/assets" > "$TEMP_ROOT/published.log"
grep -F 'skipped (existing)' "$TEMP_ROOT/published.log"
grep -F 'uploaded after retry' "$TEMP_ROOT/published.log"
[[ "$(grep -Fc "$FAIL_ASSET" "$MOCK_UPLOADS")" -eq 4 ]]
[[ "$(grep -c '^gh api ' "$MOCK_EVENTS")" -eq 4 ]]
grep -Fq '(existing release asset digest)' "$TEMP_ROOT/published.log"
if grep -Fq library-busybox-1.36.tar "$MOCK_UPLOADS"; then exit 1; fi
grep -Fq 'mock backoff 1' "$MOCK_EVENTS"
grep -Fq 'mock backoff 2' "$MOCK_EVENTS"
grep -Eq 'SHA-256 [a-f0-9]{64}' "$TEMP_ROOT/published.log"
printf 'publisher retry PASS: existing asset skipped; three failures isolated; missing-asset pass succeeds; final API verification and SHA report\n'

MOCK_CREATE_RELEASE=true
export MOCK_CREATE_RELEASE
bash "$PUBLISHER" --tag fixture --repo fixture/repository --images-file "$TEMP_ROOT/images.txt" --out "$TEMP_ROOT/assets" --replace-existing > "$TEMP_ROOT/replace.log"
grep -Fq library-busybox-1.36.tar "$MOCK_UPLOADS"
grep -Fq -- '--notes  --latest=false' "$MOCK_EVENTS"
printf 'publisher replace/create PASS: replacement uploads individual assets; release created with empty notes and latest=false\n'

MOCK_ALWAYS_FAIL=true MOCK_CREATE_RELEASE=false
export MOCK_ALWAYS_FAIL MOCK_CREATE_RELEASE
printf 'library-busybox-1.36.tar\n' > "$MOCK_REMOTE_ASSETS"
if bash "$PUBLISHER" --tag fixture --repo fixture/repository --images-file "$TEMP_ROOT/images.txt" --out "$TEMP_ROOT/assets" > "$TEMP_ROOT/missing.log"; then exit 1; else [[ "$?" -eq 1 ]]; fi
grep -Fq 'still missing' "$TEMP_ROOT/missing.log"
grep -Fq 'release-side failure, not a VM-side one' "$TEMP_ROOT/missing.log"
printf 'publisher missing PASS: permanently missing asset produces final nonzero result and release-side recovery hint\n'

before_uploads="$(wc -l < "$MOCK_UPLOADS")"
MOCK_EMPTY_ASSET=true
export MOCK_EMPTY_ASSET
if bash "$PUBLISHER" --tag fixture --repo fixture/repository --images-file "$TEMP_ROOT/images.txt" --out "$TEMP_ROOT/empty-assets" > "$TEMP_ROOT/empty-assets.log" 2>&1; then exit 1; else [[ "$?" -eq 1 ]]; fi
[[ "$(wc -l < "$MOCK_UPLOADS")" -eq "$before_uploads" ]]
grep -Fq 'generated asset is empty' "$TEMP_ROOT/empty-assets.log"
printf 'publisher empty asset PASS: fails before any upload\n'

: > "$TEMP_ROOT/empty-images.txt"
printf 'docker.io/example/image:1\nghcr.io/example/image:1\n' > "$TEMP_ROOT/collisions.txt"
for input in empty-images.txt collisions.txt missing-images.txt; do
    if bash "$PUBLISHER" --tag fixture --repo fixture/repository --images-file "$TEMP_ROOT/$input" --dry-run > "$TEMP_ROOT/$input.log" 2>&1; then exit 1; else [[ "$?" -eq 1 ]]; fi
done
[[ "$(wc -l < "$MOCK_UPLOADS")" -eq "$before_uploads" ]]
grep -Fq 'filename collision between different images' "$TEMP_ROOT/collisions.txt.log"
printf 'publisher invalid input PASS: empty/missing lists and cross-registry filename collisions fail without uploads\n'

mkdir "$TEMP_ROOT/no-gh"
ln -s /usr/bin/dirname "$TEMP_ROOT/no-gh/dirname"
if env -u 'BASH_FUNC_gh%%' PATH="$TEMP_ROOT/no-gh" /usr/bin/bash "$PUBLISHER" --tag fixture --repo fixture/repository --dry-run > "$TEMP_ROOT/no-gh.log" 2>&1; then exit 1; else [[ "$?" -eq 1 ]]; fi
grep -Fq 'Install GitHub CLI (gh)' "$TEMP_ROOT/no-gh.log"
printf 'publisher missing gh PASS: explicit installation/authentication fix-hint; no curl fallback\n'
