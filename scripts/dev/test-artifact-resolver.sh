#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git -C "$(dirname "${BASH_SOURCE[0]}")/../.." rev-parse --show-toplevel)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_ROOT"' EXIT

FAKE_ROOT="$TEMP_ROOT/repository"
MOCK_BIN="$FAKE_ROOT/mockbin"
mkdir -p "$FAKE_ROOT/learner-vm/scripts" "$FAKE_ROOT/scripts" "$MOCK_BIN"
cp "$ROOT_DIR/learner-vm/scripts/lib.sh" "$FAKE_ROOT/learner-vm/scripts/lib.sh"
: > "$FAKE_ROOT/learner-vm/scripts/consumer.sh"
printf 'resolver-binary-fixture\n' > "$TEMP_ROOT/binary.fixture"
printf 'resolver-archive-fixture\n' > "$TEMP_ROOT/archive.fixture"
BINARY_SHA="$(sha256sum "$TEMP_ROOT/binary.fixture" | awk '{print $1}')"
ARCHIVE_SHA="$(sha256sum "$TEMP_ROOT/archive.fixture" | awk '{print $1}')"
printf 'fixture-required sha256:%s - source=mock\nfixture-optional sha256:%s - source=mock\n' "$BINARY_SHA" "$ARCHIVE_SHA" > "$FAKE_ROOT/versions.lock"
printf '# test catalog\nid\tkind\trequired\tstaging_relative_path\turl_variable\tsha256_lock_key\tconsumer_script\tinstall_target\nfixture-required\tbinary\tyes\tk3s/file\tREQUIRED_URL\tfixture-required\tscripts/consumer.sh\t/usr/local/bin/test-file\nfixture-optional\tarchive\tno\tk3s/optional.tar\tOPTIONAL_URL\tfixture-optional\tscripts/consumer.sh\t/var/lib/test/images/\n' > "$FAKE_ROOT/learner-vm/artifacts.tsv"
cat > "$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'request\n' >> "$MOCK_CURL_LOG"
output=''
while (($#)); do
	case "$1" in
		--output) output="$2"; shift 2 ;;
		*) shift ;;
	esac
done
[[ -n "$output" ]]
cp -- "$MOCK_CURL_SOURCE" "$output"
printf '200'
MOCK
chmod +x "$MOCK_BIN/curl"

export SCRIPT_NAME=artifact-resolver-test SCRIPT_VERSION=0 SELFTEST_MODE=true DRY_RUN=false
export ART_HOST=art.example DOCKER_REGISTRY=art.example/repository
export MANUAL_FETCH_DIR="$TEMP_ROOT/manual-stage"
export REQUIRED_URL='https://art.example/generic/required' OPTIONAL_URL='https://art.example/generic/optional'
export MOCK_CURL_LOG="$TEMP_ROOT/curl.log" MOCK_CURL_SOURCE="$TEMP_ROOT/binary.fixture"
export PATH="$MOCK_BIN:$PATH"
source "$FAKE_ROOT/learner-vm/scripts/lib.sh"

mkdir -p "$MANUAL_FETCH_DIR/k3s"
cp "$TEMP_ROOT/binary.fixture" "$MANUAL_FETCH_DIR/k3s/file"
resolve_artifact fixture-required
[[ "$ARTIFACT_RESOLVED_SOURCE" == manual && ! -e "$MOCK_CURL_LOG" ]]
printf 'case a PASS: valid local file wins; no mock request\n'

rm -f -- "$MANUAL_FETCH_DIR/k3s/file"
resolve_artifact fixture-required
[[ "$ARTIFACT_RESOLVED_SOURCE" == Artifactory ]]
[[ "$(sha256sum "$MANUAL_FETCH_DIR/k3s/file" | awk '{print $1}')" == "$BINARY_SHA" ]]
[[ "$(wc -l < "$MOCK_CURL_LOG")" -eq 1 ]]
printf 'case b PASS: mock download verified and staged\n'

printf 'corrupt-local-fixture\n' > "$MANUAL_FETCH_DIR/k3s/file"
before_requests="$(wc -l < "$MOCK_CURL_LOG")"
if resolve_artifact fixture-required; then
	printf 'case c FAIL: bad local checksum unexpectedly resolved\n' >&2
	exit 1
else
	resolver_status=$?
	[[ "$resolver_status" -eq 1 ]]
