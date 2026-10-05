# Vendored Transfer Assets

This directory keeps small, pinned installation inputs and checksums in ordinary Git history.
The `k3s/SHA256SUMS` file covers the retained installer, image list, and SELinux RPM.
The large k3s binary and optional airgap image tarball remain out of ordinary Git history.

## One-ZIP Transfer

On the connected machine, `scripts/dev/package-vm-transfer.sh` builds a ZIP from the current worktree and embeds the verified payload under `learner-vm/content/vendor/payload/`.
The default package includes both the required k3s binary and the optional airgap tarball fallback.
The `--no-airgap-tarball` option omits that fallback and records `OPTIONAL_NOT_INCLUDED` in the embedded manifest.
Transfer only `o11y-lab-vm-repository.zip` to the learner VM.
A standalone payload archive and separate payload checksum sidecar are not required; any ZIP sidecar is for online record-keeping only.

The embedded `learner-vm/content/vendor/payload/payload-manifest.txt` is tab-separated and records each payload path, version, source URL, pinned SHA-256, and inclusion status.
After extraction, verify each included file against both this manifest and its `versions.lock` record before running `sudo bash scripts/00-diagnose.sh` from the extracted `learner-vm/` directory.
The exact receiving commands and diagnostic-only gate are in [learner-vm/README-FIRST.md](../../learner-vm/README-FIRST.md).

## Manual Recovery

If the ZIP is damaged or the required binary is absent or checksum-invalid, fetch the pinned binary on a connected machine and verify it against `versions.lock`.
Transfer a verified recovery copy to `$MANUAL_FETCH_DIR/k3s/k3s`, where `MANUAL_FETCH_DIR` defaults to `/var/tmp/o11y-lab-vm-manual`.
The optional tarball fallback path is `$MANUAL_FETCH_DIR/k3s/k3s-airgap-images-amd64.tar.zst`.
Scripts 00 and 45 prefer the payload embedded in the repository ZIP and consult these manual paths only when the corresponding embedded file is absent.
See [MANUAL-FETCH.md](MANUAL-FETCH.md) for pinned URLs, hashes, and recovery steps.

Artifactory-based k3s pulls have not been verified on the learner network.
If the optional tarball is omitted or absent, provisioning uses the configured Artifactory CRI pull path and records its actual result; do not infer success from the connected-host probe.
The k3s mirror-aware pull path is `k3s crictl pull`, not `k3s ctr images pull`.

The Podman and k3s containerd image stores are separate.
Workshop images must be provisioned into both stores as needed and verified before hand-off; attendees must not need Artifactory or any other network service at runtime.