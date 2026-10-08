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

bash "$PUBLISHER" --tag fixture --repo fixture/repository --image-only --out "$TEMP_ROOT/dry" --dry-run > "$TEMP_ROOT/dry.log"
[[ ! -e "$MOCK_EVENTS" && ! -e "$TEMP_ROOT/dry" ]]
[[ "$(grep -c '^WOULD: docker save ' "$TEMP_ROOT/dry.log")" -eq 11 ]]
grep -F 'mapping: prom/prometheus:v3.13.1 -> prom-prometheus-v3.13.1.tar' "$TEMP_ROOT/dry.log"
grep -F 'WOULD: docker save' "$TEMP_ROOT/dry.log" | grep -Fq 'library-python-3.13-bullseye.tar'
grep -F 'WOULD: docker save' "$TEMP_ROOT/dry.log" | grep -Fq 'library-eclipse-temurin-17.tar'
bash "$PUBLISHER" --tag fixture --repo fixture/repository --image-only --out "$TEMP_ROOT/dry" --dry-run > "$TEMP_ROOT/dry-again.log"
cmp "$TEMP_ROOT/dry.log" "$TEMP_ROOT/dry-again.log"
printf 'publisher dry-run PASS: actual inventory, deterministic naming, deduplicated aliases, zero client calls/files/directories\n'

FAKE_ROOT="$TEMP_ROOT/base-repository"
mkdir -p "$FAKE_ROOT/scripts/dev" "$FAKE_ROOT/learner-vm/scripts" "$FAKE_ROOT/content/extracted"
cp "$PUBLISHER" "$FAKE_ROOT/scripts/dev/publish-image-release.sh"
cp "$ROOT_DIR/learner-vm/scripts/lib.sh" "$FAKE_ROOT/learner-vm/scripts/lib.sh"
cp "$TEMP_ROOT/images.txt" "$FAKE_ROOT/content/extracted/external-images.txt"
jq -n '{fixture:{labs:[{commands:[{type:"build",tag:"local-base:1",base_images:["python:3.13-bullseye","eclipse-temurin:21","local-base:1","localhost/other:1","scratch"]}]}]}}' > "$FAKE_ROOT/content/extracted/commands.json"
bash "$FAKE_ROOT/scripts/dev/publish-image-release.sh" --tag fixture --repo fixture/repository --image-only --out "$TEMP_ROOT/base-dry" --dry-run > "$TEMP_ROOT/base-dry.log"
[[ "$(grep -c '^WOULD: docker save ' "$TEMP_ROOT/base-dry.log")" -eq 4 ]]
grep -Fq 'WOULD: docker pull python:3.13-bullseye' "$TEMP_ROOT/base-dry.log"
grep -Fq 'WOULD: docker pull eclipse-temurin:21' "$TEMP_ROOT/base-dry.log"
if grep -E '^WOULD: docker pull (local-base|localhost/|scratch)' "$TEMP_ROOT/base-dry.log"; then exit 1; fi
[[ ! -e "$MOCK_EVENTS" && ! -e "$TEMP_ROOT/base-dry" ]]
bash "$FAKE_ROOT/scripts/dev/publish-image-release.sh" --tag fixture --repo fixture/repository --images-file "$TEMP_ROOT/images.txt" --out "$TEMP_ROOT/custom-dry" --dry-run > "$TEMP_ROOT/custom-dry.log"
[[ "$(grep -c '^WOULD: docker save ' "$TEMP_ROOT/custom-dry.log")" -eq 2 ]]
printf 'publisher base coverage PASS: missing external inventory bases included; local builds/scratch excluded; explicit custom lists preserved; no client calls\n'

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

export MOCK_BUNDLE_REMOTE="$TEMP_ROOT/bundle-remote.json"
export MOCK_BUNDLE_FAIL_UPLOAD=false MOCK_BUNDLE_BAD_DIGEST=false
gh() {
    printf 'gh %s\n' "$*" >> "$MOCK_EVENTS"
    case "$1:$2" in
        release:view)
            [[ -f "$MOCK_BUNDLE_REMOTE" ]] || return 1
            jq -r '.isDraft' "$MOCK_BUNDLE_REMOTE" ;;
        release:create)
            [[ "$*" == *'--draft --latest=false'* ]]
            jq -n '{isDraft:true,assets:[]}' > "$MOCK_BUNDLE_REMOTE" ;;
        release:upload)
            [[ "$MOCK_BUNDLE_FAIL_UPLOAD" == false ]] || return 1
            local asset digest size
            asset="${4##*/}"
            digest="sha256:$(sha256sum "$4" | awk '{print $1}')"
            size="$(stat -c '%s' "$4")"
            if [[ "$MOCK_BUNDLE_BAD_DIGEST" == true ]]; then digest="sha256:$(printf '%064d' 0)"; fi
            jq --arg name "$asset" --arg digest "$digest" --argjson size "$size" '.assets += [{name:$name,digest:$digest,size:$size}]' "$MOCK_BUNDLE_REMOTE" > "$MOCK_BUNDLE_REMOTE.tmp"
            mv "$MOCK_BUNDLE_REMOTE.tmp" "$MOCK_BUNDLE_REMOTE" ;;
        release:edit)
            [[ "$*" == *'--draft=false --latest=false'* ]]
            jq '.isDraft=false' "$MOCK_BUNDLE_REMOTE" > "$MOCK_BUNDLE_REMOTE.tmp"
            mv "$MOCK_BUNDLE_REMOTE.tmp" "$MOCK_BUNDLE_REMOTE" ;;
        api:*) cat "$MOCK_BUNDLE_REMOTE" ;;
        *) return 1 ;;
    esac
}
export -f gh

