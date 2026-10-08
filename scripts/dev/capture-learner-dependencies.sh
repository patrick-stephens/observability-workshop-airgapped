#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/dist/learner-dependencies-java17-r5"
PROFILE=artifactory
DRY_RUN=false
COMPONENT=all
source "$ROOT_DIR/learner-vm/lab-vm.conf"
# CHANGE: Capture checksum-pinned Perses workshop support files independently of image and package builds.
SCRIPT_NAME=capture-learner-dependencies SCRIPT_VERSION=4 SELFTEST_MODE=true
source "$ROOT_DIR/learner-vm/scripts/lib.sh"
export PIP_DISABLE_PIP_VERSION_CHECK=1
export TURBO_TELEMETRY_DISABLED=1
usage() {
    printf '%s\n' 'Usage: capture-learner-dependencies.sh [--out DIR] [--profile artifactory|public] [--component all|python|java|go|npm|prometheus|fluentbit|lab-files] [--dry-run]'
}
die() { printf '[capture-learner-dependencies] ERROR: %s\n' "$*" >&2; exit 1; }
pin_sha256() {
    local key="$1" value
    value="$(awk -v key="$key" '$1 == key {print $2; found++} END {if (found != 1) exit 1}' "$ROOT_DIR/versions.lock")" || die "missing or duplicate checksum pin: $key"
    [[ "$value" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid SHA-256 pin: $key"
    printf '%s' "${value#sha256:}"
}
while (($#)); do
    case "$1" in
        --out|--profile|--component)
            (($# >= 2)) || die "missing value for $1"
            case "$1" in --out) OUT_DIR="$2" ;; --profile) PROFILE="$2" ;; --component) COMPONENT="$2" ;; esac
            shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ "$PROFILE" == public || "$PROFILE" == artifactory ]] || die 'profile must be public or artifactory'
[[ "$COMPONENT" =~ ^(all|python|java|go|npm|prometheus|fluentbit|lab-files)$ ]] || die 'invalid component'
if [[ "$DRY_RUN" == true ]]; then
    printf '[capture-learner-dependencies] WOULD capture %s using %s repositories into %s\n' "$COMPONENT" "$PROFILE" "$OUT_DIR"
    printf '%s\n' 'WOULD pin resolved builder digests, capture isolated caches, build supported final recipes, and audit every recorded lab image.'
    printf '%s\n' 'No directories, downloads, container calls, version-pin edits or publication during dry-run.'
    exit 0
fi
for tool in docker curl jq python3 unzip; do command -v "$tool" >/dev/null 2>&1 || die "required capture tool is missing: $tool"; done
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
mkdir -p "$OUT_DIR/cache/pypi/wheels" "$OUT_DIR/cache/maven/repository" "$OUT_DIR/cache/go/pkg/mod" "$OUT_DIR/cache/npm" "$OUT_DIR/downloads" "$OUT_DIR/build-contexts" "$OUT_DIR/images"
IMAGE_REFERENCES_FILE="$OUT_DIR/captured-image-references.txt"
: >> "$OUT_DIR/capture-image-pins.tsv.tmp"
touch "$IMAGE_REFERENCES_FILE"
if [[ "$PROFILE" == public ]]; then
    PIP_URL=https://pypi.org/simple
    MAVEN_URL=https://repo.maven.apache.org/maven2
    NPM_URL=https://registry.npmjs.org
    GO_URL=https://proxy.golang.org
else
    PIP_URL="$ART_PYPI_INDEX_URL" MAVEN_URL="$ART_MAVEN_URL" NPM_URL="$ART_NPM_URL" GO_URL="$ART_GO_PROXY_URL"
