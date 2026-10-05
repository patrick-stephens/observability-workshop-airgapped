# Vendored Transfer Assets

This directory keeps the small, pinned k3s installer, system-image list, and RHEL SELinux RPM in ordinary Git history.
The `k3s/SHA256SUMS` file covers those retained support files.
The k3s executable and airgap image tarball are not stored in Git or included in the repository ZIP.

## One-ZIP Transfer

On the connected machine, `scripts/dev/package-vm-transfer.sh` builds a source-only ZIP from the current worktree.
Transfer only `o11y-lab-vm-repository.zip` to the learner VM.
No payload archive or separate payload checksum sidecar is part of this workflow.
The exact one-ZIP receiving commands and diagnostic-only gate are in [learner-vm/README-FIRST.md](../../learner-vm/README-FIRST.md).

## Manual Recovery

Set `K3S_BINARY_URL` in `learner-vm/lab-vm.conf` to the exact HTTPS Artifactory generic-file URL supplied by the Artifactory administrator.
The packaged value is empty until that exact endpoint is provided; do not invent a path or use the public GitHub URL on the learner VM.
The pinned binary SHA-256 remains authoritative in `versions.lock` and is not duplicated in configuration.
Script 45 downloads to a temporary file, verifies the lock hash, and installs the binary before the first k3s start.
If the automatic fetch fails, an operator may download the same configured URL on the VM into `$MANUAL_FETCH_DIR/k3s/k3s`, verify it against `versions.lock`, and rerun script 45.
This is a same-VM fallback, not a second transfer artifact.
See [MANUAL-FETCH.md](MANUAL-FETCH.md) for pinned URLs, hashes, and recovery steps.

Artifactory-based k3s pulls have not been verified on the learner network.
Provisioning obtains k3s system images from the configured Artifactory mirror and records actual CRI pull results; do not infer success from the connected-host probe.
The k3s mirror-aware pull path is `k3s crictl pull`, not `k3s ctr images pull`.

The Podman and k3s containerd image stores are separate.
External Podman images use `podman pull` through `registries.conf`; external Kubernetes images use `k3s crictl pull` through k3s's `registries.yaml`.
Locally built images needed by k3s use `podman save` followed by `k3s ctr -n k8s.io images import`.
No separately transferred image bundle is required, and workshop images must be verified before attendees use the VM.