#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VM_DIR="${VM_DIR:-${HOME}/vm-images/learner-alma8}"
IMAGE_NAME="AlmaLinux-8-GenericCloud-8.10-20260928.x86_64.qcow2"
IMAGE_URL="https://repo.almalinux.org/almalinux/8/cloud/x86_64/images/${IMAGE_NAME}"
IMAGE_SHA256="4a4dfcbd0a02f9fbf62dee6420a168858ff1640a26fb8840ea4013db57436a6c"
BASE_IMAGE="$VM_DIR/$IMAGE_NAME"
VM_DISK="$VM_DIR/learner-alma8.qcow2"
SEED_IMAGE="$VM_DIR/cloud-init.iso"
USER_DATA="$VM_DIR/user-data"
META_DATA="$VM_DIR/meta-data"
PID_FILE="$VM_DIR/qemu.pid"
SERIAL_LOG="$VM_DIR/serial.log"
QEMU_LOG="$VM_DIR/qemu.log"
SSH_KNOWN_HOSTS="$VM_DIR/known_hosts"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-${HOME}/.ssh/id_ed25519.pub}"
SSH_PRIVATE_KEY_FILE="${SSH_PRIVATE_KEY_FILE:-${SSH_PUBLIC_KEY_FILE%.pub}}"
SSH_PORT="${SSH_PORT:-2238}"
VM_MEMORY_MIB="${VM_MEMORY_MIB:-8192}"
VM_VCPUS="${VM_VCPUS:-4}"
VM_NAME="learner-almalinux8"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
BUNDLE="$ROOT_DIR/dist/learner-dependencies-java17-r6.tar.gz"
BUNDLE_SHA_FILE="$BUNDLE.sha256"
GUEST_STAGE="/var/tmp/learner-dependencies-r6"
GUEST_ROOT="/opt/o11y-lab-dependencies"
WORKSHOP_USER="engineer"

