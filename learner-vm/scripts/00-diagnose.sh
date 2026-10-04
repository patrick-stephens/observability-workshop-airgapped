#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="00-diagnose"
SCRIPT_VERSION="1.0.1"
# SCRIPT_VERSION 1.0.1: Use Bash parsing for minimal-image checks and report invalid configuration safely.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib.sh"

HOSTNAME="o11y-lab.internal"
STATIC_IP=""
ART_HOST="artifactory.internal"
ART_HOST_IP=""
CA_CERT_SOURCE="/etc/pki/ca-trust/source/anchors/airgap-ca.crt"
ISO_PATH="/dev/cdrom"
DNF_DOCKER_CE_BASEURL="https://artifactory.internal/artifactory/docker-ce-rhel8/"
DNF_EPEL_BASEURL=""
CONTENT_ROOT="$SCRIPT_ROOT"
WORKSHOPS_ROOT="$CONTENT_ROOT/content/repos"
DOCS_ROOT="$CONTENT_ROOT/content/docs"
BROWSER="firefox"
CONFIG_MISSING=false
CONFIG_INVALID=false
SELFTEST=false

if [[ -r "$SCRIPT_ROOT/learner-vm/lab-vm.conf" ]]; then
    if ! source "$SCRIPT_ROOT/learner-vm/lab-vm.conf"; then CONFIG_INVALID=true; fi
else
    CONFIG_MISSING=true
fi

for argument in "$@"; do
    case "$argument" in
        --selftest) SELFTEST=true ;;
        --dry-run) DRY_RUN=true ;;
        *) printf '[%s] Unknown argument: %s\n' "$SCRIPT_NAME" "$argument" ;;
    esac
done

begin_report

if [[ "$SELFTEST" == "true" ]]; then
    step_ok "self-test check one"
    step_ok "self-test check two"
    step_fail "synthetic dependency failure" "Install the missing test dependency" \
        "printf 'synthetic diagnostic output\\n'" \
        "lab-selftest-command-that-does-not-exist"
    step_skip "synthetic optional check" "optional test dependency is absent"
    NEXT_LINE="Self-test complete; inspect the synthetic report block."
    end_report
    exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] WOULD: run read-only learner VM diagnostics"
    step_skip "dry-run requested" "read-only diagnostics were not executed"
    NEXT_LINE="Rerun without --dry-run to collect the read-only diagnostics."
    end_report
    exit 0
fi

if [[ "$CONFIG_MISSING" == "true" ]]; then
    step_fail "learner-vm/lab-vm.conf is missing" "Restore the configuration template before diagnosing this VM."
elif [[ "$CONFIG_INVALID" == "true" ]]; then
    step_fail "learner-vm/lab-vm.conf could not be loaded" "Correct its shell syntax before diagnosing this VM."
fi

compact_output() {
    local flattened="${1//$'\n'/;}"
    printf '%s' "${flattened:0:180}"
}

system_summary=()
if [[ -r /etc/redhat-release ]]; then
    IFS= read -r release_name </etc/redhat-release || true
    system_summary+=("release=${release_name:-unknown}")
else
    system_summary+=("release=unavailable")
fi
if require_or_skip uname "system architecture"; then
    architecture="$(uname -m 2>/dev/null || printf 'unavailable')"
    system_summary+=("arch=${architecture}")
fi
if require_or_skip hostname "system hostname"; then
    system_hostname="$(hostname 2>/dev/null || printf 'unavailable')"
    system_summary+=("hostname=${system_hostname}")
