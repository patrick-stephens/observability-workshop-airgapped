# Learner VM: First Run

This guide describes the connected-upstream packaging and RHEL 8.6 learner-VM hand-off.
The VM is prepared while Artifactory is reachable, then handed to attendees with its required images already present.
No container image or other dependency may be pulled from a network service during attendee runtime.

## Transfer Files

The online packager creates a repository ZIP and a separate payload archive under `payload/`.
Transfer both archives, both `.sha256` sidecars, and `payload/payload-manifest.txt` to the VM using the approved file-transfer method.
Git, Git LFS, and access to an online Git service are not required on the VM.

From the directory containing the transferred files, verify the archives before extracting them:

```bash
sha256sum -c o11y-lab-vm-repository.zip.sha256
(cd payload && sha256sum -c o11y-lab-vm-payload.tar.gz.sha256)
```

Extract the repository and payload to their expected locations:

```bash
mkdir -p "$HOME/o11y-lab"
unzip -q o11y-lab-vm-repository.zip -d "$HOME/o11y-lab"
sudo install -d -m 0700 /var/tmp/o11y-lab-vm-manual
sudo tar -xzf payload/o11y-lab-vm-payload.tar.gz --strip-components=1 -C /var/tmp/o11y-lab-vm-manual
```

The payload staging directory is `$MANUAL_FETCH_DIR`, set to `/var/tmp/o11y-lab-vm-manual` in `learner-vm/lab-vm.conf`. Keep the payload archive's directory structure intact: script 10 checks the required k3s binary against `versions.lock`, and script 45 verifies the authoritative manual-fetch catalog before installing it with root ownership and mode `0755`.

## Manual Fetch Recovery

See [content/vendor/MANUAL-FETCH.md](../content/vendor/MANUAL-FETCH.md) when a network-dependent fetch fails: first look at the artifact's `$MANUAL_FETCH_DIR` staging path, verify and use it if present, otherwise try its documented network source, and if that fails stop with FATAL and use the exact staging path named in the fix hint; for example, if script 45 reports a missing k3s binary, fetch the pinned URL from Section B on a connected machine, verify its SHA-256, transfer it to `$MANUAL_FETCH_DIR/k3s/k3s`, then rerun script 45.

The optional airgap tarball is included only when the connected operator used `--include-k3s-airgap-tarball`. If present at its catalog path, script 45 verifies its hash and copies it into k3s's agent image directory before the first service start. If absent, script 45 reports that bootstrap will use Artifactory CRI pulls; their success is not assumed.

The airgap tarball is a recovery option if Artifactory-based bootstrap proves unreliable.
K3s imports images found in its agent image directory during bootstrap, avoiding registry pulls for those system images.

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
It removes an unused compatibility executable and sidecar, the separately transferred k3s executable, and the optional airgap tarball from the repository working tree.
The small k3s installer, image list, and SELinux RPM remain in Git and are checksummed by `content/vendor/k3s/SHA256SUMS`.
Large payloads are generated on the connected machine by `scripts/dev/package-vm-transfer.sh` and are not committed.

The upstream freeze tag `workshop-lvm-prep-v2` is the recovery point for removed Git files.
From an upstream clone, restore an individual path with `git checkout workshop-lvm-prep-v2 -- <path>`.

## Transcription Protocol

For each operator run, copy the complete text from `==================== REPORT BEGIN ====================` through `==================== REPORT END ======================` into the online feedback record without editing the report.
Transcribe, do not improvise: follow the `NEXT` line and report evidence rather than making undocumented VM changes.
If a script reports a failure, transcribe the block and stop until the online team reviews it.
Provisioning scripts are idempotent artifacts; only the human operator runs them on the learner VM.
