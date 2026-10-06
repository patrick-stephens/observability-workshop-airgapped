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