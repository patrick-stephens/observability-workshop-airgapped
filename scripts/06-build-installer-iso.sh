#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[06-build-installer-iso]"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_LOCK="${REPO_ROOT}/versions.lock"
INSTALLER_DIR="${REPO_ROOT}/installer"
OUTPUT_ISO="${ISO_OUTPUT:-${REPO_ROOT}/bundle/o11y-demo-installer-amd64.iso}"
BUILD_USER="${SUDO_USER:-${USER:-root}}"
BUILD_HOME="$(getent passwd "$BUILD_USER" | cut -d: -f6)"
BUILD_HOME="${BUILD_HOME:-$HOME}"
ISO_CACHE_DIR="${ISO_CACHE_DIR:-${BUILD_HOME}/.cache/o11y-installer}"
BASE_ISO_NAME="ubuntu-24.04.5-live-server-amd64.iso"
BASE_ISO_URL="https://releases.ubuntu.com/24.04/${BASE_ISO_NAME}"
BASE_ISO="${UBUNTU_INSTALLER_ISO:-${ISO_CACHE_DIR}/${BASE_ISO_NAME}}"
APT_ARCHIVE_DIR=""
WORK_DIR=""
TEMP_OUTPUT_ISO=""

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

error() {
    log "ERROR: $*" >&2
}