payload="$TEMP_ROOT/payload"
for directory in cache/pypi/wheels cache/maven/repository cache/npm cache/go/pkg/mod images downloads; do
    mkdir -p "$payload/$directory"
    printf 'fixture\n' > "$payload/$directory/fixture"
done
printf 'mock image archive\n' > "$payload/images/lab-images.tar"
jq -n '{schema:1,architecture:"amd64",source_commit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",images:[{reference:"fixture:1",id:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}],coverage:{required:["fixture:1"],verified:["fixture:1"]},offline_verified:true}' > "$payload/manifest.json"
jq -n '{perses:{version:"fixture"}}' > "$payload/lab-files-inventory.json"
printf 'fixture generic inventory\n' > "$payload/generic-checksums.txt"
bundle="$TEMP_ROOT/fixture.tar.gz"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT_DIR/learner-vm/dependency_bundle.py" pack --source "$payload" --output "$bundle" > "$TEMP_ROOT/pack.log"
: > "$MOCK_EVENTS"
bash "$PUBLISHER" --tag fixture --repo fixture/repository --bundle "$bundle" --part-bytes 512 --out "$TEMP_ROOT/bundle-dry" --dry-run > "$TEMP_ROOT/bundle-dry.log"
[[ ! -s "$MOCK_EVENTS" && ! -e "$TEMP_ROOT/bundle-dry" ]]
grep -Fq 'no client calls' "$TEMP_ROOT/bundle-dry.log"
printf 'bundle dry-run PASS: no client calls or generated assets\n'

bash "$PUBLISHER" --tag fixture --repo fixture/repository --bundle "$bundle" --part-bytes 512 --out "$TEMP_ROOT/bundle-assets" > "$TEMP_ROOT/bundle-published.log"
jq -e '.parts | length > 1' "$TEMP_ROOT/bundle-assets/bundle-publication.json" >/dev/null
(cd "$TEMP_ROOT/bundle-assets" && sha256sum --check --status SHA256SUMS && cat fixture.tar.gz.part[0-9][0-9][0-9] > fixture.tar.gz && sha256sum --check --status fixture.tar.gz.sha256)
cmp "$bundle" "$TEMP_ROOT/bundle-assets/fixture.tar.gz"
jq -e '.isDraft == false' "$MOCK_BUNDLE_REMOTE" >/dev/null
uploads_before="$(grep -c 'gh release upload' "$MOCK_EVENTS")"
bash "$PUBLISHER" --tag fixture --repo fixture/repository --bundle "$bundle" --part-bytes 512 --out "$TEMP_ROOT/bundle-assets" > "$TEMP_ROOT/bundle-repeat.log"
[[ "$(grep -c 'gh release upload' "$MOCK_EVENTS")" == "$uploads_before" ]]
printf 'bundle publication PASS: split/reassemble checksums, remote verification, draft promotion, safe rerun\n'

cp "$MOCK_BUNDLE_REMOTE" "$TEMP_ROOT/complete-remote.json"
jq '.assets |= map(select(.name != "REASSEMBLE.md"))' "$MOCK_BUNDLE_REMOTE" > "$MOCK_BUNDLE_REMOTE.tmp"
mv "$MOCK_BUNDLE_REMOTE.tmp" "$MOCK_BUNDLE_REMOTE"
: > "$MOCK_EVENTS"
if bash "$PUBLISHER" --tag fixture --repo fixture/repository --bundle "$bundle" --part-bytes 512 --out "$TEMP_ROOT/bundle-assets" > "$TEMP_ROOT/bundle-public-missing.log" 2>&1; then exit 1; fi
grep -Fq 'refusing to modify it' "$TEMP_ROOT/bundle-public-missing.log"
if grep -Eq 'gh release (upload|edit)' "$MOCK_EVENTS"; then exit 1; fi
printf 'bundle public release PASS: incomplete public release is never modified\n'

