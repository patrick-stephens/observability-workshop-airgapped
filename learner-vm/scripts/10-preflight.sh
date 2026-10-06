#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="10-preflight"
# CHANGE: Verify any staged catalog file before accepting an installed pinned k3s binary.
SCRIPT_VERSION="7"
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
	step_fail "unknown argument: $argument" "Run learner-vm/scripts/10-preflight.sh [--dry-run]." "printf '%s\\n' --dry-run"
done

if [[ "$DRY_RUN" == true ]]; then
	step_skip "root privilege is target-side and was not checked during dry-run" "run the real preflight with sudo on RHEL"
elif ((EUID == 0)); then
	step_ok "running as root"
else
	step_fail "preflight requires root" "Run sudo learner-vm/scripts/10-preflight.sh so system paths and Artifactory configuration can be checked." "id -u"
fi

if [[ "$DRY_RUN" == true ]]; then
	step_skip "RHEL release check is target-side and was not evaluated during dry-run" "this artifact targets RHEL 8.x"
elif [[ -r /etc/redhat-release ]] && grep -Eq 'release 8([.]| )' /etc/redhat-release; then
	step_ok "RHEL 8 release detected: $(</etc/redhat-release)"
else
	step_fail "target must be RHEL 8.x" "Use the RHEL 8.6 learner image before running this preparation sequence." "cat /etc/redhat-release"
fi

if [[ -n "${WORKSHOP_USER:-}" ]]; then
	step_ok "WORKSHOP_USER is configured as $WORKSHOP_USER"
else
	step_fail "WORKSHOP_USER is empty" "Set WORKSHOP_USER=\"engineer\" in learner-vm/lab-vm.conf." "grep '^WORKSHOP_USER=' $(printf '%q' "$CONFIG_FILE")"
fi
if [[ "${PASSWORDLESS_SUDO:-}" == "yes" ]]; then
	step_ok "PASSWORDLESS_SUDO=yes"
else
	step_fail "PASSWORDLESS_SUDO must be yes" "Set PASSWORDLESS_SUDO=\"yes\" in learner-vm/lab-vm.conf for the configured wrappers." "grep '^PASSWORDLESS_SUDO=' $(printf '%q' "$CONFIG_FILE")"
fi

if [[ "$DRY_RUN" == true ]]; then
	step_skip "Artifactory DNS and hosts-file checks are target-side and were not run during dry-run" "$ART_HOST; ART_HOST_IP=${ART_HOST_IP:-<empty>}"
elif [[ -n "${ART_HOST_IP:-}" ]]; then
	if grep -Eq "^[[:space:]]*${ART_HOST_IP//./\\.}[[:space:]].*([[:space:]]|^)${ART_HOST//./\\.}([[:space:]]|$)" /etc/hosts; then
		step_ok "ART_HOST_IP mapping is already present in /etc/hosts"
	else
		host_entry="$(awk -v host="$ART_HOST" '$1 !~ /^#/ { for (i = 2; i <= NF; i++) if ($i == host) { print $1; exit } }' /etc/hosts)"
		if [[ -n "$host_entry" && "$host_entry" != "$ART_HOST_IP" ]]; then
			step_fail "ART_HOST maps to $host_entry instead of ART_HOST_IP" "Correct the conflicting /etc/hosts entry or set the verified ART_HOST_IP in learner-vm/lab-vm.conf." "getent hosts $(printf '%q' "$ART_HOST")" "grep -n $(printf '%q' "$ART_HOST") /etc/hosts"
		elif [[ "$DRY_RUN" == true ]]; then
			step_skip "would add the configured ART_HOST_IP mapping" "$ART_HOST_IP $ART_HOST"
		else
			if run "printf '%s\\n' $(printf '%q' "$ART_HOST_IP $ART_HOST") >> /etc/hosts"; then
				step_ok "added ART_HOST_IP mapping to /etc/hosts"
			else
				step_fail "could not add ART_HOST_IP to /etc/hosts" "Check /etc/hosts permissions and ART_HOST_IP in learner-vm/lab-vm.conf." "tail -n 10 /etc/hosts" "getent hosts $(printf '%q' "$ART_HOST")"
			fi
		fi
	fi
fi

if [[ "$DRY_RUN" == true ]]; then
	:
elif getent hosts "$ART_HOST" >/dev/null 2>&1; then
	step_ok "ART_HOST resolves: $ART_HOST"
