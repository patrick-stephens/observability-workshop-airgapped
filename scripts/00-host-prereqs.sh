#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[00-host-prereqs]"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_LOCK="${REPO_ROOT}/versions.lock"

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

error() {
    log "ERROR: $*" >&2
}

if [[ "${EUID}" -ne 0 ]]; then
    error "run this script with sudo: sudo $0"
    exit 1
fi

BUILD_USER="${SUDO_USER:-}"
if [[ -z "$BUILD_USER" || "$BUILD_USER" == root ]] || ! getent passwd "$BUILD_USER" >/dev/null; then
    error "could not identify the invoking non-root account; run this script with sudo from that account"
    exit 1
fi

if [[ ! -f "$VERSIONS_LOCK" ]]; then
    error "versions.lock not found at $VERSIONS_LOCK"
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    error "/etc/os-release is not readable"
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != ubuntu || "${VERSION_ID:-}" != 24.04 ]]; then
    error "this host prerequisite lock is for Ubuntu 24.04; found ${PRETTY_NAME:-unknown}"
    exit 1
fi

locked_version() {
    local package="$1"
    local key="host-${package}"
    local version
    version="$(awk -v key="$key" '$1 == key { print $2; exit }' "$VERSIONS_LOCK")"
    if [[ -z "$version" ]]; then
        version="$(awk -v key="$package" '$1 == key { print $2; exit }' "$VERSIONS_LOCK")"
    fi
    if [[ -z "$version" ]]; then
        error "host package '$package' has no versions.lock entry"
        return 1
    fi
    printf '%s\n' "$version"
}

locked_field() {
    local package="$1"
    local field="$2"
    local key="host-${package}"
    local value
    value="$(awk -v key="$key" -v field="$field" '$1 == key { print $field; exit }' "$VERSIONS_LOCK")"
    if [[ -z "$value" ]]; then
        error "field $field for host tool '$package' is missing from versions.lock"
        return 1
    fi
    printf '%s\n' "$value"
}

package_installed_at_version() {
    local package="$1"
    local expected="$2"
    local installed
    installed="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)"
    [[ "$installed" == "$expected" ]]
}

candidate_version_available() {
    local package="$1"
    local expected="$2"
    apt-cache madison "$package" | awk -F '|' -v expected="$expected" '
        {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
            if ($2 == expected) found = 1
        }
        END { exit !found }
    '
}

APT_PACKAGES=(
    ca-certificates
    curl
    git
    jq
    yq
    openssh-client
    make
    qemu-system-x86
    qemu-system-gui
    qemu-utils
    cloud-image-utils
    dpkg-dev
    openssl
    python3-yaml
    xorriso
    golang-go
)

if ! command -v docker >/dev/null 2>&1 || ! systemctl cat docker.service >/dev/null 2>&1; then
    APT_PACKAGES+=(docker.io)
fi

PACKAGES_TO_INSTALL=()
for package in "${APT_PACKAGES[@]}"; do
    version="$(locked_version "$package")"
    if ! package_installed_at_version "$package" "$version"; then
        PACKAGES_TO_INSTALL+=("${package}=${version}")
    fi
done

if (( ${#PACKAGES_TO_INSTALL[@]} > 0 )); then
    log "Refreshing APT indexes because locked host packages are missing or mismatched"
    apt-get update
    for package_version in "${PACKAGES_TO_INSTALL[@]}"; do
        package="${package_version%%=*}"
        version="${package_version#*=}"
        if ! candidate_version_available "$package" "$version"; then
            error "locked version ${package}=${version} is unavailable from configured APT sources"
            exit 1
        fi
    done
    log "Installing locked host packages: ${PACKAGES_TO_INSTALL[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends "${PACKAGES_TO_INSTALL[@]}"
else
    log "All locked host packages are already installed"
fi

install_helm() {
    local version checksum archive temporary_directory
    version="$(locked_version helm)"
    checksum="$(locked_field helm 3)"
    if [[ -x /usr/local/bin/helm ]] && /usr/local/bin/helm version --short | grep -Fq "$version"; then
        log "Pinned Helm $version is already installed"
        return
    fi

    archive="helm-${version}-linux-amd64.tar.gz"
    temporary_directory="$(mktemp -d)"
    log "Downloading and verifying pinned Helm $version"
    curl --fail --location --retry 3 --output "${temporary_directory}/${archive}" "https://get.helm.sh/${archive}"
    printf '%s  %s\n' "$checksum" "${temporary_directory}/${archive}" | sha256sum --check --status
    tar --extract --gzip --file "${temporary_directory}/${archive}" --directory "$temporary_directory" linux-amd64/helm
    install --mode 0755 "${temporary_directory}/linux-amd64/helm" /usr/local/bin/helm
    rm -rf "$temporary_directory"
}

install_kubectl() {
    local version checksum temporary_binary
    version="$(locked_version kubectl)"
    checksum="$(locked_field kubectl 3)"
    if [[ -x /usr/local/bin/kubectl ]] && /usr/local/bin/kubectl version --client --output=json | jq -e --arg version "$version" '.clientVersion.gitVersion == $version' >/dev/null; then
        log "Pinned kubectl $version is already installed"
        return
    fi

    temporary_binary="$(mktemp)"
    log "Downloading and verifying pinned kubectl $version"
    curl --fail --location --retry 3 --output "$temporary_binary" "https://dl.k8s.io/release/${version}/bin/linux/amd64/kubectl"
    printf '%s  %s\n' "$checksum" "$temporary_binary" | sha256sum --check --status
    install --mode 0755 "$temporary_binary" /usr/local/bin/kubectl
    rm -f "$temporary_binary"
}

install_helm
install_kubectl

if ! getent group kvm >/dev/null; then
    error "the kvm group was not created by the QEMU package"
    exit 1
fi
if ! getent group docker >/dev/null; then
    groupadd --system docker
fi

ensure_group_membership() {
    local group="$1"
    local members
    members="$(getent group "$group" | awk -F: '{print $4}')"
    case ",$members," in
        *",$BUILD_USER,"*)
            log "$BUILD_USER is already in the $group group"
            ;;
        *)
            log "Adding $BUILD_USER to the $group group"
            usermod --append --groups "$group" "$BUILD_USER"
            ;;
    esac
}

ensure_group_membership docker
ensure_group_membership kvm

log "Loading KVM kernel modules"
modprobe kvm
if grep -q 'GenuineIntel' /proc/cpuinfo; then
    modprobe kvm_intel
elif grep -q 'AuthenticAMD' /proc/cpuinfo; then
    modprobe kvm_amd
fi
if [[ ! -c /dev/kvm ]]; then
    error "/dev/kvm is unavailable; enable hardware virtualization in firmware and the hypervisor"
    exit 1
fi

log "Enabling and starting Docker"
if ! systemctl is-enabled --quiet docker; then
    systemctl enable docker
fi
if ! systemctl is-active --quiet docker; then
    systemctl start docker
fi
if ! docker info >/dev/null 2>&1; then
    error "Docker daemon did not become available"
    exit 1
fi
if ! docker buildx version >/dev/null 2>&1; then
    error "Docker Buildx is required to build the reproducible offline hey image"
    exit 1
fi

go_version="$(go version | awk '{print $3}')"
if [[ ! "$go_version" =~ ^go1\.(22|[2-9][3-9])([.]|$) ]]; then
    error "Go 1.22 or newer is required; found $go_version"
    exit 1
fi

log "Host prerequisites are ready"
log "Log out and back in for $BUILD_USER to receive docker and kvm group membership"
