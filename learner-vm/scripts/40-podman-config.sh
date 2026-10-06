#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="40-podman-config"
# CHANGE: Accept the shared library's normalised host-only or path-form registry endpoint.
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
	step_fail "unknown argument: $argument" "Run learner-vm/scripts/40-podman-config.sh [--dry-run]." "printf '%s\\n' --dry-run"
done
if ((EUID != 0)) && [[ "$DRY_RUN" == false ]]; then
	step_fail "Podman configuration requires root" "Run sudo learner-vm/scripts/40-podman-config.sh after script 30." "id -u"
	end_report "rerun with sudo"
	exit 1
elif ((EUID != 0)); then
	step_skip "root is required for real configuration; dry-run continues" "rerun with sudo on the learner VM"
fi

if ! validate_docker_registry "$DOCKER_REGISTRY"; then
	step_fail "DOCKER_REGISTRY must be a registry host or host/path" "Use docker-registry.\${ART_REPO_DOMAIN}, or the deployment's verified Artifactory registry path." "grep '^ART_REPO_DOMAIN=' $(printf '%q' "$CONFIG_FILE")"
	end_report "correct DOCKER_REGISTRY before writing registries.conf"
	exit 1
fi

registries_file='/etc/containers/registries.conf'
registries_tmp=''
sysctl_file='/etc/sysctl.d/99-lab.conf'
sysctl_tmp=''
cleanup() {
	[[ -z "$registries_tmp" ]] || rm -f -- "$registries_tmp"
	[[ -z "$sysctl_tmp" ]] || rm -f -- "$sysctl_tmp"
}
trap cleanup EXIT

if [[ "$DRY_RUN" == true ]]; then
	log "registries.conf v2 uses host/path mirror locations without URL schemes"
	for registry in docker.io ghcr.io quay.io registry.k8s.io; do
		log "would mirror $registry to $DOCKER_REGISTRY"
	done
	run "install -o root -g root -m 0644 <generated registries.conf> $(printf %q "$registries_file")"
	step_skip "registries.conf replacement was previewed" "$registries_file"
else
	registries_tmp=$(mktemp "${TMPDIR:-/tmp}/registries.conf.XXXXXX") || {
		step_fail "could not create temporary registries.conf" "Check temporary storage before writing Podman configuration." "df -hP /tmp" "ls -ld /tmp"
		end_report "free temporary space and rerun script 40"
		exit 1
	}
	{
		printf '# RHEL 8 containers/image v2 syntax. A mirror miss falls back to the original registry, which is unreachable on the isolated learner network, so the pull then fails predictably.\n'
		for registry in docker.io ghcr.io quay.io registry.k8s.io; do
			printf '\n[[registry]]\nprefix = "%s"\nlocation = "%s"\n[[registry.mirror]]\nlocation = "%s"\n' "$registry" "$registry" "$DOCKER_REGISTRY"
		done
	} > "$registries_tmp"
	if [[ -f "$registries_file" ]] && cmp -s "$registries_tmp" "$registries_file"; then
		step_ok "registries.conf already matches the four Artifactory mirror rules"
	elif run "install -o root -g root -m 0644 $(printf %q "$registries_tmp") $(printf %q "$registries_file")"; then
		step_ok "installed RHEL containers/image v2 registry mirror configuration"
	else
		step_fail "could not install Podman registries.conf" "Check /etc/containers permissions and DOCKER_REGISTRY syntax." "ls -ld /etc/containers" "sed -n '1,100p' $(printf %q "$registries_tmp")"
	fi
fi

sysctl_content='vm.max_map_count = 262144'
if [[ -f "$sysctl_file" ]] && [[ "$(cat "$sysctl_file")" == "$sysctl_content" ]]; then
	step_ok "OpenSearch vm.max_map_count setting is already persisted"
elif [[ "$DRY_RUN" == true ]]; then
	run "install -o root -g root -m 0644 <vm.max_map_count config> $(printf %q "$sysctl_file")"
	step_skip "vm.max_map_count persistence was previewed" "$sysctl_file"