jq '.isDraft=true | .assets[0].digest="sha256:conflicting"' "$TEMP_ROOT/complete-remote.json" > "$MOCK_BUNDLE_REMOTE"
: > "$MOCK_EVENTS"
if bash "$PUBLISHER" --tag fixture --repo fixture/repository --bundle "$bundle" --part-bytes 512 --out "$TEMP_ROOT/bundle-assets" > "$TEMP_ROOT/bundle-existing-mismatch.log" 2>&1; then exit 1; fi
grep -Fq 'existing release asset digest mismatch' "$TEMP_ROOT/bundle-existing-mismatch.log"
if grep -Eq 'gh release (upload|edit)' "$MOCK_EVENTS"; then exit 1; fi
printf 'bundle existing mismatch PASS: conflicting remote assets are never overwritten\n'

MOCK_BUNDLE_BAD_DIGEST=true
export MOCK_BUNDLE_BAD_DIGEST
rm -f "$MOCK_BUNDLE_REMOTE"
: > "$MOCK_EVENTS"
if bash "$PUBLISHER" --tag fixture --repo fixture/repository --bundle "$bundle" --part-bytes 512 --out "$TEMP_ROOT/bundle-bad" > "$TEMP_ROOT/bundle-bad.log" 2>&1; then exit 1; fi
jq -e '.isDraft == true' "$MOCK_BUNDLE_REMOTE" >/dev/null
if grep -Fq 'gh release edit' "$MOCK_EVENTS"; then exit 1; fi
grep -Fq 'remote asset verification failed' "$TEMP_ROOT/bundle-bad.log"
printf 'bundle digest mismatch PASS: failed verification never publishes draft\n'

MOCK_BUNDLE_BAD_DIGEST=false MOCK_BUNDLE_FAIL_UPLOAD=true
export MOCK_BUNDLE_BAD_DIGEST MOCK_BUNDLE_FAIL_UPLOAD
rm -f "$MOCK_BUNDLE_REMOTE"
: > "$MOCK_EVENTS"
if bash "$PUBLISHER" --tag fixture --repo fixture/repository --bundle "$bundle" --part-bytes 512 --retries 2 --out "$TEMP_ROOT/bundle-failed" > "$TEMP_ROOT/bundle-failed.log" 2>&1; then exit 1; fi
jq -e '.isDraft == true' "$MOCK_BUNDLE_REMOTE" >/dev/null
[[ "$(grep -c 'gh release upload' "$MOCK_EVENTS")" == 2 ]]
if grep -Fq 'gh release edit' "$MOCK_EVENTS"; then exit 1; fi
printf 'bundle upload failure PASS: bounded retries and draft preserved\n'

: > "$MOCK_EVENTS"
cp "$bundle" "$TEMP_ROOT/corrupt.tar.gz"
cp "$bundle.sha256" "$TEMP_ROOT/corrupt.tar.gz.sha256"
printf 'tampered\n' >> "$TEMP_ROOT/corrupt.tar.gz"
if bash "$PUBLISHER" --tag fixture --repo fixture/repository --bundle "$TEMP_ROOT/corrupt.tar.gz" --out "$TEMP_ROOT/bundle-corrupt" > "$TEMP_ROOT/bundle-corrupt.log" 2>&1; then exit 1; fi
[[ ! -s "$MOCK_EVENTS" && ! -e "$TEMP_ROOT/bundle-corrupt" ]]
if bash "$PUBLISHER" --tag fixture --repo fixture/repository --bundle "$bundle" --part-bytes 2147483648 --dry-run > "$TEMP_ROOT/bundle-size.log" 2>&1; then exit 1; fi
[[ ! -s "$MOCK_EVENTS" ]]
printf 'bundle invalid input PASS: corrupt archives and oversized parts refused before client calls\n'

: > "$MOCK_EVENTS"
bash "$PUBLISHER" --tag automatic --repo fixture/repository --out "$TEMP_ROOT/automatic-dry" --dry-run > "$TEMP_ROOT/automatic-dry.log"
[[ ! -s "$MOCK_EVENTS" && ! -e "$TEMP_ROOT/automatic-dry" ]]
grep -Fq 'WOULD: pack offline-verified capture directory' "$TEMP_ROOT/automatic-dry.log"
printf 'automatic bundle dry-run PASS: default packs without an archive argument; no side effects\n'

