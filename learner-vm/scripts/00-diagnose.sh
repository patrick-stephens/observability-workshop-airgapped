#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="00-diagnose"
# CHANGE: Check a staged k3s binary or probe the operator-supplied Artifactory URL without downloading it.
# SCRIPT_VERSION 9: Use K3S_BINARY_URL and the versions.lock binary pin; no bundled payload is required.
SCRIPT_VERSION="9"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELFTEST=false
DRY_RUN=false
UNKNOWN_ARGUMENTS=()

for argument in "$@"; do
    case "$argument" in
        --selftest) SELFTEST=true ;;
        --dry-run) DRY_RUN=true ;;
        *) UNKNOWN_ARGUMENTS+=("$argument") ;;
    esac
done

SELFTEST_MODE="$SELFTEST"
if ! source "$SCRIPT_DIR/lib.sh"; then
    exit 0
fi

begin_report
for argument in "${UNKNOWN_ARGUMENTS[@]}"; do
    step_fail "unknown argument: $argument" "Use learner-vm/scripts/00-diagnose.sh with --selftest, --dry-run, or no argument." "printf '%s\\n' --selftest --dry-run"
done

if [[ "$SELFTEST" == "true" ]]; then
    step_ok "synthetic self-test check one"
    step_ok "synthetic self-test check two"
    step_fail "synthetic dependency failure" "Install the missing dependency from learner-vm/lab-vm.conf." \
        "printf 'synthetic diagnostic output\\n'" \
        "lab-selftest-command-that-does-not-exist"
    step_skip "synthetic optional dependency is absent" "optional self-test tool"
    end_report "review the synthetic report; no provisioning was attempted"
    exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
    run "true"
    step_skip "--dry-run requested" "read-only diagnostics were not executed"
    end_report "rerun without --dry-run to collect the read-only environment report"
    exit 0
fi

if [[ "${WORKSHOP_USER:-}" == "engineer" ]]; then
    step_ok "WORKSHOP_USER is the required engineer account"
else
    step_fail "WORKSHOP_USER must be engineer" "Set WORKSHOP_USER=\"engineer\" in learner-vm/lab-vm.conf; the planned preflight requires this account." "grep '^WORKSHOP_USER=' $(printf '%q' "$CONFIG_FILE")" "getent passwd engineer"
fi

compact_output() {
    local flattened="${1//$'\n'/; }"
    printf '%s' "${flattened:0:180}"
}

check_binary() {
    local binary="$1" description="$2" version_output version_line
    if require_or_skip "$binary" "$description"; then
        if version_output="$($binary --version 2>&1)"; then :; else version_output="version command failed"; fi
        version_line="${version_output%%$'\n'*}"
        step_ok "$description: $version_line"
    fi
}

check_iso() {
    local iso_path="${ISO_PATH:-}" mount_dir="" mount_options="ro" mounted=false
    if [[ -z "$iso_path" ]]; then
        step_skip "ISO_PATH is empty" "set ISO_PATH in learner-vm/lab-vm.conf to an ISO file or CD-ROM device"
        return
    fi
    if [[ -f "$iso_path" ]]; then
        mount_options="loop,ro"
    elif [[ ! -b "$iso_path" && ! -c "$iso_path" ]]; then
        step_skip "ISO is unavailable" "$iso_path is neither a readable file nor a device"
        return
    fi
    if ((EUID != 0)); then
        step_skip "ISO mount check requires root" "rerun 00-diagnose with sudo to inspect $iso_path"
        return
    fi
    if ! require_or_skip mount "ISO mount check" || ! require_or_skip mktemp "ISO mount directory"; then
        return
    fi
    if mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/lab-iso.XXXXXX" 2>/dev/null)"; then :; else
        step_skip "ISO mount check" "could not create a temporary mount directory"
        return
    fi
    if mount -o "$mount_options" "$iso_path" "$mount_dir" >/dev/null 2>&1; then
        mounted=true
        if [[ -d "$mount_dir/BaseOS" && -d "$mount_dir/AppStream" ]]; then
            if [[ -f "$iso_path" ]]; then
                step_ok "ISO file mounted read-only; BaseOS/ and AppStream/ found"
            else
                step_ok "ISO device $iso_path mounted read-only; BaseOS/ and AppStream/ found"
            fi
        else
            step_fail "mounted ISO lacks BaseOS/ or AppStream/" "Attach the RHEL 8.6 installation ISO named by ISO_PATH in learner-vm/lab-vm.conf." "find $(printf '%q' "$mount_dir") -maxdepth 2 -type d" "findmnt $(printf '%q' "$mount_dir")"
        fi
    else
        step_skip "ISO could not be mounted" "check that $iso_path is attached and contains the RHEL 8.6 media"
    fi
    if [[ "$mounted" == "true" ]] && ! umount "$mount_dir" >/dev/null 2>&1; then
        step_fail "temporary ISO mount could not be unmounted" "Unmount $mount_dir before continuing." "mountpoint $mount_dir"
    fi
    rmdir "$mount_dir" 2>/dev/null || true
}

