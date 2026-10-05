# Manual Fetch and Recovery

Use this guide when an online or Artifactory fetch cannot be completed automatically.
The repository ZIP already contains the repository entries below; the CA certificate is supplied by the configured base image.

## Section A — Repository Files (No Fetch Needed)

These files travel inside the repository ZIP and require no separate download or transfer.
The base-image CA certificate is already at its configured path and also requires no separate transfer.

| name | source | SHA-256 | staging path | status | used by | purpose |
|---|---|---|---|---|---|---|
| Artifactory registry CA certificate | on base image | n/a | /etc/pki/ca-trust/source/anchors/airgap-ca.crt | REQUIRED | script 30 (planned) | Already present at the configured base-image path; no separate fetch is needed. |
| content/vendor/downloads/otel-developers/opentelemetry-java-tracing-demo-v1.1.zip | in repo | 86518c7cbc1d1966a4356b40a8e7ace3a5fba6d7360b1d09a7314345e967bb30 | content/vendor/downloads/otel-developers/opentelemetry-java-tracing-demo-v1.1.zip | REQUIRED | script 60 (planned) | Runtime build-context archive already included in the repository ZIP; original source URL: https://gitlab.com/o11y-workshops/opentelemetry-java-tracing-demo/-/archive/v1.1/opentelemetry-java-tracing-demo-v1.1.zip. |
| content/vendor/downloads/prometheus/prometheus-java-metrics-demo-v0.5.zip | in repo | 806746b3b2565d3a8cd3bc02611814b27b2a87a22bde652d33eb60ac4fb5c302 | content/vendor/downloads/prometheus/prometheus-java-metrics-demo-v0.5.zip | REQUIRED | script 60 (planned) | Runtime build-context archive already included in the repository ZIP; original source URL: https://gitlab.com/o11y-workshops/prometheus-java-metrics-demo/-/archive/v0.5/prometheus-java-metrics-demo-v0.5.zip. |
| content/vendor/downloads/prometheus/prometheus-service-demo-installer-v1.0.zip | in repo | a8098f487d651997ec8cf3a5322a8b70b3a3ac60d9edee4c740bf8b2351b0af1 | content/vendor/downloads/prometheus/prometheus-service-demo-installer-v1.0.zip | REQUIRED | script 60 (planned) | Runtime build-context archive already included in the repository ZIP; original source URL: https://gitlab.com/o11y-workshops/prometheus-service-demo-installer/-/archive/v1.0/prometheus-service-demo-installer-v1.0.zip. |
| content/vendor/k3s/install.sh | in repo | e5cc3b3d9dfc1662c2d9be6da5abc9a4cd317d6abc3a5ffc02e3dd3248207fee | content/vendor/k3s/install.sh | REQUIRED | script 45 (planned) | Pinned small k3s installation input included in the repository ZIP; no separate fetch is needed. |
| content/vendor/k3s/k3s-images.txt | in repo | 377307d4039ccd04f0e27d2906595a8c7b7d49a79f7553c311f6f960ff3efb58 | content/vendor/k3s/k3s-images.txt | REQUIRED | script 45 (planned) | Pinned release system-image reference list included in the repository ZIP; no separate fetch is needed. |
| content/vendor/k3s/k3s-selinux-1.6-1.el8.noarch.rpm | in repo | a1e24b0d82b1a6806cd420e2c0398a1796b055efe368fa4aebc8bb173850934f | content/vendor/k3s/k3s-selinux-1.6-1.el8.noarch.rpm | REQUIRED | script 45 (planned) | Pinned RHEL SELinux policy package included in the repository ZIP; no separate fetch is needed. |

## Section B — Payload Artifacts

Fetch these files on an internet-connected machine, verify the pinned digest, then transfer them to the VM staging path shown in the table.