else
	sysctl_tmp=$(mktemp "${TMPDIR:-/tmp}/99-lab.conf.XXXXXX") || {
		step_fail "could not create temporary sysctl config" "Check temporary storage." "df -hP /tmp" "ls -ld /tmp"
		sysctl_tmp=''
	}
	if [[ -n "$sysctl_tmp" ]]; then
		printf '%s' "$sysctl_content" > "$sysctl_tmp"
		if run "install -o root -g root -m 0644 $(printf %q "$sysctl_tmp") $(printf %q "$sysctl_file") && sysctl --system"; then
			step_ok "persisted vm.max_map_count=262144 for OpenSearch"
		else
			step_fail "could not apply vm.max_map_count" "Install the sysctl file and reapply it before the OpenSearch lab." "cat $(printf %q "$sysctl_file")" "sysctl -n vm.max_map_count"
		fi
	fi
fi

if [[ "$DRY_RUN" == true ]]; then
	step_skip "Podman parser, rootful-store, and anonymous mirror probes were not executed during dry-run" "run script 40 on the learner VM after script 20"
else
	if command -v podman >/dev/null 2>&1; then
		if podman_output="$(podman info --format '{{.Host.Security.Rootless}}' 2>&1)"; then
			if [[ "$podman_output" == false ]]; then step_ok "Podman parses registries.conf and uses the rootful store"; else step_fail "Podman is rootless or did not report its rootless state" "Run this script with sudo and use the rootful Podman store." "podman info --debug 2>&1 | tail -n 20"; fi
		else
			step_fail "Podman info rejected the registry configuration" "Use RHEL 8 registries.conf v2 syntax with host/path locations and no URL scheme." "podman info --debug 2>&1 | tail -n 20" "sed -n '1,100p' $(printf %q "$registries_file")"
		fi
	else
		step_fail "Podman is not installed" "Run learner-vm/scripts/20-install-tooling.sh first." "rpm -q podman" "command -v podman"
	fi

	if command -v sysctl >/dev/null 2>&1; then
		if sysctl -n vm.max_map_count 2>/dev/null | grep -qx 262144; then
			step_ok "vm.max_map_count is 262144"
		elif run 'sysctl -w vm.max_map_count=262144'; then
			step_ok "applied vm.max_map_count=262144"
		else
			step_fail "vm.max_map_count could not be set to 262144" "Check /etc/sysctl.d/99-lab.conf and the OpenSearch host requirement." "cat $(printf '%q' "$sysctl_file")" "sysctl -n vm.max_map_count"
		fi
	fi

	if command -v skopeo >/dev/null 2>&1; then
		probe_output=''
		if probe_output="$(skopeo inspect --format '{{.Digest}}' docker://docker.io/library/busybox:1.36 2>&1)"; then
			step_ok "anonymous Skopeo mirror probe succeeded for docker.io/library/busybox:1.36 ($probe_output)"
		elif grep -q '401' <<< "$probe_output"; then
			step_fail "Artifactory mirror returned HTTP 401 for anonymous image access; this is a design blocker" "Confirm anonymous-read policy at the registry mirror; do not add credentials to the VM." "getent hosts $(printf '%q' "$REG_HOST")" "skopeo --debug inspect docker://docker.io/library/busybox:1.36 2>&1 | tail -n 20" "sed -n '1,100p' $(printf '%q' "$registries_file")"
		else
			step_fail "anonymous Skopeo mirror probe failed" "Verify DNS, CA trust, and Artifactory availability; registry pull success is not assumed." "getent hosts $(printf '%q' "$REG_HOST")" "skopeo --debug inspect docker://docker.io/library/busybox:1.36 2>&1 | tail -n 20" "sed -n '1,100p' $(printf '%q' "$registries_file")"
		fi
	else
		step_fail "Skopeo is not installed" "Run learner-vm/scripts/20-install-tooling.sh first." "rpm -q skopeo" "command -v skopeo"
	fi
fi

end_report "Review registry and sysctl checks, then continue with scripts/45-k3s-install.sh only after Artifactory access succeeds on this VM."
((FAIL_COUNT == 0))
