#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[00-prereqs]"
HOSTS_FILE="/etc/hosts"
HOSTS_BEGIN="# BEGIN observability-workshop"
HOSTS_END="# END observability-workshop"
MODULES_FILE="/etc/modules-load.d/observability-workshop.conf"
SYSCTL_FILE="/etc/sysctl.d/99-observability-workshop.conf"
FSTAB_FILE="/etc/fstab"
FSTAB_BACKUP="/etc/fstab.pre-observability-workshop"

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

error() {
    log "ERROR: $*" >&2
}

if [[ "$EUID" -ne 0 ]]; then
    error "run this script with sudo"
    exit 1
fi

write_if_changed() {
    local temporary_file="$1"
    local target_file="$2"
    local mode="$3"
    if [[ -f "$target_file" ]] && cmp --silent "$temporary_file" "$target_file"; then
        rm -f "$temporary_file"
        log "No change needed for $target_file"
        return
    fi
    install --mode "$mode" "$temporary_file" "$target_file"
    rm -f "$temporary_file"
    log "Updated $target_file"
}

write_managed_hosts() {
    local temporary_file
    temporary_file="$(mktemp)"
    awk -v begin="$HOSTS_BEGIN" -v end="$HOSTS_END" '
        $0 == begin { skip = 1; next }
        $0 == end { skip = 0; next }
        !skip { print }
    ' "$HOSTS_FILE" > "$temporary_file"
    {
        printf '%s\n' "$HOSTS_BEGIN"
        printf '%s\n' '127.0.0.1 registry.lab.local' '127.0.0.1 workshops.lab.local'
        printf '%s\n' "$HOSTS_END"
    } >> "$temporary_file"
    write_if_changed "$temporary_file" "$HOSTS_FILE" 0644
}

write_modules() {
    local temporary_file
    temporary_file="$(mktemp)"
    printf '%s\n' overlay br_netfilter > "$temporary_file"
    write_if_changed "$temporary_file" "$MODULES_FILE" 0644
}

write_sysctls() {
    local temporary_file
    temporary_file="$(mktemp)"
    printf '%s\n' \
        'net.ipv4.ip_forward = 1' \
        'net.bridge.bridge-nf-call-iptables = 1' \
        'net.bridge.bridge-nf-call-ip6tables = 1' > "$temporary_file"
    write_if_changed "$temporary_file" "$SYSCTL_FILE" 0644
}

disable_persistent_swap() {
    local temporary_file
    if [[ ! -f "$FSTAB_FILE" ]]; then
        error "$FSTAB_FILE does not exist"
        return 1
    fi
    if [[ ! -f "$FSTAB_BACKUP" ]]; then
        cp --preserve=mode,ownership,timestamps "$FSTAB_FILE" "$FSTAB_BACKUP"
        log "Backed up $FSTAB_FILE to $FSTAB_BACKUP"
    fi

    temporary_file="$(mktemp)"
    awk '
        /^[[:space:]]*#/ { print; next }
        NF >= 3 && $3 == "swap" { print "# disabled by observability-workshop: " $0; next }
        { print }
    ' "$FSTAB_FILE" > "$temporary_file"
    write_if_changed "$temporary_file" "$FSTAB_FILE" 0644

    if swapon --noheadings | grep --quiet .; then
        log "Disabling active swap"
        swapoff --all
    else
        log "No active swap to disable"
    fi
    systemctl mask swap.target
}

log "Loading overlay and br_netfilter kernel modules"
write_modules
modprobe overlay
modprobe br_netfilter

log "Applying Kubernetes forwarding sysctls"
write_sysctls
sysctl --load "$SYSCTL_FILE"

log "Adding local workshop hostnames"
write_managed_hosts

log "Disabling swap"
disable_persistent_swap

log "Host prerequisites for K3S and Cilium are ready"