| name | source URL | SHA-256 | staging path | status | used by | purpose |
|---|---|---|---|---|---|---|
| k3s/k3s | https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/k3s | 92b94582eb7b34a8cf532e6006842b9ed215a6783cf56a3dd6271fd35243b2c0 | $MANUAL_FETCH_DIR/k3s/k3s | REQUIRED | script 45 (planned) | Required k3s release artifact; install or copy to /usr/local/bin/k3s as documented in Section B. |
| k3s/k3s-airgap-images-amd64.tar.zst | https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/k3s-airgap-images-amd64.tar.zst | 865b2a63ad7a63fc0db17b7fc2985bf4ae11d5ae93ca1472be6218d20aeb6b23 | $MANUAL_FETCH_DIR/k3s/k3s-airgap-images-amd64.tar.zst | OPTIONAL | script 45 (planned) | Optional fallback k3s release artifact; install or copy to /var/lib/rancher/k3s/agent/images/k3s-airgap-images-amd64.tar.zst as documented in Section B. |

### Required k3s Binary

On an internet-connected machine: `curl -fL -o k3s https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/k3s`.
Check the actual checksum with `sha256sum k3s` and verify it against `92b94582eb7b34a8cf532e6006842b9ed215a6783cf56a3dd6271fd35243b2c0` from this table or `versions.lock`.
Transfer the verified file to `$MANUAL_FETCH_DIR/k3s/k3s` on the VM.
The planned script 45 also accepts the file at `$MANUAL_FETCH_DIR/k3s/k3s`; to install it manually, run `sudo install -m 755 "$MANUAL_FETCH_DIR/k3s/k3s" /usr/local/bin/k3s`.

### Optional Airgap Image Tarball

On an internet-connected machine: `curl -fL -o k3s-airgap-images-amd64.tar.zst https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/k3s-airgap-images-amd64.tar.zst`.
Check the actual checksum with `sha256sum k3s-airgap-images-amd64.tar.zst` and verify it against `865b2a63ad7a63fc0db17b7fc2985bf4ae11d5ae93ca1472be6218d20aeb6b23` from this table or `versions.lock`.
Transfer the verified file to `$MANUAL_FETCH_DIR/k3s/k3s-airgap-images-amd64.tar.zst` on the VM.
Copy it before the first k3s start; the planned script 45 copies a correctly staged file automatically.
To copy manually: `sudo mkdir -p /var/lib/rancher/k3s/agent/images/` followed by `sudo cp "$MANUAL_FETCH_DIR/k3s/k3s-airgap-images-amd64.tar.zst" /var/lib/rancher/k3s/agent/images/`.
This fallback avoids pulling k3s system images during bootstrap and is only needed if Artifactory-based provisioning is unreliable.

## Section C — Container Images (Fallback Only)

If Artifactory is unreachable from the VM, script 60 cannot complete the Podman image store and script 62 cannot complete the separate k3s containerd store. Generate the optional fallback bundle on an internet-connected machine with `scripts/dev/make-image-bundles.sh`; the current dynamic image set contains 12 unique references and is derived from `content/extracted/external-images.txt` plus images in the curated Kubernetes manifests.
Regenerate and print that set with `scripts/dev/make-image-bundles.sh --list`.
Transfer fallback archives to `$MANUAL_FETCH_DIR/images/`; the tool writes per-image digest sidecars and archive checksums.

## How to Use This File

1. Look for the requested file at its staging path.
2. If present, verify its SHA-256 and use it.
3. If absent, try the documented network source while that source is reachable.
4. If the network fetch fails, stop with FATAL; the fix hint names this MANUAL-FETCH section and the exact staging path.

Worked example:

```text
Script 45: FATAL — pinned k3s binary is missing. FIX: See MANUAL-FETCH.md Section B; place the verified file at $MANUAL_FETCH_DIR/k3s/k3s.
Operator on connected machine: curl -fL -o k3s https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/k3s
Operator: printf '%s  k3s\n' '92b94582eb7b34a8cf532e6006842b9ed215a6783cf56a3dd6271fd35243b2c0' | sha256sum -c -
Operator transfers the verified file to $MANUAL_FETCH_DIR/k3s/k3s, then reruns script 45.
```
