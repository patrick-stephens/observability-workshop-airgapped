#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="20-install-tooling"
SCRIPT_VERSION="1"
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
	step_fail "unknown argument: $argument" "Run learner-vm/scripts/20-install-tooling.sh [--dry-run]." "printf '%s\\n' --dry-run"
done
if ((EUID != 0)) && [[ "$DRY_RUN" == false ]]; then
	step_fail "tool installation requires root" "Run sudo learner-vm/scripts/20-install-tooling.sh after script 10 passes." "id -u"
	end_report "correct the privilege issue before continuing to script 30"
	exit 1
elif ((EUID != 0)); then
	step_skip "real package installation requires root; continuing read-only preview" "rerun with sudo on the RHEL learner VM"
fi

TEMP_LOG=''
TEMP_ISO_REPO=''
ISO_REPO_FILE="/etc/yum.repos.d/lab-iso-$$.repo"
ISO_REPO_INSTALLED=false
ISO_MOUNT_DIR=''
declare -a FAILED_ITEMS=()
cleanup() {
	[[ -z "$TEMP_ISO_REPO" ]] || rm -f -- "$TEMP_ISO_REPO"
	if [[ "$ISO_REPO_INSTALLED" == true ]]; then rm -f -- "$ISO_REPO_FILE"; fi
	if [[ -n "$ISO_MOUNT_DIR" ]]; then
		if mountpoint -q "$ISO_MOUNT_DIR"; then umount "$ISO_MOUNT_DIR" || true; fi
		rmdir "$ISO_MOUNT_DIR" 2>/dev/null || true
	fi
	[[ -z "$TEMP_LOG" ]] || rm -f -- "$TEMP_LOG"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

quote_command() {
	local output='' argument
	for argument in "$@"; do output+=" $(printf '%q' "$argument")"; done
	printf '%s' "${output# }"
}

mount_iso_repositories() {
	local mount_options='ro'
	[[ -n "$ISO_MOUNT_DIR" ]] && return 0
	if [[ -f "$ISO_PATH" ]]; then
		mount_options='loop,ro'
	elif [[ ! -b "$ISO_PATH" && ! -c "$ISO_PATH" ]]; then
		return 1
	fi
	ISO_MOUNT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lab-rhel-iso.XXXXXX") || return 1
	if ! mount -o "$mount_options" "$ISO_PATH" "$ISO_MOUNT_DIR" >/dev/null 2>&1; then
		rmdir "$ISO_MOUNT_DIR" 2>/dev/null || true
		ISO_MOUNT_DIR=''
		return 1
	fi
	if [[ ! -d "$ISO_MOUNT_DIR/BaseOS" || ! -d "$ISO_MOUNT_DIR/AppStream" ]]; then
		umount "$ISO_MOUNT_DIR" >/dev/null 2>&1 || true
		rmdir "$ISO_MOUNT_DIR" 2>/dev/null || true
		ISO_MOUNT_DIR=''
		return 1
	fi
	TEMP_ISO_REPO=$(mktemp "${TMPDIR:-/tmp}/lab-iso-repos.XXXXXX") || return 1
	printf '[lab-iso-baseos]\nname=Temporary RHEL ISO BaseOS\nbaseurl=file://%s/BaseOS\nenabled=1\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release\n\n[lab-iso-appstream]\nname=Temporary RHEL ISO AppStream\nbaseurl=file://%s/AppStream\nenabled=1\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release\n' "$ISO_MOUNT_DIR" "$ISO_MOUNT_DIR" > "$TEMP_ISO_REPO"
	[[ ! -e "$ISO_REPO_FILE" ]] || return 1
	if install -o root -g root -m 0644 "$TEMP_ISO_REPO" "$ISO_REPO_FILE"; then ISO_REPO_INSTALLED=true; else return 1; fi
	return 0
}

dnf_action() {
	local description="$1"; shift
	local -a command=(dnf -y "$@") fallback=(dnf -y --disablerepo='*' --enablerepo=lab-iso-baseos --enablerepo=lab-iso-appstream "$@")
	if [[ "$DRY_RUN" == true ]]; then
		run "$(quote_command "${command[@]}")"
		step_skip "DNF action previewed" "$description"
		return 0
	fi
	[[ -z "$TEMP_LOG" ]] || rm -f -- "$TEMP_LOG"
	TEMP_LOG=$(mktemp "${TMPDIR:-/tmp}/20-install-tooling.XXXXXX") || { FAILED_ITEMS+=("$description (could not create transaction log)"); return 1; }
	if "${command[@]}" >"$TEMP_LOG" 2>&1; then
		step_ok "installed or confirmed $description from configured DNF repos"
		return 0
	fi
	log "DNF failed for $description; transaction tail follows"
	while IFS= read -r line; do log "$line"; done < <(tail -n 15 "$TEMP_LOG")
	if ! mount_iso_repositories; then
		FAILED_ITEMS+=("$description (Artifactory DNF failed; ISO unavailable)")
		return 1
	fi
	if "${fallback[@]}" >"$TEMP_LOG" 2>&1; then
		step_ok "installed unavailable item from temporary read-only ISO repos: $description"
		return 0
	fi
	log "ISO fallback failed for $description; transaction tail follows"
	while IFS= read -r line; do log "$line"; done < <(tail -n 15 "$TEMP_LOG")
	FAILED_ITEMS+=("$description (DNF and ISO fallback failed)")
	return 1
}

if [[ "$DRY_RUN" == true ]]; then
	step_skip "RHEL version check is target-side and was not evaluated during dry-run" "run this artifact on RHEL 8.x"
elif [[ -r /etc/redhat-release ]] && grep -Eq 'release 8([.]| )' /etc/redhat-release; then
	step_ok "RHEL 8 detected: $(</etc/redhat-release)"
else
	step_fail "target must be RHEL 8.x" "Use the RHEL 8.6 learner image." "cat /etc/redhat-release"
fi

if command -v dnf >/dev/null 2>&1 || [[ "$DRY_RUN" == true ]]; then
	dnf_action "container-tools module" module enable container-tools || true
	for group in "Server with GUI" "Development Tools"; do dnf_action "group $group" group install "$group" || true; done
	packages=(firefox gnome-terminal gnome-system-monitor git curl wget rsync tar unzip zip vim nano tree jq net-tools bind-utils nmap-ncat traceroute podman buildah skopeo podman-docker java-11-openjdk-devel java-17-openjdk-devel python3 python3-pip python3-devel chrony policycoreutils-python-utils setools-console open-vm-tools open-vm-tools-desktop)
	for package in "${packages[@]}"; do dnf_action "package $package" install "$package" || true; done
else
	step_fail "dnf is unavailable" "Restore the RHEL 8.6 DNF package manager before installing workshop tools." "command -v dnf" "cat /etc/redhat-release"
fi

if [[ -n "$HOSTNAME" ]]; then
	current_hostname="$(hostname 2>/dev/null || true)"
	if [[ "$current_hostname" == "$HOSTNAME" ]]; then
		step_ok "hostname already matches HOSTNAME"
	elif [[ "$DRY_RUN" == true ]]; then
		run "hostnamectl set-hostname $(printf %q "$HOSTNAME")"
		step_skip "hostname change was previewed" "$HOSTNAME"
	elif run "hostnamectl set-hostname $(printf %q "$HOSTNAME")"; then
		step_ok "set hostname to HOSTNAME"
	else
		step_fail "could not set hostname" "Check HOSTNAME in learner-vm/lab-vm.conf and systemd-hostnamed." "hostnamectl status" "hostnamectl --static"
	fi
fi

if [[ -z "$STATIC_IP" ]]; then
	step_skip "STATIC_IP is empty; preserving the base image network configuration" "no network changes requested"
elif [[ "$DRY_RUN" == true ]]; then
	step_skip "STATIC_IP change was not applied during dry-run" "$STATIC_IP"
elif command -v nmcli >/dev/null 2>&1; then
	connection="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: '$2 != "lo" {print $1; exit}')"
	gateway="$(ip route show default | awk 'NR == 1 {print $3}')"
	if [[ -z "$connection" || -z "$gateway" ]]; then
		step_fail "STATIC_IP is set but the active connection or current gateway is unavailable" "Restore the base network route or clear STATIC_IP in learner-vm/lab-vm.conf." "nmcli connection show --active" "ip route show default"
	elif run "nmcli connection modify $(printf %q "$connection") ipv4.method manual ipv4.addresses $(printf %q "$STATIC_IP") ipv4.gateway $(printf %q "$gateway") && nmcli connection up $(printf %q "$connection")"; then
		step_ok "applied STATIC_IP and preserved the current gateway"
	else
		step_fail "could not apply STATIC_IP" "Check STATIC_IP format and the active connection in learner-vm/lab-vm.conf." "nmcli connection show $(printf %q "$connection")" "ip address show"
	fi
else
	step_fail "STATIC_IP is set but nmcli is unavailable" "Install NetworkManager tooling or clear STATIC_IP to preserve the base network." "command -v nmcli" "ip address show"
fi

if command -v systemctl >/dev/null 2>&1; then
	firewalld_state=''
	if [[ "$DRY_RUN" == true ]]; then
		run 'systemctl enable --now chronyd'
		step_skip "chronyd enable was previewed" "systemctl enable --now chronyd"
	elif systemctl is-active --quiet chronyd 2>/dev/null; then
		step_ok "chronyd is already active"
	elif run 'systemctl enable --now chronyd'; then
		step_ok "enabled chronyd"
	else
		step_fail "could not enable chronyd" "Install chrony from the configured DNF repositories or ISO." "systemctl status chronyd --no-pager" "rpm -q chrony"
	fi
	if [[ "$DRY_RUN" == true ]]; then
		step_skip "firewalld state was not inspected during dry-run" "real execution reports the current state before any change"
	else
		firewalld_state="$(systemctl is-active firewalld 2>/dev/null || true)"
		step_skip "firewalld current state: ${firewalld_state:-unknown}" "the isolated workshop VM disables the host firewall only after preserving this state in the report"
		if [[ "$firewalld_state" == active ]]; then
			# The isolated workshop VM uses its documented local-only service ports instead of a host firewall policy.
			if run 'systemctl disable --now firewalld'; then
				step_ok "disabled firewalld after reporting its active state"
			else
				step_fail "could not disable firewalld" "Review the isolated-lab firewall decision and systemd status." "systemctl status firewalld --no-pager" "systemctl is-enabled firewalld"
			fi
		fi
	fi
	if [[ "$DRY_RUN" == true ]]; then
		run 'systemctl set-default graphical.target'
		step_skip "graphical target change was previewed" "systemctl set-default graphical.target"
	elif systemctl get-default 2>/dev/null | grep -qx graphical.target; then
		step_ok "graphical target already selected"
	elif run 'systemctl set-default graphical.target'; then
		step_ok "selected graphical target"
	else
		step_fail "could not select graphical target" "Install the Server with GUI group and check systemd." "systemctl get-default" "systemctl status gdm --no-pager"
	fi
	if [[ "$DRY_RUN" == true ]]; then
		run 'systemctl enable --now gdm'
		step_skip "GDM enable was previewed" "systemctl enable --now gdm"
	elif systemctl is-enabled gdm >/dev/null 2>&1 && systemctl is-active gdm >/dev/null 2>&1; then
		step_ok "GDM is enabled and active"
	elif run 'systemctl enable --now gdm'; then
		step_ok "enabled GDM"
	else
		step_fail "could not enable GDM" "Install the Server with GUI group from Artifactory or the RHEL ISO." "systemctl status gdm --no-pager" "rpm -q gdm"
	fi
fi

if [[ "$DRY_RUN" == false ]]; then
	for tool in podman buildah skopeo firefox git java; do
		if command -v "$tool" >/dev/null 2>&1; then
			version="$($tool --version 2>&1 | head -n 1 || true)"
			step_ok "$tool version: $version"
		else
			step_fail "$tool is not installed" "Review DNF/ISO results and install $tool before continuing." "command -v $(printf %q "$tool")" "rpm -q $(printf %q "$tool")"
		fi
	done
fi

if ((${#FAILED_ITEMS[@]} > 0)); then
	step_fail "DNF/ISO package actions failed: ${FAILED_ITEMS[*]}" "Repair the Artifactory DNF repos or attach a RHEL 8.6 ISO at ISO_PATH, then rerun this idempotent script." "dnf repolist -v" "tail -n 15 $(printf %q "$LOG_FILE")" "findmnt $(printf %q "$ISO_PATH")"
fi

end_report "Review this report and continue with learner-vm/scripts/30-ca-and-trust.sh after all required packages are present."
((FAIL_COUNT == 0))
