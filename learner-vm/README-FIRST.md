# Learner VM: First Run

This guide describes the connected-upstream packaging and RHEL 8.6 learner-VM hand-off.
The VM is prepared while Artifactory is reachable, then handed to attendees with its required images already present.
No container image or other dependency may be pulled from a network service during attendee runtime.

## One-File Transfer

On the connected upstream machine, create one self-contained ZIP from the current worktree.
The ZIP contains the current source tree and small vendored inputs only; it does not contain the k3s binary or an image archive.

```bash
cd /path/to/observability-workshop-airgapped
bash scripts/dev/package-vm-transfer.sh --out dist/o11y-lab-vm-transfer-single
```

The packager prints the ZIP size and SHA-256 and also writes an online-record sidecar.
Transfer only `o11y-lab-vm-repository.zip` to the learner VM; the sidecar and a separate payload archive are not needed.
Git, Git LFS, and access to an online Git service are not required on the VM.

On the learner VM, substitute the SHA-256 printed by the packager and choose the repository directory.

```bash
ZIP_SHA256='<SHA-256 printed by the packager>'
ZIP_NAME='o11y-lab-vm-repository.zip'
REPOSITORY_DIR="$HOME/o11y-lab"
printf '%s  %s\n' "$ZIP_SHA256" "$ZIP_NAME" | sha256sum -c -
mkdir -p "$REPOSITORY_DIR"
unzip -q "$ZIP_NAME" -d "$REPOSITORY_DIR"
cd "$REPOSITORY_DIR"
```

The k3s binary is downloaded during provisioning from an Artifactory generic-file URL and verified against the pinned SHA-256 in `versions.lock`.
The ZIP sidecar is optional online integrity metadata and is not a second transfer file.

## k3s Binary URL

The packaged `learner-vm/lab-vm.conf` intentionally leaves `K3S_BINARY_URL` empty.
Obtain the exact HTTPS generic-file URL from the Artifactory administrator and set it in that file before provisioning.
Do not invent an Artifactory path or use the public GitHub release URL on the learner VM.
The SHA-256 in `versions.lock` remains authoritative and is not duplicated in `lab-vm.conf`.

## Manual Fetch Recovery

If the automatic download fails, configure the administrator-supplied `K3S_BINARY_URL` and use the same-VM staging fallback below.
This fallback downloads on the learner VM; do not transfer a binary, payload archive, or airgap tarball separately.

```bash
set -a
source learner-vm/lab-vm.conf
set +a
sudo install -d -o "$WORKSHOP_USER" -g "$WORKSHOP_USER" -m 0750 "$MANUAL_FETCH_DIR/k3s"
curl --fail --silent --show-error --connect-timeout 15 --max-time 900 --output "$MANUAL_FETCH_DIR/k3s/k3s" "$K3S_BINARY_URL"
expected_sha="$(awk '$1 == "learner-k3s-binary-amd64" {for (i=1;i<=NF;i++) if ($i ~ /^sha256:/) {sub(/^sha256:/,"",$i); print $i; exit}}' versions.lock)"
actual_sha="$(sha256sum "$MANUAL_FETCH_DIR/k3s/k3s" | awk '{print $1}')"
[[ "$actual_sha" == "$expected_sha" ]]
```

Rerun script 45 after the staged file matches the lock hash.
If a staged file exists but has a mismatched hash, stop and replace it from the configured Artifactory URL before retrying.
See [content/vendor/MANUAL-FETCH.md](../content/vendor/MANUAL-FETCH.md) for the pinned upstream provenance and fallback details.

## Provisioning Design

Install operating-system CA trust for the configured registry with script 30 before starting k3s. Script 45 installs the retained SELinux RPM, installs the checksum-verified k3s binary, then writes `/etc/rancher/k3s/registries.yaml` before the k3s service starts so its containerd instance uses the approved Artifactory mirror for both `docker.io` and `registry.k8s.io`.
The pinned v1.37.1+k3s1 release supports mirror endpoint URLs with a path prefix and per-endpoint `tls.ca_file` configuration.

The following illustrates the supported registry structure using values from `learner-vm/lab-vm.conf`:

