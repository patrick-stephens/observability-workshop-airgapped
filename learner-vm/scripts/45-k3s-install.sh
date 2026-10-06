#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="45-k3s-install"
# CHANGE: Keep hard optional-artifact resolver/staging failures in the report flow and block startup cleanly.
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
	step_fail "unknown argument: $argument" "Run learner-vm/scripts/45-k3s-install.sh [--dry-run]." "printf '%s\\n' --dry-run"
done
if ((EUID != 0)) && [[ "$DRY_RUN" == false ]]; then
	step_fail "k3s installation requires root" "Run sudo learner-vm/scripts/45-k3s-install.sh after scripts 10-40." "id -u"
	end_report "rerun with sudo after script 40 passes"
	exit 1
elif ((EUID != 0)); then
	step_skip "root is required for installation; dry-run continues" "rerun with sudo on the learner VM"
fi

K3S='/usr/local/bin/k3s'
K3S_PAYLOAD=''
K3S_PAYLOAD_SOURCE='absent'
K3S_BINARY_URL_SAFE='unset'
K3S_BINARY_HOST=''
K3S_BINARY_CONNECT=''
VENDOR_DIR="$REPO_ROOT/content/vendor/k3s"
INSTALLER="$VENDOR_DIR/install.sh"
SELINUX_RPM="$VENDOR_DIR/k3s-selinux-1.6-1.el8.noarch.rpm"
SYSTEM_IMAGES="$VENDOR_DIR/k3s-images.txt"
REGISTRIES_FILE='/etc/rancher/k3s/registries.yaml'
TEMP_FILES=()
cleanup() { ((${#TEMP_FILES[@]} == 0)) || rm -f -- "${TEMP_FILES[@]}"; }
trap cleanup EXIT

k3s_failure() {
	local problem="$1" image="${2:-unknown}"
	step_fail "$problem; K3S_BINARY_URL=${K3S_BINARY_URL_SAFE}" "Check K3S_BINARY_URL (operator-supplied Artifactory generic-file URL), CA trust, and $REGISTRIES_FILE; use $MANUAL_FETCH_DIR/k3s/k3s only as the same-VM staging fallback. Artifactory pulls remain unverified until learner-network evidence exists." \
		"$K3S --version" \
		"$K3S crictl --help" \
		"$K3S crictl images" \
		"$K3S ctr -n k8s.io images list" \
		"journalctl -u k3s -b --no-pager | tail -n 15" \
		"cat $(printf %q "$REGISTRIES_FILE")" \
		"tail -n 15 /var/lib/rancher/k3s/agent/containerd/containerd.log" \
		"getent hosts $(printf %q "${K3S_BINARY_HOST:-$ART_HOST}")" \
		"curl -vI --connect-timeout 5 --max-time 15 $(printf %q "$K3S_BINARY_URL_SAFE") 2>&1 | tail -n 12" \
		"printf '' | openssl s_client -connect $(printf %q "${K3S_BINARY_CONNECT:-$REG_HOST:443}") -servername $(printf %q "${K3S_BINARY_HOST:-$REG_HOST}") 2>&1 | tail -n 12" \
		"printf '%s\\n' $(printf %q "$image")"
}

if [[ ! -s "$REPO_ROOT/versions.lock" ]] || ! command -v python3 >/dev/null 2>&1; then
	step_fail "versions.lock or Python 3 is unavailable" "Restore versions.lock and install Python 3 before installing the pinned k3s binary." "ls -l $(printf %q "$REPO_ROOT/versions.lock")" "command -v python3"
	end_report "restore the lock file and Python 3 before retrying"
	exit 1
fi
K3S_VALID=false
K3S_RESOLUTION_FAILED=false
if ! artifact_metadata k3s-binary; then
	K3S_RESOLUTION_FAILED=true
	step_fail "k3s binary metadata is invalid in learner-vm/artifacts.tsv" "Restore the k3s-binary catalog row and its versions.lock checksum before provisioning." "sed -n '1,20p' $(printf %q "$REPO_ROOT/learner-vm/artifacts.tsv")" "grep '^learner-k3s-binary-amd64 ' $(printf %q "$REPO_ROOT/versions.lock")"
else
	K3S_SHA="$ARTIFACT_EXPECTED_SHA256"
	K3S_MANUAL_PAYLOAD="$MANUAL_FETCH_DIR/$ARTIFACT_RELATIVE_PATH"
	if [[ -e "$K3S_MANUAL_PAYLOAD" || -L "$K3S_MANUAL_PAYLOAD" || "$DRY_RUN" == true ]] || [[ ! -x "$K3S" ]] || [[ "$(sha256sum "$K3S" 2>/dev/null | awk '{print $1}')" != "$ARTIFACT_EXPECTED_SHA256" ]]; then
		if resolve_artifact k3s-binary; then
			K3S_VALID=true
			K3S_PAYLOAD="$ARTIFACT_RESOLVED_PATH"
			K3S_PAYLOAD_SOURCE="$ARTIFACT_RESOLVED_SOURCE"
			K3S_BINARY_URL_SAFE="${ARTIFACT_SAFE_URL:-unset}"
			K3S_BINARY_HOST="${ARTIFACT_HOST:-}"
			K3S_BINARY_CONNECT="${ARTIFACT_CONNECT:-}"
		else
			artifact_status=$?
			if ((artifact_status == 3)); then
				K3S_PAYLOAD_SOURCE="$ARTIFACT_RESOLVED_SOURCE"
			else
				K3S_VALID=false
				K3S_RESOLUTION_FAILED=true
			fi
		fi
	else
		K3S_VALID=true
		K3S_PAYLOAD="$K3S"
		K3S_PAYLOAD_SOURCE='installed'
		step_ok "installed k3s binary already matches the catalogued SHA-256; no fetch needed"
	fi
fi

SUPPORT_VALID=false
if [[ -s "$INSTALLER" && -s "$SELINUX_RPM" && -s "$SYSTEM_IMAGES" ]] && (cd "$VENDOR_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
	SUPPORT_VALID=true
	step_ok "vendored installer, system image list, and SELinux RPM match SHA256SUMS"
else
	step_fail "retained k3s support files are missing or checksum-invalid" "Restore the small files listed by content/vendor/k3s/SHA256SUMS from the repository ZIP." "ls -l $(printf %q "$VENDOR_DIR")" "(cd $(printf %q "$VENDOR_DIR") && sha256sum -c SHA256SUMS)"
fi

AIRGAP_IMAGES_CHANGED=false
AIRGAP_IMAGES_READY=true
stage_optional_airgap_images() {
	local resolve_status destination destination_dir stage_tmp existing_sha
	if resolve_artifact k3s-airgap-images; then
		if [[ "$DRY_RUN" == true ]]; then
			log "[dry-run] WOULD stage artifact source=$ARTIFACT_RESOLVED_SOURCE from $ARTIFACT_RESOLVED_PATH to ${ARTIFACT_INSTALL_TARGET%/}/${ARTIFACT_RELATIVE_PATH##*/} before k3s starts"
			return 0
		fi
		destination="${ARTIFACT_INSTALL_TARGET%/}/${ARTIFACT_RELATIVE_PATH##*/}"
		destination_dir="$(dirname "$destination")"
		existing_sha=''
	if [[ -f "$destination" && ! -L "$destination" ]]; then existing_sha="$(sha256sum "$destination" 2>/dev/null | awk '{print $1}' || true)"; fi
		if [[ "$existing_sha" == "$ARTIFACT_EXPECTED_SHA256" ]]; then
			if [[ "$(stat -c '%u:%g:%a' "$destination" 2>/dev/null || true)" != '0:0:644' ]] && ! run "chown root:root $(printf %q "$destination") && chmod 0644 $(printf %q "$destination")"; then
				step_fail "could not set root ownership and mode 0644 on the verified k3s airgap archive" "Restore access to $destination or leave the optional archive unstaged and use registry mirrors." "stat -c '%U:%G:%a %n' $(printf %q "$destination")" "ls -ld $(printf %q "$destination_dir")"
				AIRGAP_IMAGES_READY=false
				return 1
			fi
			step_ok "optional k3s airgap archive already staged with the catalogued checksum: $destination"
			return 0
		fi
		if ! install -d -o root -g root -m 0755 "$destination_dir"; then
			step_fail "could not create k3s airgap image import directory: $destination_dir" "Keep the optional archive at $ARTIFACT_RESOLVED_PATH and restore access to the k3s agent image directory; see MANUAL-FETCH.md Section B." "ls -ld $(printf %q "$(dirname "$destination_dir")")" "df -hP $(printf %q "$destination_dir")"
			AIRGAP_IMAGES_READY=false
			return 1
		fi
		stage_tmp="$(mktemp "$destination_dir/.k3s-airgap-images.XXXXXX")" || stage_tmp=''
		if [[ -n "$stage_tmp" ]]; then TEMP_FILES+=("$stage_tmp"); fi
		if [[ -n "$stage_tmp" ]] && install -o root -g root -m 0644 "$ARTIFACT_RESOLVED_PATH" "$stage_tmp" && [[ "$(sha256sum "$stage_tmp" | awk '{print $1}')" == "$ARTIFACT_EXPECTED_SHA256" ]] && mv -f -- "$stage_tmp" "$destination"; then
			AIRGAP_IMAGES_CHANGED=true
			step_ok "optional k3s airgap archive staged from source $ARTIFACT_RESOLVED_SOURCE at $destination (root:root 0644)"
		else
			[[ -z "$stage_tmp" ]] || rm -f -- "$stage_tmp"
			step_fail "could not stage checksum-verified optional archive at $destination" "The verified source remains at $ARTIFACT_RESOLVED_PATH; restore the k3s agent image-directory permissions or leave the option unused and use registry mirrors." "ls -ld $(printf %q "$destination_dir")" "df -hP $(printf %q "$destination_dir")"
			AIRGAP_IMAGES_READY=false
			return 1
		fi
		return 0
	else
		resolve_status=$?
	fi
	case "$resolve_status" in
		2) return 0 ;;
		3) log "[dry-run] optional archive resolution was previewed; no staging changes were made"; return 0 ;;
		*) AIRGAP_IMAGES_READY=false; return 1 ;;
	esac
}

if [[ "$DRY_RUN" == true ]]; then
	run "rpm -Uvh $(printf %q "$SELINUX_RPM")"
	step_skip "k3s SELinux RPM installation was previewed before first start" "$SELINUX_RPM"
	step_skip "k3s binary download or local fallback install was previewed" "K3S_BINARY_URL is operator-supplied; its exact URL is not embedded in the ZIP"
	log "would write $REGISTRIES_FILE before the first k3s start using DOCKER_REGISTRY=$DOCKER_REGISTRY and CA_CERT_SOURCE=$CA_CERT_SOURCE"
	if stage_optional_airgap_images; then :; else :; fi
	step_skip "vendored install.sh would run with INSTALL_K3S_SKIP_DOWNLOAD=true and INSTALL_K3S_SKIP_SELINUX_RPM=true" "$INSTALLER"
	step_skip "k3s service, kubeconfig, node readiness, and CRI pulls are target-side and were not executed during dry-run" "the actual pull result is recorded only on the learner network"
	end_report "review the pinned payload and registry order; run without --dry-run on the learner VM"
	exit 0
fi

if [[ "$K3S_VALID" != true || "$SUPPORT_VALID" != true ]]; then
	step_skip "k3s installation stopped because the required binary or retained support files failed validation" "resolve the earlier FATAL entries before starting k3s"
	end_report "correct required inputs before starting k3s"
	exit 1
fi

SELINUX_READY=false
selinux_version="$(rpm -q --qf '%{VERSION}-%{RELEASE}' k3s-selinux 2>/dev/null || true)"
if [[ "$selinux_version" == '1.6-1.el8' ]]; then
	SELINUX_READY=true
	step_ok "pinned k3s SELinux policy is already installed"
elif run "rpm -Uvh $(printf %q "$SELINUX_RPM")"; then
	SELINUX_READY=true
	step_ok "installed retained SELinux RPM before k3s first start"
else
	k3s_failure "k3s SELinux RPM installation failed" "$SELINUX_RPM"
fi

K3S_CHANGED=true
BINARY_READY=false
if [[ -x "$K3S" ]] && [[ "$(sha256sum "$K3S" | awk '{print $1}')" == "$K3S_SHA" ]]; then
	K3S_CHANGED=false
	BINARY_READY=true
	step_ok "installed k3s binary already matches the manual-fetch pin"
elif [[ "$K3S_VALID" == true ]]; then
	if install_payload_sha="$(sha256sum "$K3S_PAYLOAD" 2>/dev/null | awk '{print $1}')"; then :; else install_payload_sha='unavailable'; fi
	if [[ "$install_payload_sha" != "$K3S_SHA" ]]; then
		k3s_failure "selected $K3S_PAYLOAD_SOURCE binary changed or failed its immediate pre-install checksum: expected $K3S_SHA, actual $install_payload_sha" "$K3S_PAYLOAD"
	elif run "install -o root -g root -m 0755 $(printf %q "$K3S_PAYLOAD") $(printf %q "$K3S")"; then
		BINARY_READY=true
		step_ok "installed the checksum-verified k3s binary from $K3S_PAYLOAD_SOURCE at $K3S"
	else
		k3s_failure "could not install verified k3s binary" "$K3S_PAYLOAD"
	fi
else
	step_skip "k3s binary install skipped because neither payload source passed validation" "resolve the earlier FATAL entries"
fi

REGISTRIES_CHANGED=false
REGISTRIES_READY=false
registry_tmp=$(mktemp "${TMPDIR:-/tmp}/k3s-registries.XXXXXX") || registry_tmp=''
if [[ -z "$registry_tmp" ]]; then
	k3s_failure "could not create a temporary registries.yaml" "$REGISTRIES_FILE"
else
	printf 'mirrors:\n  docker.io:\n    endpoint:\n      - "https://%s"\n  registry.k8s.io:\n    endpoint:\n      - "https://%s"\nconfigs:\n  "%s":\n    tls:\n      ca_file: "%s"\n' "$DOCKER_REGISTRY" "$DOCKER_REGISTRY" "$REG_HOST" "$CA_CERT_SOURCE" > "$registry_tmp"
	if [[ -f "$REGISTRIES_FILE" ]] && cmp -s "$registry_tmp" "$REGISTRIES_FILE"; then
		REGISTRIES_READY=true
		step_ok "registries.yaml already matches the pinned k3s mirror format"
	elif run "install -D -o root -g root -m 0600 $(printf %q "$registry_tmp") $(printf %q "$REGISTRIES_FILE")"; then
		REGISTRIES_READY=true
		REGISTRIES_CHANGED=true
		step_ok "wrote registries.yaml before k3s first start"
	else
		k3s_failure "could not write registries.yaml before k3s startup" "$REGISTRIES_FILE"
	fi
	rm -f -- "$registry_tmp"
fi

if stage_optional_airgap_images; then :; else :; fi

if [[ "$SELINUX_READY" != true || "$BINARY_READY" != true || "$REGISTRIES_READY" != true || "$AIRGAP_IMAGES_READY" != true || "$K3S_RESOLUTION_FAILED" == true ]]; then
	step_skip "k3s start skipped because the binary, SELinux policy, or registry configuration did not validate" "fix the earlier FATAL entries"
	end_report "k3s was not started because its required preconditions failed"
	exit 1
fi

service_active=false
if systemctl is-active --quiet k3s 2>/dev/null; then service_active=true; fi
if [[ "$service_active" == true ]]; then
	if [[ "$K3S_CHANGED" == true || "$REGISTRIES_CHANGED" == true || "$AIRGAP_IMAGES_CHANGED" == true ]]; then
		if run 'systemctl restart k3s'; then step_ok "restarted existing k3s service after required updates"; else k3s_failure "could not restart existing k3s service" "k3s service"; fi
	else
		step_ok "k3s service is already active"
	fi
else
	if run "INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_SKIP_SELINUX_RPM=true bash $(printf %q "$INSTALLER")"; then
		step_ok "ran the vendored installer with binary and RPM downloads disabled"
		if run 'systemctl enable --now k3s'; then step_ok "enabled and started k3s"; else k3s_failure "could not enable/start k3s" "systemd service"; fi
	else
		k3s_failure "vendored k3s installer failed" "$INSTALLER"
	fi
fi

kubeconfig='/etc/rancher/k3s/k3s.yaml'
kube_dir="/home/$WORKSHOP_USER/.kube"
if [[ -s "$kubeconfig" ]]; then
	if run "install -d -o $(printf %q "$WORKSHOP_USER") -g $(printf %q "$WORKSHOP_USER") -m 0700 $(printf %q "$kube_dir") && install -o $(printf %q "$WORKSHOP_USER") -g $(printf %q "$WORKSHOP_USER") -m 0600 $(printf %q "$kubeconfig") $(printf %q "$kube_dir/config")"; then
		step_ok "installed restrictive kubeconfig for $WORKSHOP_USER"
	else
		k3s_failure "could not install learner kubeconfig" "$kubeconfig"
	fi
else
	k3s_failure "k3s did not produce its server kubeconfig" "$kubeconfig"
fi
if [[ ! -e /usr/local/bin/kubectl ]]; then
	if run 'ln -s /usr/local/bin/k3s /usr/local/bin/kubectl'; then step_ok "installed kubectl symlink to k3s"; else k3s_failure "could not install kubectl symlink" "/usr/local/bin/kubectl"; fi
fi

if timeout 180 "$K3S" kubectl wait --for=condition=Ready node --all --timeout=150s >/dev/null 2>&1; then
	step_ok "k3s node reached Ready"
else
	k3s_failure "k3s node did not reach Ready" "node"
fi
image_failures=0
while IFS= read -r image || [[ -n "$image" ]]; do
	[[ -n "$image" ]] || continue
	if "$K3S" crictl images 2>/dev/null | grep -Fq -- "$image"; then
		step_ok "k3s store already contains $image"
		continue
	fi
	pull_log=$(mktemp "${TMPDIR:-/tmp}/45-k3s-pull.XXXXXX") || pull_log=''
	if [[ -z "$pull_log" ]]; then k3s_failure "could not allocate a k3s image diagnostic log" "$image"; continue; fi
	if "$K3S" crictl pull "$image" >"$pull_log" 2>&1; then
		step_ok "k3s CRI pull returned success for $image"
	else
		((image_failures+=1))
		k3s_failure "k3s CRI image pull failed; Artifactory availability is not assumed: $(tail -n 3 "$pull_log" | tr '\n' '; ')" "$image"
	fi
	rm -f -- "$pull_log"
done < "$SYSTEM_IMAGES"
if ((image_failures == 0)); then step_ok "pinned k3s system image references are available through the CRI path"; fi
if "$K3S" kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed" {bad=1; print} END {exit bad}'; then
	step_ok "kube-system workloads are Running or Completed"
else
	k3s_failure "one or more kube-system workloads are not healthy" "kube-system pods"
fi

end_report "Review node, system-pod, and CRI pull evidence; continue with scripts/50-user-setup.sh only after required checks pass. Artifactory mirror success is recorded only when each learner-network command returns success."
((FAIL_COUNT == 0))
