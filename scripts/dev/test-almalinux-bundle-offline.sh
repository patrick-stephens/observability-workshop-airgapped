#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ROOT="${1:?usage: test-almalinux-bundle-offline.sh BUNDLE_ROOT SHA256 DOG_API_FIXTURE IMAGE_VERIFY}"
BUNDLE_SHA256="${2:?bundle SHA-256 required}"
DOG_API_FIXTURE="${3:?path to learner-vm/fixtures/api.py required}"
IMAGE_VERIFY="${4:?path to verify-podman-bundle-images.py required}"
BUNDLE="$BUNDLE_ROOT/$BUNDLE_SHA256"
PROFILE="$BUNDLE_ROOT/profiles/$BUNDLE_SHA256"
WORKSHOP_USER="${WORKSHOP_USER:-engineer}"
WORKSHOP_HOME="$(getent passwd "$WORKSHOP_USER" | cut -d: -f6)"
[[ -n "$WORKSHOP_HOME" ]] || { printf 'ERROR: learner account has no home directory\n' >&2; exit 1; }
CACHE_ROOT="$WORKSHOP_HOME/.cache/o11y-lab/$BUNDLE_SHA256"
WORK_ROOT="$(mktemp -d /var/tmp/o11y-bundle-replay.XXXXXX)"
FIXTURE="o11y-offline-api-$$"
FIXTURE_STARTED=false

cleanup() {
	if [[ "$FIXTURE_STARTED" == true ]]; then
		podman rm -f "$FIXTURE" >/dev/null 2>&1 || true
	fi
	rm -rf -- "$WORK_ROOT"
}
trap cleanup EXIT

for tool in podman python3 sha256sum; do
	command -v "$tool" >/dev/null 2>&1 || { printf 'ERROR: required command is missing: %s\n' "$tool" >&2; exit 1; }
done
[[ "$BUNDLE_SHA256" =~ ^[0-9a-f]{64}$ ]] || { printf 'ERROR: invalid bundle checksum\n' >&2; exit 1; }
[[ -d "$BUNDLE" && -f "$BUNDLE/manifest.json" ]] || { printf 'ERROR: verified bundle root is missing: %s\n' "$BUNDLE" >&2; exit 1; }
[[ -r "$DOG_API_FIXTURE" ]] || { printf 'ERROR: dog API fixture is unreadable: %s\n' "$DOG_API_FIXTURE" >&2; exit 1; }
[[ -r "$IMAGE_VERIFY" ]] || { printf 'ERROR: Podman image verifier is unreadable: %s\n' "$IMAGE_VERIFY" >&2; exit 1; }
python3 "$IMAGE_VERIFY" "$BUNDLE/manifest.json"

(cd "$BUNDLE" && sha256sum --check generic-checksums.txt)

mkdir -p "$WORK_ROOT/python" "$WORK_ROOT/java" "$WORK_ROOT/perses"
cp -a "$BUNDLE/build-contexts/python/." "$WORK_ROOT/python/"
cp -a "$BUNDLE/build-contexts/java/." "$WORK_ROOT/java/"
cp -a "$BUNDLE/build-contexts/perses-derived-v2/." "$WORK_ROOT/perses/"

strip_local_digest_alias() {
	sed -i -E '/^FROM /s/@sha256:[0-9a-f]{64}$//' "$@"
}

for variant in base auto prog manual metrics; do
	context="$WORK_ROOT/python"
	strip_local_digest_alias "$context/Buildfile-$variant"
	podman build --pull=never --network=none --tag "localhost/alma-offline-python:$variant" --file "$context/Buildfile-$variant" "$context"
done
printf 'Python image cache replay PASS (5 variants)\n'

FIXTURE_STARTED=true
podman run --detach --name "$FIXTURE" --network host \
	--volume "$DOG_API_FIXTURE:/fixture.py:ro,Z" docker.io/library/python:3.13-bullseye python /fixture.py >/dev/null

