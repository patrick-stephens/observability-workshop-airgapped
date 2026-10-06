# Runtime Fetch and Recovery

This is a runtime recovery reference for the learner VM.
The repository already contains its workshop sources, documentation mirrors, runtime build-context archives, k3s support files, `app_pod.yaml`, and `reveal.js-menu`; no action is needed for those entries.
Standalone runtime files are resolved from checksum-verified local files before any Artifactory URL is probed or fetched.
Runtime image pulls use the configured Artifactory mirror. If it is unavailable, stop and contact the Artifactory administrator; there is no public-internet fallback.

## Section A — In Repository (Already Present)

All listed files are already in the repository or base image. Nothing in this section needs fetching, staging, or operator action.

The machine-readable catalog lists the exact repository paths and per-file hashes for all inventoried files.

| vendored group | source | inventory | repository/base-image path | status | purpose |
|---|---|---|---|---|---|
| Workshop repositories, including app_pod.yaml and reveal.js-menu | in repository | 129 inventoried file(s) | content/repos/… | PRESENT | Tracked source trees and vendored lab inputs; no action needed. |
| Documentation mirrors | in repository | 87 inventoried file(s) | content/docs/… | PRESENT | Tracked documentation mirrors; no action needed. |
| Runtime build-context downloads | in repository | 3 inventoried file(s) | content/vendor/downloads/… | PRESENT | Pinned build-context files already present; no action needed. |
| k3s installer, image list, and SELinux RPM | in repository | 3 inventoried file(s) | content/vendor/k3s/… | PRESENT | Already present and checksummed by content/vendor/k3s/SHA256SUMS; no action needed. |
| Artifactory CA certificate | base image | 1 inventoried file(s) | /etc/pki/ca-trust/source/anchors/airgap-ca.crt | PRESENT | Already supplied by the base image at CA_CERT_SOURCE; no action needed. |

## Section B — Fetched at Provisioning Time on the VM

Every standalone runtime artifact is catalogued in `learner-vm/artifacts.tsv` with its kind, required status, local staging path, URL variable, checksum lock key, consumer, and install target.
The pinned upstream URL and SHA-256 below identify the version in `versions.lock`; the learner VM fetches only from the configured Artifactory URL variable, never from that upstream URL.
For each entry, the resolver checks `$MANUAL_FETCH_DIR/<staging_relative_path>` first and verifies it against the checksum key in `versions.lock` before use.
A bad local checksum is a hard failure; the file is never overwritten and its URL is never fetched as a fallback.
Only when no local file exists does the resolver use the configured HTTPS Artifactory generic-file URL, download to a temporary file, verify its SHA-256, and stage it locally.
The Artifactory URL is supplied by the operator and is not stored in the catalog or committed configuration.

| id | kind | required | URL variable | SHA-256 lock key | pinned upstream reference | SHA-256 | local staging path | consumer | install target |
|---|---|---|---|---|---|---|---|---|---|
| k3s-airgap-images | archive | OPTIONAL | K3S_AIRGAP_IMAGES_URL | learner-k3s-airgap-images-amd64.tar.zst | https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/k3s-airgap-images-amd64.tar.zst | 865b2a63ad7a63fc0db17b7fc2985bf4ae11d5ae93ca1472be6218d20aeb6b23 | $MANUAL_FETCH_DIR/k3s/k3s-airgap-images-amd64.tar.zst | scripts/45-k3s-install.sh | /var/lib/rancher/k3s/agent/images/ |
| k3s-binary | binary | REQUIRED | K3S_BINARY_URL | learner-k3s-binary-amd64 | https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/k3s | 92b94582eb7b34a8cf532e6006842b9ed215a6783cf56a3dd6271fd35243b2c0 | $MANUAL_FETCH_DIR/k3s/k3s | scripts/45-k3s-install.sh | /usr/local/bin/k3s |

### Required k3s Binary Recovery

If script 45 cannot obtain the required binary, ask the Artifactory administrator for the exact generic-file URL and set `K3S_BINARY_URL` on the VM.
Run the following from the repository root to download to a temporary file, verify the lock key, and stage the file for retry.
The commands refuse to overwrite an existing staged file; investigate a checksum failure before replacing that file manually.