fi
[[ "$(wc -l < "$MOCK_CURL_LOG")" -eq "$before_requests" ]]
printf 'case c PASS: bad local checksum is a hard failure; no mock request\n'

rm -f -- "$MANUAL_FETCH_DIR/k3s/optional.tar"
unset OPTIONAL_URL
if resolve_artifact fixture-optional; then
	printf 'case d FAIL: absent optional artifact unexpectedly resolved\n' >&2
	exit 1
else
	resolver_status=$?
	[[ "$resolver_status" -eq 2 && "$ARTIFACT_RESOLUTION_STATUS" == skipped ]]
fi
printf 'case d PASS: absent optional artifact returns SKIPPED\n'

DRY_RUN=true
MANUAL_FETCH_DIR="$TEMP_ROOT/dry-run-stage"
export DRY_RUN MANUAL_FETCH_DIR
if resolve_artifact fixture-required; then
	printf 'case e FAIL: dry-run unexpectedly resolved a missing artifact\n' >&2
	exit 1
else
	resolver_status=$?
	[[ "$resolver_status" -eq 3 && "$ARTIFACT_RESOLUTION_STATUS" == would-fetch ]]
fi
[[ ! -e "$MANUAL_FETCH_DIR" ]]
[[ "$(wc -l < "$MOCK_CURL_LOG")" -eq 1 ]]
printf 'case e PASS: dry-run created no file or directory and made no mock request\n'

DRY_RUN=false
MANUAL_FETCH_DIR="$TEMP_ROOT/image-stage"
export DRY_RUN MANUAL_FETCH_DIR
printf 'fixture-image\timage-archive\tno\timages/fixture.tar\t-\tfixture-image\tscripts/consumer.sh\tpodman\n' >> "$FAKE_ROOT/learner-vm/artifacts.tsv"
mkdir -p "$MANUAL_FETCH_DIR/images"
python3 - "$MANUAL_FETCH_DIR/images/fixture.tar" <<'PY'
import hashlib
import io
import json
import sys
import tarfile

config = b'{"architecture":"amd64","os":"linux","rootfs":{"type":"layers","diff_ids":[]}}'
config_digest = hashlib.sha256(config).hexdigest()
manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json", "config": {"digest": "sha256:" + config_digest, "size": len(config), "mediaType": "application/vnd.oci.image.config.v1+json"}, "layers": []}).encode()
manifest_digest = hashlib.sha256(manifest).hexdigest()
index = json.dumps({"schemaVersion": 2, "manifests": [{"digest": "sha256:" + manifest_digest, "size": len(manifest), "mediaType": "application/vnd.oci.image.manifest.v1+json", "annotations": {"org.opencontainers.image.ref.name": "docker.io/library/busybox:1.36"}}]}).encode()
with tarfile.open(sys.argv[1], "w") as archive:
	for name, data in [("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", index), ("blobs/sha256/" + config_digest, config), ("blobs/sha256/" + manifest_digest, manifest)]:
		member = tarfile.TarInfo(name)
		member.size = len(data)
		archive.addfile(member, io.BytesIO(data))
PY
IMAGE_SHA="$(sha256sum "$MANUAL_FETCH_DIR/images/fixture.tar" | awk '{print $1}')"
printf 'fixture-image sha256:%s - operator-recorded fixture\n' "$IMAGE_SHA" >> "$FAKE_ROOT/versions.lock"
resolve_artifact fixture-image
[[ "$ARTIFACT_RESOLUTION_STATUS" == PRESENT ]]
[[ "$(wc -l < "$MOCK_CURL_LOG")" -eq 1 ]]
image_manifest="$(image_archive_manifest "$ARTIFACT_RESOLVED_PATH")"
[[ "$image_manifest" == docker.io/library/busybox:1.36$'\t'* ]]
printf 'image case a PASS: PRESENT, recorded checksum matches, OCI blobs verified, no network request\n'

