# shellcheck shell=bash
set -euo pipefail

# CHANGE: Keep dry-run reports on stdout without creating or appending system logs.
LIB_VERSION="2"
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
VENDOR_BIN="$REPO_ROOT/content/bin"
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
    local registry="${1:-${DOCKER_REGISTRY:-}}" host path
    if [[ "$registry" != */* ]]; then
        printf '[%s] FATAL: DOCKER_REGISTRY must contain a host and path: %s. FIX: correct DOCKER_REGISTRY in learner-vm/lab-vm.conf.\n' "$SCRIPT_NAME" "${registry:-<empty>}" >&2
        return 1
    fi
    host="${registry%%/*}"
    path="${registry#*/}"
    if [[ -z "$host" || -z "$path" || "$path" == /* || "$path" == */ || "$host" =~ [[:space:]] || "$path" =~ [[:space:]] || ! "$host" =~ ^[[:alnum:].-]+(:[0-9]+)?$ ]]; then
        printf '[%s] FATAL: malformed DOCKER_REGISTRY host or path: %s. FIX: correct DOCKER_REGISTRY in learner-vm/lab-vm.conf.\n' "$SCRIPT_NAME" "$registry" >&2
        return 1
    fi
    REG_HOST="$host"
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