```bash
set -euo pipefail
set -a
source learner-vm/lab-vm.conf
set +a
[[ -n "$K3S_BINARY_URL" ]] || { printf "%s\n" "Set K3S_BINARY_URL from the Artifactory administrator." >&2; exit 1; }
sudo install -d -o "$WORKSHOP_USER" -g "$WORKSHOP_USER" -m 0750 "$MANUAL_FETCH_DIR/k3s"
[[ ! -e "$MANUAL_FETCH_DIR/k3s/k3s" && ! -L "$MANUAL_FETCH_DIR/k3s/k3s" ]] || { printf "%s\n" "Staged file already exists; verify it before taking any action." >&2; exit 1; }
temporary_binary="$(mktemp)"
trap 'rm -f -- "$temporary_binary"' EXIT
curl --fail --silent --show-error --connect-timeout 10 --max-time 900 --output "$temporary_binary" "$K3S_BINARY_URL"
expected_sha="$(awk '$1 == "learner-k3s-binary-amd64" {for (i=1;i<=NF;i++) if ($i ~ /^sha256:/) {sub(/^sha256:/,"",$i); print $i; exit}}' versions.lock)"
actual_sha="$(sha256sum "$temporary_binary" | awk '{print $1}')"
[[ -n "$expected_sha" && "$actual_sha" == "$expected_sha" ]] || { printf "SHA-256 mismatch: expected %s, actual %s\n" "$expected_sha" "$actual_sha" >&2; exit 1; }
sudo install -o root -g root -m 0755 "$temporary_binary" "$MANUAL_FETCH_DIR/k3s/k3s"
sudo bash learner-vm/scripts/45-k3s-install.sh
```

If the download fails or the checksum differs, do not install the file. Preserve the report and escalate with the redacted URL, HTTP/error details, expected and actual SHA-256, DNS/TLS diagnostics, and script 45 report.
The `k3s-airgap-images` archive is optional and uses `K3S_AIRGAP_IMAGES_URL`, an operator-supplied Artifactory generic-file URL separate from the container-image registry endpoint.
If that URL is unset or the optional fetch fails, k3s obtains `registry.k8s.io` system images through the configured Artifactory registry mirrors.
The archive is not present in Git and is not transferred separately; if intentionally staged locally, place it at `$MANUAL_FETCH_DIR/k3s/k3s-airgap-images-amd64.tar.zst`, verify lock key `learner-k3s-airgap-images-amd64.tar.zst`, and rerun script 45 so it stages the file under `/var/lib/rancher/k3s/agent/images/` before startup.

## Section C — Container Images, Fetched at Provisioning Time

Script 20 fetches RHEL packages and repository metadata from the configured Artifactory DNF repositories.
If package or metadata fetches fail, capture `dnf -v repolist`, `dnf -v makecache`, repository configuration, ART_HOST DNS results, and CA/TLS diagnostics, then contact the Artifactory administrator.

| runtime package source | endpoint | status | used by | recovery |
|---|---|---|---|---|
| RHEL 8 packages and repository metadata | ART_HOST | FETCH AT PROVISIONING | script 20 | Capture dnf -v repolist and dnf -v makecache output, repository configuration, ART_HOST DNS results, and CA/TLS diagnostics; contact the Artifactory administrator. Do not use a public-internet fallback. |

Scripts 60 and 62 pull external images through `$DOCKER_REGISTRY`, configured in `registries.conf` and `/etc/rancher/k3s/registries.yaml` before k3s starts.
The Podman and k3s containerd stores are separate: script 60 uses `podman pull <original-reference>`; script 62 uses `k3s crictl pull <original-reference>` for external images.
For locally built Podman images required by k3s, use `podman save` followed by `k3s ctr -n k8s.io images import`.