cleanup() {
    if [[ -n "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
    if [[ -n "$TEMP_OUTPUT_ISO" ]]; then
        rm -f "$TEMP_OUTPUT_ISO"
    fi
}
trap cleanup EXIT

locked_field() {
    local key="$1"
    local field="$2"
    local value
    value="$(awk -v key="$key" -v field="$field" '$1 == key { print $field; exit }' "$VERSIONS_LOCK")"
    if [[ -z "$value" ]]; then
        error "required lock entry '$key' is missing from versions.lock"
        return 1
    fi
    printf '%s\n' "$value"
}

sed_replacement() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//&/\\&}"
    value="${value//|/\\|}"
    printf '%s' "$value"
}

download_base_iso() {
    local expected_sha256 actual_sha256 temporary_iso
    expected_sha256="$(locked_field ubuntu-24.04-server-installer-amd64 2 | sed 's/^sha256://')"
    mkdir -p "$(dirname "$BASE_ISO")"
    if [[ ! -f "$BASE_ISO" ]]; then
        temporary_iso="${BASE_ISO}.download.$$"
        log "Downloading pinned Ubuntu Server installer media"
        curl --fail --location --retry 3 --output "$temporary_iso" "$BASE_ISO_URL"
        mv "$temporary_iso" "$BASE_ISO"
    fi
    actual_sha256="$(sha256sum "$BASE_ISO" | awk '{ print $1 }')"
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
        error "Ubuntu installer ISO checksum mismatch: expected $expected_sha256, got $actual_sha256"
        return 1
    fi
    log "Verified $BASE_ISO_NAME"
}

find_bundle_archive() {
    local -a archives=()
    mapfile -t archives < <(find "${REPO_ROOT}/bundle" -maxdepth 1 -type f -name 'o11y-demo-*.tar.gz' -print | sort)
    if (( ${#archives[@]} != 1 )); then
        error "expected one captured o11y-demo-*.tar.gz in bundle/; run scripts/90-capture.sh first"
        return 1
    fi
    BUNDLE_ARCHIVE="${archives[0]}"
    if [[ -f "${BUNDLE_ARCHIVE}.sha256" ]]; then
        (cd "$(dirname "$BUNDLE_ARCHIVE")" && sha256sum --check "$(basename "${BUNDLE_ARCHIVE}.sha256")")
    fi
}

capture_offline_packages() {
    local package version lock_key
    APT_ARCHIVE_DIR="${WORK_DIR}/offline-apt"
    mkdir -p "${APT_ARCHIVE_DIR}/partial"
    : > "${WORK_DIR}/empty-status"
    local -a package_specs=()
    for package in docker.io jq curl openssh-server python3-yaml; do
        lock_key="host-${package}"
        version="$(locked_field "$lock_key" 2)"
        package_specs+=("${package}=${version}")
    done

    log "Capturing the pinned runtime package dependency closure"
    apt-get \
        -o "Dir::State::status=${WORK_DIR}/empty-status" \
        -o "Dir::Cache::archives=${APT_ARCHIVE_DIR}/" \
        --download-only --yes --no-install-recommends install "${package_specs[@]}"
    (cd "$APT_ARCHIVE_DIR" && dpkg-scanpackages --multiversion . /dev/null > Packages)
    gzip --keep --force "${APT_ARCHIVE_DIR}/Packages"
}

prepare_autoinstall_seed() {
    local key_file="$1"
    local password password_hash escaped_password escaped_key python_yaml_version escaped_python_yaml_version
    local -a keys=()
    mapfile -t keys < "$key_file"
    if (( ${#keys[@]} != 1 )) || [[ -z "${keys[0]}" ]]; then
        error "SSH public-key file must contain exactly one key"
        return 1
    fi
    if [[ "${keys[0]}" == *$'\r'* ]]; then
        error "SSH public key contains an unsupported carriage return"
        return 1
    fi
    escaped_key="$(sed_replacement "$(jq -Rn --arg key "${keys[0]}" '$key')")"
    password="$(openssl rand -base64 36)"
    password_hash="$(printf '%s\n' "$password" | openssl passwd -6 -stdin)"
    escaped_password="$(sed_replacement "$password_hash")"
    python_yaml_version="$(locked_field host-python3-yaml 2)"
    escaped_python_yaml_version="$(sed_replacement "$python_yaml_version")"
    sed \
        -e "s|@@PASSWORD_HASH@@|${escaped_password}|g" \
        -e "s|@@SSH_KEY_YAML@@|${escaped_key}|g" \
        -e "s|@@PYTHON_YAML_VERSION@@|${escaped_python_yaml_version}|g" \
        "${INSTALLER_DIR}/user-data.template" > "${WORK_DIR}/user-data"
    printf '%s\n' 'instance-id: observability-workshop-installer' > "${WORK_DIR}/meta-data"
}

prepare_boot_configs() {
    local grub_config="${WORK_DIR}/grub.cfg"
    xorriso -osirrox on -indev "$BASE_ISO" \
        -extract /boot/grub/grub.cfg "$grub_config" >/dev/null
    sed -E '/^[[:space:]]*linux(efi)?[[:space:]]/ { /autoinstall/! { s/[[:space:]]+---/ autoinstall ds=nocloud\\;s=\/cdrom\/ ---/; t; s/$/ autoinstall ds=nocloud\\;s=\/cdrom\//; } }' \
        "$grub_config" > "${WORK_DIR}/grub-autoinstall.cfg"
    if [[ "$(grep -c 'autoinstall ds=nocloud' "${WORK_DIR}/grub-autoinstall.cfg")" -lt 2 ]]; then
        error "could not add the autoinstall arguments to each kernel entry in the GRUB menu"
        return 1
    fi
}

build_iso() {
    local bundle_archive
    local key_file="${SSH_PUBLIC_KEY_FILE:-${BUILD_HOME}/.ssh/id_ed25519.pub}"
    find_bundle_archive
    bundle_archive="$BUNDLE_ARCHIVE"
    if [[ ! -r "$key_file" ]]; then
        error "SSH public key '$key_file' is missing; set SSH_PUBLIC_KEY_FILE to a readable key"
        return 1
    fi
    for tool in apt-get curl dpkg-scanpackages gzip jq openssl sha256sum xorriso; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            error "required command '$tool' is missing; run sudo scripts/00-host-prereqs.sh"
            return 1
        fi
    done

    WORK_DIR="$(mktemp -d)"
    download_base_iso
    capture_offline_packages
    prepare_autoinstall_seed "$key_file"
    prepare_boot_configs
    mkdir -p "$(dirname "$OUTPUT_ISO")"
    TEMP_OUTPUT_ISO="${OUTPUT_ISO}.tmp.$$"
    log "Building hybrid BIOS/UEFI ISO at $OUTPUT_ISO"
    xorriso -indev "$BASE_ISO" -outdev "$TEMP_OUTPUT_ISO" -boot_image any replay \
        -map "${WORK_DIR}/user-data" /user-data \
        -map "${WORK_DIR}/meta-data" /meta-data \
        -map "$bundle_archive" /workshop-bundle.tar.gz \
        -map "$APT_ARCHIVE_DIR" /offline-apt \
        -map "${INSTALLER_DIR}/prepare-storage.sh" /installer/prepare-storage.sh \
        -map "${INSTALLER_DIR}/select-storage.py" /installer/select-storage.py \
        -map "${INSTALLER_DIR}/install-demo.sh" /installer/install-demo.sh \
        -map "${INSTALLER_DIR}/o11y-installer.service" /installer/o11y-installer.service \
        -map "${INSTALLER_DIR}/o11y-presenter.service" /installer/o11y-presenter.service \
        -map "${WORK_DIR}/grub-autoinstall.cfg" /boot/grub/grub.cfg \
        -commit -end
    mv -- "$TEMP_OUTPUT_ISO" "$OUTPUT_ISO"
    TEMP_OUTPUT_ISO=""
    (cd "$(dirname "$OUTPUT_ISO")" && sha256sum "$(basename "$OUTPUT_ISO")" > "$(basename "${OUTPUT_ISO}.sha256")")
    log "Installer ISO ready: $OUTPUT_ISO"
}

if [[ ! -f "$VERSIONS_LOCK" ]]; then
    error "versions.lock not found at $VERSIONS_LOCK"
    exit 1
fi
build_iso
