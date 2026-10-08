#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$BIN_DIR/.." && pwd)"
SCRIPT_NAME="run-workshop"
# CHANGE: Publish curated port arrays directly for standalone containers and managed pods; retain the parent flock supervisor.
SCRIPT_VERSION="3"
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
	step_fail "curated workshop startup could not elevate to the rootful store" "Run sudo run-workshop.sh <track> <entry-name>; verify PASSWORDLESS_SUDO=yes with script 50." "id -u" "sudo -n true" "sudo -l -U $(printf %q "$WORKSHOP_USER")"
	end_report "fix the sudo wrapper policy and retry this entry"
	exit 1
fi

CURATED="$REPO_ROOT/content/extracted/curated.json"
STATE_DIR='/var/lib/lab-setup/workshop-state'
K3S='/usr/local/bin/k3s'
CURATED_ENTRY=''

quote_command() {
	local output='' argument
	for argument in "$@"; do output+=" $(printf '%q' "$argument")"; done
	printf '%s' "${output# }"
}

local_port() {
	local mapping="$1"
	local -a port_parts=()
	IFS=: read -r -a port_parts <<< "$mapping"
	case "${#port_parts[@]}" in
		2) printf '127.0.0.1:%s:%s' "${port_parts[0]}" "${port_parts[1]}" ;;
		3) printf '%s' "$mapping" ;;
		4) printf '%s' "$mapping" ;;
		*) printf '%s' "$mapping" ;;
	esac
}

print_tracks() {
	python3 - "$CURATED" <<'PY'
import json,sys
with open(sys.argv[1],encoding="utf-8") as source: data=json.load(source)
for track,value in data.items():
    print(f"{track}: {', '.join(item.get('name','<unnamed>') for item in value.get('runs',[]))}")
PY
}

print_entries() {
	local track="$1"
	python3 - "$CURATED" "$track" <<'PY'
import json,sys
with open(sys.argv[1],encoding="utf-8") as source: data=json.load(source)
for item in data.get(sys.argv[2],{}).get("runs",[]):
    mode="k3s" if item.get("requires_k3s") else item.get("exec","podman")
    print(f"{item.get('name','<unnamed>')} ({mode})")
PY
}

if [[ ! -s "$CURATED" ]]; then
	step_fail "curated run metadata is missing" "Restore content/extracted/curated.json from the repository ZIP." "ls -l $(printf %q "$CURATED")" "find $(printf %q "$REPO_ROOT/content/extracted") -maxdepth 1 -type f -name curated.json"
	end_report "restore curated.json before selecting an entry"
	exit 1
