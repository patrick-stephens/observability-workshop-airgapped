#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX='[vendor-k3s]'
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$ROOT_DIR"

VERSION='v1.37.1+k3s1'
RELEASE_TAG=${VERSION/+/%2B}
RELEASE_BASE="https://github.com/k3s-io/k3s/releases/download/$RELEASE_TAG"
SELINUX_URL='https://rpm.rancher.io/k3s/stable/common/centos/8/noarch/k3s-selinux-1.6-1.el8.noarch.rpm'
INSTALL_URL='https://get.k3s.io'
VENDOR_DIR='content/vendor/k3s'
IMAGE_LIST="$VENDOR_DIR/k3s-images.txt"
PROBE_FILE="$VENDOR_DIR/registry-probe.txt"

mkdir -p "$VENDOR_DIR"
source learner-vm/lab-vm.conf

fetch_verified() {
    local name="$1" url="$2" expected="$3" mode="${4:-0644}" target="$VENDOR_DIR/$1" temporary="$VENDOR_DIR/$1.partial" actual
    if [[ -s "$target" ]]; then
        actual=$(sha256sum "$target" | awk '{print $1}')
        if [[ "$actual" == "$expected" ]]; then
            printf '%s verified existing %s (%s)\n' "$LOG_PREFIX" "$target" "$actual"
            return 0
        fi
        printf '%s checksum mismatch for existing %s; reacquiring pinned artifact\n' "$LOG_PREFIX" "$target" >&2
    fi
    rm -f "$temporary"
    curl -fL --retry 2 --connect-timeout 15 --max-time 600 "$url" -o "$temporary"
    actual=$(sha256sum "$temporary" | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        rm -f "$temporary"
        printf '%s checksum mismatch for %s: expected %s got %s\n' "$LOG_PREFIX" "$url" "$expected" "$actual" >&2
        return 1
    fi
    chmod "$mode" "$temporary"
    mv "$temporary" "$target"
    printf '%s fetched %s (%s)\n' "$LOG_PREFIX" "$target" "$actual"
}

fetch_verified install.sh "$INSTALL_URL" e5cc3b3d9dfc1662c2d9be6da5abc9a4cd317d6abc3a5ffc02e3dd3248207fee
fetch_verified k3s-images.txt "$RELEASE_BASE/k3s-images.txt" 377307d4039ccd04f0e27d2906595a8c7b7d49a79f7553c311f6f960ff3efb58
fetch_verified k3s-selinux-1.6-1.el8.noarch.rpm "$SELINUX_URL" a1e24b0d82b1a6806cd420e2c0398a1796b055efe368fa4aebc8bb173850934f
(cd "$VENDOR_DIR" && sha256sum install.sh k3s-images.txt k3s-selinux-1.6-1.el8.noarch.rpm > SHA256SUMS.partial)
mv "$VENDOR_DIR/SHA256SUMS.partial" "$VENDOR_DIR/SHA256SUMS"

probe_temporary="$PROBE_FILE.partial"
printf 'image | tag | code\n' > "$probe_temporary"
while IFS= read -r image || [[ -n "$image" ]]; do
    [[ -n "$image" ]] || continue
    reference=${image#docker.io/}
    tag=${reference##*:}
    repository=${reference%:*}
    status='000'
    if result=$(curl --connect-timeout 10 --max-time 10 -sS -o /dev/null -w '%{http_code}' \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        "https://${DOCKER_REGISTRY}/v2/${repository}/manifests/${tag}" 2>/dev/null); then
        status="$result"
    fi
    printf '%s | %s | %s\n' "$image" "$tag" "$status" >> "$probe_temporary"
done < "$IMAGE_LIST"
mv "$probe_temporary" "$PROBE_FILE"
cat "$PROBE_FILE"
printf '%s version=%s registry=%s strategy=registries.yaml-mirror-and-k3s-crictl-pull; mirror access is not verified by the online probe\n' "$LOG_PREFIX" "$VERSION" "$DOCKER_REGISTRY"
