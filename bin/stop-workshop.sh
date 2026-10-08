#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$BIN_DIR/.." && pwd)"
SCRIPT_NAME="stop-workshop"
# CHANGE: Hold the dispatcher lock outside cleanup subprocesses so detached container monitors cannot retain it.
SCRIPT_VERSION="2"
SCRIPT_DIR="$REPO_ROOT/learner-vm/scripts"
DRY_RUN=false
INTERNAL_ROOT=false
LOCK_HELD=false
UNKNOWN_ARGUMENTS=()
for argument in "$@"; do
	case "$argument" in
		--dry-run) DRY_RUN=true ;;
		--_root) INTERNAL_ROOT=true ;;
		--_lock-held) LOCK_HELD=true ;;
		*) UNKNOWN_ARGUMENTS+=("$argument") ;;
	esac
done
source "$SCRIPT_DIR/lib.sh"
begin_report
if [[ "$DRY_RUN" == false && "$INTERNAL_ROOT" == false && "$EUID" -ne 0 ]]; then
	if command -v sudo >/dev/null 2>&1 && sudo -n "$SCRIPT_PATH" --_root "${UNKNOWN_ARGUMENTS[@]}"; then exit 0; fi
	step_fail "workshop stop could not access the rootful runtime" "Run sudo stop-workshop.sh <track> <entry-name>; verify PASSWORDLESS_SUDO=yes." "id -u" "sudo -n true" "sudo -l -U $(printf %q "$WORKSHOP_USER")"
	end_report "correct the rootful wrapper policy and retry"
	exit 1
