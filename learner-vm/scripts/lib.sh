# shellcheck shell=bash
set -euo pipefail

# CHANGE: Resolve operator-only per-image archives and record locally loaded references.
LIB_VERSION="7"
: "${SCRIPT_NAME:?Set SCRIPT_NAME before sourcing scripts/lib.sh}"
: "${SCRIPT_VERSION:?Set SCRIPT_VERSION before sourcing scripts/lib.sh}"

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
if [[ ! -d "$REPO_ROOT/learner-vm" || ! -d "$REPO_ROOT/scripts" ]]; then
    printf '[%s] FATAL: repository root could not be derived from %s. FIX: keep learner-vm/scripts/lib.sh inside the repository.\n' "$SCRIPT_NAME" "$LIB_DIR" >&2
    return 1
fi

SELFTEST_MODE="${SELFTEST_MODE:-false}"
CONFIG_FILE="$REPO_ROOT/learner-vm/lab-vm.conf"
if [[ "$SELFTEST_MODE" != "true" ]]; then
    if [[ ! -r "$CONFIG_FILE" ]]; then
        printf '[%s] FATAL: configuration is not readable. FIX: restore %s.\n' "$SCRIPT_NAME" "$CONFIG_FILE" >&2
        return 1
    fi
    if ! source "$CONFIG_FILE"; then
        printf '[%s] FATAL: configuration could not be loaded. FIX: correct shell syntax in %s.\n' "$SCRIPT_NAME" "$CONFIG_FILE" >&2
        return 1
    fi
fi

REPOS_ROOT="$REPO_ROOT/content/repos"
DOCS_ROOT="$REPO_ROOT/content/docs"
LOG_DIR="/var/log/lab-setup"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
DRY_RUN="${DRY_RUN:-false}"
OK_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
REPORT_ACTIVE=0
declare -a FAIL_ENTRIES=()
declare -a SKIP_ENTRIES=()