elif [[ -n "${ART_HOST_IP:-}" ]]; then
	step_fail "ART_HOST does not resolve despite ART_HOST_IP being configured" "Set a valid ART_HOST_IP in learner-vm/lab-vm.conf and rerun preflight." "getent hosts $(printf '%q' "$ART_HOST")" "grep -n $(printf '%q' "$ART_HOST") /etc/hosts"
else
	step_fail "ART_HOST does not resolve" "Set ART_HOST_IP in learner-vm/lab-vm.conf or repair DNS for ART_HOST before provisioning." "getent hosts $(printf '%q' "$ART_HOST")" "cat /etc/resolv.conf"
fi

if [[ "$DRY_RUN" == true ]]; then
	step_skip "CA certificate existence is target-side and was not inspected during dry-run" "$CA_CERT_SOURCE"
elif [[ -s "$CA_CERT_SOURCE" ]]; then
	step_ok "configured CA certificate exists: $CA_CERT_SOURCE"
else
	step_fail "configured CA certificate is absent" "Provide the CA certificate at CA_CERT_SOURCE in learner-vm/lab-vm.conf before installing registry trust." "ls -l $(printf '%q' "$CA_CERT_SOURCE")" "find /etc/pki/ca-trust/source/anchors -maxdepth 1 -type f -print"
fi

if [[ "$DRY_RUN" == true ]]; then
	step_skip "manual-fetch staging directory presence/creation is target-side and was not checked during dry-run" "$MANUAL_FETCH_DIR"
elif [[ -n "${MANUAL_FETCH_DIR:-}" && -d "$MANUAL_FETCH_DIR" ]]; then
	step_ok "manual-fetch staging directory exists: $MANUAL_FETCH_DIR"
elif [[ -z "${MANUAL_FETCH_DIR:-}" ]]; then
	step_fail "MANUAL_FETCH_DIR is empty" "Set MANUAL_FETCH_DIR=\"/var/tmp/o11y-lab-vm-manual\" in learner-vm/lab-vm.conf." "grep '^MANUAL_FETCH_DIR=' $(printf '%q' "$CONFIG_FILE")"
elif [[ "$DRY_RUN" == true ]]; then
	step_skip "manual-fetch staging directory would be created" "$MANUAL_FETCH_DIR"
else
	if id "$WORKSHOP_USER" >/dev/null 2>&1 && run "install -d -o $(printf %q "$WORKSHOP_USER") -g $(printf %q "$WORKSHOP_USER") -m 0750 $(printf %q "$MANUAL_FETCH_DIR")"; then
		step_ok "created manual-fetch staging directory for $WORKSHOP_USER"
	else
		step_fail "could not create MANUAL_FETCH_DIR" "Create $MANUAL_FETCH_DIR and grant $WORKSHOP_USER staging access." "id $(printf '%q' "$WORKSHOP_USER")" "ls -ld $(printf '%q' "$(dirname "$MANUAL_FETCH_DIR")")"
	fi
fi

if ! artifact_metadata k3s-binary; then
	step_fail "k3s binary metadata is invalid in learner-vm/artifacts.tsv" "Restore the k3s-binary catalog row and matching versions.lock checksum." "sed -n '1,20p' $(printf '%q' "$REPO_ROOT/learner-vm/artifacts.tsv")" "grep '^learner-k3s-binary-amd64 ' $(printf '%q' "$REPO_ROOT/versions.lock")"
elif [[ "$DRY_RUN" == true ]]; then
	step_skip "k3s artifact source check is target-side and was not evaluated during dry-run" "script 45 uses $ARTIFACT_RELATIVE_PATH or $ARTIFACT_URL_VARIABLE"
else
	manual_k3s_path="$MANUAL_FETCH_DIR/$ARTIFACT_RELATIVE_PATH"
	if [[ -e "$manual_k3s_path" || -L "$manual_k3s_path" ]]; then
		if resolve_artifact k3s-binary check-only; then :; else artifact_status=$?; fi
	elif [[ -x /usr/local/bin/k3s ]] && [[ "$(sha256sum /usr/local/bin/k3s 2>/dev/null | awk '{print $1}')" == "$ARTIFACT_EXPECTED_SHA256" ]]; then
		step_ok "installed k3s binary matches the catalogued versions.lock checksum; no fetch needed"
	else
		if resolve_artifact k3s-binary check-only; then :; else artifact_status=$?; fi
	fi
fi