```bash
set -a
source "$HOME/o11y-lab/learner-vm/lab-vm.conf"
set +a
sudo install -d -m 0755 /etc/rancher/k3s
sudo tee /etc/rancher/k3s/registries.yaml >/dev/null <<EOF
mirrors:
  docker.io:
    endpoint:
      - "https://${DOCKER_REGISTRY}"
  registry.k8s.io:
    endpoint:
      - "https://${DOCKER_REGISTRY}"
configs:
  "${ART_HOST}":
    tls:
      ca_file: "${CA_CERT_SOURCE}"
EOF
```

The pinned k3s binary provides `k3s crictl pull`, which uses the containerd CRI image service and its registry configuration.
Use that CRI path for pull diagnostics; `k3s ctr images pull` is not the mirror-aware test path.
Inspect images with `sudo /usr/local/bin/k3s crictl images` and inspect the containerd registry host configuration under `/var/lib/rancher/k3s/agent/etc/containerd/certs.d/`.
For failures, inspect `/var/lib/rancher/k3s/agent/containerd/containerd.log` and `sudo journalctl -u k3s -b --no-pager`.

The intended provisioning order is scripts 10, 20, 30, 40, 45, 50, 60, 62, and 70. This establishes CA trust, installs tools and mirrors, configures k3s before first start, and then preloads the separate rootful Podman and k3s image stores. Verify that system pods are Ready and inspect the k3s image store using `k3s kubectl get pods -A` and `k3s crictl images`.
The mirror format is documented in the [K3s private registry guide](https://docs.k3s.io/installation/private-registry) and verified against the pinned [v1.37.1+k3s1 containerd configuration source](https://github.com/k3s-io/k3s/blob/v1.37.1%2Bk3s1/pkg/agent/containerd/config.go).
The registry must be tested on the learner network before this path is considered validated.
The connected-machine probe reported HTTP 000 because its resolver could not resolve the configured registry host; this is not evidence of an image miss or a successful mirror pull.

After bootstrap, provision workshop images into the separate k3s containerd store as well as the rootful Podman store when both runtimes need them.
The k3s and Podman image stores are independent.
Before hand-off, block Artifactory access and verify that both stores contain every image required by their respective labs.
Attendees must not need Artifactory or any other network service at runtime.
Rootless Podman is not enabled by these scripts; see [docs/rootless-podman.md](../docs/rootless-podman.md) before considering a future migration because its image store requires separate preloading.

## Diagnosis and Run Order

After extraction, run only this read-only diagnostic from the repository's learner-vm directory:

```bash
cd "$HOME/o11y-lab/learner-vm"
sudo bash scripts/00-diagnose.sh
```

Transcribe its complete REPORT block into the next `feedback/airgap-run-*.md` file and wait for the report to be reviewed.
The diagnostic reports the previous online registry probe as inconclusive when its recorded status is HTTP 000.
Its report is read-only evidence and does not establish that mirror pulls have been tested on the learner network.
Do not run scripts 10–80 until the diagnostic report has been reviewed and the operator has been told to proceed.

## Removed Files and Recovery

The cleanup manifest is `scripts/dev/obsolete-artifacts.txt`.
It records the former compatibility executable and sidecar, k3s executable, and airgap tarball paths that must not enter the source ZIP.
The packager does not remove, stage, or clean these or any other working-tree files.
The small k3s installer, image list, and SELinux RPM remain in Git and are checksummed by `content/vendor/k3s/SHA256SUMS`.
Script 45 downloads the pinned k3s binary from the administrator-supplied `K3S_BINARY_URL`; k3s images are acquired through Artifactory CRI pulls during provisioning.

The upstream freeze tag `workshop-lvm-prep-v2` is the recovery point for removed Git files.
From an upstream clone, restore an individual path with `git checkout workshop-lvm-prep-v2 -- <path>`.

## Transcription Protocol

For each operator run, copy the complete text from `==================== REPORT BEGIN ====================` through `==================== REPORT END ======================` into the online feedback record without editing the report.
Transcribe, do not improvise: follow the `NEXT` line and report evidence rather than making undocumented VM changes.
If a script reports a failure, transcribe the block and stop until the online team reviews it.
Provisioning scripts are idempotent artifacts; only the human operator runs them on the learner VM.