log() { printf '[almalinux-learner-vm] %s\n' "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

running_pid() {
    local pid args
    [[ -s "$PID_FILE" ]] || return 1
    read -r pid < "$PID_FILE"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    args="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
    [[ "$args" == *"-name $VM_NAME"* && "$args" == *"$VM_DISK"* ]] || return 1
    printf '%s\n' "$pid"
}

ssh_guest() {
    [[ -r "$SSH_PRIVATE_KEY_FILE" ]] || fail "SSH key is unreadable: $SSH_PRIVATE_KEY_FILE"
    ssh -p "$SSH_PORT" -i "$SSH_PRIVATE_KEY_FILE" -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS" \
        -o ConnectTimeout=5 -o ConnectionAttempts=24 "engineer@127.0.0.1" "$@"
}

prepare() {
    local checksum_dir="$VM_DIR/gnupg" public_key
    for tool in curl gpg sha256sum qemu-img cloud-localds "$QEMU_BIN" ssh scp; do
        command -v "$tool" >/dev/null 2>&1 || fail "required host tool is missing: $tool"
    done
    [[ -r "$SSH_PUBLIC_KEY_FILE" ]] || fail "SSH public key is missing: $SSH_PUBLIC_KEY_FILE"
    [[ -r /dev/kvm && -w /dev/kvm ]] || fail "/dev/kvm is not accessible to this user"
    mkdir -p "$VM_DIR" "$checksum_dir"
    chmod 0700 "$checksum_dir"
    for file in CHECKSUM CHECKSUM.asc RPM-GPG-KEY-AlmaLinux-8; do
        [[ -s "$VM_DIR/$file" ]] || curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
            --output "$VM_DIR/$file.partial" "https://repo.almalinux.org/almalinux/8/cloud/x86_64/images/$file" 2>/dev/null || {
                rm -f "$VM_DIR/$file.partial"
                fail "could not download official AlmaLinux checksum metadata: $file"
            }
        if [[ -s "$VM_DIR/$file.partial" ]]; then mv "$VM_DIR/$file.partial" "$VM_DIR/$file"; fi
    done
    GNUPGHOME="$checksum_dir" gpg --batch --import "$VM_DIR/RPM-GPG-KEY-AlmaLinux-8" >/dev/null 2>&1
    GNUPGHOME="$checksum_dir" gpg --batch --verify "$VM_DIR/CHECKSUM.asc" "$VM_DIR/CHECKSUM" >/dev/null 2>&1 || fail "AlmaLinux CHECKSUM signature verification failed"
    grep -F "$IMAGE_SHA256  $IMAGE_NAME" "$VM_DIR/CHECKSUM" >/dev/null || fail "verified AlmaLinux CHECKSUM does not contain the pinned image digest"
    if [[ ! -s "$BASE_IMAGE" ]]; then
        curl --fail --location --retry 3 --proto '=https' --tlsv1.2 --output "$BASE_IMAGE.partial" "$IMAGE_URL"
        printf '%s  %s\n' "$IMAGE_SHA256" "$BASE_IMAGE.partial" | sha256sum --check --status || {
            rm -f "$BASE_IMAGE.partial"
            fail "downloaded AlmaLinux cloud image SHA-256 mismatch"
        }
        mv "$BASE_IMAGE.partial" "$BASE_IMAGE"
    fi
    printf '%s  %s\n' "$IMAGE_SHA256" "$BASE_IMAGE" | sha256sum --check --status || fail "cached AlmaLinux image SHA-256 mismatch"
    public_key="$(< "$SSH_PUBLIC_KEY_FILE")"
    cat > "$USER_DATA" <<EOF
#cloud-config
hostname: learner-almalinux8
ssh_pwauth: false
disable_root: true
users:
  - default
  - name: engineer
    gecos: Offline learner test
    groups: [wheel]
    shell: /bin/bash
    lock_passwd: true
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - '$public_key'
package_update: true
packages:
  - podman
  - fuse-overlayfs
  - slirp4netns
  - jq
  - unzip
  - curl
  - git
  - python3
  - openssh-server
runcmd:
  - [systemctl, enable, --now, sshd]
EOF
    printf 'instance-id: learner-almalinux8-v1\nlocal-hostname: learner-almalinux8\n' > "$META_DATA"
    cloud-localds "$SEED_IMAGE" "$USER_DATA" "$META_DATA"
    if [[ ! -e "$VM_DISK" ]]; then qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$VM_DISK" 120G >/dev/null; fi
    log "verified AlmaLinux 8.10 cloud image and prepared disposable 120 GiB guest"
}

start_vm() {
    local mode="$1" pid restrict
    if pid="$(running_pid)"; then fail "VM is already running (pid $pid); stop it before changing network mode"; fi
    if [[ -e "$PID_FILE" ]]; then rm -f "$PID_FILE"; fi
    [[ -s "$VM_DISK" && -s "$SEED_IMAGE" ]] || fail "run '$0 prepare' first"
    [[ "$mode" == bootstrap || "$mode" == offline ]] || fail "invalid network mode: $mode"
    restrict=on
    if [[ "$mode" == bootstrap ]]; then restrict=off; fi
    "$QEMU_BIN" \
        -name "$VM_NAME" -daemonize -pidfile "$PID_FILE" -D "$QEMU_LOG" \
        -machine q35,accel=kvm -cpu host -smp "$VM_VCPUS" -m "${VM_MEMORY_MIB}M" \
        -drive "file=${VM_DISK},if=virtio,format=qcow2" \
        -drive "file=${SEED_IMAGE},media=cdrom,format=raw,readonly=on" \
        -boot order=c \
        -netdev "user,id=net0,net=10.45.0.0/24,host=10.45.0.2,restrict=${restrict},hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
        -device virtio-net-pci,netdev=net0 -serial "file:${SERIAL_LOG}" \
        -monitor none -display none -no-reboot
    log "started $VM_NAME with network restrict=$restrict and localhost SSH port $SSH_PORT"
    if [[ "$mode" == bootstrap ]]; then
        log "bootstrap networking is temporary; wait for cloud-init, then stop and restart with 'offline-start' before staging the bundle"
    else
        log "guest egress is restricted; host-forwarded SSH remains available"
    fi
}

wait_bootstrap() {
    ssh_guest 'sudo cloud-init status --wait && rpm -q podman && sudo systemctl is-active sshd'
}

stage_bundle() {
    local digest
    [[ -s "$BUNDLE" && -s "$BUNDLE_SHA_FILE" ]] || fail "packed r6 bundle/checksum is missing; run the connected capture first"
    digest="$(awk '{print $1}' "$BUNDLE_SHA_FILE")"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "bundle sidecar contains an invalid SHA-256"
    ssh_guest "sudo install -d -o engineer -g engineer -m 0750 '$GUEST_STAGE'"
    scp -P "$SSH_PORT" -i "$SSH_PRIVATE_KEY_FILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS" \
        "$BUNDLE" "$BUNDLE_SHA_FILE" "$ROOT_DIR/learner-vm/dependency_bundle.py" \
        "$ROOT_DIR/scripts/dev/test-almalinux-bundle-offline.sh" "$ROOT_DIR/learner-vm/fixtures/api.py" \
        "$ROOT_DIR/scripts/dev/verify-podman-bundle-images.py" \
        "engineer@127.0.0.1:$GUEST_STAGE/"
    ssh_guest "cd '$GUEST_STAGE' && sha256sum --check '$(basename "$BUNDLE_SHA_FILE")'"
}

import_bundle() {
    local digest
    digest="$(awk '{print $1}' "$BUNDLE_SHA_FILE")"
    ssh_guest "sudo install -d -o root -g root -m 0755 '$GUEST_ROOT' && sudo /usr/bin/python3 '$GUEST_STAGE/dependency_bundle.py' verify --archive '$GUEST_STAGE/$(basename "$BUNDLE")' --sha256 '$digest' --destination '$GUEST_ROOT/$digest' && sudo podman load -i '$GUEST_ROOT/$digest/images/lab-images.tar'"
    ssh_guest "sudo /usr/bin/python3 '$GUEST_STAGE/dependency_bundle.py' profiles --mode offline --root '$GUEST_ROOT/$digest' --working-cache-root '/home/engineer/.cache/o11y-lab/$digest' --output '$GUEST_ROOT/profiles/$digest'"
    ssh_guest "sudo install -d -o '$WORKSHOP_USER' -g '$WORKSHOP_USER' -m 0700 '/home/$WORKSHOP_USER/.cache/o11y-lab/$digest/maven' '/home/$WORKSHOP_USER/.cache/o11y-lab/$digest/npm' '/home/$WORKSHOP_USER/.cache/o11y-lab/$digest/go/pkg/mod'"
    ssh_guest "sudo cp -a '$GUEST_ROOT/$digest/cache/maven/repository/.' '/home/$WORKSHOP_USER/.cache/o11y-lab/$digest/maven/' && sudo cp -a '$GUEST_ROOT/$digest/cache/npm/.' '/home/$WORKSHOP_USER/.cache/o11y-lab/$digest/npm/' && sudo cp -a '$GUEST_ROOT/$digest/cache/go/pkg/mod/.' '/home/$WORKSHOP_USER/.cache/o11y-lab/$digest/go/pkg/mod/'"
    ssh_guest "sudo chown -R '$WORKSHOP_USER:$WORKSHOP_USER' '/home/$WORKSHOP_USER/.cache/o11y-lab/$digest' && sudo chmod 0644 '$GUEST_ROOT/profiles/$digest/profile.sh'"
    log "verified bundle extracted, Podman images loaded and writable learner caches seeded"
}

test_bundle() {
    local digest
    digest="$(awk '{print $1}' "$BUNDLE_SHA_FILE")"
    ssh_guest "sudo bash '$GUEST_STAGE/test-almalinux-bundle-offline.sh' '$GUEST_ROOT' '$digest' '$GUEST_STAGE/api.py' '$GUEST_STAGE/verify-podman-bundle-images.py'"
}

stop_vm() {
    local pid
    if pid="$(running_pid)"; then
        ssh_guest 'sudo systemctl poweroff' >/dev/null 2>&1 || true
        log "requested graceful guest shutdown (pid $pid); check status before restarting in offline mode"
    else
        rm -f "$PID_FILE"
        log "$VM_NAME is already stopped"
    fi
}

status_vm() {
    if running_pid; then :; else log "$VM_NAME is stopped"; fi
}

usage() {
    printf '%s\n' 'Usage: scripts/dev/test-learner-bundle-almalinux-vm.sh prepare|bootstrap|wait-bootstrap|offline-start|ssh [COMMAND...]|stage|import|test|stop|status'
    printf '%s\n' 'bootstrap temporarily permits internet for AlmaLinux guest tooling; offline-start uses QEMU restrict=on for all bundle tests.'
}

case "${1:-help}" in
    prepare) prepare ;;
    bootstrap) prepare; start_vm bootstrap ;;
    wait-bootstrap) wait_bootstrap ;;
    offline-start) start_vm offline ;;
    ssh) shift; ssh_guest "$@" ;;
    stage) stage_bundle ;;
    import) import_bundle ;;
    test) test_bundle ;;
    stop) stop_vm ;;
    status) status_vm ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac