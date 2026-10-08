#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git -C "$(dirname "${BASH_SOURCE[0]}")/../.." rev-parse --show-toplevel)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_ROOT"' EXIT

export SCRIPT_NAME=package-probe-test SCRIPT_VERSION=0 SELFTEST_MODE=true DRY_RUN=false
export ART_HOST=art.example ART_REPO_DOMAIN=art.example DOCKER_REGISTRY=docker-registry.art.example
export MOCK_STATUS=200 MOCK_EXIT=0
source "$ROOT_DIR/learner-vm/scripts/lib.sh"
eval "$(sed -n '/^check_package_repository() {$/,/^}$/p' "$ROOT_DIR/learner-vm/scripts/00-diagnose.sh")"

curl() {
	[[ "$*" != *--insecure* ]]
	[[ "$*" == *"$MOCK_EXPECTED_URL"* ]] || { printf 'unexpected package probe URL: %s\n' "$*" >&2; return 90; }
	if [[ -n "${ART_PACKAGE_CA_CERT:-}" ]]; then [[ "$*" == *"$ART_PACKAGE_CA_CERT"* ]]; fi
	printf '%s' "$MOCK_STATUS"
	return "$MOCK_EXIT"
}

probe() {
	local label="$1" base="$2" suffix="$3" setting="$4" expected="$5"
	MOCK_EXPECTED_URL="$expected"
	check_package_repository "$label" "$base" "$suffix" "$setting"
}

probe PyPI https://art.example/artifactory/api/pypi/simple flask/ ART_PYPI_INDEX_URL https://art.example/artifactory/api/pypi/simple/flask/
probe Maven https://art.example/artifactory/maven/maven2 org/apache/maven/plugins/maven-compiler-plugin/3.11.0/maven-compiler-plugin-3.11.0.pom ART_MAVEN_URL https://art.example/artifactory/maven/maven2/org/apache/maven/plugins/maven-compiler-plugin/3.11.0/maven-compiler-plugin-3.11.0.pom
probe npm https://art.example/artifactory/api/npm/node-js react ART_NPM_URL https://art.example/artifactory/api/npm/node-js/react
probe Go https://art.example/artifactory/api/go/gocenter github.com/prometheus/client_golang/@v/v1.12.1.mod ART_GO_PROXY_URL https://art.example/artifactory/api/go/gocenter/github.com/prometheus/client_golang/@v/v1.12.1.mod
[[ "$OK_COUNT" -eq 4 && "$FAIL_COUNT" -eq 0 ]]
printf 'package diagnostic probes PASS: four exact configured paths, TLS retained\n'

MOCK_STATUS=404
probe PyPI https://art.example/artifactory/api/pypi/simple flask/ ART_PYPI_INDEX_URL https://art.example/artifactory/api/pypi/simple/flask/
[[ "$FAIL_COUNT" -eq 1 ]]
grep -Fq 'HTTP 404 can mean absent package metadata' <<< "${FAIL_ENTRIES[0]}"
printf 'package diagnostic failure PASS: package 404 remains distinct from image availability\n'

ART_PACKAGE_CA_CERT="$TEMP_ROOT/artifactory-ca.pem"
printf 'fixture CA path\n' > "$ART_PACKAGE_CA_CERT"
export ART_PACKAGE_CA_CERT MOCK_STATUS=200
before_ok="$OK_COUNT"
probe npm https://art.example/artifactory/api/npm/node-js react ART_NPM_URL https://art.example/artifactory/api/npm/node-js/react
[[ "$OK_COUNT" -eq $((before_ok + 1)) ]]
printf 'package diagnostic CA PASS: configured custom CA is passed to TLS client\n'

if python3 "$ROOT_DIR/learner-vm/dependency_bundle.py" endpoint --base 'https://user:password@art.example/repository' --suffix metadata > "$TEMP_ROOT/unsafe.out" 2>&1; then
	printf 'package endpoint validation FAIL: credentials were accepted\n' >&2
	exit 1
fi
printf 'package endpoint safety PASS: credential-bearing URLs rejected\n'