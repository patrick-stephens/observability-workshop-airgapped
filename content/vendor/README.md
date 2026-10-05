# Vendored Transfer Assets

This directory keeps small, pinned installation inputs and checksums in the repository.
Large release binaries and container-image archives are generated as a separate transfer payload by `scripts/dev/package-vm-transfer.sh` on the connected upstream machine.
The `k3s/SHA256SUMS` file covers only the small files retained beside it.

The repository ZIP and payload archive are transferred separately to the learner VM.
Transfer the payload manifest and each archive's `.sha256` sidecar as well.
Verify both archives before extraction:

```bash
sha256sum -c o11y-lab-vm-repository.zip.sha256
(cd payload && sha256sum -c o11y-lab-vm-payload.tar.gz.sha256)
```

Extract the repository ZIP to the operator's chosen workspace and the payload archive to `/var/tmp/o11y-lab-vm-transfer/`.
The archive contains `payload/k3s/k3s`, which the operator hash-checks against `payload/payload-manifest.txt` and installs as `/usr/local/bin/k3s` with mode `0700` and root ownership.
The required payload contains the pinned k3s executable; the airgap image tarball is included only when the online packager receives `--include-k3s-airgap-tarball`.
If included, verify its manifest hash and place it in `/var/lib/rancher/k3s/agent/images/` before the first k3s start as the optional system-image fallback.
Use these commands after extracting the payload archive and checking the file hashes:

```bash
sudo install -o root -g root -m 0700 /var/tmp/o11y-lab-vm-transfer/payload/k3s/k3s /usr/local/bin/k3s
sudo install -D -o root -g root -m 0600 /var/tmp/o11y-lab-vm-transfer/payload/k3s/k3s-airgap-images-amd64.tar.zst /var/lib/rancher/k3s/agent/images/k3s-airgap-images-amd64.tar.zst
```

Run the second command only when the optional tarball was packaged.
Detailed transfer commands and provisioning order are in [learner-vm/README-FIRST.md](../../learner-vm/README-FIRST.md).

During provisioning, k3s obtains its system images from the configured Artifactory registry mirror while the registry is reachable.
The k3s `registries.yaml` mirror applies to containerd CRI pulls, including kubelet pulls and `k3s crictl pull`; `k3s ctr` is not the pull path for testing mirrors.
The online registry probe returned HTTP 000 because the connected host could not resolve the configured registry hostname, so mirror access remains unverified until tested on the learner network.

The Podman and k3s containerd image stores are separate.
Workshop images must be provisioned into both stores as needed and verified before hand-off; attendees must not need Artifactory or any other network service at runtime.

The removed files are listed in `scripts/dev/obsolete-artifacts.txt`.
To recover an upstream source file after cleanup, restore it from the freeze tag, for example `git checkout workshop-lvm-prep-v2 -- content/vendor/k3s/k3s`.