validate_docker_registry() {
    local registry="${1:-${DOCKER_REGISTRY:-docker-registry.${ART_REPO_DOMAIN:-artifactory.internal}}}" host path=''
    if [[ "$registry" == *://* ]]; then registry="${registry#*://}"; fi
    host="${registry%%/*}"
    if [[ "$registry" == */* ]]; then path="${registry#*/}"; fi
    if [[ ! "$host" =~ ^[[:alnum:].-]+(:[0-9]+)?$ || "$path" == /* || "$registry" == */ || "$path" == *..* || ( -n "$path" && ! "$path" =~ ^[[:alnum:]_./-]+$ ) ]]; then
        printf '[%s] FATAL: malformed registry endpoint; correct DOCKER_REGISTRY in learner-vm/lab-vm.conf (value withheld).\n' "$SCRIPT_NAME" >&2
        return 1
    fi
    REG_HOST="$host"
    DOCKER_REGISTRY="$registry"
    REGISTRY_FORM='subdomain'
    [[ -z "$path" ]] || REGISTRY_FORM='path'
}

if [[ "$SELFTEST_MODE" != "true" ]]; then
    validate_docker_registry "$DOCKER_REGISTRY" || return 1
fi

log() {
    local line="[${SCRIPT_NAME}] $*"
    printf '%s\n' "$line"
    if [[ "$SELFTEST_MODE" != "true" && "$DRY_RUN" != "true" ]] && mkdir -p "$LOG_DIR" 2>/dev/null && printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null; then
        :
    fi
}

step_ok() {
    ((OK_COUNT += 1))
    log "✓ $*"
}

step_skip() {
    local reason="$1" message="$2" entry
    entry="$message ($reason)"
    ((SKIP_COUNT += 1))
    SKIP_ENTRIES+=("$entry")
    log "→ SKIPPED: $message — $reason"
}

step_fail() {
    local what="$1"
    local fix_hint="$2"
    shift 2
    local failure_id="F$((FAIL_COUNT + 1))"
    local diagnostic output status line line_count flattened index timeout_seconds=10

    ((FAIL_COUNT += 1))
    FAIL_ENTRIES+=("${failure_id}: ${what} | FIX: ${fix_hint}")
    log "✗ ${failure_id}: ${what} | FIX: ${fix_hint}"

    for diagnostic in "$@"; do
        if command -v timeout >/dev/null 2>&1; then
            if output="$(timeout --signal=TERM "${timeout_seconds}s" bash -c "$diagnostic" 2>&1)"; then
                status=0
            else
                status=$?
            fi
        elif output="$(bash -c "$diagnostic" 2>&1)"; then
            status=0
        else
            status=$?
        fi
        if ((status == 124 || status == 137)); then
            flattened="timed out after ${timeout_seconds}s"
        elif [[ -z "$output" ]]; then
            flattened="command not found or no output (exit ${status})"
        else
            flattened=""
            line_count=0
            while IFS= read -r line || [[ -n "$line" ]]; do
                if ((line_count >= 15)); then
                    flattened+="; (output capped at 15 lines)"
                    break
                fi
                [[ -n "$flattened" ]] && flattened+="; "
                flattened+="$line"
                ((line_count += 1))
            done <<<"$output"
        fi
        index=$((${#FAIL_ENTRIES[@]} - 1))
        FAIL_ENTRIES[index]+=" | DIAG[$diagnostic]: $flattened"
    done
}

begin_report() {
    REPORT_ACTIVE=1
}

end_report() {
    local hostname_value timestamp_value git_sha result skipped_summary line log_summary
    local report_lines=() skip_joined=""

    REPORT_ACTIVE=0
    if [[ "$SELFTEST_MODE" == "true" ]]; then
        hostname_value="selftest"
        timestamp_value="synthetic"
        git_sha="not-read"
    else
        if hostname_value="$(hostname 2>/dev/null)"; then :; else hostname_value="unavailable"; fi
        if timestamp_value="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"; then :; else timestamp_value="unavailable"; fi
        if command -v git >/dev/null 2>&1 && git_sha="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)"; then :; else git_sha="unavailable"; fi
    fi

    if ((FAIL_COUNT > 0)); then result="FAILED"; else result="PASSED"; fi
    if ((SKIP_COUNT > 0)); then
        skip_joined="$(IFS='; '; printf '%s' "${SKIP_ENTRIES[*]}")"
        skipped_summary="SKIPPED (${SKIP_COUNT}): ${skip_joined}"
    else
        skipped_summary="SKIPPED (0): none"
    fi
    if [[ "$DRY_RUN" == "true" ]]; then log_summary="not written during --dry-run: ${LOG_FILE}"; else log_summary="${LOG_FILE}"; fi

    report_lines+=("==================== REPORT BEGIN ====================")
    report_lines+=("SCRIPT: ${SCRIPT_NAME} ${SCRIPT_VERSION}")
    report_lines+=("LIBRARY: lib.sh ${LIB_VERSION}")
    report_lines+=("HOST: ${hostname_value} ${timestamp_value} git: ${git_sha}")
    report_lines+=("RESULT: ${result} (ok=${OK_COUNT} failed=${FAIL_COUNT} skipped=${SKIP_COUNT})")
    for line in "${FAIL_ENTRIES[@]}"; do report_lines+=("$line"); done
    report_lines+=("OK: ${OK_COUNT} steps — full log: ${log_summary}")
    report_lines+=("${skipped_summary}")
    report_lines+=("NEXT: ${1:-Review the report and follow README-FIRST.md.}")
    report_lines+=("==================== REPORT END ======================")

    printf '%s\n' "${report_lines[@]}"
    if [[ "$SELFTEST_MODE" != "true" && "$DRY_RUN" != "true" ]] && mkdir -p "$LOG_DIR" 2>/dev/null; then
        printf '%s\n' "${report_lines[@]}" >>"$LOG_FILE" 2>/dev/null || true
    fi
}

run() {
    local command="$*"
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[dry-run] WOULD: ${command}"
        return 0
    fi
    bash -c "$command"
}

require_or_skip() {
    local binary="$1"
    local description="$2"
    if command -v "$binary" >/dev/null 2>&1; then
        return 0
    fi
    step_skip "$binary is not installed" "$description"
    return 1
}

artifact_lock_sha256() {
    local key="$1"
    awk -v key="$key" '$1 == key {for (i=1;i<=NF;i++) if ($i ~ /^sha256:/) {sub(/^sha256:/,"",$i); print $i; exit}}' "$REPO_ROOT/versions.lock"
}

registry_probe_result() {
    local reference="$1" status="$2"
    if [[ "$status" =~ ^[1-5][0-9][0-9]$ ]]; then
        REGISTRY_RESPONSES=$((${REGISTRY_RESPONSES:-0} + 1))
    fi
    case "$status" in
        200) step_skip "HTTP 200: image cached" "registry probe $reference (informational)" ;;
        401|403) step_skip "HTTP $status: registry requires auth or has restricted access" "registry probe $reference (informational)" ;;
        404) step_skip "HTTP 404: not cached or not visible to this probe; pull result decides availability" "registry probe $reference (informational)" ;;
        000|'') step_skip "endpoint unreachable or DNS/TLS failure; evaluating all registry responses before reporting failure" "registry probe $reference (HTTP 000)" ;;
        *) step_skip "HTTP $status: endpoint responded; use a mirror pull to establish image availability" "registry probe $reference (informational)" ;;
    esac
}

registry_pull_result() {
    local reference="$1" status="$2" output="$3" duration="$4" was_present="$5" category fix_hint
    if ((status == 0)); then
        local warming='already present before pull'
        [[ "$was_present" == true ]] || warming='diagnostic warmed the local Podman store as a side effect'
        step_ok "pull verified $reference via $DOCKER_REGISTRY in ${duration}s; $warming"
        return 0
    fi
    if grep -Eiq 'no such host|name.*resol|connection refused|network.*unreachable|timeout|timed out|TLS|x509|certificate' <<< "$output"; then
        category='registry endpoint unreachable, DNS, or TLS failure'
        fix_hint='Check endpoint DNS, TLS trust, and registry routing.'
    elif grep -Eq '401|403' <<< "$output" || grep -Eiq 'unauthorized|authentication required|denied' <<< "$output"; then
        category='authentication required or restricted access (see exact response below)'
        fix_hint='Ask the registry administrator to correct access; do not infer access from manifest probes.'
    elif grep -Eiq '404|manifest unknown|name unknown|not found' <<< "$output"; then
        category='image absent after mirror resolution'
        fix_hint='Check the original reference and image availability at the configured mirror.'
    else
        category='container pull failed'
        fix_hint='Inspect the exact pull output before retrying.'
    fi
    log "exact pull output for $reference (exit $status): $output"
    if [[ "$SELFTEST_MODE" == true ]]; then
        step_fail "$category for $reference at $DOCKER_REGISTRY (exit $status, ${duration}s)" "$fix_hint Synthetic fixture; no network request." "printf '%s\\n' $(printf '%q' "$output")"
        return 0
    fi
    local tls_connect="$REG_HOST"
    [[ "$REG_HOST" == *:* ]] || tls_connect="$REG_HOST:443"
    step_fail "$category for $reference at $DOCKER_REGISTRY (exit $status, ${duration}s)" "$fix_hint See MANUAL-FETCH.md Section C for the optional local archive." \
        "printf '%s\\n' $(printf '%q' "$output")" \
        "getent hosts $(printf '%q' "${REG_HOST%%:*}")" \
        "curl -vI --connect-timeout 5 --max-time 10 https://$(printf '%q' "$DOCKER_REGISTRY")/v2/ 2>&1 | tail -n 12" \
        "printf '' | openssl s_client -connect $(printf '%q' "$tls_connect") -servername $(printf '%q' "${REG_HOST%%:*}") 2>&1 | tail -n 10"
}

verify_registry_pull() {
    local reference="$1" was_present=false started="$SECONDS" output status=0
    if ! command -v podman >/dev/null 2>&1; then
        step_skip "Podman absent on minimal base; script 20 installs it" "pull verification unavailable for $reference"
        return 0
    fi
    if podman image exists "$reference" >/dev/null 2>&1; then was_present=true; fi
    if output="$(podman pull "$reference" 2>&1)"; then :; else status=$?; fi
    registry_pull_result "$reference" "$status" "$output" "$((SECONDS - started))" "$was_present"
}

image_archive_ids() {
    awk -F '\t' '$0 !~ /^#/ && $2 == "image-archive" {print $1}' "$REPO_ROOT/learner-vm/artifacts.tsv"
}

image_canonical_reference() {
    local reference="$1" first="${1%%/*}"
    if [[ "$reference" != */* ]]; then
        printf 'docker.io/library/%s\n' "$reference"
    elif [[ "$first" != *.* && "$first" != *:* && "$first" != localhost ]]; then
        printf 'docker.io/%s\n' "$reference"
    else
        printf '%s\n' "$reference"
    fi
}

image_asset_name() {
    local reference="$1" first path
    first="${reference%%/*}"
    path="$reference"
    if [[ "$reference" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == localhost ) ]]; then
        path="${reference#*/}"
    elif [[ "$reference" != */* ]]; then
        path="library/$reference"
    fi
    [[ "$path" =~ ^[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] || return 1
    path="${path//\//-}"
    printf '%s.tar\n' "${path//:/-}"
}

image_archive_reference() {
    local filename="$1" reference asset
    while IFS= read -r reference || [[ -n "$reference" ]]; do
        reference="${reference%%#*}"
        [[ -n "$reference" ]] || continue
        asset="$(image_asset_name "$reference")" || return 1
        if [[ "$asset" == "$filename" ]]; then printf '%s\n' "$reference"; return 0; fi
    done < "$REPO_ROOT/content/extracted/external-images.txt"
    return 1
}

image_archive_manifest() {
    python3 - "$1" <<'PY'
import hashlib
import json
import re
import sys
import tarfile

with tarfile.open(sys.argv[1], "r:*") as archive:
    members = {}
    for member in archive.getmembers():
        name = member.name[2:] if member.name.startswith("./") else member.name
        if name in members:
            raise ValueError("duplicate archive member")
        members[name] = member

    def read_member(name):
        member = members[name]
        if not member.isfile():
            raise ValueError("manifest/blob is not a regular file")
        return archive.extractfile(member)

    def read_json(name):
        with read_member(name) as source:
            return json.load(source)

    def verify_descriptor(descriptor):
        digest = descriptor["digest"]
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            raise ValueError("unsupported descriptor digest")
        name = "blobs/sha256/" + digest.split(":", 1)[1]
        checksum = hashlib.sha256()
        size = 0
        with read_member(name) as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                checksum.update(block)
                size += len(block)
        if checksum.hexdigest() != digest.split(":", 1)[1] or size != descriptor["size"]:
            raise ValueError("OCI descriptor checksum/size mismatch")
        return name

    def emit(reference, config, manifest):
        if not reference or re.search(r"[\s|]", reference):
            raise ValueError("missing/unsafe image reference in archive")
        first = reference.split("/", 1)[0]
        if "/" not in reference:
            reference = "docker.io/library/" + reference
        elif "." not in first and ":" not in first and first != "localhost":
            reference = "docker.io/" + reference
        print(reference + "\t" + config + "\t" + manifest)

    def visit(descriptor, inherited_reference=""):
        name = verify_descriptor(descriptor)
        document = read_json(name)
        annotations = descriptor.get("annotations", {})
        reference = annotations.get("io.containerd.image.name") or annotations.get("org.opencontainers.image.ref.name") or inherited_reference
        if "manifests" in document:
            for child in document["manifests"]:
                visit(child, reference)
        else:
            verify_descriptor(document["config"])
            for layer in document.get("layers", []):
                verify_descriptor(layer)
            emit(reference, document["config"]["digest"], descriptor["digest"])

    if "index.json" in members and "oci-layout" in members:
        for descriptor in read_json("index.json")["manifests"]:
            visit(descriptor)
    elif "manifest.json" in members:
        for image in read_json("manifest.json"):
            with read_member(image["Config"]) as source:
                config = "sha256:" + hashlib.sha256(source.read()).hexdigest()
            filename_digest = image["Config"].split("/")[-1]
            if filename_digest.endswith(".json"):
                filename_digest = filename_digest[:-5]
            if re.fullmatch(r"[0-9a-f]{64}", filename_digest) and config != "sha256:" + filename_digest:
                raise ValueError("Docker config checksum mismatch")
            for layer in image["Layers"]:
                with read_member(layer) as source:
                    checksum = hashlib.sha256()
                    for block in iter(lambda: source.read(1024 * 1024), b""):
                        checksum.update(block)
                config_document = read_json(image["Config"])
                diff_ids = config_document.get("rootfs", {}).get("diff_ids", [])
                position = image["Layers"].index(layer)
                if diff_ids and (position >= len(diff_ids) or "sha256:" + checksum.hexdigest() != diff_ids[position]):
                    raise ValueError("Docker layer diff-ID mismatch")
            for reference in image.get("RepoTags") or []:
                emit(reference, config, "-")
PY
}

load_image_archives() {
    local store="$1" artifact_id result archive_path manifest reference config_digest manifest_digest actual expected_reference
    declare -gA LOCAL_ARCHIVE_IMAGES=()
    while IFS= read -r artifact_id; do
        artifact_metadata "$artifact_id" || return 1
        case "$store:$ARTIFACT_INSTALL_TARGET" in
            podman:podman|podman:both|k3s:k3s-containerd|k3s:both) ;;
            *) continue ;;
        esac
        if resolve_artifact "$artifact_id"; then :; else
            result=$?
            ((result == 2)) && continue
            return 1
        fi
        archive_path="$ARTIFACT_RESOLVED_PATH"
        expected_reference="$(image_archive_reference "${ARTIFACT_RELATIVE_PATH##*/}")" || {
            step_fail "catalog archive has no matching original image reference: $artifact_id" "Match its filename to content/extracted/external-images.txt before loading."
            return 1
        }
        if ! manifest="$(image_archive_manifest "$archive_path" 2>/dev/null)"; then
            step_fail "image archive $artifact_id contains an invalid manifest or blob checksum" "Correct $archive_path; see MANUAL-FETCH.md Section C. No network fallback is attempted for a corrupt archive."
            return 1
        fi
        if [[ "$DRY_RUN" == true ]]; then
            log "[dry-run] image-archive stage: $store would load $archive_path; embedded manifest validated when present"
            continue
        fi
        if [[ "$store" == podman ]]; then
            if ! docker load -i "$archive_path"; then
                step_fail "could not load $artifact_id into Podman" "Check $archive_path and the rootful store; see MANUAL-FETCH.md Section C."
                return 1
            fi
            if ! docker image inspect "$expected_reference" >/dev/null 2>&1; then
                step_fail "local archive did not load original reference $expected_reference" "Correct $archive_path; see MANUAL-FETCH.md Section C."
                return 1
            fi
            LOCAL_ARCHIVE_IMAGES["$expected_reference"]='local archive'
        elif ! /usr/local/bin/k3s ctr -n k8s.io images import "$archive_path"; then
            step_fail "could not import $artifact_id into k3s" "Check $archive_path and the k8s.io namespace; see MANUAL-FETCH.md Section C."
            return 1
        fi
        while IFS=$'\t' read -r reference config_digest manifest_digest; do
            [[ -n "$reference" ]] || continue
            if [[ "$store" == podman ]]; then
                actual="$(docker image inspect --format '{{.Id}}' "$reference" 2>/dev/null || true)"
                actual="sha256:${actual#sha256:}"
                if [[ "$actual" != "$config_digest" ]]; then
                    step_fail "loaded image config digest mismatch for $reference: expected $config_digest, actual $actual" "Correct $archive_path before provisioning; see MANUAL-FETCH.md Section C."
                    return 1
                fi
                LOCAL_ARCHIVE_IMAGES["$reference"]='local archive'
            else
                actual="$(/usr/local/bin/k3s ctr -n k8s.io images list | awk -v ref="$reference" '$1 == ref {print $3; exit}')"
                if [[ -z "$actual" || ( "$manifest_digest" != - && "$actual" != "$manifest_digest" ) ]]; then
                    step_fail "imported k3s image reference/digest mismatch for $reference" "Correct $archive_path; see MANUAL-FETCH.md Section C."
                    return 1
                fi
            fi
        done <<< "$manifest"
        step_ok "loaded local image archive $artifact_id into $store; embedded references and hashes checked when present"
    done < <(image_archive_ids)
}

artifact_metadata() {
    local requested_id="$1" catalog="$REPO_ROOT/learner-vm/artifacts.tsv"
    local id kind required relative_path url_variable lock_key consumer install_target extra row_sha line_number=0 found=0 header_seen=0 expected_header actual_header
    local -A seen_ids=()
    expected_header=$'id\tkind\trequired\tstaging_relative_path\turl_variable\tsha256_lock_key\tconsumer_script\tinstall_target'
    [[ "$requested_id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
        printf '[%s] FATAL: invalid artifact ID.\n' "$SCRIPT_NAME" >&2
        return 1
    }
    [[ -r "$catalog" ]] || {
        printf '[%s] FATAL: artifact catalog is not readable: %s\n' "$SCRIPT_NAME" "$catalog" >&2
        return 1
    }
    while IFS=$'\t' read -r id kind required relative_path url_variable lock_key consumer install_target extra || [[ -n "$id${kind}${required}${relative_path}${url_variable}${lock_key}${consumer}${install_target}${extra}" ]]; do
        ((line_number += 1))
        [[ -n "$id" ]] || continue
        [[ "$id" == \#* ]] && continue
        if [[ "$id" == id ]]; then
            actual_header="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$id" "$kind" "$required" "$relative_path" "$url_variable" "$lock_key" "$consumer" "$install_target")"
            [[ "$actual_header" == "$expected_header" ]] || {
                printf '[%s] FATAL: artifact catalog header is invalid.\n' "$SCRIPT_NAME" >&2
                return 1
            }
            header_seen=1
            continue
        fi
        [[ -z "$extra" ]] || {
            printf '[%s] FATAL: artifact catalog row %s has more than eight columns.\n' "$SCRIPT_NAME" "$line_number" >&2
            return 1
        }
        [[ "$id" =~ ^[a-z0-9][a-z0-9-]*$ && -z "${seen_ids[$id]+x}" ]] || {
            printf '[%s] FATAL: artifact catalog row %s has an invalid or duplicate ID.\n' "$SCRIPT_NAME" "$line_number" >&2
            return 1
        }
        seen_ids["$id"]=1
        [[ "$kind" =~ ^(binary|archive|rpm|file|image-archive)$ ]] || {
            printf '[%s] FATAL: artifact %s has an unsupported kind.\n' "$SCRIPT_NAME" "$id" >&2
            return 1
        }
        [[ "$required" == yes || "$required" == no ]] || {
            printf '[%s] FATAL: artifact %s required must be yes or no.\n' "$SCRIPT_NAME" "$id" >&2
            return 1
        }
        if [[ "$kind" == image-archive && ( "$required" != no || "$url_variable" != - || ! "$install_target" =~ ^(podman|k3s-containerd|both)$ ) ]]; then
            printf '[%s] FATAL: image archive %s must be optional, filesystem-only, and target an image store.\n' "$SCRIPT_NAME" "$id" >&2
            return 1
        fi
        [[ "$relative_path" =~ ^[A-Za-z0-9._/-]+$ && "$relative_path" != /* && "$relative_path" != */ && "/$relative_path/" != *"/../"* && "/$relative_path/" != *"//"* ]] || {
            printf '[%s] FATAL: artifact %s has an unsafe staging path.\n' "$SCRIPT_NAME" "$id" >&2
            return 1
        }
        [[ "$url_variable" =~ ^[A-Z_][A-Z0-9_]*$ || ( "$kind" == image-archive && "$url_variable" == - ) ]] || {
            printf '[%s] FATAL: artifact %s has an invalid URL variable name.\n' "$SCRIPT_NAME" "$id" >&2
            return 1
        }
        [[ "$lock_key" =~ ^[A-Za-z0-9._-]+$ ]] || {
            printf '[%s] FATAL: artifact %s has an invalid checksum lock key.\n' "$SCRIPT_NAME" "$id" >&2
            return 1
        }
        row_sha="$(artifact_lock_sha256 "$lock_key")"
        if [[ "$kind" == image-archive && -z "$row_sha" ]] && awk -v key="$lock_key" '$1 == key {found=1} END {exit !found}' "$REPO_ROOT/versions.lock"; then
            printf '[%s] FATAL: operator-recorded image archive pin %s lacks a valid checksum.\n' "$SCRIPT_NAME" "$lock_key" >&2
            return 1
        fi
        [[ "$row_sha" =~ ^[0-9a-f]{64}$ || ( "$kind" == image-archive && -z "$row_sha" ) ]] || {
            printf '[%s] FATAL: artifact %s checksum key is missing or invalid in versions.lock.\n' "$SCRIPT_NAME" "$id" >&2
            return 1
        }
        [[ "$consumer" =~ ^scripts/[A-Za-z0-9._/-]+$ && -f "$REPO_ROOT/learner-vm/$consumer" ]] || {
            printf '[%s] FATAL: artifact %s consumer script is invalid or missing.\n' "$SCRIPT_NAME" "$id" >&2
            return 1
        }
        [[ ( "$install_target" == /* && "$install_target" != *"/../"* ) || ( "$kind" == image-archive && "$install_target" =~ ^(podman|k3s-containerd|both)$ ) ]] || {
            printf '[%s] FATAL: artifact %s install target must be a safe absolute path.\n' "$SCRIPT_NAME" "$id" >&2
            return 1
        }
        if [[ "$id" == "$requested_id" ]]; then
            ARTIFACT_ID="$id"
            ARTIFACT_KIND="$kind"
            ARTIFACT_REQUIRED="$required"
            ARTIFACT_RELATIVE_PATH="$relative_path"
            ARTIFACT_URL_VARIABLE="$url_variable"
            ARTIFACT_LOCK_KEY="$lock_key"
            ARTIFACT_CONSUMER="$consumer"
            ARTIFACT_INSTALL_TARGET="$install_target"
            ARTIFACT_EXPECTED_SHA256="$(artifact_lock_sha256 "$lock_key")"
            found=1
        fi
    done < "$catalog"
    ((header_seen == 1)) || {
        printf '[%s] FATAL: artifact catalog header is missing.\n' "$SCRIPT_NAME" >&2
        return 1
    }
    ((found == 1)) || {
        printf '[%s] FATAL: artifact ID is not catalogued: %s\n' "$SCRIPT_NAME" "$requested_id" >&2
        return 1
    }
    [[ "$ARTIFACT_EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ || ( "$ARTIFACT_KIND" == image-archive && -z "$ARTIFACT_EXPECTED_SHA256" ) ]] || {
        printf '[%s] FATAL: artifact %s has an invalid SHA-256 lock value.\n' "$SCRIPT_NAME" "$requested_id" >&2
        return 1
    }
}

artifact_safe_url_parts() {
    local url="$1" expected_host="$2"
    python3 - "$url" "$expected_host" <<'PY'
import sys
from urllib.parse import urlsplit

parsed = urlsplit(sys.argv[1])
expected_host = sys.argv[2].lower()
if parsed.scheme != "https" or not parsed.hostname or parsed.hostname.lower() != expected_host:
    raise SystemExit(1)
if parsed.username is not None or parsed.password is not None or parsed.fragment:
    raise SystemExit(1)
try:
    port = parsed.port
except ValueError:
    raise SystemExit(1)
if not parsed.path.startswith("/") or any(ord(char) < 32 for char in sys.argv[1]):
    raise SystemExit(1)
authority = parsed.hostname + (f":{port}" if port else "")
print(parsed.hostname)
print(authority if port else authority + ":443")
print(f"https://{authority}/<redacted>")
PY
}

artifact_network_summary() {
    local host="$1" connect="$2" dns_summary tls_summary
    dns_summary="$(timeout 5 getent hosts "$host" 2>&1 | tail -n 2 | tr '\n' '; ' || true)"
    tls_summary="$(printf '' | timeout 5 openssl s_client -connect "$connect" -servername "$host" 2>&1 | tail -n 2 | tr '\n' '; ' || true)"
    log "artifact network diagnostics for $host: DNS ${dns_summary:-unavailable}; TLS ${tls_summary:-unavailable}"
}

resolve_artifact() {
    local requested_id="$1" mode="${2:-resolve}" local_path url url_info host connect safe_url
    local curl_exit http_status actual_sha='unavailable' curl_log status_file download_tmp destination_dir staged_tmp file_mode stage_error='' curl_summary=''
    case "$mode" in
        resolve|check-only) ;;
        *) step_fail "invalid artifact resolver mode" "Use resolve_artifact <id> with optional check-only mode."; return 1 ;;
    esac
    if ! artifact_metadata "$requested_id"; then
        step_fail "artifact metadata is invalid for $requested_id" "Restore its validated row in learner-vm/artifacts.tsv and the matching SHA-256 record in versions.lock." "sed -n '1,20p' $(printf '%q' "$REPO_ROOT/learner-vm/artifacts.tsv")" "grep '^learner-' $(printf '%q' "$REPO_ROOT/versions.lock")"
        ARTIFACT_RESOLUTION_STATUS='failed'
        return 1
    fi
    local_path="$MANUAL_FETCH_DIR/$ARTIFACT_RELATIVE_PATH"
    ARTIFACT_RESOLVED_PATH=''
    ARTIFACT_RESOLVED_SOURCE=''
    ARTIFACT_RESOLUTION_STATUS=''
    ARTIFACT_SAFE_URL=''
    ARTIFACT_HOST=''
    ARTIFACT_CONNECT=''

    if [[ "$ARTIFACT_KIND" == image-archive ]]; then
        if [[ ! -e "$local_path" && ! -L "$local_path" ]]; then
            ARTIFACT_RESOLUTION_STATUS='ABSENT'
            step_skip "image archive $ARTIFACT_ID ABSENT at $local_path" "filesystem-only optional input; handled in the pull stage, no network request here"
            return 2
        fi
        if [[ ! -f "$local_path" || -L "$local_path" ]]; then
            step_fail "image archive $ARTIFACT_ID is not a regular file: $local_path" "Provide a regular archive; see MANUAL-FETCH.md Section C. No network fallback is attempted."
            return 1
        fi
        if [[ -n "$ARTIFACT_EXPECTED_SHA256" ]]; then
            actual_sha="$(sha256sum "$local_path" | awk '{print $1}')"
            if [[ "$actual_sha" != "$ARTIFACT_EXPECTED_SHA256" ]]; then
                step_fail "FATAL image archive $ARTIFACT_ID checksum mismatch: expected $ARTIFACT_EXPECTED_SHA256, actual $actual_sha" "Correct the local archive or operator-recorded versions.lock pin; see MANUAL-FETCH.md Section C. No network request is attempted."
                return 1
            fi
        else
            step_skip "image archive $ARTIFACT_ID has no operator-recorded checksum at $ARTIFACT_LOCK_KEY" "present (unverified archive SHA-256); loader verifies embedded manifest hashes when present"
        fi
        ARTIFACT_RESOLVED_PATH="$local_path"
        ARTIFACT_RESOLVED_SOURCE='manual'
        ARTIFACT_RESOLUTION_STATUS='PRESENT'
        step_ok "image archive $ARTIFACT_ID PRESENT at $local_path; source $ARTIFACT_RESOLVED_SOURCE; no network request"
        return 0
    fi

    if [[ -e "$local_path" || -L "$local_path" ]]; then
        if [[ ! -f "$local_path" || -L "$local_path" ]]; then
            step_fail "staged artifact $ARTIFACT_ID is not a regular file: $local_path" "Replace the local file with a regular file matching versions.lock; it will not be overwritten or fetched again." "ls -ld $(printf '%q' "$local_path")"
            ARTIFACT_RESOLUTION_STATUS='failed'
            return 1
        fi
        if ! command -v sha256sum >/dev/null 2>&1; then
            step_fail "sha256sum is unavailable for staged artifact $ARTIFACT_ID" "Install coreutils before verifying $local_path." "command -v sha256sum" "rpm -q coreutils"
            ARTIFACT_RESOLUTION_STATUS='failed'
            return 1
        fi
        actual_sha="$(sha256sum "$local_path" | awk '{print $1}')"
        if [[ "$actual_sha" != "$ARTIFACT_EXPECTED_SHA256" ]]; then
            step_fail "staged artifact $ARTIFACT_ID checksum mismatch: expected $ARTIFACT_EXPECTED_SHA256, actual $actual_sha" "Do not overwrite or fetch over this file. Replace $local_path with the verified file from $ARTIFACT_URL_VARIABLE, following MANUAL-FETCH.md Section B." "sha256sum $(printf '%q' "$local_path")" "grep '^${ARTIFACT_LOCK_KEY} ' $(printf '%q' "$REPO_ROOT/versions.lock")"
            ARTIFACT_RESOLUTION_STATUS='failed'
            return 1
        fi
        ARTIFACT_RESOLVED_PATH="$local_path"
        ARTIFACT_RESOLVED_SOURCE='manual'
        ARTIFACT_RESOLUTION_STATUS='resolved'
        step_ok "artifact $ARTIFACT_ID resolved from source manual at $local_path (SHA-256 verified)"
        return 0
    fi

    if ! declare -p "$ARTIFACT_URL_VARIABLE" >/dev/null 2>&1; then
        url=''
    else
        url="${!ARTIFACT_URL_VARIABLE-}"
    fi
    if [[ -z "$url" ]]; then
        if [[ "$ARTIFACT_REQUIRED" == yes ]]; then
            step_fail "required artifact $ARTIFACT_ID is absent at $local_path and $ARTIFACT_URL_VARIABLE is unset" "Stage the verified file at $local_path or set $ARTIFACT_URL_VARIABLE to its Artifactory generic-file URL; see MANUAL-FETCH.md Section B." "awk -F= -v key=$(printf %q "$ARTIFACT_URL_VARIABLE") '\$1 == key {print key \" is configured (value redacted)\"; found=1} END {if (!found) print key \" is unset\"}' $(printf '%q' "$CONFIG_FILE")" "grep '^${ARTIFACT_LOCK_KEY} ' $(printf '%q' "$REPO_ROOT/versions.lock")" "ls -ld $(printf '%q' "$(dirname "$local_path")")"
            ARTIFACT_RESOLUTION_STATUS='failed'
            return 1
        fi
        ARTIFACT_RESOLUTION_STATUS='skipped'
        step_skip "optional artifact $ARTIFACT_ID is absent at $local_path and $ARTIFACT_URL_VARIABLE is unset" "configured registry mirrors remain the fallback"
        return 2
    fi

    if ! url_info="$(artifact_safe_url_parts "$url" "$ART_HOST" 2>/dev/null)"; then
        if [[ "$ARTIFACT_REQUIRED" == yes ]]; then
            step_fail "artifact $ARTIFACT_ID URL is not a credential-free HTTPS URL on ART_HOST; expected SHA-256 $ARTIFACT_EXPECTED_SHA256, actual unavailable" "Set $ARTIFACT_URL_VARIABLE to the administrator-supplied HTTPS Artifactory generic-file URL and see MANUAL-FETCH.md Section B." "getent hosts $(printf '%q' "$ART_HOST")" "awk -F= -v key=$(printf %q "$ARTIFACT_URL_VARIABLE") '\$1 == key {print key \" is configured (value redacted)\"; found=1} END {if (!found) print key \" is unset\"}' $(printf '%q' "$CONFIG_FILE")"
            ARTIFACT_RESOLUTION_STATUS='failed'
            return 1
        fi
        ARTIFACT_RESOLUTION_STATUS='skipped'
        step_skip "optional artifact $ARTIFACT_ID URL is invalid; expected SHA-256 $ARTIFACT_EXPECTED_SHA256, actual unavailable" "URL value withheld; correct $ARTIFACT_URL_VARIABLE or leave it unset to use the registry mirror"
        return 2
    fi
    mapfile -t _artifact_url_parts <<< "$url_info"
    host="${_artifact_url_parts[0]}"
    connect="${_artifact_url_parts[1]}"
    safe_url="${_artifact_url_parts[2]}"
    ARTIFACT_HOST="$host"
    ARTIFACT_CONNECT="$connect"
    ARTIFACT_SAFE_URL="$safe_url"

    if [[ "$mode" == check-only ]]; then
        local head_response='' head_headers='' head_status='000' head_exit=1 content_length='not returned'
        if head_response="$(curl --head --silent --show-error --connect-timeout 5 --max-time 10 --dump-header - --output /dev/null --write-out $'\n%{http_code}' "$url" 2>/dev/null)"; then
            head_exit=0
            head_status="${head_response##*$'\n'}"
            head_headers="${head_response%$'\n'*}"
        else
            head_headers="$head_response"
        fi
        content_length="$(awk 'tolower($1) == "content-length:" {gsub("\\r", "", $2); value=$2} END {if (value != "") print value}' <<< "$head_headers")"
        [[ -n "$content_length" ]] || content_length='not returned'
        if ((head_exit == 0)) && [[ "$head_status" =~ ^2[0-9][0-9]$ ]]; then
            ARTIFACT_RESOLUTION_STATUS='available'
            ARTIFACT_RESOLVED_SOURCE='Artifactory (HEAD only)'
            step_ok "artifact $ARTIFACT_ID is not staged; $ARTIFACT_URL_VARIABLE HEAD returned HTTP $head_status, Content-Length $content_length at $safe_url; no body downloaded"
            return 0
        fi
        if [[ "$ARTIFACT_REQUIRED" == yes ]]; then
            step_fail "artifact $ARTIFACT_ID is not staged; $ARTIFACT_URL_VARIABLE HEAD failed at $safe_url (HTTP $head_status, Content-Length $content_length)" "Check Artifactory reachability and CA trust, or stage a verified file at $local_path; see MANUAL-FETCH.md Section B." "getent hosts $(printf '%q' "$host")" "printf '' | openssl s_client -connect $(printf '%q' "$connect") -servername $(printf '%q' "$host") 2>&1 | tail -n 10" "grep '^${ARTIFACT_LOCK_KEY} ' $(printf '%q' "$REPO_ROOT/versions.lock")"
            ARTIFACT_RESOLUTION_STATUS='failed'
            return 1
        fi
        ARTIFACT_RESOLUTION_STATUS='skipped'
        step_skip "optional artifact $ARTIFACT_ID HEAD failed at $safe_url (HTTP $head_status, Content-Length $content_length)" "system images will use the configured registry mirrors"
        artifact_network_summary "$host" "$connect"
        return 2
    fi

    if [[ "$DRY_RUN" == true ]]; then
        ARTIFACT_RESOLUTION_STATUS='would-fetch'
        ARTIFACT_RESOLVED_SOURCE='Artifactory (dry-run; not fetched)'
        step_skip "artifact $ARTIFACT_ID is absent at $local_path; dry-run would fetch from $safe_url, verify SHA-256, and stage it" "URL value withheld; no directory, file, or permission changes made"
        return 3
    fi
    if ! command -v curl >/dev/null 2>&1; then
        if [[ "$ARTIFACT_REQUIRED" == yes ]]; then
            step_fail "curl is unavailable for artifact $ARTIFACT_ID; expected SHA-256 $ARTIFACT_EXPECTED_SHA256, actual unavailable" "Install curl through DNF or stage the verified file at $local_path; see MANUAL-FETCH.md Section B." "command -v curl" "rpm -q curl"
            ARTIFACT_RESOLUTION_STATUS='failed'
            return 1
        fi
        ARTIFACT_RESOLUTION_STATUS='skipped'
        step_skip "curl is unavailable for optional artifact $ARTIFACT_ID" "system images will use the configured registry mirrors"
        return 2
    fi

    download_tmp="$(mktemp "${TMPDIR:-/tmp}/artifact-${ARTIFACT_ID}.XXXXXX")" || download_tmp=''
    fetch_log="$(mktemp "${TMPDIR:-/tmp}/artifact-${ARTIFACT_ID}-curl.XXXXXX")" || fetch_log=''
    status_file="$(mktemp "${TMPDIR:-/tmp}/artifact-${ARTIFACT_ID}-status.XXXXXX")" || status_file=''
    if [[ -z "$download_tmp$fetch_log$status_file" ]]; then
        rm -f -- "$download_tmp" "$fetch_log" "$status_file" 2>/dev/null || true
        if [[ "$ARTIFACT_REQUIRED" == yes ]]; then
            step_fail "could not create temporary files for artifact $ARTIFACT_ID; expected SHA-256 $ARTIFACT_EXPECTED_SHA256, actual unavailable" "Check temporary storage, or stage the verified file at $local_path; see MANUAL-FETCH.md Section B." "df -hP /tmp" "ls -ld /tmp"
            ARTIFACT_RESOLUTION_STATUS='failed'
            return 1
        fi
        ARTIFACT_RESOLUTION_STATUS='skipped'
        step_skip "could not create temporary files for optional artifact $ARTIFACT_ID" "system images will use the configured registry mirrors"
        return 2
    fi
    curl_exit=0
    if curl --fail --silent --show-error --connect-timeout 10 --max-time 900 --output "$download_tmp" --write-out '%{http_code}' "$url" >"$status_file" 2>"$fetch_log"; then :; else curl_exit=$?; fi
    http_status="$(cat "$status_file" 2>/dev/null || printf '000')"
    curl_summary="$(sed -E 's#https?://[^[:space:]]+#<URL>#g' "$fetch_log" | tail -n 4 | tr '\n' '; ')"
    if [[ -s "$download_tmp" ]]; then actual_sha="$(sha256sum "$download_tmp" | awk '{print $1}')"; fi
    if ((curl_exit == 0)) && [[ "$http_status" == 200 && "$actual_sha" == "$ARTIFACT_EXPECTED_SHA256" ]]; then
        destination_dir="$(dirname "$local_path")"
        file_mode=0644
        [[ "$ARTIFACT_KIND" == binary ]] && file_mode=0755
        staged_tmp=''
        if install -d -o "$(id -u)" -g "$(id -g)" -m 0750 "$destination_dir"; then
            staged_tmp="$(mktemp "$destination_dir/.artifact-${ARTIFACT_ID}.XXXXXX")" || staged_tmp=''
        fi
        if [[ -n "$staged_tmp" ]] && install -o "$(id -u)" -g "$(id -g)" -m "$file_mode" "$download_tmp" "$staged_tmp" && mv -f -- "$staged_tmp" "$local_path"; then
            rm -f -- "$download_tmp" "$fetch_log" "$status_file"
            ARTIFACT_RESOLVED_PATH="$local_path"
            ARTIFACT_RESOLVED_SOURCE='Artifactory'
            ARTIFACT_RESOLUTION_STATUS='resolved'
            step_ok "artifact $ARTIFACT_ID downloaded from Artifactory, SHA-256 verified, and staged at $local_path"
            return 0
        fi
        rm -f -- "$staged_tmp" "$download_tmp" "$fetch_log" "$status_file" 2>/dev/null || true
        stage_error='; verified download could not be staged'
        http_status="$http_status; stage failed"
    else
        rm -f -- "$download_tmp" "$fetch_log" "$status_file" 2>/dev/null || true
    fi
    if [[ "$ARTIFACT_REQUIRED" == yes ]]; then
        step_fail "artifact $ARTIFACT_ID fetch failed at $safe_url (curl exit $curl_exit, HTTP $http_status)$stage_error: ${curl_summary:-no curl error text}; expected SHA-256 $ARTIFACT_EXPECTED_SHA256, actual $actual_sha" "Set $ARTIFACT_URL_VARIABLE to the administrator-supplied URL or manually stage a verified file at $local_path; see MANUAL-FETCH.md Section B." "getent hosts $(printf '%q' "$host")" "printf '' | openssl s_client -connect $(printf %q "$connect") -servername $(printf %q "$host") 2>&1 | tail -n 10" "grep '^${ARTIFACT_LOCK_KEY} ' $(printf %q "$REPO_ROOT/versions.lock")"
        ARTIFACT_RESOLUTION_STATUS='failed'
        return 1
    fi
    ARTIFACT_RESOLUTION_STATUS='skipped'
    step_skip "optional artifact $ARTIFACT_ID fetch failed at $safe_url (curl exit $curl_exit, HTTP $http_status)$stage_error: ${curl_summary:-no curl error text}; expected SHA-256 $ARTIFACT_EXPECTED_SHA256, actual $actual_sha" "invalid files were not staged; system images will use the configured registry mirrors unless explicitly required. URL credentials, path, and query were withheld."
    artifact_network_summary "$host" "$connect"
    return 2
}