cp "$MANUAL_FETCH_DIR/images/fixture.tar" "$TEMP_ROOT/valid-image.tar"
printf 'bad image\n' > "$MANUAL_FETCH_DIR/images/fixture.tar"
if resolve_artifact fixture-image; then exit 1; else [[ "$?" -eq 1 ]]; fi
[[ "$(wc -l < "$MOCK_CURL_LOG")" -eq 1 ]]
printf 'image case b PASS: FATAL checksum mismatch, no network request\n'
rm -f -- "$MANUAL_FETCH_DIR/images/fixture.tar"
if resolve_artifact fixture-image; then exit 1; else [[ "$?" -eq 2 && "$ARTIFACT_RESOLUTION_STATUS" == ABSENT ]]; fi
[[ "$(wc -l < "$MOCK_CURL_LOG")" -eq 1 ]]
printf 'image case c PASS: ABSENT informational, no network request\n'

cp "$TEMP_ROOT/valid-image.tar" "$MANUAL_FETCH_DIR/images/fixture.tar"
cp "$ROOT_DIR/learner-vm/scripts/60-load-images.sh" "$FAKE_ROOT/learner-vm/scripts/60-load-images.sh"
ln -s "$ROOT_DIR/content" "$FAKE_ROOT/content"
export WORKSHOP_USER=engineer REG_HOST=art.example
bash "$FAKE_ROOT/learner-vm/scripts/60-load-images.sh" --dry-run > "$TEMP_ROOT/present-preview.log"
grep -F '[dry-run] image-archive stage:' "$TEMP_ROOT/present-preview.log"
rm -f -- "$MANUAL_FETCH_DIR/images/fixture.tar"
bash "$FAKE_ROOT/learner-vm/scripts/60-load-images.sh" --dry-run > "$TEMP_ROOT/absent-preview.log"
if grep -F '[dry-run] image-archive stage:' "$TEMP_ROOT/absent-preview.log"; then exit 1; fi
[[ "$(wc -l < "$MOCK_CURL_LOG")" -eq 1 ]]
printf 'loader dry-run PASS: stage appears only for a present valid archive; no load/pull/network call\n'

validate_docker_registry docker-registry.art.example
[[ "$REG_HOST" == docker-registry.art.example && "$REGISTRY_FORM" == subdomain ]]
validate_docker_registry art.example/artifactory/docker-registry
[[ "$REG_HOST" == art.example && "$REGISTRY_FORM" == path ]]
validate_docker_registry https://art.example/artifactory/docker-registry
[[ "$REG_HOST" == art.example && "$DOCKER_REGISTRY" == art.example/artifactory/docker-registry ]]
printf 'REG_HOST PASS: subdomain, path, and HTTPS-prefixed path forms\n'

cp "$TEMP_ROOT/valid-image.tar" "$MANUAL_FETCH_DIR/images/fixture.tar"
DRY_RUN=false
expected_config="$(image_archive_manifest "$MANUAL_FETCH_DIR/images/fixture.tar" | cut -f2)"
mock_loads=0
podman() {
	case "$1" in
		load) ((mock_loads += 1)); return 0 ;;
		image) printf '%s\n' "$expected_config" ;;
		*) return 1 ;;
	esac
}
load_image_archives podman
[[ "$mock_loads" -eq 1 ]]
unset -f podman
printf 'loader digest PASS: mocked Podman load config ID matches OCI manifest\n'

python3 - "$TEMP_ROOT/valid-image.tar" "$TEMP_ROOT/corrupt-image.tar" <<'PY'
import io
import sys
import tarfile
with tarfile.open(sys.argv[1]) as source, tarfile.open(sys.argv[2], "w") as target:
	for member in source.getmembers():
		data = source.extractfile(member).read()
		if member.name.startswith("blobs/"):
			data = b"tampered blob"
		member.size = len(data)
		target.addfile(member, io.BytesIO(data))
PY
if image_archive_manifest "$TEMP_ROOT/corrupt-image.tar" >/dev/null 2>&1; then exit 1; fi
printf 'loader corruption PASS: malformed OCI blob digest rejected before load\n'

awk '$1 != "fixture-image"' "$FAKE_ROOT/versions.lock" > "$TEMP_ROOT/unpinned.lock"
mv "$TEMP_ROOT/unpinned.lock" "$FAKE_ROOT/versions.lock"
resolve_artifact fixture-image
[[ "$ARTIFACT_RESOLUTION_STATUS" == PRESENT && -z "$ARTIFACT_EXPECTED_SHA256" ]]
[[ "$(wc -l < "$MOCK_CURL_LOG")" -eq 1 ]]
printf 'image optional-pin PASS: missing checksum is explicitly skipped; PRESENT without network\n'
