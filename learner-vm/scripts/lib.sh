# shellcheck shell=bash
: "${SCRIPT_NAME:?Set SCRIPT_NAME before sourcing scripts/lib.sh}"
: "${SCRIPT_VERSION:?Set SCRIPT_VERSION before sourcing scripts/lib.sh}"

LOG_DIR="/var/log/lab-setup"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
DRY_RUN="${DRY_RUN:-false}"
OK_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
REPORT_ACTIVE=0
declare -a FAIL_ENTRIES=()
declare -a DIAGNOSTIC_LINES=()
declare -a SKIP_ENTRIES=()

log() {
    local line="[${SCRIPT_NAME}] $*"
    printf '%s\n' "$line"
    if mkdir -p "$LOG_DIR" 2>/dev/null && printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null; then
        :
    fi
}

step_ok() {
    ((OK_COUNT += 1))
    log "✓ $*"
}

step_skip() {
    local entry="$1: $2"
    ((SKIP_COUNT += 1))
    SKIP_ENTRIES+=("$entry")
    log "→ SKIPPED: $entry"
}

step_fail() {
    local what="$1"
    local fix_hint="$2"
    shift 2
    local failure_id="F$((FAIL_COUNT + 1))"
    local diagnostic output status line line_count

    ((FAIL_COUNT += 1))
    FAIL_ENTRIES+=("${failure_id}: ${what} | FIX: ${fix_hint}")
    log "✗ ${failure_id}: ${what} | FIX: ${fix_hint}"

    for diagnostic in "$@"; do
        DIAGNOSTIC_LINES+=("${failure_id} diagnostic: ${diagnostic}")
        if output="$(bash -c "$diagnostic" 2>&1)"; then
            status=0
        else
            status=$?
        fi
        if [[ -z "$output" ]]; then
            DIAGNOSTIC_LINES+=("  (no output; exit ${status})")
            continue
        fi
        line_count=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            DIAGNOSTIC_LINES+=("  ${line}")
            ((line_count += 1))
            if ((line_count >= 15)); then
                break
            fi
        done <<<"$output"
    done
}

begin_report() {
    REPORT_ACTIVE=1
}

end_report() {
    local hostname_value timestamp_value git_sha result skipped_summary
    local report_lines=() diagnostic_budget line

    REPORT_ACTIVE=0
    if hostname_value="$(hostname 2>/dev/null)"; then :; else hostname_value="unavailable"; fi
    if timestamp_value="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"; then :; else timestamp_value="unavailable"; fi
    if command -v git >/dev/null 2>&1 && git_sha="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" rev-parse --short HEAD 2>/dev/null)"; then
        :
    else
        git_sha="unavailable"
    fi

    if ((FAIL_COUNT > 0)); then result="FAILED"; else result="PASSED"; fi
    if ((SKIP_COUNT > 0)); then
        skipped_summary="SKIPPED (${SKIP_COUNT}): $(IFS='; '; printf '%s' "${SKIP_ENTRIES[*]}")"
    else
        skipped_summary="SKIPPED (0): none"
    fi

    report_lines+=("===== REPORT BEGIN =====")
    report_lines+=("SCRIPT: ${SCRIPT_NAME} ${SCRIPT_VERSION}")
    report_lines+=("HOSTNAME: ${hostname_value}")
    report_lines+=("UTC: ${timestamp_value}")
    report_lines+=("REPO_GIT_SHA: ${git_sha}")
    report_lines+=("RESULT: ${result} (ok=${OK_COUNT} failed=${FAIL_COUNT} skipped=${SKIP_COUNT})")
    report_lines+=("${FAIL_ENTRIES[@]}")
    report_lines+=("OK: ${OK_COUNT} checks; full log: ${LOG_FILE}")
    report_lines+=("${skipped_summary}")
    report_lines+=("NEXT: ${NEXT_LINE:-Review the report and follow README-FIRST.md.}")

    diagnostic_budget=$((60 - ${#report_lines[@]} - 1))
    if ((diagnostic_budget > 0)); then
        for line in "${DIAGNOSTIC_LINES[@]}"; do
            if ((diagnostic_budget <= 0)); then break; fi
            report_lines+=("${line}")
            ((diagnostic_budget -= 1))
        done
    fi
    if ((${#DIAGNOSTIC_LINES[@]} > 0 && ${#report_lines[@]} < 59)); then
        local emitted_diagnostics=$((60 - ${#report_lines[@]} - 1))
        if ((${#DIAGNOSTIC_LINES[@]} > emitted_diagnostics)); then
            report_lines+=("  (diagnostics truncated to keep report under 60 lines)")
        fi
    fi
    report_lines+=("===== REPORT END =====")

    printf '%s\n' "${report_lines[@]}"
}

run() {
    local rendered
    if [[ "$DRY_RUN" == "true" ]]; then
        printf -v rendered '%q ' "$@"
        log "[dry-run] WOULD: ${rendered% }"
        return 0
    fi
    "$@"
}

require_or_skip() {
    local binary="$1"
    local description="$2"
    if command -v "$binary" >/dev/null 2>&1; then
        return 0
    fi
    step_skip "$description" "$binary is not installed"
    return 1
}
