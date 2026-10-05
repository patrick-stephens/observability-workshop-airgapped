#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="50-user-setup"
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
	step_fail "unknown argument: $argument" "Run learner-vm/scripts/50-user-setup.sh [--dry-run]." "printf '%s\\n' --dry-run"
done
if ((EUID != 0)) && [[ "$DRY_RUN" == false ]]; then
	step_fail "user setup requires root" "Run sudo learner-vm/scripts/50-user-setup.sh after script 40." "id -u"
	end_report "rerun with sudo"
	exit 1
elif ((EUID != 0)); then
	step_skip "root is required for account and wrapper changes; dry-run continues" "rerun with sudo on the learner VM"
fi

if [[ "${PASSWORDLESS_SUDO:-}" != yes ]]; then
	step_fail "PASSWORDLESS_SUDO must be yes" "Set PASSWORDLESS_SUDO=\"yes\" in learner-vm/lab-vm.conf." "grep '^PASSWORDLESS_SUDO=' $(printf '%q' "$CONFIG_FILE")"
fi
if [[ -z "${WORKSHOP_USER:-}" ]]; then
	step_fail "WORKSHOP_USER is empty" "Set WORKSHOP_USER=\"engineer\" in learner-vm/lab-vm.conf." "grep '^WORKSHOP_USER=' $(printf '%q' "$CONFIG_FILE")"
	end_report "set WORKSHOP_USER before configuring sudoers and wrappers"
	exit 1