fi
python3 "$ROOT_DIR/learner-vm/dependency_bundle.py" profiles --mode artifactory --root "$OUT_DIR" --output "$OUT_DIR/configuration/capture" --pypi-url "$PIP_URL" --maven-url "$MAVEN_URL" --npm-url "$NPM_URL" --go-url "$GO_URL" --ca "$ART_PACKAGE_CA_CERT"
declare -a CAPTURED_IMAGES=()
FIXTURE_CONTAINER="learner-capture-fixture-$$"
FIXTURE_NETWORK="learner-capture-internal-$$"
FIXTURE_STARTED=false
cleanup() {
    if [[ "$FIXTURE_STARTED" == true ]]; then
        docker rm -f "$FIXTURE_CONTAINER" >/dev/null 2>&1 || true
        docker network rm "$FIXTURE_NETWORK" >/dev/null 2>&1 || true
        docker network rm "$FIXTURE_NETWORK-online" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
pin_image() {
    local key="$1" pinned_reference image_reference
    pinned_reference="$(awk -v key="$key" '$1 == key {print $2; found++} END {if (found != 1) exit 1}' "$ROOT_DIR/versions.lock")" || die "missing or duplicate immutable versions.lock pin: $key"
    [[ "$pinned_reference" == *@sha256:* ]] || die "builder pin must include a digest: $key"
    docker pull --platform linux/amd64 "$pinned_reference" >&2 || die "could not capture pinned image $key"
    image_reference="${pinned_reference%@sha256:*}"
    if ! docker image inspect "$image_reference" >/dev/null 2>&1; then docker tag "$pinned_reference" "$image_reference"; fi
    record_image "$image_reference"
    printf '%s\t%s\n' "$key" "$pinned_reference" >> "$OUT_DIR/capture-image-pins.tsv.tmp"
    printf '%s' "$pinned_reference"
}
record_image() {
    local reference="$1"
    grep -Fxq "$reference" "$IMAGE_REFERENCES_FILE" 2>/dev/null || printf '%s\n' "$reference" >> "$IMAGE_REFERENCES_FILE"
}
capture_context() {
    local archive="$1" destination="$2"
    mkdir -p "$destination"
    unzip -oq "$archive" -d "$destination"
}
fetch_generic() {
    local url="$1" destination="$2" expected_sha256="${3:-}" actual_sha256 relative
    [[ "$PROFILE" == public ]] || die 'generic download requires an administrator-supplied Artifactory URL; no public fallback'
    curl --fail --location --proto '=https' --tlsv1.2 --output "$destination.partial" "$url"
    if [[ -n "$expected_sha256" ]]; then
        actual_sha256="$(sha256sum "$destination.partial" | awk '{print $1}')"
        [[ "$actual_sha256" == "$expected_sha256" ]] || die "generic download checksum mismatch for $url"
    fi
    mv "$destination.partial" "$destination"
    relative="${destination#"$OUT_DIR/"}"
    [[ "$relative" != "$destination" && "$relative" != /* ]] || die "generic download is outside the bundle root: $destination"
}
if [[ "$COMPONENT" == all || "$COMPONENT" == lab-files ]]; then
    PERSES_LAB_ARCHIVE="$OUT_DIR/downloads/perses-install-demo-v1.10.zip"
    fetch_generic https://gitlab.com/o11y-workshops/perses-install-demo/-/archive/v1.10/perses-install-demo-v1.10.zip "$PERSES_LAB_ARCHIVE" "$(pin_sha256 capture.perses-install-demo.sha256)"
    capture_context "$PERSES_LAB_ARCHIVE" "$OUT_DIR/build-contexts/perses-lab"
    [[ -s "$OUT_DIR/build-contexts/perses-lab/perses-install-demo-v1.10/support/workshop-prometheus.yml" ]] || die 'Perses lab archive is missing its Prometheus mount configuration'
    jq -n --arg sha256 "$(pin_sha256 capture.perses-install-demo.sha256)" '{perses: {version: "v1.10", source: "https://gitlab.com/o11y-workshops/perses-install-demo/-/archive/v1.10/perses-install-demo-v1.10.zip", sha256: $sha256, archive: "downloads/perses-install-demo-v1.10.zip", support: "build-contexts/perses-lab/perses-install-demo-v1.10/support"}}' > "$OUT_DIR/lab-files-inventory.json"
fi

build_image() {
    local tag="$1" context="$2" recipe="$3"
    docker build --platform linux/amd64 --pull=false --network=none --tag "$tag" --file "$recipe" "$context"
    CAPTURED_IMAGES+=("$tag")
    record_image "$tag"
}
build_fluentbit_image() {
    local tag="$1" source_config="$2" config_name="$3" context recipe
    context="$OUT_DIR/build-contexts/fluentbit/${tag//[^A-Za-z0-9._-]/_}"
    mkdir -p "$context"
    cp "$source_config" "$context/$config_name"
    docker run --rm --network none --volume "$context/$config_name:/tmp/$config_name:ro" "$FLUENTBIT_IMAGE" --dry-run -c "/tmp/$config_name"
    recipe="$context/Offline-Buildfile"
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" fluentbit --source "$context/$config_name" --output "$recipe" --base "$FLUENTBIT_IMAGE" --programmatic "$config_name"
    build_image "$tag" "$context" "$recipe"
}
alias_image_tags() {
    local source="$1" tag
    shift
    for tag in "$@"; do
        docker tag "$source" "$tag"
        CAPTURED_IMAGES+=("$tag")
        record_image "$tag"
    done
}
make_package_caches_readable() {
    local image cache
    image="$(pin_image learner-bundle.image.python)"
    for cache in pypi maven go npm; do
        docker run --rm --user 0 --volume "$OUT_DIR/cache/$cache:/cache" "$image" sh -ec 'chmod -R a+rX /cache'
    done
}

if [[ "$COMPONENT" == all || "$COMPONENT" == python ]]; then
    PYTHON_IMAGE="$(pin_image learner-bundle.image.python)"
    PYTHON_SOURCE="$ROOT_DIR/content/repos/opentelemetry/_vendored/intro-to-instrumentation-v1.4"
    docker run --rm --platform linux/amd64 --volume "$PYTHON_SOURCE:/source:ro" --volume "$OUT_DIR/cache/pypi:/cache" --env PIP_DISABLE_PIP_VERSION_CHECK=1 --env PIP_INDEX_URL="$PIP_URL" "$PYTHON_IMAGE" python -m pip wheel --wheel-dir /cache/wheels --requirement /source/requirements.txt prometheus-flask-exporter opentelemetry-api==1.44.0 opentelemetry-sdk==1.44.0 opentelemetry-exporter-otlp==1.44.0 'opentelemetry-distro[otlp]==0.65b0' opentelemetry-instrumentation-flask==0.65b0 opentelemetry-instrumentation-jinja2==0.65b0 opentelemetry-instrumentation-requests==0.65b0
    docker run --rm --platform linux/amd64 --volume "$PYTHON_SOURCE:/source:ro" --volume "$OUT_DIR/cache/pypi:/cache" --env PIP_DISABLE_PIP_VERSION_CHECK=1 --env PIP_INDEX_URL="$PIP_URL" "$PYTHON_IMAGE" sh -ec 'python -m pip install --no-index --find-links /cache/wheels -r /source/requirements.txt "opentelemetry-distro[otlp]==0.65b0"; opentelemetry-bootstrap -a requirements > /cache/bootstrap-requirements.txt; python -m pip wheel -r /cache/bootstrap-requirements.txt --wheel-dir /cache/wheels'
    PYTHON_CONTEXT="$OUT_DIR/build-contexts/python"
    mkdir -p "$PYTHON_CONTEXT"
    cp -a "$PYTHON_SOURCE/." "$PYTHON_CONTEXT/"
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" patch-runtime --source "$PYTHON_CONTEXT"
    cp -a "$OUT_DIR/cache/pypi/wheels" "$PYTHON_CONTEXT/wheelhouse"
    for variant in base auto prog manual metrics; do
        case "$variant" in base) recipe=Buildfile ;; auto) recipe=automatic/Buildfile-auto ;; prog) recipe=programmatic/Buildfile-prog ;; manual) recipe=manual/Buildfile-manual ;; metrics) recipe=metrics/Buildfile-metrics ;; esac
        python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" python --source "$PYTHON_CONTEXT/$recipe" --output "$PYTHON_CONTEXT/Buildfile-$variant" --base "$PYTHON_IMAGE" --programmatic "$variant"
        build_image "hello-otel:$variant" "$PYTHON_CONTEXT" "$PYTHON_CONTEXT/Buildfile-$variant"
    done
    docker tag hello-otel:auto hello-otel:auto-manual
    CAPTURED_IMAGES+=(hello-otel:auto-manual)
    record_image hello-otel:auto-manual
fi

if [[ "$COMPONENT" == all || "$COMPONENT" == java ]]; then
    MAVEN_IMAGE="$(pin_image learner-bundle.image.maven-builder)"
    JAVA_IMAGE="$(pin_image learner-bundle.image.java17)"
    capture_context "$ROOT_DIR/content/vendor/downloads/otel-developers/opentelemetry-java-tracing-demo-v1.1.zip" "$OUT_DIR/build-contexts/java"
    capture_context "$ROOT_DIR/content/vendor/downloads/prometheus/prometheus-java-metrics-demo-v0.5.zip" "$OUT_DIR/build-contexts/java"
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" patch-runtime --source "$OUT_DIR/build-contexts/java"
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" java17 --source "$OUT_DIR/build-contexts/java"
    FIXTURE_IMAGE="$(pin_image learner-bundle.image.python)"
    docker network create --internal "$FIXTURE_NETWORK"
    FIXTURE_STARTED=true
    docker network create "$FIXTURE_NETWORK-online"
    docker run --detach --name "$FIXTURE_CONTAINER" --network "$FIXTURE_NETWORK" --network-alias learner-fixture --volume "$ROOT_DIR/learner-vm/fixtures/api.py:/fixture.py:ro" "$FIXTURE_IMAGE" python /fixture.py
    docker network connect --alias learner-fixture "$FIXTURE_NETWORK-online" "$FIXTURE_CONTAINER"
    for project in opentelemetry-java-tracing-demo-v1.1 prometheus-java-metrics-demo-v0.5; do
        context="$OUT_DIR/build-contexts/java/$project"
        mkdir -p "$context/captured-jars"
        for pom in "$context"/pom*.xml; do
            docker run --rm --network "$FIXTURE_NETWORK-online" --platform linux/amd64 --volume "$context:/source" --volume "$OUT_DIR/cache/maven/repository:/cache" --volume "$OUT_DIR/configuration/capture/settings.xml:/settings.xml:ro" --env O11Y_DOG_API_URL=http://learner-fixture:18187/api --workdir /source "$MAVEN_IMAGE" mvn --no-snapshot-updates --batch-mode --settings /settings.xml -Dmaven.repo.local=/cache --file "${pom##*/}" clean install
            docker run --rm --network "$FIXTURE_NETWORK" --platform linux/amd64 --volume "$context:/source" --volume "$OUT_DIR/cache/maven/repository:/cache" --volume "$OUT_DIR/configuration/capture/settings.xml:/settings.xml:ro" --env O11Y_DOG_API_URL=http://learner-fixture:18187/api --workdir /source "$MAVEN_IMAGE" mvn --offline --no-snapshot-updates --batch-mode --settings /settings.xml -Dmaven.repo.local=/cache --file "${pom##*/}" clean install
            python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" verify-java17 --source "$context/target"
            cp "$context"/target/*.jar "$context/captured-jars/"
        done
        docker run --rm --platform linux/amd64 --volume "$context:/source" "$MAVEN_IMAGE" sh -ec 'cp /source/captured-jars/*.jar /source/target/'
    done
    agent="$OUT_DIR/downloads/opentelemetry-javaagent-2.30.0.jar"
    fetch_generic https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.30.0/opentelemetry-javaagent.jar "$agent"
    context="$OUT_DIR/build-contexts/java/opentelemetry-java-tracing-demo-v1.1"
    cp "$agent" "$context/opentelemetry-javaagent-2.30.0.jar"
    for variant in base auto java-tools manual; do
        case "$variant" in base) recipe=Buildfile ;; auto) recipe=Buildfile-AgentContainer ;; java-tools) recipe=Buildfile-AgentJavaTools ;; manual) recipe=Buildfile-manual ;; esac
        python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" java --source "$context/$recipe" --output "$context/Offline-$recipe" --base "$JAVA_IMAGE"
        build_image "java-demo:$variant" "$context" "$context/Offline-$recipe"
    done
    docker tag java-demo:base java-demo
    CAPTURED_IMAGES+=(java-demo)
    record_image java-demo
    metrics_context="$OUT_DIR/build-contexts/java/opentelemetry-java-tracing-demo-v1.1-metrics"
    docker run --rm --user 0 --volume "$OUT_DIR/build-contexts/java:/source" "$MAVEN_IMAGE" rm -rf /source/opentelemetry-java-tracing-demo-v1.1-metrics
    cp -a "$context/." "$metrics_context/"
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" java-metrics --source "$metrics_context/src/main/java/io/chronosphere/App.java"
    docker run --rm --network "$FIXTURE_NETWORK" --platform linux/amd64 --volume "$metrics_context:/source" --volume "$OUT_DIR/cache/maven/repository:/cache" --volume "$OUT_DIR/configuration/capture/settings.xml:/settings.xml:ro" --env O11Y_DOG_API_URL=http://learner-fixture:18187/api --workdir /source "$MAVEN_IMAGE" mvn --offline --no-snapshot-updates --batch-mode --settings /settings.xml -Dmaven.repo.local=/cache --file pom.xml clean install
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" verify-java17 --source "$metrics_context/target"
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" java --source "$metrics_context/Buildfile" --output "$metrics_context/Offline-Buildfile" --base "$JAVA_IMAGE"
    build_image java-demo:metrics "$metrics_context" "$metrics_context/Offline-Buildfile"
    JAVA_PROMETHEUS_IMAGE="$(pin_image learner-bundle.image.prometheus-base)"
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" config --source "$context/Buildfile-prom" --output "$context/Offline-Buildfile-prom" --base "$JAVA_PROMETHEUS_IMAGE"
    build_image java-demo-prometheus:v3.13.1 "$context" "$context/Offline-Buildfile-prom"
    context="$OUT_DIR/build-contexts/java/prometheus-java-metrics-demo-v0.5"
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" java --source "$context/Buildfile" --output "$context/Offline-Buildfile" --base "$JAVA_IMAGE"
    build_image basic-java-metrics "$context" "$context/Offline-Buildfile"
    docker tag basic-java-metrics basic-java-metrics:base
    CAPTURED_IMAGES+=(basic-java-metrics:base)
    record_image basic-java-metrics:base
fi

if [[ "$COMPONENT" == all || "$COMPONENT" == go ]]; then
    [[ "$PROFILE" == public || -n "$ART_GO_SUMDB" ]] || die 'Artifactory Go capture requires ART_GO_SUMDB; public checksum fallback is not allowed'
    GO_IMAGE="$(pin_image learner-bundle.image.go-service-builder)"
    ALPINE_IMAGE="$(pin_image learner-bundle.image.alpine)"
    capture_context "$ROOT_DIR/content/vendor/downloads/prometheus/prometheus-service-demo-installer-v1.0.zip" "$OUT_DIR/build-contexts/go"
    context="$OUT_DIR/build-contexts/go/prometheus-service-demo-installer-v1.0/installs/demo"
    docker run --rm --platform linux/amd64 --volume "$context:/source" --volume "$OUT_DIR/cache/go/pkg/mod:/cache" --env GOMODCACHE=/cache --env GOPROXY="$GO_URL" --env GOSUMDB="${ART_GO_SUMDB:-sum.golang.org}" --env GOTOOLCHAIN=local --workdir /source "$GO_IMAGE" sh -ec 'go mod tidy; go mod download; go build -o /source/prometheus_demo_service .'
    # Prime any missing checksum transparency proofs through the local module proxy before the network-disabled replay.
    docker run --rm --platform linux/amd64 --volume "$context:/source" --volume "$OUT_DIR/cache/go/pkg/mod:/cache" --env GOMODCACHE=/cache --env GOPROXY=file:///cache/cache/download --env GOSUMDB="${ART_GO_SUMDB:-sum.golang.org}" --env GOTOOLCHAIN=local --workdir /source "$GO_IMAGE" go mod download
    mkdir -p "$OUT_DIR/build-contexts/prometheus"
    docker run --rm --network none --platform linux/amd64 --volume "$context:/source" --volume "$OUT_DIR/cache/go/pkg/mod:/cache" --env GOMODCACHE=/cache --env GOPROXY=file:///cache/cache/download --env GOTOOLCHAIN=local --workdir /source "$GO_IMAGE" sh -ec 'go mod download; go build -o /source/prometheus_demo_service .'
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" go --source "$context/Buildfile" --output "$context/Offline-Buildfile" --base "$ALPINE_IMAGE"
    build_image prometheus_services_demo:v1 "$context" "$context/Offline-Buildfile"
fi

if [[ "$COMPONENT" == all || "$COMPONENT" == npm ]]; then
    NODE_IMAGE="$(pin_image learner-bundle.image.node)"
    source_archive="$OUT_DIR/downloads/perses-v0.54.0.tar.gz"
    fetch_generic https://github.com/perses/perses/archive/refs/tags/v0.54.0.tar.gz "$source_archive"
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" extract-source --source "$source_archive" --output "$OUT_DIR/build-contexts/perses-upstream"
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" copy-context --source "$OUT_DIR/build-contexts/perses-upstream/perses-0.54.0" --output "$OUT_DIR/build-contexts/perses-derived-v2"
    context="$OUT_DIR/build-contexts/perses-derived-v2"
    [[ -s "$context/ui/package.json" && -s "$context/go.mod" ]] || die 'Perses source layout does not match the documented build plan'
    docker run --rm --platform linux/amd64 --volume "$context:/source" --volume "$OUT_DIR/cache/npm:/cache" --env NPM_CONFIG_REGISTRY="$NPM_URL" --env NPM_CONFIG_PREFER_OFFLINE=true --env NPM_CONFIG_AUDIT=false --env NPM_CONFIG_FUND=false --env NPM_CONFIG_UPDATE_NOTIFIER=false --env TURBO_TELEMETRY_DISABLED=1 --workdir /source/ui "$NODE_IMAGE" npm ci --cache /cache
    docker run --rm --network none --platform linux/amd64 --volume "$context:/source" --volume "$OUT_DIR/cache/npm:/cache" --env NPM_CONFIG_AUDIT=false --env NPM_CONFIG_FUND=false --env NPM_CONFIG_UPDATE_NOTIFIER=false --env TURBO_TELEMETRY_DISABLED=1 --workdir /source/ui "$NODE_IMAGE" sh -ec 'rm -rf node_modules; npm ci --offline --cache /cache; npm run build'
    docker run --rm --user 0 --volume "$context/ui:/source" "$NODE_IMAGE" sh -ec 'find /source -type d -name node_modules -prune -exec rm -rf {} +'
    go_version="$(awk '$1 == "go" {print $2; exit}' "$context/go.mod")"
    [[ "$go_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die 'Perses Go toolchain declaration is invalid'
    [[ "$go_version" == 1.26.5 ]] || die "Perses go.mod toolchain $go_version differs from the reviewed builder pin"
    PERSES_GO_IMAGE="$(pin_image learner-bundle.image.go-builder)"
    [[ "$PROFILE" == public || -n "$ART_GO_SUMDB" ]] || die 'Artifactory Go capture requires ART_GO_SUMDB'
    docker run --rm --platform linux/amd64 --volume "$context:/source" --volume "$OUT_DIR/cache/go/pkg/mod:/cache" --env GOMODCACHE=/cache --env GOPROXY="$GO_URL" --env GOSUMDB="${ART_GO_SUMDB:-sum.golang.org}" --env GOTOOLCHAIN=local --workdir /source "$PERSES_GO_IMAGE" sh -ec 'go mod tidy; go mod download'
    # Prime any missing checksum transparency proofs through the local module proxy before the network-disabled replay.
    docker run --rm --platform linux/amd64 --volume "$context:/source" --volume "$OUT_DIR/cache/go/pkg/mod:/cache" --env GOMODCACHE=/cache --env GOPROXY=file:///cache/cache/download --env GOSUMDB="${ART_GO_SUMDB:-sum.golang.org}" --env GOTOOLCHAIN=local --workdir /source "$PERSES_GO_IMAGE" go mod download
    docker run --rm --network none --platform linux/amd64 --volume "$context:/source" --volume "$OUT_DIR/cache/go/pkg/mod:/cache" --env GOMODCACHE=/cache --env GOPROXY=file:///cache/cache/download --env GOTOOLCHAIN=local --workdir /source "$PERSES_GO_IMAGE" sh -ec 'bash scripts/compress_assets.sh; go build ./cmd/perses'
    docker run --rm --platform linux/amd64 --volume "$context:/source" --volume "$OUT_DIR/cache/go/pkg/mod:/cache" --env GOMODCACHE=/cache --env GOPROXY="$GO_URL" --env CAPTURE_UID="$(id -u)" --env CAPTURE_GID="$(id -g)" --workdir /source "$PERSES_GO_IMAGE" sh -ec 'go run ./scripts/plugin/install_plugin.go; chown -R "$CAPTURE_UID:$CAPTURE_GID" plugins-archive'
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" capture-plugins --source "$context" --output "$OUT_DIR/downloads/perses-plugins"
fi

if [[ "$COMPONENT" == all || "$COMPONENT" == prometheus ]]; then
    PROMETHEUS_IMAGE="$(pin_image learner-bundle.image.prometheus-base)"
    PROM_CONTEXT="$ROOT_DIR/content/repos/prometheus/_vendored/workshop-prometheus"
    for variant in v3.13 bad-target; do
        python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" config --source "$PROM_CONTEXT/Buildfile" --output "$OUT_DIR/build-contexts/prometheus/Offline-$variant" --base "$PROMETHEUS_IMAGE"
        build_image "workshop-prometheus:$variant" "$PROM_CONTEXT" "$OUT_DIR/build-contexts/prometheus/Offline-$variant"
    done
    OTEL_PROM_CONTEXT="$OUT_DIR/build-contexts/python/metrics/prometheus"
    if [[ ! -s "$OTEL_PROM_CONTEXT/Buildfile-prom" ]]; then
        mkdir -p "$OTEL_PROM_CONTEXT"
        cp "$ROOT_DIR/content/repos/opentelemetry/_vendored/intro-to-instrumentation-v1.4/metrics/prometheus/Buildfile-prom" "$OTEL_PROM_CONTEXT/Buildfile-prom"
        cp "$ROOT_DIR/content/repos/opentelemetry/_vendored/intro-to-instrumentation-v1.4/metrics/prometheus/prometheus.yml" "$OTEL_PROM_CONTEXT/prometheus.yml"
    fi
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" config --source "$OTEL_PROM_CONTEXT/Buildfile-prom" --output "$OUT_DIR/build-contexts/prometheus/Offline-otel-lab06" --base "$PROMETHEUS_IMAGE"
    build_image workshop-prometheus:v3.13.1 "$OTEL_PROM_CONTEXT" "$OUT_DIR/build-contexts/prometheus/Offline-otel-lab06"
fi

if [[ "$COMPONENT" == all || "$COMPONENT" == fluentbit ]]; then
    FLUENTBIT_IMAGE="$(pin_image learner-bundle.image.fluent-bit)"
    OTEL_COLLECTOR_IMAGE="$(pin_image learner-bundle.image.otel-collector)"
    FLUENTBIT_ARCHIVE="$OUT_DIR/downloads/fluentbit-install-demo-v2.9.zip"
    FLUENTBIT_ARCHIVE_SHA256="$(pin_sha256 learner-bundle.archive.fluentbit-helper)"
    fetch_generic https://gitlab.com/o11y-workshops/fluentbit-install-demo/-/archive/v2.9/fluentbit-install-demo-v2.9.zip "$FLUENTBIT_ARCHIVE" "$FLUENTBIT_ARCHIVE_SHA256"
    FLUENTBIT_ROOT="$OUT_DIR/build-contexts/fluentbit-upstream"
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" extract-zip --source "$FLUENTBIT_ARCHIVE" --output "$FLUENTBIT_ROOT"
    FLUENTBIT_SUPPORT="$FLUENTBIT_ROOT/fluentbit-install-demo-v2.9/support"

    build_fluentbit_image workshop-fb:v1 "$ROOT_DIR/learner-vm/fixtures/fluentbit-lab3-v1.yaml" workshop-fb.yaml
    build_fluentbit_image workshop-fb:v2 "$ROOT_DIR/learner-vm/fixtures/fluentbit-lab3-v2.yaml" workshop-fb.yaml
    build_fluentbit_image workshop-fb:v3 "$FLUENTBIT_SUPPORT/configs-lab-3/workshop-fb.yaml" workshop-fb.yaml
    build_fluentbit_image workshop-fb:v4 "$ROOT_DIR/learner-vm/fixtures/fluentbit-lab4-v4.yaml" workshop-fb.yaml
    build_fluentbit_image workshop-fb:v5 "$ROOT_DIR/learner-vm/fixtures/fluentbit-lab4-v5.yaml" workshop-fb.yaml
    build_fluentbit_image workshop-fb:v6 "$ROOT_DIR/learner-vm/fixtures/fluentbit-lab4-v6.yaml" workshop-fb.yaml
    build_fluentbit_image workshop-fb:v7 "$FLUENTBIT_SUPPORT/configs-lab-4/workshop-fb.yaml" workshop-fb.yaml
    build_fluentbit_image workshop-fb:v8 "$FLUENTBIT_SUPPORT/configs-lab-5/workshop-fb.yaml" workshop-fb.yaml
    memory_context="$OUT_DIR/build-contexts/fluentbit/workshop-fb_v9"
    mkdir -p "$memory_context"
    cp "$FLUENTBIT_SUPPORT/configs-lab-5/workshop-fb.yaml" "$memory_context/workshop-fb.yaml"
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" fluentbit-memory-limit --source "$memory_context/workshop-fb.yaml"
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" fluentbit --source "$memory_context/workshop-fb.yaml" --output "$memory_context/Offline-Buildfile" --base "$FLUENTBIT_IMAGE" --programmatic workshop-fb.yaml
    build_image workshop-fb:v9 "$memory_context" "$memory_context/Offline-Buildfile"
    alias_image_tags workshop-fb:v8 workshop-fb:v10
    build_fluentbit_image workshop-fb:v11 "$FLUENTBIT_SUPPORT/configs-lab-6/workshop-fb.yaml" workshop-fb.yaml
    build_fluentbit_image workshop-fb:v12 "$ROOT_DIR/learner-vm/fixtures/fluentbit-otel-v12.yaml" workshop-fb.yaml
    build_fluentbit_image workshop-fb:v13 "$ROOT_DIR/learner-vm/fixtures/fluentbit-otel-v13.yaml" workshop-fb.yaml
    build_fluentbit_image workshop-fb:v14 "$FLUENTBIT_SUPPORT/configs-lab-7/workshop-fb.yaml" workshop-fb.yaml
    build_fluentbit_image workshop-fb:v15 "$FLUENTBIT_SUPPORT/configs-lab-10/routing-fb-1.yaml" routing-fb-1.yaml
    build_fluentbit_image workshop-fb:v16 "$FLUENTBIT_SUPPORT/configs-lab-10/routing-fb-2.yaml" routing-fb-2.yaml
    build_fluentbit_image workshop-fb:v17 "$FLUENTBIT_SUPPORT/configs-lab-10/routing-fb-3.yaml" routing-fb-3.yaml
    build_fluentbit_image workshop-fb:v18 "$FLUENTBIT_SUPPORT/configs-lab-10/conditional-routing.yaml" conditional-routing.yaml
    build_fluentbit_image workshop-fb:v19 "$FLUENTBIT_SUPPORT/configs-lab-10/combined-routing.yaml" combined-routing.yaml

    collector_context="$OUT_DIR/build-contexts/fluentbit/workshop-otel-v0.159"
    mkdir -p "$collector_context"
    cp "$FLUENTBIT_SUPPORT/configs-lab-7/workshop-otel.yaml" "$collector_context/workshop-otel.yaml"
    docker run --rm --network none --volume "$collector_context/workshop-otel.yaml:/tmp/workshop-otel.yaml:ro" "$OTEL_COLLECTOR_IMAGE" validate --config=/tmp/workshop-otel.yaml
    python3 "$ROOT_DIR/scripts/dev/prepare-learner-build.py" config --source "$FLUENTBIT_SUPPORT/configs-lab-7/Buildfile-otel" --output "$collector_context/Offline-Buildfile" --base "$OTEL_COLLECTOR_IMAGE"
    build_image workshop-otel:v0.159 "$collector_context" "$collector_context/Offline-Buildfile"

    build_fluentbit_image opensearch:fb-opensearch "$ROOT_DIR/learner-vm/fixtures/fluentbit-opensearch.yaml" fluent-bit.yaml
fi

if [[ "$COMPONENT" == all ]]; then
    while IFS= read -r reference || [[ -n "$reference" ]]; do
        reference="${reference%%#*}"
        reference="${reference//[[:space:]]/}"
        [[ -n "$reference" ]] || continue
        if [[ "$reference" == eclipse-temurin:21 ]]; then
            printf '[capture-learner-dependencies] SKIP upstream Java 21 base; derived learner recipes use pinned Java 17.\n'
            continue
        fi
        case "$reference" in
            docker.io/jaegertracing/all-in-one:1.76.0) key=learner-bundle.image.jaeger ;;
            docker.io/library/busybox:1.36) key=learner-bundle.image.busybox ;;
            docker.io/opensearchproject/opensearch-dashboards:3.3.0) key=learner-bundle.image.opensearch-dashboards ;;
            docker.io/opensearchproject/opensearch:3.3.1) key=learner-bundle.image.opensearch ;;
            docker.io/persesdev/perses:v0.54.0) key=image.perses ;;
            docker.io/prom/prometheus:v3.13.1|prom/prometheus:v3.13.1) key=learner-bundle.image.prometheus-base ;;
            ghcr.io/fluent/fluent-bit:5.1.1) key=learner-bundle.image.fluent-bit ;;
            otel/opentelemetry-collector-contrib:0.159.0|docker.io/otel/opentelemetry-collector-contrib:0.159.0) key=learner-bundle.image.otel-collector ;;
            eclipse-temurin:17|docker.io/library/eclipse-temurin:17) key=learner-bundle.image.java17 ;;
            python:3.13-bullseye|docker.io/library/python:3.13-bullseye) key=learner-bundle.image.python ;;
            quay.io/prometheus/node-exporter:v1.12.1) key=learner-bundle.image.node-exporter ;;
            *) die "external lab image is not covered by an immutable versions.lock pin: $reference" ;;
        esac
        pin_image "$key" >/dev/null
    done < "$ROOT_DIR/content/extracted/external-images.txt"
fi

if [[ "$COMPONENT" != lab-files ]]; then make_package_caches_readable; fi
if [[ -s "$OUT_DIR/capture-image-pins.tsv" ]]; then
    cat "$OUT_DIR/capture-image-pins.tsv" "$OUT_DIR/capture-image-pins.tsv.tmp" | sort -u > "$OUT_DIR/capture-image-pins.tsv.merged"
    mv "$OUT_DIR/capture-image-pins.tsv.merged" "$OUT_DIR/capture-image-pins.tsv"
else
    sort -u "$OUT_DIR/capture-image-pins.tsv.tmp" > "$OUT_DIR/capture-image-pins.tsv"
fi
rm -f -- "$OUT_DIR/capture-image-pins.tsv.tmp"
if [[ "$COMPONENT" != lab-files && -s "$IMAGE_REFERENCES_FILE" ]]; then
    mapfile -t CAPTURED_IMAGES < "$IMAGE_REFERENCES_FILE"
    : > "$OUT_DIR/captured-image-inventory.tsv"
    for image in "${CAPTURED_IMAGES[@]}"; do
        image_id="$(docker image inspect --format '{{.Id}}' "$image")" || die "captured image reference is missing: $image"
        repo_digests="$(docker image inspect --format '{{join .RepoDigests ","}}' "$image")"
        printf '%s\t%s\t%s\n' "$image" "$image_id" "$repo_digests" >> "$OUT_DIR/captured-image-inventory.tsv"
    done
    docker save --output "$OUT_DIR/images/lab-images.tar" "${CAPTURED_IMAGES[@]}"
    if [[ "$COMPONENT" == all || "$COMPONENT" == java || "$COMPONENT" == fluentbit ]]; then
        export CAPTURE_EXPECTED_IMAGES="$OUT_DIR/captured-image-inventory.tsv"
        python3 - "$OUT_DIR/captured-image-inventory.tsv" "$OUT_DIR/images/lab-images.tar" <<'PY'
import hashlib
import json
import sys
import tarfile

def canonical(reference):
    name = reference.split("@", 1)[0]
    first = name.split("/", 1)[0]
    if "/" not in name:
        reference = "docker.io/library/" + reference
    elif "." not in first and ":" not in first and first != "localhost":
        reference = "docker.io/" + reference
    name, separator, digest = reference.partition("@")
    last = name.rsplit("/", 1)[-1]
    if ":" not in last and not separator:
        reference = name + ":latest"
    return reference

with open(sys.argv[1], encoding="utf-8") as source:
    references = {canonical(line.split("\t", 1)[0].rstrip("\n")) for line in source}
archive_references = set()
invalid_configs = []
with tarfile.open(sys.argv[2]) as archive:
    for image in json.load(archive.extractfile("manifest.json")):
        archive_references.update(canonical(reference) for reference in image.get("RepoTags") or [])
        config = image["Config"]
        payload = archive.extractfile(config).read()
        actual = "sha256:" + hashlib.sha256(payload).hexdigest()
        expected = "sha256:" + config.rsplit("/", 1)[-1].removesuffix(".json")
        if actual != expected:
            invalid_configs.append(config)
missing = sorted(references - archive_references)
extra = sorted(archive_references - references)
print(json.dumps({"expected": len(references), "archive_tags": len(archive_references), "missing": missing, "extra": extra, "invalid_configs": invalid_configs}, indent=2))
sys.exit(bool(missing or extra or invalid_configs))
PY
        python3 - "$OUT_DIR/captured-image-inventory.tsv" "$OUT_DIR/manifest.json" "$ROOT_DIR/content/extracted/commands.json" "$ROOT_DIR" <<'PY'
import json
import sys
import subprocess
images = []
with open(sys.argv[1], encoding="utf-8") as source:
    for line in source:
        reference, image_id, repo_digests = line.rstrip("\n").split("\t")
        images.append({"reference": reference, "id": image_id, "repo_digests": [value for value in repo_digests.split(",") if value]})
with open(sys.argv[3], encoding="utf-8") as source:
    commands = json.load(source)
required = sorted({command["tag"] for track in commands.values() for lab in track.get("labs", []) for command in lab.get("commands", []) if command.get("type") == "build" and isinstance(command.get("tag"), str)})
captured = {image["reference"] for image in images}
verified = sorted(set(required) & captured)
excluded = sorted(set(required) - captured)
manifest = {"schema": 1, "architecture": "amd64", "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=sys.argv[4], text=True).strip(), "images": images, "image_archive": "images/lab-images.tar", "captured_components": ["python", "java17", "go", "npm", "prometheus", "fluentbit"], "offline_verified": False, "coverage": {"required": required, "verified": verified, "excluded": excluded}}
with open(sys.argv[2], "w", encoding="utf-8") as destination:
    json.dump(manifest, destination, indent=2)
    destination.write("\n")
PY
    fi
fi
rm -rf -- "$OUT_DIR/configuration/capture"
python3 - "$OUT_DIR/downloads" "$OUT_DIR/generic-checksums.txt" <<'PY'
import hashlib
from pathlib import Path
import sys

root = Path(sys.argv[1])
records = []
for path in sorted(root.rglob("*")):
    if path.is_symlink():
        raise SystemExit("generic download tree contains a symbolic link: " + str(path))
    if path.is_file():
        checksum = hashlib.sha256(path.read_bytes()).hexdigest()
        records.append(f"{checksum}  {path.relative_to(root.parent).as_posix()}\n")
Path(sys.argv[2]).write_text("".join(records), encoding="utf-8")
PY
printf '[capture-learner-dependencies] Captured component=%s; outputs are partial until all declared labs and package caches pass offline validation.\n' "$COMPONENT"
printf '%s\n' 'No aggregate release asset was sealed or published. Use the full coverage manifest gate before packing.'