| image | runtime source | status | used by | recovery |
|---|---|---|---|---|
| docker.io/jaegertracing/all-in-one:1.76.0 | DOCKER_REGISTRY (Artifactory mirror) | FETCH AT PROVISIONING | script 60 (Podman) and script 62 (k3s containerd) | Record the original image reference, DOCKER_REGISTRY endpoint, k3s version if applicable, pull output, CA/DNS results, and relevant journal; escalate to the Artifactory administrator. Do not use a public-internet fallback. |
| docker.io/library/busybox:1.36 | DOCKER_REGISTRY (Artifactory mirror) | FETCH AT PROVISIONING | script 60 (Podman) | Record the original image reference, DOCKER_REGISTRY endpoint, k3s version if applicable, pull output, CA/DNS results, and relevant journal; escalate to the Artifactory administrator. Do not use a public-internet fallback. |
| docker.io/library/eclipse-temurin:21 | DOCKER_REGISTRY (Artifactory mirror) | FETCH AT PROVISIONING | script 60 (Podman) | Record the original image reference, DOCKER_REGISTRY endpoint, k3s version if applicable, pull output, CA/DNS results, and relevant journal; escalate to the Artifactory administrator. Do not use a public-internet fallback. |
| docker.io/library/python:3.13-bullseye | DOCKER_REGISTRY (Artifactory mirror) | FETCH AT PROVISIONING | script 60 (Podman) | Record the original image reference, DOCKER_REGISTRY endpoint, k3s version if applicable, pull output, CA/DNS results, and relevant journal; escalate to the Artifactory administrator. Do not use a public-internet fallback. |
| docker.io/opensearchproject/opensearch-dashboards:3.3.0 | DOCKER_REGISTRY (Artifactory mirror) | FETCH AT PROVISIONING | script 60 (Podman) | Record the original image reference, DOCKER_REGISTRY endpoint, k3s version if applicable, pull output, CA/DNS results, and relevant journal; escalate to the Artifactory administrator. Do not use a public-internet fallback. |
| docker.io/opensearchproject/opensearch:3.3.1 | DOCKER_REGISTRY (Artifactory mirror) | FETCH AT PROVISIONING | script 60 (Podman) | Record the original image reference, DOCKER_REGISTRY endpoint, k3s version if applicable, pull output, CA/DNS results, and relevant journal; escalate to the Artifactory administrator. Do not use a public-internet fallback. |
| docker.io/otel/opentelemetry-collector-contrib:0.159.0 | DOCKER_REGISTRY (Artifactory mirror) | FETCH AT PROVISIONING | script 60 (Podman) | Record the original image reference, DOCKER_REGISTRY endpoint, k3s version if applicable, pull output, CA/DNS results, and relevant journal; escalate to the Artifactory administrator. Do not use a public-internet fallback. |
| docker.io/persesdev/perses:v0.54.0 | DOCKER_REGISTRY (Artifactory mirror) | FETCH AT PROVISIONING | script 60 (Podman) | Record the original image reference, DOCKER_REGISTRY endpoint, k3s version if applicable, pull output, CA/DNS results, and relevant journal; escalate to the Artifactory administrator. Do not use a public-internet fallback. |
| docker.io/prom/prometheus:v3.13.1 | DOCKER_REGISTRY (Artifactory mirror) | FETCH AT PROVISIONING | script 60 (Podman) | Record the original image reference, DOCKER_REGISTRY endpoint, k3s version if applicable, pull output, CA/DNS results, and relevant journal; escalate to the Artifactory administrator. Do not use a public-internet fallback. |
| ghcr.io/fluent/fluent-bit:5.1.1 | DOCKER_REGISTRY (Artifactory mirror) | FETCH AT PROVISIONING | script 60 (Podman) | Record the original image reference, DOCKER_REGISTRY endpoint, k3s version if applicable, pull output, CA/DNS results, and relevant journal; escalate to the Artifactory administrator. Do not use a public-internet fallback. |
| localhost/hello-otel:prog | repository build and local Podman store | LOCAL BUILD/IMPORT | script 60 (Podman) and script 62 (k3s containerd) | Rebuild from the recorded commands.json entry and vendored context; when k3s needs the image, use podman save and k3s ctr -n k8s.io images import. |
| quay.io/prometheus/node-exporter:v1.12.1 | DOCKER_REGISTRY (Artifactory mirror) | FETCH AT PROVISIONING | script 60 (Podman) | Record the original image reference, DOCKER_REGISTRY endpoint, k3s version if applicable, pull output, CA/DNS results, and relevant journal; escalate to the Artifactory administrator. Do not use a public-internet fallback. |

If Artifactory is unreachable or an image is absent from the mirror, do not attempt a public-internet fallback. Contact the Artifactory administrator.
Before escalating, capture the original image reference, configured `$DOCKER_REGISTRY` endpoint, pull command output, DNS lookup, CA/TLS diagnostics, `podman info` or `k3s crictl images`, k3s version, and relevant k3s/containerd journal excerpts.
Learner-network Artifactory access and image pulls remain unverified until operator reports are reviewed.