fi
if require_or_skip ip "primary IPv4 address"; then
    route_output="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"
    route_fields=()
    read -r -a route_fields <<<"$route_output"
    primary_ipv4=""
    for ((route_index = 0; route_index < ${#route_fields[@]}; route_index++)); do
        if [[ "${route_fields[route_index]}" == "src" && $((route_index + 1)) -lt ${#route_fields[@]} ]]; then
            primary_ipv4="${route_fields[route_index + 1]}"
            break
        fi
    done
    if [[ -n "$primary_ipv4" ]]; then
        system_summary+=("primary_ipv4=${primary_ipv4}")
    else
        step_skip "primary IPv4 address" "no IPv4 route source address was found"
    fi
fi
if [[ -r /proc/meminfo ]]; then
    memory_total="unknown"
    memory_available="unknown"
    while read -r key value unit; do
        case "$key" in
            MemTotal:) memory_total="${value} ${unit:-kB}" ;;
            MemAvailable:) memory_available="${value} ${unit:-kB}" ;;
        esac
    done </proc/meminfo
    system_summary+=("memory_total=${memory_total}" "memory_available=${memory_available}")
else
    step_skip "memory report" "/proc/meminfo is unavailable"
fi
if require_or_skip df "disk free on / and /var/lib"; then
    disk_report="$(df -hP / /var/lib 2>&1 || true)"
    system_summary+=("disk=$(compact_output "$disk_report")")
fi
step_ok "system: ${system_summary[*]}"

iso_path="${ISO_PATH:-}"
if [[ -z "$iso_path" ]]; then
    step_fail "ISO_PATH is empty" "Set ISO_PATH to an ISO file or CD-ROM device in lab-vm.conf."
elif [[ -f "$iso_path" ]]; then
    if ! require_or_skip mount "ISO loop-mount check"; then :; else
        if ! require_or_skip mktemp "ISO temporary mount directory"; then :; else
            mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/lab-iso.XXXXXX" 2>/dev/null || true)"
            if [[ -z "$mount_dir" ]]; then
                step_skip "ISO loop-mount check" "could not create a temporary mount directory"
            elif mount -o loop,ro "$iso_path" "$mount_dir" 2>&1; then
                if [[ -d "$mount_dir/BaseOS" && -d "$mount_dir/AppStream" ]]; then
                    step_ok "ISO: file form; BaseOS/ and AppStream/ found"
                else
                    step_fail "ISO file is missing BaseOS/ or AppStream/" "Attach the correct RHEL 8.6 installation ISO."
                fi
                if ! umount "$mount_dir" 2>/dev/null; then
                    step_fail "could not unmount ISO file" "Unmount the diagnostic mount point before retrying."
                fi
                rmdir "$mount_dir" 2>/dev/null || true
            else
                step_fail "could not loop-mount ISO file $iso_path" "Check the ISO path, image integrity, and mount permissions."
                rmdir "$mount_dir" 2>/dev/null || true
            fi
        fi
    fi
elif [[ -b "$iso_path" || -c "$iso_path" ]]; then
    if ! require_or_skip mount "ISO device-mount check"; then :; else
        if ! require_or_skip mktemp "ISO temporary mount directory"; then :; else
            mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/lab-iso.XXXXXX" 2>/dev/null || true)"
            if [[ -z "$mount_dir" ]]; then
                step_skip "ISO device-mount check" "could not create a temporary mount directory"
            elif mount -o ro "$iso_path" "$mount_dir" 2>&1; then
                if [[ -d "$mount_dir/BaseOS" && -d "$mount_dir/AppStream" ]]; then
                    step_ok "ISO: device form ($iso_path); BaseOS/ and AppStream/ found"
                else
                    step_fail "ISO device is missing BaseOS/ or AppStream/" "Attach the correct RHEL 8.6 installation ISO."
                fi
                if ! umount "$mount_dir" 2>/dev/null; then
                    step_fail "could not unmount ISO device" "Unmount the diagnostic mount point before retrying."
                fi
                rmdir "$mount_dir" 2>/dev/null || true
            else
                step_fail "could not mount ISO device $iso_path" "Attach the CD-ROM ISO and check mount permissions."
                rmdir "$mount_dir" 2>/dev/null || true
            fi
        fi
    fi
else
    step_fail "ISO_PATH is neither a file nor a device: $iso_path" "Attach an ISO file or a CD-ROM device and update lab-vm.conf."
fi

if require_or_skip curl "Artifactory HTTPS probes"; then
    art_host="${ART_HOST:-}"
    if [[ -z "$art_host" ]]; then
        step_fail "ART_HOST is empty" "Set ART_HOST in lab-vm.conf to the Artifactory hostname."
    else
        check_http() {
            local label="$1" url="$2" expected="$3" accept_header="${4:-}"
            local status="000" curl_args=(--connect-timeout 10 --max-time 10 -sS -o /dev/null -w '%{http_code}')
            if [[ -n "$accept_header" ]]; then curl_args+=(-H "Accept: ${accept_header}"); fi
            if status="$(curl "${curl_args[@]}" "$url" 2>/dev/null)"; then :; fi
            case " $expected " in
                *" ${status} "*) step_ok "Artifactory ${label}: HTTP ${status}" ;;
                *)
                    printf -v quoted_host '%q' "$art_host"
                    printf -v quoted_url '%q' "$url"
                    step_fail "Artifactory ${label}: HTTP ${status}" "Check Artifactory routing, CA trust, and the requested path." \
                        "getent hosts ${quoted_host}" \
                        "curl -v --connect-timeout 10 --max-time 10 -o /dev/null ${quoted_url} 2>&1 | tail -n 10"
                    ;;
            esac
        }

        check_http "root" "https://${art_host}/" "200 302"
        manifest_accept="application/vnd.docker.distribution.manifest.v2+json"
        for manifest in \
            "/library/busybox/manifests/1.36" \
            "/fluent/fluent-bit/manifests/5.1.1" \
            "/prometheus/node-exporter/manifests/v1.12.1"; do
            check_http "manifest ${manifest}" "https://${art_host}/v2${manifest}" "200" "$manifest_accept"
        done
    fi
fi

docker_candidates=(
    "${DNF_DOCKER_CE_BASEURL:-}"
    "https://${ART_HOST}/artifactory/docker-ce-rhel8/"
    "https://${ART_HOST}/artifactory/docker-ce-centos8/"
    "https://${ART_HOST}/docker-ce-rhel8/"
)
if require_or_skip curl "Docker CE repository candidate probes"; then
    for candidate in "${docker_candidates[@]}"; do
        [[ -n "$candidate" ]] || continue
        [[ "$candidate" == */ ]] || candidate="${candidate}/"
        status="000"
        if status="$(curl --connect-timeout 10 --max-time 10 -sS -o /dev/null -w '%{http_code}' "${candidate}repodata/repomd.xml" 2>/dev/null)"; then :; fi
        if [[ "$status" == "200" ]]; then
            step_ok "Docker CE candidate ${candidate}: HTTP ${status}"
        else
            step_fail "Docker CE candidate ${candidate}: HTTP ${status}" "Ask the Artifactory administrator to confirm the correct repository URL."
        fi
    done
fi

anchor_dir="/etc/pki/ca-trust/source/anchors"
if [[ -d "$anchor_dir" ]]; then
    anchor_files=("$anchor_dir"/*)
    if ((${#anchor_files[@]} == 0)) || [[ ! -e "${anchor_files[0]}" ]]; then
        step_skip "CA trust anchors" "$anchor_dir contains no visible files"
    else
        anchor_listing=""
        for anchor_file in "${anchor_files[@]}"; do anchor_listing+="${anchor_file##*/} "; done
        step_ok "CA trust anchors: ${anchor_listing% }"
    fi
else
    step_skip "CA trust anchors" "$anchor_dir does not exist"
fi

trust_bundle="/etc/pki/tls/certs/ca-bundle.crt"
if [[ -r "$CA_CERT_SOURCE" && -r "$trust_bundle" ]] && require_or_skip openssl "Artifactory CA bundle subject check" && require_or_skip grep "Artifactory CA bundle subject check"; then
    ca_subject="$(openssl x509 -in "$CA_CERT_SOURCE" -noout -subject 2>/dev/null || true)"
    ca_subject="${ca_subject#subject=}"
    bundle_subjects="$(openssl crl2pkcs7 -nocrl -certfile "$trust_bundle" 2>/dev/null | openssl pkcs7 -print_certs -noout 2>/dev/null || true)"
    if [[ -n "$ca_subject" && -n "$bundle_subjects" ]] && grep -Fq -- "$ca_subject" <<<"$bundle_subjects"; then
        step_ok "OS CA bundle contains the configured Artifactory CA subject"
    else
        step_fail "could not confirm the Artifactory CA in the extracted OS bundle" "Verify CA_CERT_SOURCE and refresh the OS trust store; subject matching is best effort."
    fi
elif [[ ! -r "$CA_CERT_SOURCE" ]]; then
    step_skip "Artifactory CA bundle subject check" "configured CA file is not readable: $CA_CERT_SOURCE"
elif [[ ! -r "$trust_bundle" ]]; then
    step_skip "Artifactory CA bundle subject check" "OS CA bundle is not readable: $trust_bundle"
fi

for certificate_path in "/etc/docker/certs.d/${ART_HOST}/ca.crt" "/etc/containers/certs.d/${ART_HOST}/ca.crt"; do
    if [[ -e "$certificate_path" ]]; then
        step_fail "unexpected per-registry CA file: $certificate_path" "Use the OS trust store and remove this registry-specific certificate if it is not required."
    else
        step_ok "per-registry CA file absent as expected: $certificate_path"
    fi
done

proxy_report=()
for proxy_name in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
    proxy_value="${!proxy_name-}"
    if [[ -n "$proxy_value" ]]; then proxy_report+=("${proxy_name}=${proxy_value}"); else proxy_report+=("${proxy_name}=<unset>"); fi
done
step_ok "proxy environment: ${proxy_report[*]}"

if require_or_skip dnf "DNF state checks"; then
    if dnf_output="$(dnf -q repolist 2>&1)"; then
        step_ok "dnf repolist: $(compact_output "$dnf_output")"
    else
        step_fail "dnf repolist failed" "Repair DNF repository configuration and connectivity." "dnf -v repolist 2>&1 | tail -n 15"
    fi
    if dnf_output="$(dnf -q module list container-tools 2>&1)"; then
        step_ok "dnf module list container-tools: $(compact_output "$dnf_output")"
    else
        step_fail "dnf module list container-tools failed" "Check enabled repositories and module metadata." "dnf -v module list container-tools 2>&1 | tail -n 15"
    fi
    if dnf_output="$(dnf -q list available docker-ce 2>&1)"; then
        step_ok "docker-ce resolves in DNF: $(compact_output "$dnf_output")"
    else
        step_fail "docker-ce does not resolve in DNF" "Confirm the Docker CE repository URL with the Artifactory administrator." "dnf -v list available docker-ce 2>&1 | tail -n 15"
    fi
fi

tracks=(opentelemetry opentelemetry-java prometheus fluent-bit perses)
if [[ -d "$CONTENT_ROOT" ]]; then
    step_ok "content repository root present: $CONTENT_ROOT"
else
    step_fail "content repository root is absent: $CONTENT_ROOT" "Transfer the complete workshop repository to the VM and set CONTENT_ROOT."
fi
for track in "${tracks[@]}"; do
    repo_track="$WORKSHOPS_ROOT/$track"
    docs_track="$DOCS_ROOT/$track"
    if [[ -d "$repo_track" ]]; then
        shopt -s nullglob
        lab_files=("$repo_track"/lab*.html)
        shopt -u nullglob
        step_ok "content track $track: ${#lab_files[@]} lab*.html file(s) in $repo_track"
    else
        step_fail "content track repository is absent: $repo_track" "Transfer the workshop content for the $track track."
    fi
    if [[ -d "$docs_track" && ( -f "$docs_track/index.html" || -f "$docs_track/README.md" ) ]]; then
        step_ok "content documentation landing page present: $docs_track"
    elif [[ -d "$docs_track" ]]; then
        step_fail "content documentation landing page is absent: $docs_track" "Add index.html or README.md for the $track documentation track."
    else
        step_fail "content documentation track is absent: $docs_track" "Transfer the documentation for the $track track."
    fi
done

for tool in git curl podman skopeo docker jq java python3; do
    if require_or_skip "$tool" "tool inventory ($tool)"; then
        case "$tool" in
            jq) version_output="$($tool --version 2>&1 || true)" ;;
            java) version_output="$($tool -version 2>&1 || true)" ;;
            *) version_output="$($tool --version 2>&1 || true)" ;;
        esac
        version_line="${version_output%%$'\n'*}"
        step_ok "tool present: $tool${version_line:+ ($version_line)}"
    fi
done

if require_or_skip getenforce "SELinux mode"; then
    selinux_mode="$(getenforce 2>/dev/null || printf 'unavailable')"
    step_ok "SELinux mode: $selinux_mode"
elif [[ -r /sys/fs/selinux/enforce ]]; then
    IFS= read -r selinux_mode </sys/fs/selinux/enforce || true
    step_ok "SELinux enforcement flag: ${selinux_mode:-unknown}"
else
    step_skip "SELinux mode" "getenforce and the SELinux enforcement flag are unavailable"
fi
if require_or_skip systemctl "firewalld state"; then
    if firewalld_state="$(systemctl is-active firewalld 2>&1)"; then
        step_ok "firewalld state: $firewalld_state"
    else
        step_ok "firewalld state: ${firewalld_state:-inactive}"
    fi
else
    step_skip "firewalld state" "systemctl is unavailable"
fi

NEXT_LINE="Review failures and skips, correct the VM configuration, then rerun scripts/00-diagnose.sh."
end_report
exit 0