fi
if [[ ! "$WORKSHOP_USER" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; then
	step_fail "WORKSHOP_USER contains characters unsafe for sudoers syntax" "Set WORKSHOP_USER to a valid local account name such as engineer in learner-vm/lab-vm.conf." "grep '^WORKSHOP_USER=' $(printf '%q' "$CONFIG_FILE")" "getent passwd $(printf '%q' "$WORKSHOP_USER")"
	end_report "correct WORKSHOP_USER before changing sudoers"
	exit 1
fi

if [[ "$DRY_RUN" == true ]]; then
	step_skip "wheel group and $WORKSHOP_USER account checks are target-side and were not evaluated during dry-run" "create the engineer account in the RHEL base image; this script never sets or resets passwords"
else
	if ! getent group wheel >/dev/null 2>&1; then
		step_fail "required wheel group is missing" "Restore the RHEL wheel group before applying the workshop sudo policy." "getent group wheel" "getent group"
	else
		step_ok "wheel group exists"
	fi
	if ! id "$WORKSHOP_USER" >/dev/null 2>&1; then
		step_fail "workshop account $WORKSHOP_USER does not exist" "Create $WORKSHOP_USER in the base image; this script does not set or reset passwords." "getent passwd $(printf '%q' "$WORKSHOP_USER")" "grep '^WORKSHOP_USER=' $(printf '%q' "$CONFIG_FILE")"
		end_report "create the operator account without setting its password, then rerun"
		exit 1
	fi
fi

user_groups="$(id -nG "$WORKSHOP_USER" 2>/dev/null || true)"
if [[ " $user_groups " == *" wheel "* ]]; then
	step_ok "$WORKSHOP_USER already belongs to wheel"
elif [[ "$DRY_RUN" == true ]]; then
	run "usermod -aG wheel $(printf %q "$WORKSHOP_USER")"
	step_skip "wheel membership change was previewed" "$WORKSHOP_USER"
elif run "usermod -aG wheel $(printf %q "$WORKSHOP_USER")"; then
	step_ok "added $WORKSHOP_USER to wheel"
else
	step_fail "could not add $WORKSHOP_USER to wheel" "Check the existing account and the wheel group." "id $(printf '%q' "$WORKSHOP_USER")" "getent group wheel"
fi

sudoers_file='/etc/sudoers.d/90-lab-workshop'
sudoers_line="$WORKSHOP_USER ALL=(ALL) NOPASSWD: ALL"
if grep -Fxq -- "$sudoers_line" "$sudoers_file" 2>/dev/null; then
	step_ok "passwordless sudo rule is already configured for $WORKSHOP_USER"
elif [[ "$DRY_RUN" == true ]]; then
	step_skip "would validate a temporary sudoers rule with visudo before atomic install" "$sudoers_file"
else
	sudoers_tmp=$(mktemp /etc/sudoers.d/.lab-workshop.XXXXXX) || sudoers_tmp=''
	if [[ -z "$sudoers_tmp" ]]; then
		step_fail "could not create temporary sudoers file" "Check /etc/sudoers.d permissions and disk space." "ls -ld /etc/sudoers.d" "df -hP /etc"
	else
		sudoers_backup=''
		backup_ready=true
		preserve_backup=false
		if [[ -e "$sudoers_file" ]]; then
			if [[ -L "$sudoers_file" ]]; then
				backup_ready=false
				step_fail "refusing to replace a symlinked sudoers policy" "Inspect $sudoers_file and restore a regular file before retrying." "ls -l $(printf '%q' "$sudoers_file")" "visudo -c"
			else
				sudoers_backup=$(mktemp /etc/sudoers.d/.lab-workshop-backup.XXXXXX) || sudoers_backup=''
			fi
			if [[ "$backup_ready" == true ]] && { [[ -z "$sudoers_backup" ]] || ! cp -p -- "$sudoers_file" "$sudoers_backup"; }; then
				backup_ready=false
				step_fail "could not back up the existing sudoers policy" "Preserve $sudoers_file and check /etc/sudoers.d permissions before retrying." "ls -l $(printf '%q' "$sudoers_file")" "ls -ld /etc/sudoers.d" "df -hP /etc"
			fi
		fi
		if [[ "$backup_ready" == true ]]; then
			if [[ -f "$sudoers_file" ]]; then cat "$sudoers_file" > "$sudoers_tmp"; fi
			grep -Fxq -- "$sudoers_line" "$sudoers_tmp" || printf '%s\n' "$sudoers_line" >> "$sudoers_tmp"
			chmod 0440 "$sudoers_tmp"
			if ! visudo -c -f "$sudoers_tmp" >/dev/null 2>&1; then
				step_fail "temporary sudoers rule failed validation" "Do not install it; correct PASSWORDLESS_SUDO and account syntax." "visudo -c -f $(printf '%q' "$sudoers_tmp")" "cat $(printf '%q' "$sudoers_tmp")"
			elif mv -f -- "$sudoers_tmp" "$sudoers_file"; then
				sudoers_tmp=''
				if visudo -c >/dev/null 2>&1; then
					step_ok "installed and validated passwordless sudo policy for $WORKSHOP_USER"
					[[ -z "$sudoers_backup" ]] || rm -f -- "$sudoers_backup"
				else
					rollback_ok=true
					if [[ -n "$sudoers_backup" ]]; then
						if mv -f -- "$sudoers_backup" "$sudoers_file"; then sudoers_backup=''; else rollback_ok=false; preserve_backup=true; fi
					elif ! rm -f -- "$sudoers_file"; then
						rollback_ok=false
					fi
					if [[ "$rollback_ok" == true ]]; then
						step_fail "sudoers policy failed system validation and the prior file was restored" "Correct the other invalid sudoers input before retrying." "visudo -c" "ls -l $(printf '%q' "$sudoers_file")"
					else
						step_fail "sudoers system validation failed and rollback needs operator attention" "Restore the prior policy from $sudoers_backup if present, then run visudo -c before allowing further changes." "ls -l $(printf '%q' /etc/sudoers.d/.lab-workshop-backup.*)" "visudo -c" "ls -l $(printf '%q' "$sudoers_file")"
					fi
				fi
			else
				step_fail "could not atomically install the validated sudoers policy" "Check /etc/sudoers.d permissions; the prior file was not intentionally removed." "ls -ld /etc/sudoers.d" "ls -l $(printf '%q' "$sudoers_tmp")" "visudo -c"
			fi
		fi
		if [[ "$preserve_backup" == false && -n "$sudoers_backup" ]]; then rm -f -- "$sudoers_backup"; fi
		[[ -z "$sudoers_tmp" ]] || rm -f -- "$sudoers_tmp"
	fi
fi

render_wrapper() {
	local target="$1" runtime="$2"
	cat > "$target" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if ((EUID == 0)); then
    exec $runtime "\$@"
fi
exec /usr/bin/sudo -n $runtime "\$@"
EOF
}

install_wrapper() {
	local name="$1" target="/usr/local/bin/$1" wrapper_tmp
	if [[ "$DRY_RUN" == true ]]; then
		step_skip "would install non-recursive $name wrapper calling /usr/bin/podman directly" "$target"
		return 0
	fi
	wrapper_tmp=$(mktemp "${TMPDIR:-/tmp}/lab-${name}.XXXXXX") || wrapper_tmp=''
	if [[ -z "$wrapper_tmp" ]]; then
		step_fail "could not create temporary $name wrapper" "Check temporary storage and /usr/local/bin permissions." "df -hP /tmp" "ls -ld /usr/local/bin"
		return 0
	fi
	if [[ ! -x /usr/bin/podman ]]; then
		step_fail "the real Podman executable is missing at /usr/bin/podman" "Run learner-vm/scripts/20-install-tooling.sh before creating Docker-compatible wrappers." "ls -l /usr/bin/podman" "rpm -q podman podman-docker"
		rm -f -- "$wrapper_tmp"
		return 0
	fi
	render_wrapper "$wrapper_tmp" /usr/bin/podman
	chmod 0755 "$wrapper_tmp"
	if ! bash -n "$wrapper_tmp"; then
		step_fail "generated $name wrapper did not pass bash -n" "Inspect the wrapper template in learner-vm/scripts/50-user-setup.sh." "bash -n $(printf '%q' "$wrapper_tmp")" "sed -n '1,20p' $(printf '%q' "$wrapper_tmp")"
	elif [[ -e "$target" || -L "$target" ]]; then
		if [[ -f "$target" && ! -L "$target" ]] && cmp -s "$wrapper_tmp" "$target"; then
			step_ok "$name wrapper already matches the managed rootful Podman wrapper"
		else
			step_fail "refusing to replace an existing unmanaged wrapper: $target" "Inspect or move the existing command deliberately before rerunning script 50." "ls -l $(printf '%q' "$target")" "head -n 12 $(printf '%q' "$target")"
		fi
	elif install -o root -g root -m 0755 "$wrapper_tmp" "$target"; then
		step_ok "installed $name wrapper using absolute /usr/bin/podman and a root-aware sudo branch"
	else
		step_fail "could not install valid $name wrapper" "Check /usr/local/bin permissions and the Podman package." "bash -n $(printf '%q' "$wrapper_tmp")" "ls -ld /usr/local/bin" "rpm -q podman podman-docker"
	fi
	rm -f -- "$wrapper_tmp"
}

install_wrapper podman
install_wrapper docker

if [[ "$AUTOLOGIN" == yes ]]; then
	if [[ "$DRY_RUN" == true ]]; then
		step_skip "GDM autologin configuration was previewed without changing passwords" "$WORKSHOP_USER"
	else
		gdm_config='/etc/gdm/custom.conf'
		if [[ ! -f "$gdm_config" ]]; then
			step_fail "GDM configuration file is missing" "Install the Server with GUI group before enabling autologin." "rpm -q gdm" "ls -l /etc/gdm"
		else
			gdm_tmp=$(mktemp "${TMPDIR:-/tmp}/gdm-custom.XXXXXX") || gdm_tmp=''
			if [[ -z "$gdm_tmp" ]]; then
				step_fail "could not create temporary GDM configuration" "Check temporary disk space." "df -hP /tmp" "ls -l $(printf '%q' "$gdm_config")"
			else
				awk -v user="$WORKSHOP_USER" '
BEGIN { in_daemon=0; have_daemon=0; have_enable=0; have_user=0 }
/^\[daemon\][[:space:]]*$/ {
    if (in_daemon && !have_enable) print "AutomaticLoginEnable=True"
    if (in_daemon && !have_user) print "AutomaticLogin=" user
    in_daemon=1; have_daemon=1; print; next
}
/^\[/ {
    if (in_daemon && !have_enable) print "AutomaticLoginEnable=True"
    if (in_daemon && !have_user) print "AutomaticLogin=" user
    in_daemon=0
}
in_daemon && /^[[:space:]]*AutomaticLoginEnable[[:space:]]*=/ {
    if (!have_enable) print "AutomaticLoginEnable=True"
    have_enable=1; next
}
in_daemon && /^[[:space:]]*AutomaticLogin[[:space:]]*=/ {
    if (!have_user) print "AutomaticLogin=" user
    have_user=1; next
}
{ print }
END {
    if (in_daemon && !have_enable) print "AutomaticLoginEnable=True"
    if (in_daemon && !have_user) print "AutomaticLogin=" user
    if (!have_daemon) print "\n[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=" user
}' "$gdm_config" > "$gdm_tmp"
				if cmp -s "$gdm_tmp" "$gdm_config"; then
					step_ok "GDM autologin already targets $WORKSHOP_USER"
				elif install -o root -g root -m 0644 "$gdm_tmp" "$gdm_config"; then
					step_ok "configured GDM autologin for $WORKSHOP_USER without changing its password"
				else
					step_fail "could not update GDM autologin configuration" "Check AUTOLOGIN and permissions for /etc/gdm/custom.conf." "grep -n '^\\[daemon\\]' $(printf '%q' "$gdm_config")" "ls -l $(printf '%q' "$gdm_config")"
				fi
				rm -f -- "$gdm_tmp"
			fi
		fi
	fi
else
	step_skip "AUTOLOGIN is disabled" "GDM autologin was not changed"
fi

if [[ "$DRY_RUN" == true ]]; then
	step_skip "ownership repair and wrapper invocation tests are target-side and were not run during dry-run" "$REPO_ROOT and /home/$WORKSHOP_USER"
else
	home_dir="$(getent passwd "$WORKSHOP_USER" | cut -d: -f6)"
	if [[ -z "$home_dir" || ! -d "$home_dir" ]]; then
		step_fail "home directory for $WORKSHOP_USER is missing" "Restore the account home directory before installing the workshop." "getent passwd $(printf '%q' "$WORKSHOP_USER")" "ls -ld /home"
	else
		if run "chown -R $(printf %q "$WORKSHOP_USER:$WORKSHOP_USER") $(printf %q "$REPO_ROOT") && chown $(printf %q "$WORKSHOP_USER:$WORKSHOP_USER") $(printf %q "$home_dir")"; then
			step_ok "repaired repository and home ownership for $WORKSHOP_USER"
		else
			step_fail "could not repair repository/home ownership" "Check WORKSHOP_USER and the mounted repository permissions." "stat -c '%U:%G %n' $(printf %q "$REPO_ROOT") $(printf %q "$home_dir")" "df -hP /home"
		fi
	fi
	if command -v runuser >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
		for command_name in docker podman; do
			if timeout 10 "/usr/local/bin/$command_name" --version >/dev/null 2>&1; then
				step_ok "root invocation test passed for $command_name wrapper"
			else
				step_fail "root invocation test failed for $command_name wrapper" "Restore the absolute /usr/bin/podman target and rerun script 50." "head -n 10 $(printf %q "/usr/local/bin/$command_name")" "command -v podman"
			fi
			if timeout 15 runuser -u "$WORKSHOP_USER" -- "/usr/local/bin/$command_name" --version >/dev/null 2>&1; then
				step_ok "$WORKSHOP_USER invocation test passed for $command_name wrapper"
			else
				step_fail "$WORKSHOP_USER invocation test failed for $command_name wrapper" "Check PASSWORDLESS_SUDO and the wrapper's absolute Podman path." "sudo -l -U $(printf %q "$WORKSHOP_USER")" "head -n 10 $(printf %q "/usr/local/bin/$command_name")"
			fi
		done
	else
		step_skip "runuser or timeout is unavailable; root/engineer wrapper invocation tests were not executed" "install shadow-utils and coreutils before script 50"
	fi
fi

end_report "Review account, sudoers, wrapper, and GDM results; continue with scripts/60-load-images.sh after the rootful runtime is ready."
((FAIL_COUNT == 0))