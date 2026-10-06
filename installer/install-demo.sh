#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[o11y-installer]"
INSTALLER_DIR="/opt/o11y-installer"
REPO_DIR="/opt/observability-workshop"
APT_SOURCE="/etc/apt/sources.list.d/o11y-installer.list"
APT_OPTIONS=(
    -o "Dir::Etc::sourcelist=${APT_SOURCE}"
    -o Dir::Etc::sourceparts=-
    -o APT::Get::List-Cleanup=0
)

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

error() {
    log "ERROR: $*" >&2
}

locked_version() {
    local key="$1"
    local version
    version="$(awk -v key="$key" '$1 == key { print $2; exit }' "${REPO_DIR}/versions.lock")"
    if [[ -z "$version" ]]; then
        error "required package pin '$key' is missing from versions.lock"
        return 1
    fi
    printf '%s\n' "$version"
}

verify_loaded_images() {
    local references_file="${REPO_DIR}/bundle/image-references-amd64.txt"
    local image_reference tagged_reference missing=0
    if [[ ! -s "$references_file" ]]; then
        error "pinned image reference list is missing or empty: $references_file"
        return 1
    fi
    while IFS= read -r image_reference; do
        [[ -n "$image_reference" ]] || continue
        tagged_reference="${image_reference%@sha256:*}"
        if docker image inspect "$tagged_reference" >/dev/null 2>&1; then
            log "Verified local image $image_reference"
        else
            error "pinned image is not available in the local Docker store: $image_reference"
            missing=1
        fi
    done < "$references_file"
    return "$missing"
}

load_host_images() {
    local image_archive="${REPO_DIR}/bundle/container-images-amd64.tar"
    if [[ ! -f "${image_archive}.sha256" ]]; then
        error "Docker image archive checksum is missing"
        return 1
    fi
    if ! (cd "${REPO_DIR}/bundle" && sha256sum --check "$(basename "${image_archive}.sha256")"); then
        error "Docker image archive checksum verification failed"
        return 1
    fi
    if ! docker load --input "$image_archive"; then
        error "Docker image archive load failed; checking which pinned images are available locally"
        verify_loaded_images || true
        return 1
    fi
    verify_loaded_images
}

main() {
    local package
    local -a package_specs=()
    if [[ "$EUID" -ne 0 ]]; then
        error "run this script as root"
        return 1
    fi
    if [[ -e /var/lib/o11y-installer/complete ]]; then
        log "installation is already complete"
        return
    fi

    install --directory --mode 0755 /var/lib/o11y-installer "$REPO_DIR"
    log "Extracting the captured repository and offline bundle"
    tar --extract --gzip --file "${INSTALLER_DIR}/workshop-bundle.tar.gz" \
        --directory "$REPO_DIR" --no-same-owner
    "${REPO_DIR}/scripts/91-verify-bundle.sh"
    if [[ -e /home/ubuntu/demo && ! -L /home/ubuntu/demo ]]; then
        error "/home/ubuntu/demo exists and is not a symlink; refusing to replace it"
        return 1
    fi
    ln --symbolic --force "$REPO_DIR" /home/ubuntu/demo

    printf 'deb [trusted=yes] file:%s ./\n' "${INSTALLER_DIR}/offline-apt" > "$APT_SOURCE"
    log "Installing pinned runtime packages from the ISO's local APT repository"
    apt-get "${APT_OPTIONS[@]}" update
    for package in docker.io jq curl openssh-server; do
        package_specs+=("${package}=$(locked_version "host-${package}")")
    done
    apt-get "${APT_OPTIONS[@]}" install --yes --no-install-recommends "${package_specs[@]}"
    rm -f "$APT_SOURCE"
    apt-get clean

    usermod --append --groups docker ubuntu
    install --directory --mode 0755 /etc/sudoers.d
    printf '%s\n' 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-observability-workshop
    chmod 0440 /etc/sudoers.d/90-observability-workshop
    visudo --check --file /etc/sudoers.d/90-observability-workshop
    systemctl enable --now docker.service ssh.service

    log "Loading the captured images into the host Docker store for Perses"
    load_host_images
    log "Preparing the offline K3S and observability deployment"
    "${REPO_DIR}/scripts/00-prereqs.sh"
    "${REPO_DIR}/scripts/10-k3s.sh"
    "${REPO_DIR}/scripts/30-stack.sh" --offline
    "${REPO_DIR}/scripts/reset.sh"
    "${REPO_DIR}/scripts/verify-observability.sh"
    systemctl daemon-reload
    systemctl enable --now o11y-presenter.service
    "${REPO_DIR}/scripts/verify-installer.sh" --during-install

    touch /var/lib/o11y-installer/complete
    log "Installation complete; presenter UI is available at http://localhost:8080"
}

main "$@"