registry_diagnostics() {
    local label="$1" request_url="$2" fallback_url="$3" fix_hint="$4" host_quoted request_quoted fallback_quoted tls_target
    printf -v host_quoted '%q' "$ART_HOST"
    printf -v request_quoted '%q' "$request_url"
    printf -v fallback_quoted '%q' "$fallback_url"
    tls_target="${REG_HOST}:443"
    if [[ "$REG_HOST" == *:* ]]; then tls_target="$REG_HOST"; fi
    step_fail "$label" "$fix_hint" \
        "getent hosts $host_quoted" \
        "curl -v --connect-timeout 10 --max-time 10 -o /dev/null $request_quoted 2>&1 | tail -n 10" \
        "printf '' | openssl s_client -connect ${tls_target} -servername ${REG_HOST%%:*} 2>/dev/null | openssl x509 -noout -subject -issuer" \
        "curl -sS --connect-timeout 10 --max-time 10 -o /dev/null -w 'HTTP %{http_code}\\n' $fallback_quoted"
}

check_http_status() {
    local label="$1" url="$2" expected="$3" accept_header="${4:-}" status="000"
    local curl_args=(--connect-timeout 10 --max-time 10 -sS -o /dev/null -w '%{http_code}')
    if [[ -n "$accept_header" ]]; then curl_args+=(-H "Accept: $accept_header"); fi
    if status="$(curl "${curl_args[@]}" "$url" 2>/dev/null)"; then :; fi
    if [[ " $expected " == *" $status "* ]]; then
        step_ok "$label: HTTP $status"
    else
        local fallback_path="/v2/" fallback_url="https://${ART_HOST}/v2/" fix_hint
        if [[ "$url" == "https://${DOCKER_REGISTRY}/v2/" ]]; then
            fallback_path="/v2/"
            fallback_url="https://${ART_HOST}${fallback_path}"
        elif [[ "$url" == "https://${ART_HOST}/" ]]; then
            fallback_url="https://${ART_HOST}/v2/"
        elif [[ "$url" == "https://${DOCKER_REGISTRY}"* ]]; then
            fallback_path="${url#https://"${DOCKER_REGISTRY}"/v2}"
            fallback_url="https://${ART_HOST}/v2${fallback_path}"
        fi
        case "$status" in
            401) fix_hint="Registry authentication is required despite anonymous-pull confirmation; escalate this design change to the Artifactory administrator." ;;
            404) fix_hint="The image is not cached or the registry path is wrong; confirm DOCKER_REGISTRY and warm the image before script 60." ;;
            *) fix_hint="Check ART_HOST, DOCKER_REGISTRY, the OS CA trust store, and the Artifactory route." ;;
        esac
        registry_diagnostics "$label: HTTP $status" "$url" "$fallback_url" "$fix_hint"
    fi
}

