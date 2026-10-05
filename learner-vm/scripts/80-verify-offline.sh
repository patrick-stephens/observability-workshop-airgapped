#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="80-verify-offline"
# CHANGE: Direct missing Podman images to the configured Artifactory pull path; separate bundles are not used.
SCRIPT_VERSION="2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
UNKNOWN_ARGUMENTS=()
for argument in "$@"; do
	case "$argument" in
		--dry-run) DRY_RUN=true ;;
		*) UNKNOWN_ARGUMENTS+=("$argument") ;;
	esac
done
source "$SCRIPT_DIR/lib.sh"
begin_report
for argument in "${UNKNOWN_ARGUMENTS[@]}"; do
	step_fail "unknown argument: $argument" "Run learner-vm/scripts/80-verify-offline.sh [--dry-run]." "printf '%s\\n' --dry-run"
done
if ((EUID != 0)) && [[ "$DRY_RUN" == false ]]; then
	step_fail "offline verification requires root for the rootful store and temporary egress rules" "Run sudo learner-vm/scripts/80-verify-offline.sh after scripts 10-70." "id -u" "sudo -n true"
	end_report "rerun with sudo on the learner VM after provisioning"
	exit 1
elif ((EUID != 0)); then
	step_skip "root is required for real store/firewall checks; dry-run continues" "rerun with sudo on the learner VM"
fi

CURATED="$REPO_ROOT/content/extracted/curated.json"
EXTERNAL_IMAGES="$REPO_ROOT/content/extracted/external-images.txt"
COMMANDS="$REPO_ROOT/content/extracted/commands.json"
SYSTEM_IMAGES="$REPO_ROOT/content/vendor/k3s/k3s-images.txt"
K3S_MANIFEST="$REPO_ROOT/content/repos/opentelemetry/_vendored/app_pod.yaml"
REPORT_FILE="$REPO_ROOT/learner-vm/verify-report.md"
REPORT_TMP=''
PROBE_LOG=''
FIREWALL_CLEANUP_FAILED=false
FIREWALL_COMMENT="o11y-offline-${BASHPID}"
declare -a BLOCKED_V4=()
declare -a BLOCKED_V6=()
declare -a GENERATED_IMAGES=()
declare -a GENERATED_K3S_IMAGES=()
BUILD_CONTEXT=''
SMOKE_IMAGE="localhost/o11y-offline-smoke:${BASHPID}"
SMOKE_IMAGE_OWNED=false
PROBE_IMAGE=''
PROBE_IMAGE_OWNED=false

cleanup_firewall() {
	local address
	local -a remaining_v4=() remaining_v6=()
	for address in "${BLOCKED_V4[@]}"; do
		if iptables -w 5 -C OUTPUT -d "$address/32" -m comment --comment "$FIREWALL_COMMENT" -j REJECT >/dev/null 2>&1; then
			if ! iptables -w 5 -D OUTPUT -d "$address/32" -m comment --comment "$FIREWALL_COMMENT" -j REJECT >/dev/null 2>&1; then FIREWALL_CLEANUP_FAILED=true; remaining_v4+=("$address"); fi
		fi
	done
	for address in "${BLOCKED_V6[@]}"; do
		if ip6tables -w 5 -C OUTPUT -d "$address/128" -m comment --comment "$FIREWALL_COMMENT" -j REJECT >/dev/null 2>&1; then
			if ! ip6tables -w 5 -D OUTPUT -d "$address/128" -m comment --comment "$FIREWALL_COMMENT" -j REJECT >/dev/null 2>&1; then FIREWALL_CLEANUP_FAILED=true; remaining_v6+=("$address"); fi
		fi
	done
	BLOCKED_V4=("${remaining_v4[@]}")
	BLOCKED_V6=("${remaining_v6[@]}")
}

cleanup() {
	cleanup_firewall
	if [[ "$FIREWALL_CLEANUP_FAILED" == true ]]; then printf '[%s] FATAL: could not remove every temporary rule tagged %s\n' "$SCRIPT_NAME" "$FIREWALL_COMMENT" >&2; fi
	if [[ "$DRY_RUN" == false && "$PROBE_IMAGE_OWNED" == true && -n "$PROBE_IMAGE" ]] && command -v podman >/dev/null 2>&1 && ! podman image rm "$PROBE_IMAGE" >/dev/null 2>&1; then printf '[%s] FATAL: could not remove temporary probe image %s\n' "$SCRIPT_NAME" "$PROBE_IMAGE" >&2; fi
	if [[ "$DRY_RUN" == false && "$SMOKE_IMAGE_OWNED" == true && -n "$SMOKE_IMAGE" ]] && command -v podman >/dev/null 2>&1 && ! podman image rm "$SMOKE_IMAGE" >/dev/null 2>&1; then printf '[%s] FATAL: could not remove temporary smoke image %s\n' "$SCRIPT_NAME" "$SMOKE_IMAGE" >&2; fi
	[[ -z "$BUILD_CONTEXT" ]] || rm -rf -- "$BUILD_CONTEXT"
	[[ -z "$PROBE_LOG" ]] || rm -f -- "$PROBE_LOG"
	[[ -z "$REPORT_TMP" ]] || rm -f -- "$REPORT_TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

record_result() {
	[[ "$DRY_RUN" == true || -z "$REPORT_TMP" ]] || printf '%s\n' "$*" >> "$REPORT_TMP"
}

normalize_image() {
	local image="$1" first="${1%%/*}"
	if [[ "$image" == */* ]]; then
		if [[ "$first" == *.* || "$first" == *:* || "$first" == localhost ]]; then printf '%s' "$image"; else printf 'docker.io/%s' "$image"; fi
	else
		printf 'docker.io/library/%s' "$image"
	fi
}

load_image_sets() {
	if ! command -v python3 >/dev/null 2>&1; then
		step_fail "Python 3 is unavailable for the committed image catalogs" "Run learner-vm/scripts/20-install-tooling.sh and restore commands.json and curated.json." "command -v python3" "rpm -q python3"
		return 1
	fi
	mapfile -t GENERATED_IMAGES < <(python3 - "$EXTERNAL_IMAGES" "$CURATED" "$COMMANDS" <<'PY'
import json,sys
images=set()
def normalise(value):
    first=value.split("/",1)[0]
    if "/" in value:
        return value if ("." in first or ":" in first or first=="localhost") else "docker.io/"+value
    return "docker.io/library/"+value
with open(sys.argv[1],encoding="utf-8") as source:
    images.update(normalise(line.split("#",1)[0].strip()) for line in source if line.split("#",1)[0].strip())
with open(sys.argv[2],encoding="utf-8") as source: curated=json.load(source)
for track in curated.values():
    for run in track.get("runs",[]):
        if run.get("requires_k3s"): continue
        for key in ("image","images"):
            value=run.get(key,[])
            if isinstance(value,str): value=[value]
            if isinstance(value,list): images.update(item if item.startswith(("localhost/","docker.io/","ghcr.io/","quay.io/")) else normalise(item) for item in value if isinstance(item,str) and item)
with open(sys.argv[3],encoding="utf-8") as source: commands=json.load(source)
for track in commands.values():
    for lab in track.get("labs",[]):
        for command in lab.get("commands",[]):
            if command.get("type")=="build" and command.get("preload_status")!="INTERACTIVE" and command.get("tag"):
                images.add(command["tag"])
print("\n".join(sorted(images)))
PY
)
	mapfile -t GENERATED_K3S_IMAGES < <(python3 - "$SYSTEM_IMAGES" "$CURATED" "$K3S_MANIFEST" <<'PY'
import json,sys
images=set()
with open(sys.argv[1],encoding="utf-8") as source:
    images.update(line.strip() for line in source if line.strip() and not line.lstrip().startswith("#"))
with open(sys.argv[2],encoding="utf-8") as source: curated=json.load(source)
for track in curated.values():
    for run in track.get("runs",[]):
        if run.get("requires_k3s"):
            for key in ("image","images"):
                value=run.get(key,[])
                if isinstance(value,str): value=[value]
                if isinstance(value,list): images.update(item for item in value if isinstance(item,str) and item)
with open(sys.argv[3],encoding="utf-8") as source:
    for line in source:
        stripped=line.strip()
        if stripped.startswith("image:"):
            images.add(stripped.split(":",1)[1].strip().strip("\\\"'"))
print("\n".join(sorted(images)))
PY
)
	[[ -n "${GENERATED_IMAGES[*]}" && -n "${GENERATED_K3S_IMAGES[*]}" ]]
}

curated_entries() {
	python3 - "$CURATED" <<'PY'
import json,sys
with open(sys.argv[1],encoding="utf-8") as source: data=json.load(source)
for track,values in data.items():
    for entry in values.get("runs",[]): print(track+"\t"+entry.get("name",""))
PY
}

verify_podman_images() {
	local image
	for image in "${GENERATED_IMAGES[@]}"; do
		if podman image exists "$image" >/dev/null 2>&1; then
			step_ok "rootful Podman image is preloaded: $image"
			record_result "- PASS Podman image: $image"
		else
			step_fail "required rootful Podman image is missing: $image" "Check the configured Artifactory mirror, then rerun learner-vm/scripts/60-load-images.sh; locally built images are reconstructed from the vendored commands and contexts." "podman images --no-trunc" "grep -F $(printf %q "$image") $(printf %q "$EXTERNAL_IMAGES")" "cat $(printf %q "$REPO_ROOT/content/extracted/built-tags.txt")" "sed -n '1,100p' /etc/containers/registries.conf"
			record_result "- FAIL Podman image: $image"
		fi
	done
}

verify_k3s_images() {
	local image image_list
	image_list="$(/usr/local/bin/k3s ctr -n k8s.io images list 2>/dev/null || true)"
	for image in "${GENERATED_K3S_IMAGES[@]}"; do
		if awk -v reference="$image" '$1 == reference {found=1} END {exit !found}' <<< "$image_list"; then
			step_ok "k3s containerd has required reference: $image"
			record_result "- PASS k3s image: $image"
		else
			step_fail "required k3s containerd image reference is missing: $image" "Run learner-vm/scripts/62-k3s-images.sh; external images use k3s crictl pull and local images use Podman save/import." "/usr/local/bin/k3s crictl images" "/usr/local/bin/k3s ctr -n k8s.io images list" "/usr/local/bin/k3s crictl --help" "journalctl -u k3s -b --no-pager | tail -n 15"
			record_result "- FAIL k3s image: $image"
		fi
	done
}

run_curated_entries() {
	local phase="$1" track entry status failed=false
	while IFS=$'\t' read -r track entry; do
		[[ -n "$track" && -n "$entry" ]] || continue
		if [[ "$DRY_RUN" == true ]]; then
			run "$REPO_ROOT/bin/run-workshop.sh --dry-run $(printf %q "$track") $(printf %q "$entry")"
			run "$REPO_ROOT/bin/stop-workshop.sh --dry-run $(printf %q "$track") $(printf %q "$entry")"
			continue
		fi
		if "$REPO_ROOT/bin/run-workshop.sh" "$track" "$entry"; then
			step_ok "$phase curated startup/readiness passed for $track/$entry"
			record_result "- PASS $phase curated entry: $track/$entry"
			if "$REPO_ROOT/bin/stop-workshop.sh" "$track" "$entry"; then
				step_ok "$phase curated cleanup passed for $track/$entry"
				record_result "- PASS $phase cleanup: $track/$entry"
			else
				step_fail "$phase cleanup failed for $track/$entry" "Run stop-workshop.sh for this exact entry and inspect its state file; do not remove unrelated resources." "cat /var/lib/lab-setup/workshop-state/*.json" "podman ps -a --no-trunc" "/usr/local/bin/k3s kubectl get pods -A -o wide"
				record_result "- FAIL $phase cleanup: $track/$entry"
				failed=true
				break
			fi
		else
			status=$?
			step_fail "$phase curated startup/readiness failed for $track/$entry (exit $status)" "Use the dispatcher report, fix the image or readiness issue, and retry this entry individually." "tail -n 30 $(printf %q "$LOG_FILE")" "podman ps -a --no-trunc" "/usr/local/bin/k3s kubectl get pods -A -o wide"
			record_result "- FAIL $phase curated entry: $track/$entry (exit $status)"
			if [[ -s "/var/lib/lab-setup/workshop-state/$(printf '%s-%s' "$track" "$entry" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.-]/-/g').json" ]]; then
				if ! "$REPO_ROOT/bin/stop-workshop.sh" "$track" "$entry"; then
					step_fail "$phase cleanup after startup failure did not complete for $track/$entry" "Inspect and stop only the resource recorded for this entry before continuing." "cat /var/lib/lab-setup/workshop-state/*.json" "podman ps -a --no-trunc" "/usr/local/bin/k3s kubectl get pods -A -o wide"
					failed=true
					break
				fi
			fi
			failed=true
		fi
	done < <(curated_entries)
	[[ "$failed" == false ]]
}

setup_report() {
	if [[ "$DRY_RUN" == true ]]; then return 0; fi
	REPORT_TMP=$(mktemp "$REPO_ROOT/learner-vm/.verify-report.XXXXXX") || REPORT_TMP=''
	if [[ -z "$REPORT_TMP" ]]; then
		step_fail "could not create verify-report.md temporary file" "Check repository write permissions and free space." "ls -ld $(printf %q "$REPO_ROOT/learner-vm")" "df -hP $(printf %q "$REPO_ROOT")"
		return 1
	fi
	{
		printf '# Offline Verification Report\n\n'
		printf 'Date: %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		printf 'Script versions: 80-verify-offline %s, run-workshop 1, stop-workshop 1.\n\n' "$SCRIPT_VERSION"
		printf 'Artifactory availability and offline behaviour are tested only by this operator-run verification on the learner VM.\n\n'
		printf '## Part A: Artifactory Reachable\n\n'
	} > "$REPORT_TMP"
}

for input in "$CURATED" "$EXTERNAL_IMAGES" "$COMMANDS" "$SYSTEM_IMAGES" "$K3S_MANIFEST"; do
	if [[ ! -s "$input" ]]; then
		step_fail "required offline verification input is missing: ${input#"$REPO_ROOT/"}" "Restore the generated metadata and vendored k3s files from the repository ZIP." "ls -l $(printf %q "$input")" "find $(printf %q "$REPO_ROOT/content") -maxdepth 4 -type f -print"
	fi
done
if ((${#UNKNOWN_ARGUMENTS[@]} > 0)); then
	step_fail "unexpected arguments were supplied" "Run learner-vm/scripts/80-verify-offline.sh [--dry-run]." "printf '%s\\n' --dry-run"
fi
if ! load_image_sets; then
	step_fail "could not construct the required Podman and k3s image sets" "Validate external-images.txt, curated.json, commands.json, and k3s-images.txt with Python 3." "python3 -m json.tool $(printf %q "$CURATED")" "python3 -m json.tool $(printf %q "$COMMANDS")" "cat $(printf %q "$SYSTEM_IMAGES")"
fi

if [[ "$DRY_RUN" == true ]]; then
	step_skip "Part A rootful-store, image, k3s, docs, wrapper, and curated checks are target-side; entries will be run and stopped individually only during operator execution" "run without --dry-run on the learner VM"
	log "would verify ${#GENERATED_IMAGES[@]} Podman references and ${#GENERATED_K3S_IMAGES[@]} k3s references"
	while IFS=$'\t' read -r track entry; do
		[[ -n "$track" && -n "$entry" ]] || continue
		log "would start/check/stop curated entry individually: $track/$entry"
	done < <(curated_entries)
	step_skip "Part B egress blocking, forced pull failure, repeated runs, and temporary build are target-side and intentionally untouched in dry-run" "Part B uses per-IP iptables/ip6tables rules only after safe prerequisites pass"
	step_skip "verify-report.md is written only by the operator-run verification; this dry-run created no files or rules" "$REPORT_FILE"
	end_report "review this plan; no learner-VM test or Artifactory verification is claimed"
	exit 0
fi

if ! setup_report; then
	end_report "fix the report path before verification"
	exit 1
fi

if [[ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || printf unknown)" == false ]]; then
	step_ok "Podman is using the rootful store"
	record_result "- PASS Podman rootful store"
else
	step_fail "Podman is not confirmed rootful" "Run scripts 20 and 50, then use the absolute /usr/local/bin wrappers against /usr/bin/podman." "podman info --debug 2>&1 | tail -n 20" "id"
	record_result "- FAIL Podman rootful store"
fi
if command -v runuser >/dev/null 2>&1; then
	for wrapper in docker podman; do
		if runuser -u "$WORKSHOP_USER" -- "/usr/local/bin/$wrapper" --version >/dev/null 2>&1; then
			step_ok "$WORKSHOP_USER wrapper works: $wrapper"
			record_result "- PASS $WORKSHOP_USER $wrapper wrapper"
		else
			step_fail "$WORKSHOP_USER wrapper failed: $wrapper" "Verify PASSWORDLESS_SUDO=yes and rerun scripts/50-user-setup.sh." "sudo -l -U $(printf %q "$WORKSHOP_USER")" "head -n 12 $(printf %q "/usr/local/bin/$wrapper")" "command -v podman"
			record_result "- FAIL $WORKSHOP_USER $wrapper wrapper"
		fi
		if "/usr/local/bin/$wrapper" --version >/dev/null 2>&1; then
			step_ok "root invocation works without wrapper recursion: $wrapper"
			record_result "- PASS root $wrapper wrapper"
		else
			step_fail "root invocation failed for $wrapper wrapper" "Ensure the wrapper directly calls /usr/bin/podman when EUID is zero." "head -n 12 $(printf %q "/usr/local/bin/$wrapper")" "command -v /usr/bin/podman"
			record_result "- FAIL root $wrapper wrapper"
		fi
	done
else
	step_fail "runuser is unavailable for engineer wrapper tests" "Install shadow-utils with script 20." "command -v runuser" "rpm -q shadow-utils"
fi

verify_podman_images
if [[ -x /usr/local/bin/k3s ]]; then
	if /usr/local/bin/k3s kubectl wait --for=condition=Ready node --all --timeout=30s >/dev/null 2>&1; then
		step_ok "k3s node is Ready"
		record_result "- PASS k3s node Ready"
	else
		step_fail "k3s node is not Ready" "Run script 45 and inspect the k3s service before image checks." "/usr/local/bin/k3s kubectl get nodes -o wide" "journalctl -u k3s -b --no-pager | tail -n 20" "cat /etc/rancher/k3s/registries.yaml"
		record_result "- FAIL k3s node Ready"
	fi
	if /usr/local/bin/k3s kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed" {bad=1; print} END {exit bad}'; then
		step_ok "k3s system workloads are Running or Completed"
		record_result "- PASS k3s system workloads"
	else
		step_fail "k3s system workloads are unhealthy" "Inspect kube-system events, images, and the k3s journal." "/usr/local/bin/k3s kubectl get pods -n kube-system -o wide" "/usr/local/bin/k3s kubectl get events -n kube-system --sort-by=.lastTimestamp | tail -n 15" "journalctl -u k3s -b --no-pager | tail -n 20"
		record_result "- FAIL k3s system workloads"
	fi
	verify_k3s_images
else
	step_fail "pinned k3s CLI is missing" "Run learner-vm/scripts/45-k3s-install.sh before offline verification." "ls -l /usr/local/bin/k3s" "rpm -q k3s-selinux"
	record_result "- FAIL k3s CLI"
fi
if curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:$DOCS_PORT/" >/dev/null; then
	step_ok "mirrored docs server responds on localhost:$DOCS_PORT"
	record_result "- PASS docs localhost:$DOCS_PORT"
else
	step_fail "mirrored documentation is unavailable on localhost:$DOCS_PORT" "Run learner-vm/scripts/70-quickstart.sh and restore content/docs." "systemctl status o11y-workshop-docs.service --no-pager" "curl -v --connect-timeout 3 http://127.0.0.1:$DOCS_PORT/" "find $(printf %q "$DOCS_ROOT") -type f -name index.html"
	record_result "- FAIL docs localhost:$DOCS_PORT"
fi
run_curated_entries 'Part A' || true

printf '\n## Part B: Artifactory Blocked\n\n' >> "$REPORT_TMP"

establish_firewall_block() {
	local v4 v6 address added=0
	if ! command -v iptables >/dev/null 2>&1 || ! command -v iptables-save >/dev/null 2>&1; then return 1; fi
	if systemctl is-active --quiet firewalld 2>/dev/null; then return 1; fi
	if [[ -n "${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}${all_proxy:-}" ]]; then return 1; fi
	v4="$(getent ahostsv4 "$ART_HOST" | awk '{print $1}' | sort -u)"
	v6="$(getent ahostsv6 "$ART_HOST" | awk '{print $1}' | sort -u)"
	[[ -n "$v4$v6" ]] || return 1
	[[ -z "$v6" ]] || command -v ip6tables >/dev/null 2>&1 || return 1
	iptables-save >/dev/null 2>&1 || return 1
	if [[ -n "$v6" ]] && ! ip6tables-save >/dev/null 2>&1; then return 1; fi
	while IFS= read -r address; do
		[[ -n "$address" ]] || continue
		BLOCKED_V4+=("$address")
		if ! iptables -w 5 -I OUTPUT 1 -d "$address/32" -m comment --comment "$FIREWALL_COMMENT" -j REJECT; then unset 'BLOCKED_V4[-1]'; cleanup_firewall; return 1; fi
		added=1
	done <<< "$v4"
	while IFS= read -r address; do
		[[ -n "$address" ]] || continue
		BLOCKED_V6+=("$address")
		if ! ip6tables -w 5 -I OUTPUT 1 -d "$address/128" -m comment --comment "$FIREWALL_COMMENT" -j REJECT; then unset 'BLOCKED_V6[-1]'; cleanup_firewall; return 1; fi
		added=1
	done <<< "$v6"
	((added == 1))
}

if establish_firewall_block; then
	step_ok "temporary egress rejection is active only for resolved Artifactory IPs ($ART_HOST)"
	record_result "- PASS temporary firewall rules installed for Artifactory IPs only"
	probe_image="docker.io/library/busybox:1.36-offline-probe-${BASHPID}"
	if podman image exists "$probe_image" >/dev/null 2>&1; then
		step_fail "offline pull probe tag unexpectedly already exists" "Use a fresh probe tag and rerun; no existing image is removed." "podman image inspect $(printf %q "$probe_image")"
		record_result "- FAIL unique offline pull probe tag was not unique"
	else
		PROBE_LOG=$(mktemp "${TMPDIR:-/tmp}/o11y-offline-pull.XXXXXX") || PROBE_LOG=''
		if [[ -z "$PROBE_LOG" ]]; then
			step_fail "could not create the offline pull probe log" "Check temporary storage before Part B." "df -hP /tmp"
		else
			PROBE_IMAGE="$probe_image"
			PROBE_IMAGE_OWNED=true
			if podman pull "$probe_image" >"$PROBE_LOG" 2>&1; then
				step_fail "unexpectedly pulled a deliberately unique image while Artifactory egress was blocked" "Inspect registries.conf and mirror/upstream routing; only the unique tag from this run will be removed." "podman image inspect $(printf %q "$probe_image")" "iptables -w 5 -S OUTPUT" "ip6tables -w 5 -S OUTPUT"
				record_result "- FAIL blocked pull probe unexpectedly succeeded"
			elif grep -Eiq 'connection refused|connection reset|timed out|i/o timeout|network is unreachable|no route to host|dial tcp' "$PROBE_LOG"; then
				step_ok "unique Podman pull failed with a network transport error while Artifactory IP egress was blocked"
				record_result "- PASS blocked unique image pull failed due to a network transport error"
			else
				step_fail "unique Podman pull failed but did not prove an egress block" "Inspect the pull error and verify the mirror route while preserving all preloaded images." "tail -n 15 $(printf %q "$PROBE_LOG")" "iptables -w 5 -S OUTPUT" "ip6tables -w 5 -S OUTPUT"
				record_result "- FAIL unique pull error did not establish that egress was blocked"
			fi
		fi
	fi
	PROBE_LOG=$(mktemp "${TMPDIR:-/tmp}/o11y-offline-curl.XXXXXX") || PROBE_LOG=''
	if [[ -z "$PROBE_LOG" ]]; then
		step_fail "could not create the Artifactory socket probe log" "Check temporary storage before confirming Part B." "df -hP /tmp"
	elif art_status="$(curl --noproxy '*' -sS --connect-timeout 3 --max-time 5 -o /dev/null -w '%{http_code}' "https://$ART_HOST/v2/" 2>"$PROBE_LOG")"; then
		step_fail "Artifactory HTTPS remained reachable during the egress block (HTTP $art_status)" "Review the resolved Artifactory addresses and remove only this script's tagged rules." "getent ahosts $(printf %q "$ART_HOST")" "iptables -w 5 -S OUTPUT" "ip6tables -w 5 -S OUTPUT"
		record_result "- FAIL Artifactory HTTPS was still reachable"
	elif grep -Eiq 'failed to connect|connection refused|connection reset|timed out|network is unreachable|no route to host' "$PROBE_LOG"; then
		step_ok "Artifactory socket probe failed at the network layer while its resolved IPs were blocked"
		record_result "- PASS Artifactory HTTPS socket blocked"
	else
		step_fail "Artifactory HTTPS probe failed for a reason other than confirmed egress blocking" "Check the certificate and DNS before interpreting this offline result." "tail -n 10 $(printf %q "$PROBE_LOG")" "getent ahosts $(printf %q "$ART_HOST")" "iptables -w 5 -S OUTPUT" "ip6tables -w 5 -S OUTPUT"
		record_result "- FAIL Artifactory HTTPS failure did not prove an egress block"
	fi
	rm -f -- "$PROBE_LOG"
	PROBE_LOG=''
	verify_podman_images
	verify_k3s_images
	run_curated_entries 'Part B' || true
	if podman image exists docker.io/library/busybox:1.36 >/dev/null 2>&1; then
		if podman image inspect "$SMOKE_IMAGE" >/dev/null 2>&1; then
			step_fail "offline smoke image tag unexpectedly exists" "Investigate the unique tag before building; no existing image is overwritten." "podman image inspect $(printf %q "$SMOKE_IMAGE")"
		else
			SMOKE_IMAGE_OWNED=true
			BUILD_CONTEXT=$(mktemp -d "${TMPDIR:-/tmp}/o11y-offline-build.XXXXXX") || BUILD_CONTEXT=''
			if [[ -z "$BUILD_CONTEXT" ]]; then
				step_fail "could not create temporary offline build context" "Check temporary storage." "df -hP /tmp"
			else
				printf 'FROM docker.io/library/busybox:1.36\nLABEL o11y.offline.smoke="true"\nCMD ["true"]\n' > "$BUILD_CONTEXT/Containerfile"
				if podman build --pull=never -t "$SMOKE_IMAGE" "$BUILD_CONTEXT" >/dev/null 2>&1 && podman image exists "$SMOKE_IMAGE" >/dev/null 2>&1; then
					step_ok "attendee-style Podman build succeeded offline from the preloaded BusyBox base without changing a workshop source tree"
					record_result "- PASS temporary offline build from preloaded docker.io/library/busybox:1.36"
				else
				step_fail "attendee-style build failed with Artifactory blocked" "Ensure docker.io/library/busybox:1.36 is preloaded and the build uses only the temporary context." "podman image inspect docker.io/library/busybox:1.36" "podman build --pull=never -t $(printf %q "$SMOKE_IMAGE") $(printf %q "$BUILD_CONTEXT")" "podman info --debug 2>&1 | tail -n 15"
				record_result "- FAIL temporary offline build"
			fi
			if ! podman image exists "$SMOKE_IMAGE" >/dev/null 2>&1; then
				SMOKE_IMAGE_OWNED=false
				SMOKE_IMAGE=''
			elif podman image rm "$SMOKE_IMAGE" >/dev/null 2>&1; then
				SMOKE_IMAGE_OWNED=false
				SMOKE_IMAGE=''
				step_ok "removed only the temporary offline smoke image created by this script"
				record_result "- PASS temporary offline build image removed"
			else
				step_fail "could not remove the temporary offline smoke image" "Remove only the image tag created by this verification after confirming its exact name." "podman image inspect $(printf %q "$SMOKE_IMAGE")" "podman image rm $(printf %q "$SMOKE_IMAGE")"
				record_result "- FAIL temporary offline build image cleanup; EXIT trap will retry"
			fi
		fi
	fi
	fi
	cleanup_firewall
	if [[ "$FIREWALL_CLEANUP_FAILED" == false ]]; then
		step_ok "removed only the temporary Artifactory egress rules created by this script"
		record_result "- PASS temporary firewall rules removed; pre-existing rules were not flushed or restored wholesale"
	else
		step_fail "one or more temporary Artifactory firewall rules could not be removed" "Restore only rules tagged $FIREWALL_COMMENT, then compare the firewall with the pre-test state." "iptables -w 5 -S OUTPUT" "ip6tables -w 5 -S OUTPUT" "iptables-save" "ip6tables-save"
		record_result "- FAIL firewall cleanup; inspect only rules tagged $FIREWALL_COMMENT"
	fi
else
	if [[ "$FIREWALL_CLEANUP_FAILED" == true ]]; then
		step_fail "Part B setup failed and a temporary firewall rule could not be removed" "Remove only rules tagged $FIREWALL_COMMENT, then compare firewall state before any rerun." "iptables -w 5 -S OUTPUT" "ip6tables -w 5 -S OUTPUT" "iptables-save" "ip6tables-save"
		record_result "- FAIL Part B setup rollback; inspect rules tagged $FIREWALL_COMMENT"
	else
		step_skip "Part B skipped because reversible per-IP blocking could not be established safely; no firewall rule was retained" "requires resolvable Artifactory addresses, working iptables-save, no active firewalld, no proxy, and ip6tables when IPv6 addresses resolve"
		record_result "- SKIP Part B: safe reversible firewall blocking prerequisites were not met; no pull/build offline claim"
	fi
fi

if [[ -n "$REPORT_TMP" ]]; then
	{
		printf '\n## Interpretation\n\n'
		printf 'This report records only the host and commands shown above. A skipped Part B is not evidence of offline operation. Artifactory-based k3s pulls are considered verified only when this report includes successful learner-network CRI pull results.\n'
	} >> "$REPORT_TMP"
	if install -o root -g root -m 0644 "$REPORT_TMP" "$REPORT_FILE"; then
		step_ok "wrote operator verification results to $REPORT_FILE"
	else
		step_fail "could not install verify-report.md" "Check repository ownership and disk space." "ls -ld $(printf %q "$REPO_ROOT/learner-vm")" "df -hP $(printf %q "$REPO_ROOT")"
	fi
fi

end_report "Review verify-report.md and the full log. Any skipped offline block is explicitly inconclusive; no learner-VM verification is claimed by dry-run."
((FAIL_COUNT == 0))