MOCK_BUNDLE_FAIL_UPLOAD=false
export MOCK_BUNDLE_FAIL_UPLOAD
rm -f "$MOCK_BUNDLE_REMOTE"
bash "$PUBLISHER" --tag automatic --repo fixture/repository --bundle-source "$payload" --part-bytes 512 --out "$TEMP_ROOT/automatic-assets" > "$TEMP_ROOT/automatic-published.log"
automatic_bundle="$TEMP_ROOT/automatic-assets/learner-dependencies-automatic.tar.gz"
[[ -s "$automatic_bundle" && -s "$automatic_bundle.sha256" ]]
jq -e '.isDraft == false' "$MOCK_BUNDLE_REMOTE" >/dev/null
uploads_before="$(grep -c 'gh release upload' "$MOCK_EVENTS")"
archive_before="$(sha256sum "$automatic_bundle")"
bash "$PUBLISHER" --tag automatic --repo fixture/repository --bundle-source "$payload/" --part-bytes 512 --out "$TEMP_ROOT/automatic-assets" > "$TEMP_ROOT/automatic-repeat.log"
[[ "$(sha256sum "$automatic_bundle")" == "$archive_before" ]]
[[ "$(grep -c 'gh release upload' "$MOCK_EVENTS")" == "$uploads_before" ]]
grep -Fq 'Reusing automatic bundle' "$TEMP_ROOT/automatic-repeat.log"
printf 'automatic bundle PASS: archive/checksum created, verified and published through mocks; unchanged rerun reuses it\n'

: > "$MOCK_EVENTS"
cp "$payload/cache/npm/fixture" "$TEMP_ROOT/cache-fixture.backup"
printf 'changed cache\n' >> "$payload/cache/npm/fixture"
if bash "$PUBLISHER" --tag automatic --repo fixture/repository --bundle-source "$payload" --out "$TEMP_ROOT/automatic-assets" > "$TEMP_ROOT/automatic-changed.log" 2>&1; then exit 1; fi
grep -Fq 'capture contents changed' "$TEMP_ROOT/automatic-changed.log"
[[ ! -s "$MOCK_EVENTS" ]]
cp "$TEMP_ROOT/cache-fixture.backup" "$payload/cache/npm/fixture"
printf 'new cache file\n' > "$payload/cache/npm/extra"
if bash "$PUBLISHER" --tag automatic --repo fixture/repository --bundle-source "$payload" --out "$TEMP_ROOT/automatic-assets" > "$TEMP_ROOT/automatic-added.log" 2>&1; then exit 1; fi
grep -Fq 'capture file inventory changed' "$TEMP_ROOT/automatic-added.log"
[[ ! -s "$MOCK_EVENTS" ]]
rm "$payload/cache/npm/extra"
printf 'automatic changed source PASS: changed or added files never reuse a stale bundle or call GitHub\n'

cp -a "$payload" "$TEMP_ROOT/unverified-source"
jq '.offline_verified=false' "$TEMP_ROOT/unverified-source/manifest.json" > "$TEMP_ROOT/unverified-manifest.json"
mv "$TEMP_ROOT/unverified-manifest.json" "$TEMP_ROOT/unverified-source/manifest.json"
if bash "$PUBLISHER" --tag unverified --repo fixture/repository --bundle-source "$TEMP_ROOT/unverified-source" --out "$TEMP_ROOT/unverified-assets" > "$TEMP_ROOT/automatic-unverified.log" 2>&1; then exit 1; fi
grep -Fq 'has not passed offline validation' "$TEMP_ROOT/automatic-unverified.log"
[[ ! -s "$MOCK_EVENTS" && ! -e "$TEMP_ROOT/unverified-assets" ]]
if bash "$PUBLISHER" --tag missing --repo fixture/repository --bundle-source "$TEMP_ROOT/missing-source" --out "$TEMP_ROOT/missing-source-assets" > "$TEMP_ROOT/automatic-missing.log" 2>&1; then exit 1; fi
[[ ! -s "$MOCK_EVENTS" && ! -e "$TEMP_ROOT/missing-source-assets" ]]
if bash "$PUBLISHER" --tag conflict --repo fixture/repository --bundle-source "$payload" --bundle "$bundle" --dry-run > "$TEMP_ROOT/automatic-conflict.log" 2>&1; then exit 1; fi
[[ ! -s "$MOCK_EVENTS" ]]
printf 'automatic invalid source PASS: unverified/missing trees and conflicting modes fail without publication\n'

cp "$ROOT_DIR/learner-vm/dependency_bundle.py" "$FAKE_ROOT/learner-vm/dependency_bundle.py"
mkdir -p "$FAKE_ROOT/dist"
cp -a "$payload" "$FAKE_ROOT/dist/learner-dependencies-java17-r7"
rm -f "$MOCK_BUNDLE_REMOTE"
bash "$FAKE_ROOT/scripts/dev/publish-image-release.sh" --tag default --repo fixture/repository --out "$TEMP_ROOT/default-assets" --part-bytes 512 > "$TEMP_ROOT/default-published.log"
[[ -s "$TEMP_ROOT/default-assets/learner-dependencies-default.tar.gz" ]]
jq -e '.isDraft == false' "$MOCK_BUNDLE_REMOTE" >/dev/null
printf 'automatic default source PASS: no archive or capture-directory argument required\n'
