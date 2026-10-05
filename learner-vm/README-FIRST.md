# Learner VM: First Run

This guide describes the RHEL 8.6 learner-VM repository workflow.
The Git repository is the only transfer artefact; no other files are transferred.
Vendored workshop sources, documentation mirrors, build-context archives, and small k3s support files are already in the repository.
Network-fetched runtime dependencies use Artifactory, with no public-internet fallback.
The operator sets `K3S_BINARY_URL` on the VM before provisioning.

## Repository Workflow

1. On the connected machine, commit and push the reviewed repository changes.
2. Bring the repository onto the airgapped network using the approved internal mirror or repository transfer process.
3. On the learner VM, clone or copy the repository into its working directory.
4. Edit `learner-vm/lab-vm.conf` and set `K3S_BINARY_URL` to the exact HTTPS Artifactory generic-file URL supplied by the administrator.
5. From the repository's `learner-vm/` directory, run `sudo bash scripts/00-diagnose.sh`.
6. Transcribe the complete REPORT block into `feedback/airgap-run-001.md` and wait for review.
7. After approval, run scripts 10 through 80 in numeric order and transcribe each complete REPORT block.
8. When both parts of `80-verify-offline.sh` pass, shut down cleanly and snapshot the VM.

Set this one runtime URL on the learner VM; the committed value remains empty:

```bash
K3S_BINARY_URL=""
```

Do not invent an endpoint or use a public release URL.
The binary SHA-256 authority is the `learner-k3s-binary-amd64` record in `versions.lock`.
`10-preflight.sh` fails with an administrator-directed fix hint if script 45 would need a download while the URL is unset.

## Runtime Recovery

Script 45 downloads the pinned binary from Artifactory, verifies it against `versions.lock`, configures `/etc/rancher/k3s/registries.yaml` with the mirror and CA, and only then starts k3s.
If the binary fetch fails, use [MANUAL-FETCH.md](../content/vendor/MANUAL-FETCH.md), Section B, to download it directly on the VM to `$MANUAL_FETCH_DIR/k3s/k3s`, verify the lock hash, and rerun script 45.
Recover the binary on the learner VM from the configured Artifactory source.

Scripts 60 and 62 fetch external workshop images through the configured Artifactory mirror.
Podman and k3s containerd have separate image stores; use `podman pull` for external Podman images, `k3s crictl pull` for external Kubernetes images, and `podman save` plus `k3s ctr -n k8s.io images import` only for locally built images.
If Artifactory is unavailable or an image is missing, capture the image reference, endpoint, command output, DNS/CA diagnostics, k3s version, and relevant journals, then contact the Artifactory administrator.
Do not try a public-internet fallback.

## Report Protocol

Run the initial diagnostic from the repository's `learner-vm/` directory:

```bash
cd /path/to/repository/learner-vm
sudo bash scripts/00-diagnose.sh
```

Copy every complete REPORT block verbatim into the corresponding feedback record.
Follow each `NEXT` line and stop after any failure until the report has been reviewed.
The connected-machine registry probe returned HTTP 000 because its resolver could not resolve the configured host; this is not learner-network evidence.
The learner VM has not been validated until its own diagnostic and provisioning reports are reviewed.