required_files=(
	"$REPO_ROOT/content/vendor/MANUAL-FETCH.md"
	"$REPO_ROOT/content/vendor/manual-fetch.json"
	"$REPO_ROOT/content/vendor/k3s/install.sh"
	"$REPO_ROOT/content/vendor/k3s/k3s-images.txt"
	"$REPO_ROOT/content/vendor/k3s/k3s-selinux-1.6-1.el8.noarch.rpm"
	"$REPO_ROOT/content/vendor/k3s/SHA256SUMS"
	"$REPO_ROOT/content/extracted/commands.json"
	"$REPO_ROOT/content/extracted/curated.json"
	"$REPO_ROOT/content/extracted/external-images.txt"
	"$REPO_ROOT/content/extracted/build-failures-expected.txt"
	"$REPO_ROOT/content/extracted/runtime-downloads.txt"
	"$REPO_ROOT/content/extracted/syntax-risk.txt"
	"$REPO_ROOT/content/extracted/k8s-references.txt"
	"$REPO_ROOT/content/extracted/docs-gaps.txt"
	"$REPO_ROOT/content/extracted/vendored-files.txt"
)
missing_files=()
for file in "${required_files[@]}"; do
	if [[ "$file" == "$REPO_ROOT/content/extracted/build-failures-expected.txt" || "$file" == "$REPO_ROOT/content/extracted/syntax-risk.txt" || "$file" == "$REPO_ROOT/content/extracted/docs-gaps.txt" ]]; then
		[[ -f "$file" ]] || missing_files+=("${file#"$REPO_ROOT/"}")
	else
		[[ -s "$file" ]] || missing_files+=("${file#"$REPO_ROOT/"}")
	fi
done
if ((${#missing_files[@]} == 0)); then
	step_ok "required manual-fetch, k3s, and extracted workshop metadata are present"
else
	step_fail "required repository inputs are missing: ${missing_files[*]}" "Restore these files from the repository ZIP before provisioning." "find $(printf '%q' "$REPO_ROOT/content/vendor") -maxdepth 2 -type f -print" "ls -l $(printf '%q' "$REPO_ROOT/content/extracted")"
fi

if [[ "$DRY_RUN" == true ]]; then
	step_skip "root filesystem capacity is target-side and was not checked during dry-run" "required free space is at least 40 GiB"
	step_skip "RAM capacity is target-side and was not checked during dry-run" "required memory is at least 6 GiB"
	step_skip "lab log directory writability is target-side and was not checked during dry-run" "$LOG_DIR"
	step_skip "firewalld state is target-side and was not checked during dry-run" "enabled state alone is not a preflight failure"
else
	root_available_kb="$(df -Pk / | awk 'NR == 2 {print $4}')"
	if [[ "$root_available_kb" =~ ^[0-9]+$ ]] && ((root_available_kb >= 41943040)); then
	step_ok "root filesystem has at least 40 GiB free"
	else
	step_fail "root filesystem has less than 40 GiB free" "Expand the VM disk or free space before installing tools and images." "df -hP /"
	fi
	memory_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
	if [[ "$memory_kb" =~ ^[0-9]+$ ]] && ((memory_kb >= 6291456)); then
		step_ok "system has at least 6 GiB RAM"
	else
		step_fail "system has less than 6 GiB RAM" "Assign at least 6 GiB to the RHEL learner VM before provisioning." "grep '^MemTotal:' /proc/meminfo" "free -h"
	fi
	if [[ -d "$LOG_DIR" && -w "$LOG_DIR" ]]; then
		step_ok "lab log directory is writable"
	elif run "install -d -o root -g root -m 0755 $(printf %q "$LOG_DIR")" && [[ -w "$LOG_DIR" ]]; then
		step_ok "created writable lab log directory"
	else
		step_fail "lab log directory is not writable" "Create $LOG_DIR with root write access before provisioning." "ls -ld /var/log /var/log/lab-setup" "df -hP /var/log"
	fi
	if command -v systemctl >/dev/null 2>&1; then
		firewall_state="$(systemctl is-active firewalld 2>/dev/null || true)"
		step_skip "firewalld state reported as ${firewall_state:-unknown}; enabled state alone is not a preflight failure" "script 20 documents the lab firewall decision before changing it"
	else
		step_skip "systemctl is unavailable; firewalld state could not be reported" "inspect firewalld after systemd tooling is available"
	fi
fi

end_report "Review this report and follow README-FIRST.md; continue only after binary source and capacity checks pass."
((FAIL_COUNT == 0))
