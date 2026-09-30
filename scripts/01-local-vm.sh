#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[01-local-vm]"
VM_NAME="observability-workshop-k3s"
VM_DIR="${VM_DIR:-${HOME}/vm-images/observability-workshop}"
BASE_IMAGE_NAME="noble-server-cloudimg-amd64.img"
BASE_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/${BASE_IMAGE_NAME}"
EXPECTED_IMAGE_SHA256="6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2"
BASE_IMAGE="${VM_DIR}/${BASE_IMAGE_NAME}"
VM_DISK="${VM_DIR}/noble-verify.qcow2"
USER_DATA="${VM_DIR}/user-data"
META_DATA="${VM_DIR}/meta-data"
SEED_IMAGE="${VM_DIR}/cloud-init.iso"
SSH_KEY_HASH="${VM_DIR}/ssh-public-key.sha256"
KNOWN_HOSTS="${VM_DIR}/known_hosts"
PID_FILE="${VM_DIR}/qemu.pid"
SERIAL_LOG="${VM_DIR}/serial.log"
QEMU_LOG="${VM_DIR}/qemu.log"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-${HOME}/.ssh/id_ed25519.pub}"
SSH_PRIVATE_KEY_FILE="${SSH_PRIVATE_KEY_FILE:-${SSH_PUBLIC_KEY_FILE%.pub}}"
SSH_FORWARD_PORT="${SSH_FORWARD_PORT:-2222}"
VM_MEMORY_MIB="${VM_MEMORY_MIB:-8192}"
VM_VCPUS="${VM_VCPUS:-4}"
SSH_WAIT_SECONDS="${SSH_WAIT_SECONDS:-180}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

error() {
    log "ERROR: $*" >&2
}

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "required command '$1' is not installed"
        return 1
    fi
}

running_pid() {
    local pid process_args
    [[ -s "$PID_FILE" ]] || return 1
    read -r pid < "$PID_FILE"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    process_args="$(tr '\0' ' ' < "/proc/${pid}/cmdline")"
    [[ "$process_args" == *"-name ${VM_NAME}"* && "$process_args" == *"${VM_DISK}"* ]] || return 1
    printf '%s\n' "$pid"
}

ssh_to_vm() {
    if ! running_pid >/dev/null; then
        error "VM is not running; start it with '$0 start'"
        return 1
    fi
    if [[ ! -f "$SSH_PRIVATE_KEY_FILE" ]]; then
        error "SSH private key '$SSH_PRIVATE_KEY_FILE' does not exist"
        return 1
    fi
    exec ssh \
        -p "$SSH_FORWARD_PORT" \
        -i "$SSH_PRIVATE_KEY_FILE" \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=${KNOWN_HOSTS}" \
        "ubuntu@127.0.0.1" "$@"
}

check_image() {
    local image_path="$1"
    local actual_sha256
    actual_sha256="$(sha256sum "$image_path" | awk '{print $1}')"
    if [[ "$actual_sha256" != "$EXPECTED_IMAGE_SHA256" ]]; then
        error "Ubuntu cloud image checksum mismatch: expected $EXPECTED_IMAGE_SHA256, got $actual_sha256"
        return 1
    fi
}

download_image() {
    local temporary_image="${BASE_IMAGE}.download.$$"
    if [[ -e "$BASE_IMAGE" ]]; then
        log "Verifying cached Ubuntu 24.04 cloud image"
        check_image "$BASE_IMAGE"
        return
    fi

    log "Downloading the pinned Ubuntu 24.04 cloud image"
    curl --fail --location --retry 3 --output "$temporary_image" "$BASE_IMAGE_URL"
    if ! check_image "$temporary_image"; then
        rm -f "$temporary_image"
        return 1
    fi
    mv "$temporary_image" "$BASE_IMAGE"
}

prepare_cloud_init() {
    local public_key key_hash escaped_key temporary_user_data
    if [[ ! -r "$SSH_PUBLIC_KEY_FILE" ]]; then
        error "SSH public key '$SSH_PUBLIC_KEY_FILE' is missing; set SSH_PUBLIC_KEY_FILE to a readable public key"
        return 1
    fi

    public_key="$(< "$SSH_PUBLIC_KEY_FILE")"
    key_hash="$(printf '%s' "$public_key" | sha256sum | awk '{print $1}')"
    if [[ -e "$VM_DISK" ]]; then
        if [[ ! -f "$SSH_KEY_HASH" ]] || [[ "$(< "$SSH_KEY_HASH")" != "$key_hash" ]]; then
            error "the VM disk was created with a different SSH key; use '$0 destroy' before changing keys"
            return 1
        fi
        if [[ ! -f "$SEED_IMAGE" ]]; then
            error "cloud-init seed is missing for the existing VM; use '$0 destroy' to recreate it"
            return 1
        fi
        return
    fi

    escaped_key="${public_key//\'/\'\'}"
    temporary_user_data="${USER_DATA}.tmp.$$"
    {
        printf '%s\n' \
            '#cloud-config' \
            'hostname: observability-workshop' \
            'ssh_pwauth: false' \
            'disable_root: true' \
            'users:' \
            '  - default' \
            '  - name: ubuntu' \
            '    groups: [adm, sudo]' \
            '    shell: /bin/bash' \
            '    lock_passwd: true' \
            '    sudo: ALL=(ALL) NOPASSWD:ALL' \
            '    ssh_authorized_keys:'
        printf "      - '%s'\n" "$escaped_key"
    } > "$temporary_user_data"
    mv "$temporary_user_data" "$USER_DATA"
    printf '%s\n' 'instance-id: observability-workshop-k3s-v1' 'local-hostname: observability-workshop' > "$META_DATA"

    log "Creating cloud-init data with the configured SSH public key"
    cloud-localds "$SEED_IMAGE" "$USER_DATA" "$META_DATA"
    log "Creating the VM qcow2 overlay"
    qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$VM_DISK" 60G
    printf '%s\n' "$key_hash" > "$SSH_KEY_HASH"
}