fi
if ((${#UNKNOWN_ARGUMENTS[@]} < 1)); then
	step_skip "track is required" "run stop-workshop.sh <track> [entry-name] [--dry-run]"
	end_report "supply the curated track and entry name shown by run-workshop.sh"
	exit 2
fi

TRACK="${UNKNOWN_ARGUMENTS[0]}"
ENTRY_NAME="${UNKNOWN_ARGUMENTS[1]:-}"
if ((${#UNKNOWN_ARGUMENTS[@]} > 2)); then
	step_fail "too many stop selectors were supplied" "Run stop-workshop.sh <track> [entry-name] [--dry-run]." "find /var/lib/lab-setup/workshop-state -maxdepth 1 -type f -name '*.json' -print" "cat /var/lib/lab-setup/workshop-state/*.json"
	end_report "select at most one track and one entry"
	exit 2
fi
if [[ "$DRY_RUN" == false && "$LOCK_HELD" == false ]]; then
	if ! command -v flock >/dev/null 2>&1 || [[ ! -d /var/lock || ! -w /var/lock ]]; then
		step_fail "could not establish the workshop dispatcher lock" "Install util-linux and ensure /var/lock is writable by root before stopping curated entries." "command -v flock" "ls -ld /var/lock" "rpm -q util-linux"
		end_report "fix the dispatcher lock before stopping a resource"
		exit 1
	fi
	if flock --nonblock --close --conflict-exit-code 75 /var/lock/lab-workshop.lock "$SCRIPT_PATH" --_root --_lock-held "${UNKNOWN_ARGUMENTS[@]}"; then exit 0; else
		lock_status=$?
		if ((lock_status == 75)); then
			step_fail "another run-workshop or stop-workshop operation is in progress" "Wait for the active dispatcher to finish; do not change resources concurrently." "flock -n /var/lock/lab-workshop.lock true" "ps -ef | grep -E '[r]un-workshop|[s]top-workshop'"
			end_report "retry after the active resource operation completes"
			exit 1
		fi
		exit "$lock_status"
	fi
fi
if [[ -z "$ENTRY_NAME" ]]; then
	STATE_DIR='/var/lib/lab-setup/workshop-state'
	mapfile -t TRACK_STATES < <(python3 - "$STATE_DIR" "$TRACK" <<'PY'
import glob,json,os,sys
for path in glob.glob(os.path.join(sys.argv[1],"*.json")):
    try:
        with open(path,encoding="utf-8") as source: state=json.load(source)
    except (OSError,json.JSONDecodeError):
        continue
    if state.get("track")==sys.argv[2]: print(path)
PY
)
	if ((${#TRACK_STATES[@]} == 0)); then
		step_skip "no active workshop entry is recorded for track $TRACK" "$STATE_DIR"
		end_report "start a curated entry with run-workshop.sh before stopping it"
		exit 0
	elif ((${#TRACK_STATES[@]} > 1)); then
		step_fail "multiple active entries are recorded for track $TRACK; no resource was touched" "Provide the exact entry name and investigate why more than one state file exists." "find $(printf %q "$STATE_DIR") -maxdepth 1 -type f -name '*.json' -print" "cat $(printf %q "$STATE_DIR")/*.json"
		end_report "select the exact recorded entry before cleanup"
		exit 1
	fi
	ENTRY_NAME="$(python3 - "${TRACK_STATES[0]}" <<'PY'
import json,sys
with open(sys.argv[1],encoding="utf-8") as source: print(json.load(source).get("entry",""))
PY
)"
fi
SLUG="$(printf '%s-%s' "$TRACK" "$ENTRY_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.-]/-/g')"
STATE_FILE="/var/lib/lab-setup/workshop-state/$SLUG.json"
K3S='/usr/local/bin/k3s'
quote_command() {
	local output='' argument
	for argument in "$@"; do output+=" $(printf '%q' "$argument")"; done
	printf '%s' "${output# }"
}
if [[ ! -s "$STATE_FILE" ]]; then
	step_skip "no state record exists for $TRACK/$ENTRY_NAME; no resources were touched" "$STATE_FILE"
	end_report "run the selected entry with run-workshop.sh before stopping it"
	exit 0
fi

state_type="$(jq -r '.type // empty' "$STATE_FILE")"
container="$(jq -r '.container // empty' "$STATE_FILE")"
pod="$(jq -r '.pod // empty' "$STATE_FILE")"
namespace="$(jq -r '.namespace // empty' "$STATE_FILE")"
resource="$(jq -r '.resource // empty' "$STATE_FILE")"
expected_uid="$(jq -r '.uid // empty' "$STATE_FILE")"
forward_pid="$(jq -r '.pid // empty' "$STATE_FILE")"

if [[ "$DRY_RUN" == true ]]; then
	step_skip "would stop only recorded resource type=$state_type container=$container pod=$pod resource=$resource" "$STATE_FILE"
	end_report "rerun without --dry-run to stop this recorded entry"
	exit 0
fi

stop_ok=true
case "$state_type" in
	podman-container)
		if podman container exists "$container" >/dev/null 2>&1; then
			actual_uid="$(podman container inspect --format '{{.Id}}' "$container" 2>/dev/null || true)"
			managed="$(podman container inspect --format '{{ index .Config.Labels "o11y-workshop.managed" }}' "$container" 2>/dev/null || true)"
			if [[ "$actual_uid" != "$expected_uid" || "$managed" != 1 ]]; then
				step_fail "container identity/ownership differs from the state record" "Do not remove it manually; inspect the recorded ID and container label first." "podman inspect $(printf %q "$container")" "cat $(printf %q "$STATE_FILE")"
				stop_ok=false
			elif run "podman stop --time 10 $(printf %q "$container") && podman rm $(printf %q "$container")"; then
				step_ok "stopped and removed only managed container $container"
			else
				step_fail "could not stop managed container $container" "Inspect its state and retry stop-workshop.sh for this entry." "podman inspect $(printf %q "$container")" "podman logs $(printf %q "$container") 2>&1 | tail -n 15"
				stop_ok=false
			fi
		else
			step_skip "managed container is already absent" "$container"
		fi
		;;
	podman-pod|podman-manifest)
		if podman pod exists "$pod" >/dev/null 2>&1; then
			actual_uid="$(podman pod inspect --format '{{.Id}}' "$pod" 2>/dev/null || true)"
			if [[ -n "$expected_uid" && "$actual_uid" != "$expected_uid" ]]; then
				step_fail "pod identity differs from the state record" "Leave it untouched and inspect the recorded Podman pod ID." "podman pod inspect $(printf %q "$pod")" "cat $(printf %q "$STATE_FILE")"
				stop_ok=false
			elif run "podman pod rm --force $(printf %q "$pod")"; then
				step_ok "stopped and removed only the recorded pod $pod"
			else
				step_fail "could not stop recorded Podman pod $pod" "Inspect the pod and retry stop-workshop.sh for this entry." "podman pod inspect $(printf %q "$pod")" "podman pod ps --no-trunc"
				stop_ok=false
			fi
		else
			step_skip "recorded Podman pod is already absent" "$pod"
		fi
		;;
	k3s)
		if [[ "$forward_pid" =~ ^[0-9]+$ ]] && kill -0 "$forward_pid" 2>/dev/null; then
			process_args="$(ps -p "$forward_pid" -o args= 2>/dev/null || true)"
			if [[ "$process_args" == *"kubectl port-forward"* && "$process_args" == *"$resource"* ]]; then
				if run "kill $(printf %q "$forward_pid")"; then step_ok "stopped only the recorded localhost port-forward"; else step_fail "could not stop recorded port-forward PID $forward_pid" "Inspect the exact process and PID file before retrying." "ps -p $(printf %q "$forward_pid") -o pid,args"; stop_ok=false; fi
			else
				step_fail "recorded PID no longer identifies this workshop port-forward" "Do not kill the unrelated process; inspect the state and process arguments." "ps -p $(printf %q "$forward_pid") -o pid,args" "cat $(printf %q "$STATE_FILE")"
				stop_ok=false
			fi
		else
			step_skip "recorded port-forward is no longer running" "PID ${forward_pid:-absent}"
		fi
		if [[ -n "$resource" ]]; then
			resource_kind="${resource%%/*}"
			resource_name="${resource#*/}"
			if [[ -n "$namespace" ]]; then namespace_args=(-n "$namespace"); else namespace_args=(); fi
			if current_uid="$("$K3S" kubectl get "$resource_kind" "$resource_name" "${namespace_args[@]}" -o jsonpath='{.metadata.uid}' 2>/dev/null)"; then
				if [[ "$current_uid" != "$expected_uid" ]]; then
					step_fail "k3s resource UID differs from the recorded run" "Leave the changed resource untouched and inspect it before cleanup." "$K3S kubectl get $(printf %q "$resource_kind") $(printf %q "$resource_name") -o yaml" "cat $(printf %q "$STATE_FILE")"
					stop_ok=false
				elif run "$(quote_command "$K3S" kubectl delete "$resource_kind" "$resource_name" "${namespace_args[@]}")"; then
					step_ok "deleted only the recorded k3s resource $resource"
				else
					step_fail "could not delete recorded k3s resource $resource" "Inspect the named resource and rerun stop-workshop.sh." "$K3S kubectl describe $(printf %q "$resource_kind") $(printf %q "$resource_name")" "journalctl -u k3s -b --no-pager | tail -n 15"
					stop_ok=false
				fi
			else
				step_skip "recorded k3s resource is already absent" "$resource"
			fi
		fi
		;;
	*)
		step_fail "state record has an unknown resource type: $state_type" "Inspect $STATE_FILE; do not remove unrecognized resources." "cat $(printf '%q' "$STATE_FILE")" "find /var/lib/lab-setup/workshop-state -maxdepth 1 -type f -print"
		stop_ok=false
		;;
esac

if [[ "$stop_ok" == true ]]; then
	if run "rm -f -- $(printf %q "$STATE_FILE")"; then step_ok "removed state for $TRACK/$ENTRY_NAME"; else step_fail "could not remove workshop state record" "Remove the exact state file after confirming the resource is stopped." "ls -l $(printf %q "$STATE_FILE")"; fi
fi
end_report "Check the report; only the resource named in this state record was considered for cleanup."
((FAIL_COUNT == 0))
