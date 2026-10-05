#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="45-k3s-install"
# CHANGE: Prefer and validate same-VM recovery staging before an installed binary or bounded Artifactory fetch.
SCRIPT_VERSION="5"
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
K3S_MANUAL_PAYLOAD="$MANUAL_FETCH_DIR/k3s/k3s"
K3S_PAYLOAD="$K3S_MANUAL_PAYLOAD"
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

locked_sha256() {
	local key="$1"
	awk -v key="$key" '$1 == key {for (i=1;i<=NF;i++) if ($i ~ /^sha256:/) {sub(/^sha256:/,"",$i); print $i; exit}}' "$REPO_ROOT/versions.lock"
}

parse_k3s_url() {
	python3 - "$K3S_BINARY_URL" "$ART_HOST" <<'PY'
import sys
from urllib.parse import urlsplit, urlunsplit
parsed=urlsplit(sys.argv[1])
expected_host=sys.argv[2].lower()
if parsed.scheme != "https" or not parsed.hostname or parsed.hostname.lower() != expected_host:
    raise SystemExit(1)
try:
    port=parsed.port
except ValueError:
    raise SystemExit(1)
authority=parsed.hostname + (f":{port}" if port else "")
print(parsed.hostname)
print(authority if port else authority + ":443")
print(urlunsplit(("https", authority, parsed.path, "", "")))
PY
}

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
K3S_SHA="$(locked_sha256 learner-k3s-binary-amd64)"
if [[ ! "$K3S_SHA" =~ ^[0-9a-f]{64}$ ]]; then
	step_fail "versions.lock lacks a valid k3s binary SHA-256" "Restore the learner-k3s-binary-amd64 pin in versions.lock on the connected source tree." "grep '^learner-k3s-binary-amd64 ' $(printf %q "$REPO_ROOT/versions.lock")" "sed -n '/learner-k3s-binary-amd64/p' $(printf %q "$REPO_ROOT/versions.lock")"
	end_report "restore the pinned k3s binary hash before retrying"
	exit 1
fi

K3S_VALID=false
if [[ "$DRY_RUN" == true ]]; then
	step_skip "staged binary lookup, Artifactory download, and checksum are target-side and were not executed during dry-run" "use $K3S_MANUAL_PAYLOAD first, otherwise set K3S_BINARY_URL to the administrator-supplied Artifactory generic-file URL"
	K3S_PAYLOAD_SOURCE='not selected during dry-run'
	K3S_VALID=false