fi
if ((${#UNKNOWN_ARGUMENTS[@]} < 1)); then
	step_skip "track was not selected; available curated entries follow" "run-workshop.sh <track> <entry-name>"
	print_tracks
	end_report "select one track and entry; run only one curated service at a time"
	exit 0
fi
TRACK="${UNKNOWN_ARGUMENTS[0]}"
ENTRY_NAME="${UNKNOWN_ARGUMENTS[1]:-}"
if ((${#UNKNOWN_ARGUMENTS[@]} > 2)); then
	step_fail "too many workshop selectors were supplied" "Run run-workshop.sh <track> [entry-name] [--dry-run] and choose one curated entry." "run-workshop.sh $(printf %q "$TRACK")" "python3 -m json.tool $(printf %q "$CURATED")"
	end_report "select at most one track and one entry"
	exit 2
fi
if [[ -z "$ENTRY_NAME" ]]; then
	step_skip "entry name was not selected; available entries for $TRACK follow" "run-workshop.sh $TRACK <entry-name>"
	print_entries "$TRACK"
	end_report "select one entry from the list and run it by name"
	exit 0
fi

CURATED_ENTRY="$(python3 - "$CURATED" "$TRACK" "$ENTRY_NAME" <<'PY'
import json,sys
with open(sys.argv[1],encoding="utf-8") as source: data=json.load(source)
entry=next((item for item in data.get(sys.argv[2],{}).get("runs",[]) if item.get("name")==sys.argv[3]),None)
if entry is not None: print(json.dumps(entry,separators=(",",":")))
PY
)"
if [[ -z "$CURATED_ENTRY" ]]; then
	step_fail "unknown curated entry $TRACK/$ENTRY_NAME" "Choose an entry printed by run-workshop.sh $TRACK." "python3 -m json.tool $(printf %q "$CURATED")" "printf '%s\\n' $(printf %q "$TRACK")"
	print_entries "$TRACK"
	end_report "choose a listed track/entry pair"
	exit 2
fi

SLUG="$(printf '%s-%s' "$TRACK" "$ENTRY_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.-]/-/g')"
STATE_FILE="$STATE_DIR/$SLUG.json"
write_state() {
	local type="$1" container="${2:-}" pod="${3:-}" manifest="${4:-}" namespace="${5:-}" resource="${6:-}" uid="${7:-}" pid="${8:-}"
	local temporary
	temporary=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 1
	python3 - "$temporary" "$TRACK" "$ENTRY_NAME" "$type" "$container" "$pod" "$manifest" "$namespace" "$resource" "$uid" "$pid" <<'PY' || { rm -f -- "$temporary"; return 1; }
import json,sys
keys=("track","entry","type","container","pod","manifest","namespace","resource","uid","pid")
values=sys.argv[2:]
with open(sys.argv[1],"w",encoding="utf-8") as output: json.dump(dict(zip(keys,values)),output,indent=2); output.write("\n")
PY
	if ! chmod 0600 "$temporary" || ! mv -f -- "$temporary" "$STATE_FILE"; then rm -f -- "$temporary"; return 1; fi
}

if [[ "$DRY_RUN" == true ]]; then
	python3 - "$CURATED_ENTRY" <<'PY'
import json,sys
entry=json.loads(sys.argv[1])
print(f"name={entry['name']} exec={entry.get('exec','')} requires_k3s={entry.get('requires_k3s',False)} image={entry.get('image','')} manifest={entry.get('source',{}).get('manifest','')}")
print("check="+json.dumps(entry.get("check",{}),separators=(",",":")))
for step in entry.get("steps",[]): print("step="+step)
PY
	step_skip "dry-run selected $TRACK/$ENTRY_NAME; no service, pod, container, state file, or port-forward was created" "stop it later with stop-workshop.sh $TRACK $ENTRY_NAME"
	end_report "review the selected entry's exact source and readiness fields; rerun without --dry-run to start it"
	exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
	step_fail "jq is unavailable for curated entry parsing" "Install jq with learner-vm/scripts/20-install-tooling.sh." "command -v jq" "rpm -q jq"
	end_report "install jq before dispatching curated entries"
	exit 1
fi
if ! install -d -o root -g root -m 0700 "$STATE_DIR"; then
	step_fail "could not create workshop state directory" "Create the root-owned state directory at $STATE_DIR." "ls -ld /var/lib/lab-setup" "df -hP /var/lib"
	end_report "fix the state directory before starting resources"
	exit 1
fi
if [[ "$DRY_RUN" == false && "$LOCK_HELD" == false ]]; then
	if ! command -v flock >/dev/null 2>&1 || [[ ! -d /var/lock || ! -w /var/lock ]]; then
		step_fail "could not establish the workshop dispatcher lock" "Install util-linux and ensure /var/lock is writable by root before starting curated entries." "command -v flock" "ls -ld /var/lock" "rpm -q util-linux"
		end_report "fix the dispatcher lock before starting a resource"
		exit 1
	fi
	if flock --nonblock --close --conflict-exit-code 75 /var/lock/lab-workshop.lock "$SCRIPT_PATH" --_root --_lock-held "${UNKNOWN_ARGUMENTS[@]}"; then exit 0; else
		lock_status=$?
		if ((lock_status == 75)); then
			step_fail "another run-workshop or stop-workshop operation is in progress" "Wait for the active dispatcher to finish; do not start a second curated entry." "flock -n /var/lock/lab-workshop.lock true" "ps -ef | grep -E '[r]un-workshop|[s]top-workshop'"
			end_report "retry after the active resource operation completes"
			exit 1
		fi
		exit "$lock_status"
	fi
fi
existing_state="$(find "$STATE_DIR" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null || true)"
if [[ -n "$existing_state" ]]; then
	step_fail "another curated entry may already be active" "Stop the matching tracked entry with stop-workshop.sh before starting a conflicting service." "find $(printf %q "$STATE_DIR") -maxdepth 1 -type f -name '*.json' -print" "cat $(printf %q "$existing_state")"
	end_report "stop the tracked entry before starting another"
	exit 1
fi
if [[ -e "$STATE_FILE" ]]; then
	step_fail "state file already exists for $TRACK/$ENTRY_NAME" "Inspect and stop the matching recorded resource with stop-workshop.sh." "cat $(printf %q "$STATE_FILE")"
	end_report "resolve the existing state before restarting"
	exit 1
fi

ENTRY_TYPE="$(jq -r '.requires_k3s // false | if . then "k3s" else "podman" end' <<< "$CURATED_ENTRY")"
check_type="$(jq -r '.check.type // "http"' <<< "$CURATED_ENTRY")"
check_url="$(jq -r '.check.url // empty' <<< "$CURATED_ENTRY")"
check_expect="$(jq -r '.check.expect // empty' <<< "$CURATED_ENTRY")"
resource_container="lab-$SLUG"
manifest="$(jq -r '.source.manifest // empty' <<< "$CURATED_ENTRY")"
namespace="$(jq -r '.source.namespace // empty' <<< "$CURATED_ENTRY")"

wait_http() {
	local url="$1" expected="$2" attempt body
	url="${url/localhost/127.0.0.1}"
	for ((attempt=1; attempt<=30; attempt++)); do
		if body="$(curl -fsS --connect-timeout 2 --max-time 5 "$url" 2>/dev/null)"; then
			if [[ -z "$expected" ]] || grep -Fq -- "$expected" <<< "$body"; then return 0; fi
		fi
		sleep 2
	done
	return 1
}

if [[ "$ENTRY_TYPE" == k3s ]]; then
	if [[ -z "$manifest" || ! -s "$REPO_ROOT/$manifest" ]]; then
		step_fail "k3s curated entry has no readable source manifest" "Restore the vendored manifest named in curated.json." "jq -r '.opentelemetry.runs[] | select(.name==\"$ENTRY_NAME\") | .source.manifest' $(printf %q "$CURATED")" "ls -l $(printf %q "$REPO_ROOT/$manifest")"
		end_report "restore the manifest before running the k3s entry"
		exit 1
	fi
	step_count="$(jq '.steps | length' <<< "$CURATED_ENTRY")"
	if ((step_count < 3)); then
		step_fail "k3s curated entry is missing apply/wait/port-forward steps" "Regenerate curated.json with an explicit k3s resource wait and localhost port-forward." "jq '.opentelemetry.runs[] | select(.name==\"$ENTRY_NAME\") | .steps' $(printf %q "$CURATED")"
		end_report "repair k3s steps before applying a manifest"
		exit 1
	fi
	apply_step="$(jq -r '.steps[0]' <<< "$CURATED_ENTRY")"
	wait_step="$(jq -r '.steps[1]' <<< "$CURATED_ENTRY")"
	forward_step="$(jq -r '.steps[2]' <<< "$CURATED_ENTRY")"
	if [[ "$apply_step" != "kubectl apply -f $manifest" || "$wait_step" != *"kubectl wait"* || "$forward_step" != *"kubectl port-forward --address 127.0.0.1"* ]]; then
		step_fail "k3s curated command steps do not match the safe apply/wait/localhost-forward contract" "Correct the k3s entry's steps in content/extracted/curated.json." "jq '.opentelemetry.runs[] | select(.name==\"$ENTRY_NAME\") | .steps' $(printf %q "$CURATED")"
		end_report "repair the curated k3s commands before starting"
		exit 1
	fi
	read -r -a wait_words <<< "$wait_step"
	wait_resource=''
	for word in "${wait_words[@]}"; do
		case "$word" in pod/*|deployment/*|statefulset/*) wait_resource="$word"; break ;; esac
	done
	if [[ -z "$wait_resource" ]]; then
		step_fail "could not determine the named Kubernetes resource from the recorded wait step" "Keep a pod/name, deployment/name, or statefulset/name token in curated.json." "printf '%s\\n' $(printf %q "$wait_step")"
		end_report "correct the wait step before applying"
		exit 1
	fi
	resource_kind="${wait_resource%%/*}"
	resource_name="${wait_resource#*/}"
	if [[ -n "$namespace" ]]; then namespace_args=(-n "$namespace"); else namespace_args=(); fi
	if "$K3S" kubectl get "$resource_kind" "$resource_name" "${namespace_args[@]}" >/dev/null 2>&1; then
		step_fail "refusing to replace pre-existing k3s resource $wait_resource" "Stop or investigate the existing resource before using the curated k3s entry." "$K3S kubectl get $(printf %q "$resource_kind") $(printf %q "$resource_name") -o wide" "$K3S kubectl get $(printf %q "$resource_kind") $(printf %q "$resource_name") -o jsonpath='{.metadata.uid}'"
		end_report "existing resource was left untouched"
		exit 1
	fi
	if "$K3S" kubectl apply -f "$REPO_ROOT/$manifest"; then
		step_ok "applied curated manifest $manifest"
	else
		step_fail "kubectl apply failed for $manifest" "Check k3s service readiness and the vendored manifest path." "$K3S kubectl get nodes -o wide" "journalctl -u k3s -b --no-pager | tail -n 15" "ls -l $(printf %q "$REPO_ROOT/$manifest")"
		end_report "fix the apply failure before waiting or forwarding"
		exit 1
	fi
	if [[ -n "$namespace" ]]; then wait_args=(-n "$namespace"); else wait_args=(); fi
	if "$K3S" kubectl wait --for=condition=Ready "$resource_kind/$resource_name" "${wait_args[@]}" --timeout=120s; then
		step_ok "Kubernetes resource is Ready: $wait_resource"
	else
		"$K3S" kubectl delete "$resource_kind" "$resource_name" "${namespace_args[@]}" >/dev/null 2>&1 || true
		step_fail "Kubernetes resource did not become Ready: $wait_resource" "Check the k3s image store and the original references in the vendored manifest." "$K3S kubectl describe $(printf %q "$resource_kind") $(printf %q "$resource_name") ${namespace_args[*]}" "$K3S crictl images" "journalctl -u k3s -b --no-pager | tail -n 15"
		end_report "resource was removed because this run created it but readiness failed"
		exit 1
	fi
	resource_uid="$("$K3S" kubectl get "$resource_kind" "$resource_name" "${namespace_args[@]}" -o jsonpath='{.metadata.uid}')"
	read -r -a forward_words <<< "$forward_step"
	forward_index=0
	for index in "${!forward_words[@]}"; do [[ "${forward_words[$index]}" == port-forward ]] && forward_index="$index" && break; done
	forward_ports=()
	for ((index=forward_index+1; index<${#forward_words[@]}; index++)); do
		word="${forward_words[$index]}"
		case "$word" in
			--address|-n|--namespace) ((index+=1)); continue ;;
			pod/*|deployment/*|statefulset/*) continue ;;
		esac
		if [[ "$word" == *:* ]]; then forward_ports+=("$word"); fi
	done
	((${#forward_ports[@]} > 0)) || { step_fail "port-forward step has no local:remote port mapping" "Correct the k3s entry's localhost port-forward in curated.json." "printf '%s\\n' $(printf %q "$forward_step")"; end_report "do not leave the created resource running without its forward"; exit 1; }
	forward_log="$LOG_DIR/${SCRIPT_NAME}-${SLUG}-forward.log"
	"$K3S" kubectl port-forward "${namespace_args[@]}" --address 127.0.0.1 "$resource_kind/$resource_name" "${forward_ports[@]}" >"$forward_log" 2>&1 &
	forward_pid=$!
	if ! wait_http "$check_url" "$check_expect"; then
		kill "$forward_pid" 2>/dev/null || true
		"$K3S" kubectl delete "$resource_kind" "$resource_name" "${namespace_args[@]}" >/dev/null 2>&1 || true
		step_fail "k3s readiness check failed at $check_url" "Check the curated expectation and the vendored Pod images." "tail -n 15 $(printf %q "$forward_log")" "$K3S kubectl describe $(printf %q "$resource_kind") $(printf %q "$resource_name") ${namespace_args[*]}" "$K3S crictl images"
		end_report "resources from this failed run were stopped and deleted"
		exit 1
	fi
		if ! write_state k3s '' '' "$manifest" "$namespace" "$resource_kind/$resource_name" "$resource_uid" "$forward_pid"; then
			kill "$forward_pid" 2>/dev/null || true
			if [[ "$("$K3S" kubectl get "$resource_kind" "$resource_name" "${namespace_args[@]}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)" == "$resource_uid" ]]; then "$K3S" kubectl delete "$resource_kind" "$resource_name" "${namespace_args[@]}" >/dev/null 2>&1 || true; fi
			step_fail "could not record k3s resource state for safe cleanup" "Check write access to $STATE_DIR; the resource created by this run was stopped." "ls -ld $(printf %q "$STATE_DIR")" "df -hP /var/lib"
			end_report "state was not recorded; the resource and port-forward from this run were cleaned up"
			exit 1
		fi
	step_ok "k3s entry $TRACK/$ENTRY_NAME is ready at $check_url; state recorded for exact cleanup"
else
	image="$(jq -r '.image // empty' <<< "$CURATED_ENTRY")"
	if [[ -z "$image" ]]; then
		step_fail "Podman curated entry has no image" "Select an entry with an image field or update curated.json to a supported manifest run." "jq --arg track $(printf %q "$TRACK") '.[$track].runs' $(printf %q "$CURATED")"
		end_report "no runtime was started"
		exit 1
	fi
	if [[ -n "$manifest" ]]; then
		manifest_file="$REPO_ROOT/$manifest"
		pod_name="$(awk '/^metadata:/ {inmeta=1; next} inmeta && /^[[:space:]]+name:/ {print $2; exit}' "$manifest_file")"
		[[ -n "$pod_name" ]] || { step_fail "Podman manifest has no metadata.name" "Restore the name in $manifest." "grep -n -A3 '^metadata:' $(printf %q "$manifest_file")"; end_report "no Podman pod was started"; exit 1; }
		if podman pod exists "$pod_name" >/dev/null 2>&1; then
			step_fail "refusing to replace pre-existing Podman pod $pod_name" "Stop or inspect the existing pod before running this entry." "podman pod inspect $(printf %q "$pod_name")" "podman pod ps --no-trunc"
			end_report "existing pod was left untouched"
			exit 1
		fi
		if podman play kube "$manifest_file"; then
			step_ok "started Podman-native manifest as pod $pod_name"
		else
			partial_uid="$(podman pod inspect --format '{{.Id}}' "$pod_name" 2>/dev/null || true)"
			if [[ -n "$partial_uid" ]]; then podman pod rm --force "$partial_uid" >/dev/null 2>&1 || true; fi
			step_fail "podman play kube failed for $manifest" "Check that exact images are loaded in the rootful Podman store." "podman pod ps --no-trunc" "podman images --no-trunc" "podman play kube --help"
			end_report "no state was recorded; resolve the manifest error"
			exit 1
		fi
		pod_uid="$(podman pod inspect --format '{{.Id}}' "$pod_name" 2>/dev/null || true)"
		if [[ -z "$pod_uid" ]]; then
			step_fail "Podman manifest started but its pod ID could not be recorded" "Inspect the newly created named pod and stop it only after confirming its exact ID." "podman pod ps --no-trunc" "podman pod inspect $(printf %q "$pod_name")"
			end_report "readiness was not attempted because the new pod identity is unknown"
			exit 1
		fi
		if ! wait_http "$check_url" "$check_expect"; then
			current_pod_uid="$(podman pod inspect --format '{{.Id}}' "$pod_name" 2>/dev/null || true)"
			if [[ "$current_pod_uid" == "$pod_uid" ]]; then podman pod rm --force "$pod_uid" >/dev/null 2>&1 || true; else step_fail "Podman pod ID changed during readiness check; cleanup left it untouched" "Inspect the pod and remove it only if it is still the resource created by this run." "podman pod inspect $(printf %q "$pod_name")" "podman pod ps --no-trunc"; fi
			step_fail "Podman manifest readiness check failed at $check_url" "Check the curated check expectation and manifest images." "podman pod inspect $(printf %q "$pod_name")" "podman pod logs $(printf %q "$pod_name")" "podman images --no-trunc"
			end_report "the pod created by this run was removed after readiness failed"
			exit 1
		fi
		if ! write_state podman-manifest '' "$pod_name" "$manifest" '' "$pod_name" "$pod_uid"; then
			if [[ "$(podman pod inspect --format '{{.Id}}' "$pod_name" 2>/dev/null || true)" == "$pod_uid" ]]; then podman pod rm --force "$pod_name" >/dev/null 2>&1 || true; fi
			step_fail "could not record Podman manifest state for safe cleanup" "Check write access to $STATE_DIR; the pod created by this run was stopped." "ls -ld $(printf %q "$STATE_DIR")" "podman pod inspect $(printf %q "$pod_name")"
			end_report "state was not recorded; the pod from this run was removed"
			exit 1
		fi
		step_ok "Podman manifest entry $TRACK/$ENTRY_NAME is ready at $check_url"
	else
		ports_json="$(jq -c '.ports // []' <<< "$CURATED_ENTRY")"
		cwd="$(jq -r '.source.cwd // "."' <<< "$CURATED_ENTRY")"
		workdir="$REPO_ROOT/content/repos/$TRACK"
		[[ "$cwd" == . ]] || workdir="$workdir/$cwd"
		has_pod=false
		raw_command="$(jq -r '.source.raw // ""' <<< "$CURATED_ENTRY")"
		[[ "$raw_command" == *"--pod "* ]] && has_pod=true
		command_id="$(printf '%s' "$SLUG" | cut -c1-48)"
		pod_name="$command_id"
		if podman container exists "$resource_container" >/dev/null 2>&1 || podman pod exists "$pod_name" >/dev/null 2>&1; then
			step_fail "managed resource name is already in use for $TRACK/$ENTRY_NAME" "Stop the recorded workshop entry before retrying." "podman container exists $(printf %q "$resource_container")" "podman pod exists $(printf %q "$pod_name")"
			end_report "existing resource was left untouched"
			exit 1
		fi
		if [[ "$has_pod" == true ]]; then
			create_args=(podman pod create --name "$pod_name" --label "o11y-workshop.managed=1" --label "o11y-workshop.track=$TRACK" --label "o11y-workshop.entry=$ENTRY_NAME")
			while IFS= read -r port; do [[ -n "$port" ]] || continue; create_args+=(--publish "$(local_port "$port")"); done < <(jq -r '.[]' <<< "$ports_json")
			if ! run "$(quote_command "${create_args[@]}")"; then
				step_fail "could not create managed Podman pod" "Check local port conflicts and the Podman rootful store." "podman pod ps" "podman info --debug 2>&1 | tail -n 15"
				end_report "podman pod was not started"
				exit 1
			fi
		fi
		start_args=(podman run --detach --name "$resource_container" --label "o11y-workshop.managed=1" --label "o11y-workshop.track=$TRACK" --label "o11y-workshop.entry=$ENTRY_NAME")
		if [[ "$has_pod" == true ]]; then start_args+=(--pod "$pod_name"); fi
		if [[ "$has_pod" == false ]]; then while IFS= read -r port; do [[ -n "$port" ]] || continue; start_args+=(--publish "$(local_port "$port")"); done < <(jq -r '.[]' <<< "$ports_json"); fi
		while IFS= read -r pair; do [[ -n "$pair" ]] || continue; start_args+=(--env "$pair"); done < <(jq -r '.env // {} | to_entries[] | "\(.key)=\(.value)"' <<< "$CURATED_ENTRY")
		while IFS= read -r volume; do
			[[ -n "$volume" ]] || continue
			volume="${volume//\$(pwd)/$workdir}"
			start_args+=(--volume "$volume")
		done < <(jq -r '.volumes[]?' <<< "$CURATED_ENTRY")
		start_args+=("$image")
		while IFS= read -r argument; do [[ -n "$argument" ]] || continue; start_args+=("$argument"); done < <(jq -r '.cmd[]?' <<< "$CURATED_ENTRY")
		if run "cd $(printf %q "$workdir") && $(quote_command "${start_args[@]}")"; then
			step_ok "started rootful Podman entry $TRACK/$ENTRY_NAME"
		else
			if [[ "$has_pod" == true ]]; then podman pod rm -f "$pod_name" >/dev/null 2>&1 || true; fi
			step_fail "Podman run failed for $TRACK/$ENTRY_NAME" "Check the exact curated image, volume path, and host port mappings." "podman images --no-trunc" "podman ps -a --no-trunc" "ls -ld $(printf %q "$workdir")"
			end_report "no active container was recorded"
			exit 1
		fi
		if [[ -n "$check_url" ]]; then
			if ! wait_http "$check_url" "$check_expect"; then
				if [[ "$has_pod" == true ]]; then podman pod rm -f "$pod_name" >/dev/null 2>&1 || true; else podman stop "$resource_container" >/dev/null 2>&1 || true; podman rm "$resource_container" >/dev/null 2>&1 || true; fi
				step_fail "Podman readiness check failed at $check_url" "Check the curated expected text, local port, and image logs." "podman logs $(printf %q "$resource_container") 2>&1 | tail -n 15" "podman inspect $(printf %q "$resource_container")" "curl -v --connect-timeout 3 $(printf %q "$check_url")"
				end_report "the resource created by this run was removed after readiness failed"
				exit 1
			fi
		elif [[ "$check_type" == running ]]; then
			if ! podman container inspect --format '{{.State.Running}}' "$resource_container" | grep -qx true; then
				step_fail "curated Podman container is not running" "Check the source lab image and command in curated.json." "podman ps -a --no-trunc" "podman logs $(printf %q "$resource_container") 2>&1 | tail -n 15"
			fi
		fi
		container_uid="$(podman container inspect --format '{{.Id}}' "$resource_container")"
		if [[ "$has_pod" == true ]]; then
			pod_uid="$(podman pod inspect --format '{{.Id}}' "$pod_name")"
			if ! write_state podman-pod "$resource_container" "$pod_name" '' '' "$pod_name" "$pod_uid"; then
				if [[ "$(podman pod inspect --format '{{.Id}}' "$pod_name" 2>/dev/null || true)" == "$pod_uid" ]]; then podman pod rm --force "$pod_name" >/dev/null 2>&1 || true; fi
				step_fail "could not record Podman pod state for safe cleanup" "Check write access to $STATE_DIR; the pod created by this run was stopped." "ls -ld $(printf %q "$STATE_DIR")" "podman pod inspect $(printf %q "$pod_name")"
				end_report "state was not recorded; the pod from this run was removed"
				exit 1
			fi
		else
			if ! write_state podman-container "$resource_container" '' '' '' "$resource_container" "$container_uid"; then
				actual_uid="$(podman container inspect --format '{{.Id}}' "$resource_container" 2>/dev/null || true)"
				managed="$(podman container inspect --format '{{ index .Config.Labels "o11y-workshop.managed" }}' "$resource_container" 2>/dev/null || true)"
				if [[ "$actual_uid" == "$container_uid" && "$managed" == 1 ]]; then podman stop --time 10 "$resource_container" >/dev/null 2>&1 || true; podman rm "$resource_container" >/dev/null 2>&1 || true; fi
				step_fail "could not record Podman container state for safe cleanup" "Check write access to $STATE_DIR; the container created by this run was stopped." "ls -ld $(printf %q "$STATE_DIR")" "podman inspect $(printf %q "$resource_container")"
				end_report "state was not recorded; the container from this run was removed"
				exit 1
			fi
		fi
		step_ok "Podman entry $TRACK/$ENTRY_NAME is ready"
	fi
fi

end_report "Use stop-workshop.sh $TRACK $ENTRY_NAME to remove only this recorded resource."
((FAIL_COUNT == 0))