wait_for_ssh() {
    local deadline=$((SECONDS + SSH_WAIT_SECONDS))
    while (( SECONDS < deadline )); do
        if ssh \
            -p "$SSH_FORWARD_PORT" \
            -i "$SSH_PRIVATE_KEY_FILE" \
            -o IdentitiesOnly=yes \
            -o BatchMode=yes \
            -o ConnectTimeout=2 \
            -o StrictHostKeyChecking=accept-new \
            -o "UserKnownHostsFile=${KNOWN_HOSTS}" \
            ubuntu@127.0.0.1 true >/dev/null 2>&1; then
            log "Ubuntu guest is reachable over SSH"
            return
        fi
        sleep 2
    done
    error "guest did not become reachable over SSH within ${SSH_WAIT_SECONDS}s; inspect '$SERIAL_LOG' and '$QEMU_LOG'"
    return 1
}

start_vm() {
    local existing_pid
    mkdir -p "$VM_DIR"
    require_tool curl
    require_tool sha256sum
    require_tool awk
    require_tool qemu-img
    require_tool cloud-localds
    require_tool ssh
    require_tool "$QEMU_BIN"
    if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
        error "/dev/kvm is not accessible; enable KVM access for this user"
        return 1
    fi

    if existing_pid="$(running_pid)"; then
        log "VM is already running with PID $existing_pid"
        wait_for_ssh
        return
    fi
    if [[ -e "$PID_FILE" ]]; then
        log "Removing a stale QEMU PID file"
        rm -f "$PID_FILE"
    fi

    download_image
    prepare_cloud_init
    log "Starting Ubuntu 24.04 on KVM with user-mode NAT"
    "$QEMU_BIN" \
        -name "$VM_NAME" \
        -daemonize \
        -pidfile "$PID_FILE" \
        -D "$QEMU_LOG" \
        -machine q35,accel=kvm \
        -cpu host \
        -smp "$VM_VCPUS" \
        -m "${VM_MEMORY_MIB}M" \
        -drive "file=${VM_DISK},if=virtio,format=qcow2" \
        -drive "file=${SEED_IMAGE},media=cdrom,format=raw,readonly=on" \
        -netdev "user,id=net0,net=10.44.0.0/24,host=10.44.0.2,restrict=on,hostfwd=tcp:127.0.0.1:${SSH_FORWARD_PORT}-:22" \
        -device virtio-net-pci,netdev=net0 \
        -serial "file:${SERIAL_LOG}" \
        -monitor none \
        -display none \
        -no-reboot
    wait_for_ssh
    log "Connect with: $0 ssh"
}

stop_vm() {
    local pid deadline
    if ! pid="$(running_pid)"; then
        log "VM is already stopped"
        rm -f "$PID_FILE"
        return
    fi

    log "Sending SIGTERM to VM process $pid"
    kill -TERM "$pid"
    deadline=$((SECONDS + 30))
    while (( SECONDS < deadline )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            log "VM stopped"
            return
        fi
        sleep 1
    done
    error "VM process $pid did not stop within 30 seconds"
    return 1
}

destroy_vm() {
    stop_vm
    log "Removing the VM overlay and generated cloud-init/SSH state; retaining the verified base image"
    rm -f "$VM_DISK" "$USER_DATA" "$META_DATA" "$SEED_IMAGE" "$SSH_KEY_HASH" "$KNOWN_HOSTS" "$SERIAL_LOG" "$QEMU_LOG" "$PID_FILE"
}

show_status() {
    local pid
    if pid="$(running_pid)"; then
        log "VM is running with PID $pid"
        log "SSH: ssh -p ${SSH_FORWARD_PORT} -i ${SSH_PRIVATE_KEY_FILE} ubuntu@127.0.0.1"
    else
        log "VM is stopped"
    fi
}

main() {
    local action="${1:-start}"
    if (( $# > 0 )); then
        shift
    fi

    case "$action" in
        start)
            start_vm
            ;;
        stop)
            stop_vm
            ;;
        status)
            show_status
            ;;
        ssh)
            ssh_to_vm "$@"
            ;;
        destroy)
            destroy_vm
            ;;
        help|-h|--help)
            printf 'Usage: %s [start|stop|status|ssh|destroy]\n' "$0"
            ;;
        *)
            error "unknown action '$action'"
            printf 'Usage: %s [start|stop|status|ssh|destroy]\n' "$0" >&2
            return 2
            ;;
    esac
}

main "$@"
