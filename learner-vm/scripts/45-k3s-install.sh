#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="45-k3s-install"
# CHANGE: Install pinned k3s from the self-contained ZIP payload, falling back to MANUAL_FETCH_DIR only when absent.
SCRIPT_VERSION="3"
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
K3S_ZIP_PAYLOAD="$REPO_ROOT/learner-vm/content/vendor/payload/k3s/k3s"
K3S_MANUAL_PAYLOAD="$MANUAL_FETCH_DIR/k3s/k3s"
AIRGAP_ZIP_PAYLOAD="$REPO_ROOT/learner-vm/content/vendor/payload/k3s/k3s-airgap-images-amd64.tar.zst"
AIRGAP_MANUAL_PAYLOAD="$MANUAL_FETCH_DIR/k3s/k3s-airgap-images-amd64.tar.zst"
K3S_PAYLOAD="$K3S_ZIP_PAYLOAD"
K3S_PAYLOAD_SOURCE='absent'
AIRGAP_PAYLOAD="$AIRGAP_ZIP_PAYLOAD"
AIRGAP_PAYLOAD_SOURCE='absent'
VENDOR_DIR="$REPO_ROOT/content/vendor/k3s"
INSTALLER="$VENDOR_DIR/install.sh"
SELINUX_RPM="$VENDOR_DIR/k3s-selinux-1.6-1.el8.noarch.rpm"
SYSTEM_IMAGES="$VENDOR_DIR/k3s-images.txt"
REGISTRIES_FILE='/etc/rancher/k3s/registries.yaml'
TEMP_FILES=()
cleanup() { ((${#TEMP_FILES[@]} == 0)) || rm -f -- "${TEMP_FILES[@]}"; }
trap cleanup EXIT

manual_sha256() {
	python3 - "$REPO_ROOT/content/vendor/manual-fetch.json" "$1" <<'PY'
import json,sys
with open(sys.argv[1],encoding="utf-8") as source: entries=json.load(source)
entry=next((item for item in entries if item.get("category")=="payload" and item.get("name")==sys.argv[2]),None)
if not entry or not isinstance(entry.get("sha256"),str): raise SystemExit(1)
print(entry["sha256"])
PY
}

k3s_failure() {
	local problem="$1" image="${2:-unknown}"
	step_fail "$problem" "Check CA trust and $REGISTRIES_FILE; payloads are read from the ZIP first, then $MANUAL_FETCH_DIR/k3s/ per Section B of content/vendor/MANUAL-FETCH.md. Artifactory pulls are not verified until this learner network returns success." \
		"$K3S --version" \
		"$K3S crictl --help" \
		"$K3S crictl images" \
		"$K3S ctr -n k8s.io images list" \
		"journalctl -u k3s -b --no-pager | tail -n 15" \
		"cat $(printf %q "$REGISTRIES_FILE")" \
		"tail -n 15 /var/lib/rancher/k3s/agent/containerd/containerd.log" \
		"printf '%s\\n' $(printf %q "$image")"
}

if [[ ! -s "$REPO_ROOT/content/vendor/manual-fetch.json" ]] || ! command -v python3 >/dev/null 2>&1; then
	step_fail "manual-fetch catalog or Python 3 is unavailable" "Restore content/vendor/manual-fetch.json and install Python 3 before installing k3s." "ls -l $(printf %q "$REPO_ROOT/content/vendor/manual-fetch.json")" "command -v python3"
	end_report "restore the catalog and Python 3 before retrying"
	exit 1
fi
K3S_SHA="$(manual_sha256 k3s/k3s 2>/dev/null || true)"
AIRGAP_SHA="$(manual_sha256 k3s/k3s-airgap-images-amd64.tar.zst 2>/dev/null || true)"
if [[ ! "$K3S_SHA" =~ ^[0-9a-f]{64}$ || ! "$AIRGAP_SHA" =~ ^[0-9a-f]{64}$ ]]; then
	step_fail "manual-fetch catalog lacks valid pinned k3s payload hashes" "Regenerate content/vendor/manual-fetch.json from versions.lock on the connected machine." "python3 -m json.tool $(printf '%q' "$REPO_ROOT/content/vendor/manual-fetch.json")" "grep -n 'k3s/k3s' $(printf '%q' "$REPO_ROOT/content/vendor/manual-fetch.json")"
	end_report "restore the two catalog payload rows before installing k3s"
	exit 1
fi

K3S_VALID=false
if [[ "$DRY_RUN" == true ]]; then
	step_skip "required k3s payload presence/checksum are target-side and were not read during dry-run" "ZIP first: $K3S_ZIP_PAYLOAD; fallback: $K3S_MANUAL_PAYLOAD; SHA-256 $K3S_SHA"
	K3S_PAYLOAD_SOURCE='not selected during dry-run'
else
	if [[ -e "$K3S_ZIP_PAYLOAD" || -L "$K3S_ZIP_PAYLOAD" ]]; then
		K3S_PAYLOAD="$K3S_ZIP_PAYLOAD"
		K3S_PAYLOAD_SOURCE='single-ZIP payload'
	elif [[ -e "$K3S_MANUAL_PAYLOAD" || -L "$K3S_MANUAL_PAYLOAD" ]]; then
		K3S_PAYLOAD="$K3S_MANUAL_PAYLOAD"
		K3S_PAYLOAD_SOURCE='MANUAL_FETCH_DIR fallback'
	fi
	if [[ "$K3S_PAYLOAD_SOURCE" == 'absent' ]]; then
		step_fail "required k3s binary is absent from both payload locations" "The ZIP must contain learner-vm/content/vendor/payload/k3s/k3s; fallback path is $K3S_MANUAL_PAYLOAD. See Section B of content/vendor/MANUAL-FETCH.md." "ls -l $(printf %q "$K3S_ZIP_PAYLOAD")" "ls -l $(printf %q "$K3S_MANUAL_PAYLOAD")" "grep -n 'k3s/k3s' $(printf %q "$REPO_ROOT/content/vendor/MANUAL-FETCH.md")"
	else
		if actual="$(sha256sum "$K3S_PAYLOAD" 2>/dev/null | awk '{print $1}')"; then :; else actual='unavailable'; fi
		if [[ "$actual" == "$K3S_SHA" ]]; then
			K3S_VALID=true
			step_ok "required k3s binary found at $K3S_PAYLOAD_SOURCE ($K3S_PAYLOAD) and checksum-valid"
		else
			step_fail "k3s binary checksum mismatch at $K3S_PAYLOAD: expected $K3S_SHA, actual $actual" "Restore the payload in the single ZIP or replace the fallback at $K3S_MANUAL_PAYLOAD using Section B of content/vendor/MANUAL-FETCH.md." "sha256sum $(printf %q "$K3S_PAYLOAD")" "grep -n 'k3s/k3s' $(printf %q "$REPO_ROOT/content/vendor/manual-fetch.json")"
		fi
	fi
fi

SUPPORT_VALID=false
if [[ -s "$INSTALLER" && -s "$SELINUX_RPM" && -s "$SYSTEM_IMAGES" ]] && (cd "$VENDOR_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
	SUPPORT_VALID=true
	step_ok "vendored installer, system image list, and SELinux RPM match SHA256SUMS"
else
	step_fail "retained k3s support files are missing or checksum-invalid" "Restore the small files listed by content/vendor/k3s/SHA256SUMS from the repository ZIP." "ls -l $(printf %q "$VENDOR_DIR")" "(cd $(printf %q "$VENDOR_DIR") && sha256sum -c SHA256SUMS)"
fi

AIRGAP_VALID=false
AIRGAP_INPUT_OK=true
if [[ "$DRY_RUN" == true ]]; then
	step_skip "optional airgap tarball presence/checksum are target-side and were not read during dry-run" "ZIP first: $AIRGAP_ZIP_PAYLOAD; fallback: $AIRGAP_MANUAL_PAYLOAD; SHA-256 $AIRGAP_SHA"
else
	if [[ -e "$AIRGAP_ZIP_PAYLOAD" || -L "$AIRGAP_ZIP_PAYLOAD" ]]; then
		AIRGAP_PAYLOAD="$AIRGAP_ZIP_PAYLOAD"
		AIRGAP_PAYLOAD_SOURCE='single-ZIP payload'
	elif [[ -e "$AIRGAP_MANUAL_PAYLOAD" || -L "$AIRGAP_MANUAL_PAYLOAD" ]]; then
		AIRGAP_PAYLOAD="$AIRGAP_MANUAL_PAYLOAD"
		AIRGAP_PAYLOAD_SOURCE='MANUAL_FETCH_DIR fallback'
	fi
	if [[ "$AIRGAP_PAYLOAD_SOURCE" == 'absent' ]]; then
		step_skip "optional airgap tarball is absent from ZIP and manual staging; bootstrap will use Artifactory CRI pulls, not yet verified on the learner network" "recover the optional file to $AIRGAP_MANUAL_PAYLOAD using Section B of content/vendor/MANUAL-FETCH.md if required"
	else
		if actual="$(sha256sum "$AIRGAP_PAYLOAD" 2>/dev/null | awk '{print $1}')"; then :; else actual='unavailable'; fi
		if [[ "$actual" == "$AIRGAP_SHA" ]]; then
			AIRGAP_VALID=true
			step_ok "optional k3s system-image fallback found at $AIRGAP_PAYLOAD_SOURCE ($AIRGAP_PAYLOAD) and checksum-valid"
		else
			AIRGAP_INPUT_OK=false
			step_fail "optional airgap tarball checksum mismatch at $AIRGAP_PAYLOAD: expected $AIRGAP_SHA, actual $actual" "Restore the ZIP payload or recover the pinned fallback to $AIRGAP_MANUAL_PAYLOAD using Section B of content/vendor/MANUAL-FETCH.md." "sha256sum $(printf %q "$AIRGAP_PAYLOAD")" "grep -n 'k3s-airgap-images' $(printf %q "$REPO_ROOT/content/vendor/manual-fetch.json")"
		fi
	fi
fi

if [[ "$DRY_RUN" == true ]]; then
	run "rpm -Uvh $(printf %q "$SELINUX_RPM")"
	step_skip "k3s SELinux RPM installation was previewed before first start" "$SELINUX_RPM"
	run "install -o root -g root -m 0755 $(printf %q "$K3S_PAYLOAD") $K3S"
	step_skip "pinned k3s binary installation was previewed" "$K3S"
	log "would write $REGISTRIES_FILE before the first k3s start using DOCKER_REGISTRY=$DOCKER_REGISTRY and CA_CERT_SOURCE=$CA_CERT_SOURCE"
	if [[ "$AIRGAP_VALID" == true ]]; then run "install -D -o root -g root -m 0600 $(printf %q "$AIRGAP_PAYLOAD") /var/lib/rancher/k3s/agent/images/k3s-airgap-images-amd64.tar.zst"; fi
	step_skip "vendored install.sh would run with INSTALL_K3S_SKIP_DOWNLOAD=true and INSTALL_K3S_SKIP_SELINUX_RPM=true" "$INSTALLER"
	step_skip "k3s service, kubeconfig, node readiness, and CRI pulls are target-side and were not executed during dry-run" "the actual pull result is recorded only on the learner network"
	end_report "review the pinned payload and registry order; run without --dry-run on the learner VM"
	exit 0
fi

if [[ "$K3S_VALID" != true || "$SUPPORT_VALID" != true || "$AIRGAP_INPUT_OK" != true ]]; then
	step_skip "k3s installation stopped because a required input or a supplied optional fallback failed validation" "resolve the earlier FATAL entries before starting k3s"
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

AIRGAP_STAGED=false
AIRGAP_CHANGED=false
if [[ "$AIRGAP_VALID" == true ]]; then
	image_dir='/var/lib/rancher/k3s/agent/images'
	image_target="$image_dir/k3s-airgap-images-amd64.tar.zst"
	if [[ -s "$image_target" ]] && cmp -s "$AIRGAP_PAYLOAD" "$image_target"; then
		AIRGAP_STAGED=true
		step_ok "verified airgap images are already staged before k3s start"
	elif run "install -D -o root -g root -m 0600 $(printf %q "$AIRGAP_PAYLOAD") $(printf %q "$image_target")"; then
		AIRGAP_STAGED=true
		AIRGAP_CHANGED=true
		step_ok "copied optional verified airgap images before first k3s start"
	else
		k3s_failure "could not stage optional k3s airgap images" "$AIRGAP_PAYLOAD"
	fi
fi

if [[ "$SELINUX_READY" != true || "$BINARY_READY" != true || "$REGISTRIES_READY" != true || ( "$AIRGAP_VALID" == true && "$AIRGAP_STAGED" != true ) ]]; then
	step_skip "k3s start skipped because a required binary, SELinux, registry, or supplied-fallback stage did not validate" "fix the earlier FATAL entries"
	end_report "k3s was not started because its required preconditions failed"
	exit 1
fi

service_active=false
if systemctl is-active --quiet k3s 2>/dev/null; then service_active=true; fi
if [[ "$service_active" == true ]]; then
	if [[ "$K3S_CHANGED" == true || "$REGISTRIES_CHANGED" == true || "$AIRGAP_CHANGED" == true ]]; then
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