check_manifest() {
    local reference="$1" reference_path first_component last_component repository tag manifest_path url
    [[ -n "$reference" && "$reference" != \#* ]] || return 0
    reference_path="$reference"
    first_component="${reference_path%%/*}"
    if [[ "$first_component" == *.* || "$first_component" == *:* || "$first_component" == "localhost" ]]; then
        reference_path="${reference_path#*/}"
    fi
    if [[ "$reference_path" != */* ]]; then reference_path="library/$reference_path"; fi
    last_component="${reference_path##*/}"
    if [[ "$last_component" != *:* ]]; then
        step_skip "registry image has no tag" "$reference"
        return 0
    fi
    tag="${last_component##*:}"
    repository="${reference_path%:*}"
    manifest_path="/$repository/manifests/$tag"
    url="https://${DOCKER_REGISTRY}/v2${manifest_path}"
    check_http_status "registry manifest $reference" "$url" "200" "application/vnd.docker.distribution.manifest.v2+json"
}

image_repository() {
    local reference="$1" first_component
    first_component="${reference%%/*}"
    if [[ "$first_component" == *.* || "$first_component" == *:* || "$first_component" == "localhost" ]]; then
        reference="${reference#*/}"
    fi
    reference="${reference%:*}"
    if [[ "$reference" != */* ]]; then reference="library/$reference"; fi
    printf '%s' "$reference"
}

if [[ -r /etc/redhat-release ]]; then
    release_name="$(</etc/redhat-release)"
    step_ok "RHEL release: $release_name"
else
    step_skip "/etc/redhat-release is unavailable" "RHEL release identification"
fi
if require_or_skip uname "system architecture"; then step_ok "architecture: $(uname -m)"; fi
if require_or_skip hostname "system hostname"; then step_ok "hostname: $(hostname)"; fi
if require_or_skip hostname "IP address inventory"; then step_ok "hostname -I: $(hostname -I 2>/dev/null || printf 'unavailable')"; fi
if require_or_skip free "memory inventory"; then step_ok "memory (GiB): $(free -g 2>&1 | awk '/^Mem:/ {print $2 " total, " $7 " available"}' || true)"; fi
if require_or_skip df "disk inventory"; then
    step_ok "disk space: $(df -hP / /var/lib 2>&1 | awk 'NR <= 3 {printf "%s%s", (NR == 1 ? "" : "; "), $0}' || true)"
fi

if require_or_skip id "workshop user inventory"; then
    if id "$WORKSHOP_USER" >/dev/null 2>&1; then
        user_groups="$(id -nG "$WORKSHOP_USER" 2>/dev/null || true)"
        if [[ " $user_groups " == *" wheel "* ]]; then
            step_ok "$WORKSHOP_USER exists and belongs to wheel"
        else
            step_fail "$WORKSHOP_USER is not a wheel member" "Check WORKSHOP_USER in learner-vm/lab-vm.conf and add the user to wheel using the approved base-image process." "id $(printf '%q' "$WORKSHOP_USER")" "getent group wheel"
        fi
        if grep -R -E "^[[:space:]]*${WORKSHOP_USER}[[:space:]].*NOPASSWD|^[[:space:]]*%wheel[[:space:]].*NOPASSWD" /etc/sudoers /etc/sudoers.d 2>/dev/null; then
            step_skip "passwordless sudo is already configured" "script 50 normally configures it; wrappers require it"
        else
            step_skip "passwordless sudo is absent as expected" "script 50 will configure it because auto-elevate wrappers require non-interactive sudo"
        fi
    else
        step_fail "$WORKSHOP_USER does not exist" "Create $WORKSHOP_USER in the base image and add it to wheel." "getent passwd $(printf '%q' "$WORKSHOP_USER")" "grep '^WORKSHOP_USER=' $(printf '%q' "$CONFIG_FILE")"
    fi
fi
if require_or_skip visudo "sudoers syntax validator"; then step_ok "visudo is installed"; fi

check_iso

if require_or_skip curl "Artifactory and registry HTTPS probes"; then
    check_http_status "Artifactory root" "https://${ART_HOST}/" "200 302"
    check_http_status "registry v2 endpoint" "https://${DOCKER_REGISTRY}/v2/" "200"
    external_images="$REPO_ROOT/content/extracted/external-images.txt"
    declare -A probed_images=()
    known_images=(
        "docker.io/library/busybox:1.36"
        "ghcr.io/fluent/fluent-bit:5.1.1"
        "quay.io/prometheus/node-exporter:v1.12.1"
    )
    for image in "${known_images[@]}"; do
        probed_images["$image"]=1
        check_manifest "$image"
    done
    if [[ -r "$external_images" ]]; then
        while IFS= read -r image || [[ -n "$image" ]]; do
            [[ -n "$image" && -z "${probed_images[$image]+x}" ]] || continue
            probed_images["$image"]=1
            for known_image in "${known_images[@]}"; do
                if [[ "$image" != "$known_image" && "$(image_repository "$image")" == "$(image_repository "$known_image")" ]]; then
                    step_skip "external-images.txt tag differs from recon tag $known_image" "probing $image because the committed content inventory is authoritative"
                fi
            done
            check_manifest "$image"
        done <"$external_images"
        step_ok "additional tagged images from external-images.txt were included in registry probes"
    else
        step_skip "external image inventory is unavailable" "transfer content/extracted/external-images.txt from the online capture"
    fi
fi

if require_or_skip dnf "DNF repository and module checks"; then
    if dnf_output="$(dnf -q repolist 2>&1)"; then
        step_ok "dnf repolist: $(compact_output "$dnf_output")"
    else
        step_fail "dnf repolist failed" "Repair the BaseOS, AppStream, and EPEL Artifactory repositories." "dnf -v repolist 2>&1 | tail -n 20"
    fi
    if dnf_output="$(dnf -q module list container-tools 2>&1)"; then
        step_ok "container-tools module state: $(compact_output "$dnf_output")"
    else
        step_fail "dnf module list container-tools failed" "Check enabled DNF repositories and module metadata." "dnf -v module list container-tools 2>&1 | tail -n 20"
    fi
    dnf_started=$SECONDS
    if dnf_output="$(dnf -q makecache 2>&1)"; then
        step_ok "dnf makecache completed in $((SECONDS - dnf_started)) seconds"
    else
        step_fail "dnf makecache failed after $((SECONDS - dnf_started)) seconds" "Repair DNF repository connectivity before provisioning." "dnf -v makecache 2>&1 | tail -n 20"
    fi
fi

anchor_dir="/etc/pki/ca-trust/source/anchors"
if [[ -d "$anchor_dir" ]]; then
    anchor_listing="$(find "$anchor_dir" -maxdepth 1 -type f -printf '%f ' 2>/dev/null || true)"
    anchor_count="$(find "$anchor_dir" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
    step_ok "OS trust anchors: $anchor_count file(s): ${anchor_listing:-none}"
else
    step_skip "$anchor_dir is absent" "OS trust-anchor inventory"
fi
trust_bundle="/etc/pki/tls/certs/ca-bundle.crt"
if [[ -r "$trust_bundle" ]] && require_or_skip openssl "OS CA bundle subject inventory"; then
    bundle_subjects="$(openssl crl2pkcs7 -nocrl -certfile "$trust_bundle" 2>/dev/null | openssl pkcs7 -print_certs -noout 2>/dev/null || true)"
    bundle_subject_count="$(grep -c '^subject=' <<<"$bundle_subjects" || true)"
    if [[ -r "$CA_CERT_SOURCE" ]]; then
        ca_subject="$(openssl x509 -in "$CA_CERT_SOURCE" -noout -subject 2>/dev/null || true)"
        if [[ -n "$ca_subject" ]] && grep -Fq -- "${ca_subject#subject=}" <<<"$bundle_subjects"; then
            step_ok "OS CA bundle has $bundle_subject_count subjects and contains the configured airgap CA"
        else
            step_skip "airgap CA subject was not confirmed in the bundle" "verify CA_CERT_SOURCE and the base image trust store"
        fi
    else
        step_skip "configured airgap CA source is not readable" "CA subject comparison against the OS bundle"
    fi
else
    step_skip "OS CA bundle is unavailable" "openssl subject inventory"
fi
registry_ca="/etc/containers/certs.d/${REG_HOST}/ca.crt"
if [[ -e "$registry_ca" ]]; then
    step_ok "registry-specific CA is already present: $registry_ca"
else
    step_skip "registry-specific CA is absent as expected" "script 30 installs $registry_ca"
fi

proxy_report=()
for proxy_name in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
    proxy_value="${!proxy_name-}"
    if [[ -n "$proxy_value" ]]; then proxy_report+=("$proxy_name=set"); else proxy_report+=("$proxy_name=unset"); fi
done
step_ok "proxy environment: ${proxy_report[*]}"

if command -v docker >/dev/null 2>&1; then
    docker_path="$(command -v docker)"
    docker_real="$(readlink -f "$docker_path" 2>/dev/null || printf '%s' "$docker_path")"
    docker_owner="$(rpm -qf "$docker_path" 2>/dev/null || true)"
    if [[ "$docker_real" == *podman* ]]; then
        step_ok "docker resolves to the Podman shim: $docker_path -> $docker_real"
    elif [[ "$docker_owner" == podman-docker-* ]]; then
        step_ok "docker command is provided by podman-docker: $docker_path ($docker_owner)"
    else
        step_fail "docker-compatible command does not resolve to the Podman shim: $docker_real" "Ensure /usr/local/bin/docker or the podman-docker package resolves to the rootful Podman runtime." "rpm -qf $(printf '%q' "$docker_path")" "readlink -f $(printf '%q' "$docker_path")" "head -n 12 $(printf '%q' "$docker_path")"
    fi
else
    step_skip "docker command is absent as expected on the base image" "script 20 installs the podman-docker shim"
fi
if [[ -S /var/run/docker.sock ]]; then
    step_fail "unexpected container API socket is present at /var/run/docker.sock" "Remove the socket before using the Podman-only runtime configuration." "stat /var/run/docker.sock" "ss -lxnp | grep -F /var/run/docker.sock"
else
    step_ok "no container API socket is present"
fi
if require_or_skip rpm "podman-docker package state"; then
    if rpm -q podman-docker >/dev/null 2>&1; then
        step_ok "podman-docker is installed"
    else
        step_skip "podman-docker is absent as expected" "script 20 installs the Docker-compatible Podman shim"
    fi
fi
for container_tool in podman buildah skopeo; do check_binary "$container_tool" "$container_tool version"; done
if require_or_skip podman "Podman information and storage"; then
    if podman_output="$(podman info 2>&1)"; then
        step_ok "podman info succeeded: $(compact_output "$podman_output")"
    else
        step_fail "podman info failed" "Check rootful Podman storage and configuration." "podman info 2>&1 | tail -n 15"
    fi
else
    step_skip "Podman info was not run" "Podman is not installed on the minimal base image"
fi
registries_config="/etc/containers/registries.conf"
if [[ -r "$registries_config" ]]; then
    step_ok "stock registries.conf context: $(head -n 20 "$registries_config" | tr '\n' '; ')"
else
    step_skip "stock registries.conf is absent" "script 40 replaces this file wholesale"
fi

if require_or_skip systemctl "Podman socket state"; then
    socket_state="$(systemctl is-active podman.socket 2>&1 || true)"
    if [[ "$socket_state" == "active" ]]; then
        step_ok "podman.socket is active"
    else
        step_skip "podman.socket is ${socket_state:-unknown} as expected" "script 50 manages the socket if required"
    fi
else
    step_skip "systemd service state is unavailable" "podman.socket check"
fi
if require_or_skip sysctl "vm.max_map_count state"; then
    map_count="$(sysctl -n vm.max_map_count 2>/dev/null || printf 'unavailable')"
    if [[ "$map_count" == "65530" ]]; then
        step_skip "stock vm.max_map_count is $map_count" "script 40 raises it to 262144 for the OpenSearch lab"
    else
        step_ok "vm.max_map_count is $map_count (OpenSearch requires 262144)"
    fi
fi

if [[ -d "$REPO_ROOT" ]]; then
    step_ok "repository root present: $REPO_ROOT"
else
    step_fail "repository root is absent: $REPO_ROOT" "Transfer the complete repository to the learner VM." "pwd" "ls -ld $(printf '%q' "$REPO_ROOT")"
fi
tracks=(opentelemetry otel-developers prometheus fluentbit perses)
for track in "${tracks[@]}"; do
    repo_track="$REPOS_ROOT/$track"
    if [[ -d "$repo_track" ]]; then
        shopt -s nullglob
        lab_files=("$repo_track"/lab*.html)
        shopt -u nullglob
        if ((${#lab_files[@]} > 0)); then
            step_ok "content repo $track: ${#lab_files[@]} lab*.html file(s)"
        else
            step_fail "content repo $track has no lab*.html files" "Restore content/repos/$track from the online capture." "find $(printf '%q' "$repo_track") -maxdepth 2 -type f" "ls -la $(printf '%q' "$repo_track")"
        fi
    else
        step_fail "content repo is absent: $repo_track" "Transfer content/repos/$track from the online capture." "ls -ld $(printf '%q' "$repo_track")" "find $(printf '%q' "$REPOS_ROOT") -maxdepth 1 -type d"
    fi
    docs_track="$DOCS_ROOT/$track"
    landing_page="$(find "$docs_track" -type f \( -name index.html -o -name index.htm \) -print -quit 2>/dev/null || true)"
    if [[ -n "$landing_page" ]]; then
        step_ok "docs landing page present for $track: ${landing_page#"$REPO_ROOT/"}"
    else
        step_fail "docs landing page is absent for $track" "Transfer the mirrored content/docs/$track tree from the online capture." "find $(printf '%q' "$docs_track") -type f -name index.html -o -name index.htm" "ls -la $(printf '%q' "$docs_track")"
    fi
done

locked_sha256() {
    local key="$1"
    awk -v key="$key" '$1 == key {for (i=1;i<=NF;i++) if ($i ~ /^sha256:/) {sub(/^sha256:/,"",$i); print $i; exit}}' "$REPO_ROOT/versions.lock"
}

k3s_manual_payload="$MANUAL_FETCH_DIR/k3s/k3s"
k3s_expected="$(locked_sha256 learner-k3s-binary-amd64)"
if [[ ! "$k3s_expected" =~ ^[0-9a-f]{64}$ ]]; then
    step_fail "versions.lock does not contain the pinned k3s binary SHA-256" "Restore the learner-k3s-binary-amd64 record in versions.lock on the connected source tree." "grep '^learner-k3s-binary-amd64 ' $(printf '%q' "$REPO_ROOT/versions.lock")" "sed -n '/learner-k3s-binary-amd64/p' $(printf '%q' "$REPO_ROOT/versions.lock")"
elif ! command -v sha256sum >/dev/null 2>&1; then
    step_fail "sha256sum is unavailable for k3s binary verification" "Install RHEL coreutils before provisioning." "command -v sha256sum" "rpm -q coreutils"
elif [[ -e "$k3s_manual_payload" || -L "$k3s_manual_payload" ]]; then
    if k3s_actual="$(sha256sum "$k3s_manual_payload" 2>/dev/null | awk '{print $1}')"; then :; else k3s_actual='unavailable'; fi
    if [[ "$k3s_actual" == "$k3s_expected" ]]; then
        step_ok "staged local k3s binary is checksum-valid: $k3s_manual_payload"
    else
        step_fail "staged local k3s binary checksum mismatch: expected $k3s_expected, actual $k3s_actual" "Replace the staged file using K3S_BINARY_URL from learner-vm/lab-vm.conf and the pinned SHA in versions.lock." "sha256sum $(printf '%q' "$k3s_manual_payload")" "grep '^learner-k3s-binary-amd64 ' $(printf '%q' "$REPO_ROOT/versions.lock")"
    fi
elif [[ -z "${K3S_BINARY_URL:-}" ]]; then
    step_fail "k3s binary cannot be fetched because K3S_BINARY_URL is unset and no staged binary exists" "Obtain the Artifactory generic-file URL from the administrator and set K3S_BINARY_URL, or download the pinned binary on this VM to $k3s_manual_payload." "grep '^K3S_BINARY_URL=' $(printf '%q' "$CONFIG_FILE")" "ls -ld $(printf '%q' "$MANUAL_FETCH_DIR/k3s")" "grep '^learner-k3s-binary-amd64 ' $(printf '%q' "$REPO_ROOT/versions.lock")"
else
    k3s_url_info="$(python3 - "$K3S_BINARY_URL" "$ART_HOST" <<'PY'
import sys
from urllib.parse import urlsplit, urlunsplit
parsed = urlsplit(sys.argv[1])
expected_host = sys.argv[2].lower()
if parsed.scheme != "https" or not parsed.hostname or parsed.hostname.lower() != expected_host:
    raise SystemExit(1)
try:
    port = parsed.port
except ValueError:
    raise SystemExit(1)
authority = parsed.hostname + (f":{port}" if port else "")
safe_url = urlunsplit(("https", authority, parsed.path, "", ""))
connect = authority if port else authority + ":443"
print(parsed.hostname)
print(connect)
print(safe_url)
PY
2>/dev/null || true)"
    mapfile -t k3s_url_parts <<< "$k3s_url_info"
    if ((${#k3s_url_parts[@]} != 3)); then
        step_fail "K3S_BINARY_URL must be an HTTPS Artifactory generic-file URL on ART_HOST" "Obtain the exact URL from the Artifactory administrator; do not use a public release URL." "awk -F= '/^K3S_BINARY_URL=/ {print \"K3S_BINARY_URL is configured (value redacted)\"; found=1} END {if (!found) print \"K3S_BINARY_URL is unset\"}' $(printf '%q' "$CONFIG_FILE")" "grep '^ART_HOST=' $(printf '%q' "$CONFIG_FILE")" "getent hosts $(printf %q "$ART_HOST")"
    else
        k3s_url_host="${k3s_url_parts[0]}"
        k3s_url_connect="${k3s_url_parts[1]}"
        k3s_url_safe="${k3s_url_parts[2]}"
        k3s_head_status='000'
        if k3s_head_status="$(curl --head --silent --show-error --connect-timeout 5 --max-time 20 --output /dev/null --write-out '%{http_code}' "$K3S_BINARY_URL" 2>/dev/null)"; then :; fi
        if [[ "$k3s_head_status" =~ ^2[0-9][0-9]$ ]]; then
            step_ok "configured Artifactory k3s binary URL responded to bounded TLS HEAD: $k3s_url_safe (HTTP $k3s_head_status); binary was not downloaded"
        else
            step_fail "K3S_BINARY_URL HEAD probe failed: $k3s_url_safe (HTTP ${k3s_head_status:-000})" "Check Artifactory generic-file access, CA trust, and K3S_BINARY_URL; this probe did not download the binary." "getent hosts $(printf '%q' "$k3s_url_host")" "curl -vI --connect-timeout 5 --max-time 20 $(printf '%q' "$k3s_url_safe") 2>&1 | tail -n 12" "printf '' | openssl s_client -connect $(printf '%q' "$k3s_url_connect") -servername $(printf '%q' "$k3s_url_host") 2>&1 | tail -n 12" "grep '^learner-k3s-binary-amd64 ' $(printf '%q' "$REPO_ROOT/versions.lock")"
        fi
    fi
fi

k3s_probe="$REPO_ROOT/content/vendor/k3s/registry-probe.txt"
if [[ -r "$k3s_probe" ]] && grep -Eq '\|[[:space:]]*000[[:space:]]*$' "$k3s_probe"; then
    step_skip "online k3s registry probe was inconclusive (HTTP 000), not passed" "test registry mirror pulls on the learner network; inspect /var/lib/rancher/k3s/agent/containerd/containerd.log and the generated containerd hosts.toml files"
else
    step_skip "no successful k3s registry-probe result is recorded" "verify Artifactory mirror pulls during provisioning before claiming registry readiness"
fi
missing_content=()
for artifact in commands.json external-images.txt curated.json; do
    if [[ ! -s "$REPO_ROOT/content/extracted/$artifact" ]]; then missing_content+=("$artifact"); fi
done
if ((${#missing_content[@]} == 0)); then
    step_ok "required extracted content is present: commands.json, external-images.txt, curated.json"
else
    step_skip "missing extracted content: ${missing_content[*]}" "produced by prompt 10s online; transfer is incomplete without it, and script 60 consumes commands.json"
fi

if require_or_skip getenforce "SELinux mode"; then step_ok "SELinux mode: $(getenforce 2>/dev/null || printf 'unavailable')"; fi
if require_or_skip systemctl "firewalld state"; then step_ok "firewalld state: $(systemctl is-active firewalld 2>&1 || printf 'inactive or unavailable')"; fi
if require_or_skip systemctl "systemd default target"; then step_ok "default target: $(systemctl get-default 2>&1 || printf 'unavailable')"; fi
if require_or_skip rpm "GNOME display manager inventory"; then
    if rpm -q gdm >/dev/null 2>&1; then
        step_ok "gdm is installed"
    else
        step_skip "gdm is absent as expected on the minimal base" "script 20 installs the desktop"
    fi
fi

end_report "review this diagnostic report, then run script 10 in dry-run mode before provisioning"
exit 0