maven="docker.io/library/maven:3.9.11-eclipse-temurin-17"
settings="$PROFILE/settings.xml"
bundle_maven_repo="$BUNDLE/cache/maven/repository"
for project in opentelemetry-java-tracing-demo-v1.1 opentelemetry-java-tracing-demo-v1.1-metrics prometheus-java-metrics-demo-v0.5; do
	context="$WORK_ROOT/java/$project"
	if [[ "$project" == opentelemetry-java-tracing-demo-v1.1-metrics ]]; then
		poms=("$context/pom.xml")
	else
		poms=("$context"/pom*.xml)
	fi
	for pom in "${poms[@]}"; do
		podman run --rm --pull=never --network host --volume "$context:/source:Z" \
			--volume "$CACHE_ROOT/maven:/cache:Z" \
			--volume "$bundle_maven_repo:$bundle_maven_repo:ro,Z" \
			--volume "$settings:/settings.xml:ro,Z" \
			--env O11Y_DOG_API_URL=http://127.0.0.1:18187/api --workdir /source "$maven" \
			mvn --offline --no-snapshot-updates --batch-mode --settings /settings.xml \
			-Dmaven.repo.local=/cache --file "${pom##*/}" clean install
		printf 'Maven offline replay PASS: %s/%s\n' "$project" "${pom##*/}"
	 done
done

context="$WORK_ROOT/perses/ui"
node="docker.io/library/node:24.21.0-bookworm"
podman run --rm --pull=never --network=none --volume "$context:/source:Z" \
	--volume "$CACHE_ROOT/npm:/cache:Z" \
	--env NPM_CONFIG_AUDIT=false --env NPM_CONFIG_FUND=false --env NPM_CONFIG_UPDATE_NOTIFIER=false \
	--env TURBO_TELEMETRY_DISABLED=1 --workdir /source "$node" sh -ec 'npm ci --offline --cache /cache && npm run build'
printf 'Perses npm/UI cache replay PASS\n'

go_context="$BUNDLE/build-contexts/go/prometheus-service-demo-installer-v1.0/installs/demo"
podman run --rm --pull=never --network=none --volume "$go_context:/source:Z" \
	--volume "$CACHE_ROOT/go/pkg/mod:/cache:Z" \
	--env GOMODCACHE=/cache --env GOPROXY=file:///cache/cache/download \
	--env GOSUMDB=sum.golang.org --env GOTOOLCHAIN=local --workdir /source docker.io/library/golang:1.17-alpine \
	sh -ec 'go mod download && go build -o /tmp/prometheus_demo_service .'
printf 'Go service cache/checksum replay PASS\n'

perses="$WORK_ROOT/perses"
podman run --rm --pull=never --network=none --volume "$perses:/source:Z" \
	--volume "$CACHE_ROOT/go/pkg/mod:/cache:Z" \
	--env GOMODCACHE=/cache --env GOPROXY=file:///cache/cache/download \
	--env GOSUMDB=sum.golang.org --env GOTOOLCHAIN=local --workdir /source docker.io/library/golang:1.26.5-bookworm \
	sh -ec 'go mod download && bash scripts/compress_assets.sh && go build ./cmd/perses'
printf 'Perses Go cache/checksum replay PASS\n'

java_name="o11y-alma-java-metrics-$$"
trap 'podman rm -f "$java_name" >/dev/null 2>&1 || true; cleanup' EXIT
podman run --detach --name "$java_name" --network host localhost/java-demo:metrics >/dev/null
metrics_ready=false
for attempt in {1..30}; do
	if curl --silent --fail --connect-timeout 1 --max-time 2 http://127.0.0.1:9464/metrics >/dev/null; then metrics_ready=true; break; fi
	sleep 1
done
[[ "$metrics_ready" == true ]] || { printf 'ERROR: java-demo:metrics did not become ready\n' >&2; exit 1; }
curl --fail --silent http://127.0.0.1:9999/ >/dev/null
curl --silent --max-time 2 http://127.0.0.1:9999/doggo >/dev/null || true
curl --fail --silent http://127.0.0.1:9464/metrics | grep -E 'app_hits_total|http_request_duration_seconds_count'
printf 'Java metrics runtime smoke PASS\n'
podman rm -f "$java_name" >/dev/null
trap cleanup EXIT

printf 'AlmaLinux offline learner bundle acceptance PASS\n'