else
	if [[ -e "$K3S_MANUAL_PAYLOAD" || -L "$K3S_MANUAL_PAYLOAD" ]]; then
		K3S_PAYLOAD="$K3S_MANUAL_PAYLOAD"
		K3S_PAYLOAD_SOURCE='MANUAL_FETCH_DIR fallback'
		if actual="$(sha256sum "$K3S_PAYLOAD" 2>/dev/null | awk '{print $1}')" && [[ "$actual" == "$K3S_SHA" ]]; then
			K3S_VALID=true
			step_ok "same-VM staged k3s binary is checksum-valid: $K3S_PAYLOAD"
		else
			step_fail "same-VM staged k3s binary checksum mismatch: K3S_BINARY_URL=${K3S_BINARY_URL_SAFE}; expected SHA-256 $K3S_SHA, actual ${actual:-unavailable}" "Follow MANUAL-FETCH.md Section B to correct K3S_BINARY_URL or replace the staged file, then verify against versions.lock." "sha256sum $(printf %q "$K3S_MANUAL_PAYLOAD")" "grep '^learner-k3s-binary-amd64 ' $(printf %q "$REPO_ROOT/versions.lock")"
		fi
	elif [[ -x "$K3S" ]] && [[ "$(sha256sum "$K3S" 2>/dev/null | awk '{print $1}')" == "$K3S_SHA" ]]; then
		K3S_VALID=true
		K3S_PAYLOAD="$K3S"
		K3S_PAYLOAD_SOURCE='already-installed pinned binary'
		step_ok "existing k3s binary already matches the versions.lock SHA-256"
	elif [[ -z "${K3S_BINARY_URL:-}" ]]; then
		step_fail "K3S_BINARY_URL is unset and no same-VM staged k3s binary exists" "Obtain the exact Artifactory generic-file URL from the administrator and set K3S_BINARY_URL, or download the pinned binary on this VM to $K3S_MANUAL_PAYLOAD." "awk -F= '/^K3S_BINARY_URL=/ {print \"K3S_BINARY_URL is configured (value redacted)\"; found=1} END {if (!found) print \"K3S_BINARY_URL is unset\"}' $(printf '%q' "$CONFIG_FILE")" "ls -ld $(printf '%q' "$MANUAL_FETCH_DIR/k3s")" "grep '^learner-k3s-binary-amd64 ' $(printf '%q' "$REPO_ROOT/versions.lock")"
	else
		url_info=''
		if url_info="$(parse_k3s_url 2>/dev/null)"; then
			mapfile -t url_parts <<< "$url_info"
			K3S_BINARY_HOST="${url_parts[0]}"
			K3S_BINARY_CONNECT="${url_parts[1]}"
			K3S_BINARY_URL_SAFE="${url_parts[2]}"
			download_tmp=$(mktemp "${TMPDIR:-/tmp}/k3s-binary.XXXXXX") || download_tmp=''
			fetch_log=$(mktemp "${TMPDIR:-/tmp}/k3s-fetch.XXXXXX") || fetch_log=''
			status_file=$(mktemp "${TMPDIR:-/tmp}/k3s-fetch-status.XXXXXX") || status_file=''
			if [[ -z "$download_tmp$fetch_log$status_file" ]]; then
				[[ -z "$download_tmp" ]] || rm -f -- "$download_tmp"
				[[ -z "$fetch_log" ]] || rm -f -- "$fetch_log"
				[[ -z "$status_file" ]] || rm -f -- "$status_file"
				step_fail "could not create temporary files for the k3s Artifactory fetch" "Check temporary storage before retrying script 45." "df -hP /tmp" "ls -ld /tmp"
			else
				TEMP_FILES+=("$download_tmp" "$fetch_log" "$status_file")
				fetch_exit=0
				if curl --fail --silent --show-error --connect-timeout 15 --max-time 900 --output "$download_tmp" --write-out '%{http_code}' "$K3S_BINARY_URL" >"$status_file" 2>"$fetch_log"; then :; else fetch_exit=$?; fi
				fetch_http="$(cat "$status_file" 2>/dev/null || printf '000')"
				if ((fetch_exit != 0)) || [[ "$fetch_http" != 200 ]]; then
					fetch_actual='unavailable'
					if [[ -s "$download_tmp" ]]; then fetch_actual="$(sha256sum "$download_tmp" | awk '{print $1}')"; fi
					K3S_ERROR_SUMMARY="$(sed -E 's#https?://[^[:space:]]+#<URL>#g' "$fetch_log" | tail -n 4 | tr '\n' '; ')"
					step_fail "k3s binary fetch failed from $K3S_BINARY_URL_SAFE (curl exit $fetch_exit, HTTP ${fetch_http:-000}): ${K3S_ERROR_SUMMARY:-no curl error text}; expected SHA-256 $K3S_SHA, actual ${fetch_actual}" "Set K3S_BINARY_URL to the administrator-supplied Artifactory generic-file URL and follow MANUAL-FETCH.md Section B for same-VM recovery." "getent hosts $(printf %q "$K3S_BINARY_HOST")" "curl -vI --connect-timeout 5 --max-time 10 $(printf %q "$K3S_BINARY_URL_SAFE") 2>&1 | tail -n 12" "printf '' | openssl s_client -connect $(printf %q "$K3S_BINARY_CONNECT") -servername $(printf %q "$K3S_BINARY_HOST") 2>&1 | tail -n 12" "cat $(printf %q "$REGISTRIES_FILE")" "journalctl -u k3s -b --no-pager | tail -n 15"
				else
					actual="$(sha256sum "$download_tmp" | awk '{print $1}')"
					if [[ "$actual" == "$K3S_SHA" ]]; then
						K3S_VALID=true
						K3S_PAYLOAD="$download_tmp"
						K3S_PAYLOAD_SOURCE='K3S_BINARY_URL'
						step_ok "downloaded k3s binary from the configured Artifactory endpoint and verified SHA-256 $actual (HTTP $fetch_http)"
					else
						step_fail "downloaded k3s binary SHA-256 mismatch from $K3S_BINARY_URL_SAFE (HTTP $fetch_http): expected $K3S_SHA, actual $actual" "Do not install this file. Correct K3S_BINARY_URL and follow MANUAL-FETCH.md Section B for same-VM recovery." "sha256sum $(printf %q "$download_tmp")" "grep '^learner-k3s-binary-amd64 ' $(printf %q "$REPO_ROOT/versions.lock")" "getent hosts $(printf %q "$K3S_BINARY_HOST")" "printf '' | openssl s_client -connect $(printf %q "$K3S_BINARY_CONNECT") -servername $(printf %q "$K3S_BINARY_HOST") 2>&1 | tail -n 12"
					fi
				fi
			fi
		else
			step_fail "K3S_BINARY_URL must be an HTTPS generic-file URL on ART_HOST" "Obtain the exact URL from the Artifactory administrator; do not use a public release URL." "printf '%s\\n' 'K3S_BINARY_URL is configured; value redacted'" "grep '^ART_HOST=' $(printf %q "$CONFIG_FILE")" "getent hosts $(printf %q "$ART_HOST")"
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

if [[ "$DRY_RUN" == true ]]; then
	run "rpm -Uvh $(printf %q "$SELINUX_RPM")"
	step_skip "k3s SELinux RPM installation was previewed before first start" "$SELINUX_RPM"
	step_skip "k3s binary download or local fallback install was previewed" "K3S_BINARY_URL is operator-supplied; its exact URL is not embedded in the ZIP"
	log "would write $REGISTRIES_FILE before the first k3s start using DOCKER_REGISTRY=$DOCKER_REGISTRY and CA_CERT_SOURCE=$CA_CERT_SOURCE"
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

if [[ "$SELINUX_READY" != true || "$BINARY_READY" != true || "$REGISTRIES_READY" != true ]]; then
	step_skip "k3s start skipped because the binary, SELinux policy, or registry configuration did not validate" "fix the earlier FATAL entries"
	end_report "k3s was not started because its required preconditions failed"
	exit 1
fi

service_active=false
if systemctl is-active --quiet k3s 2>/dev/null; then service_active=true; fi
if [[ "$service_active" == true ]]; then
	if [[ "$K3S_CHANGED" == true || "$REGISTRIES_CHANGED" == true ]]; then
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
