# Offline Bundle

This directory is generated on an internet-connected Ubuntu 24.04 build node and carried to an airgapped replay node.
Everything here except this README is produced by scripts and is ignored by git.
The bootable installer ISO is a separate output and is excluded from this archive and its checksum manifest because the ISO already embeds the archive.

## What the Bundle Contains

`o11y-demo-<date>-<gitsha>.tar.gz` is the single file you carry to the replay node.
`o11y-demo-<date>-<gitsha>.tar.gz.sha256` is its checksum, which you should carry with it.
The archive contains the repository files needed to deploy (`README.md`, `versions.lock`, `images.txt`, `docs/`, `scripts/`, `installer/`, `dashboards/`, `charts/`, `values/`, `manifests/`) and this `bundle/` directory.

Inside `bundle/`:

- `manifest.json` records every chart name and version, every image reference with its digest, the bundle creation time, and the git SHA the bundle was built from.
- `oci/` holds one OCI image layout per image, named after the image reference, for example `oci/quay.io_cilium_cilium_v1.17.6`.
- `container-images-amd64.tar` holds the same pinned images in `docker save` format for import into the K3S container runtime.
- `k3s-airgap-images-amd64.tar.zst` holds the K3S system images.
- `tools/` holds the pinned `k3s`, `helm`, `cilium`, and `hubble` binaries and their release archives.
- `perses-plugins/` holds the Perses Prometheus, Loki, and Tempo plugin archives.
- `SHA256SUMS` and `container-images-amd64.tar.sha256` are checksums checked before anything is installed.

The images come from three sources, unioned and deduplicated:

- every container, init container, Helm hook job, and Helm test pod rendered by `helm template` from each chart in `charts/` with its file in `values/`;
- `images.txt`, the images found running after the last validated `scripts/30-stack.sh`;
- the demo app and support images in `manifests/`, plus the `skopeo` image used to seed the local registry.

Every image must be pinned by tag and digest in `versions.lock`, or the capture fails.

## Building the Bundle (Build Node, Online)

Run these from the repository root on the connected build node:

```bash
sudo scripts/00-host-prereqs.sh
scripts/31-capture-plugins.sh
scripts/90-capture.sh
scripts/91-verify-bundle.sh
```

`scripts/90-capture.sh` runs `scripts/05-capture-cluster-assets.sh` first, so nothing needs to be cached beforehand.
`scripts/91-verify-bundle.sh` prints a single `✓` line on success, or lists every missing image and chart and exits non-zero.

## Bootable Installer ISO

After capturing and verifying the bundle, `scripts/06-build-installer-iso.sh` combines its archive with the pinned Ubuntu Server installer and a local APT repository for the node's runtime packages.
The ISO installs the operating system and demo stack offline, installs pinned PyYAML into the live installer from its local package repository, then waits five seconds before disk selection and auto-selects only when exactly one writable, non-removable disk is available.
When zero or multiple eligible disks are found, storage selection remains interactive rather than guessing.
The manual replay procedure below remains available and documents the same deployment steps individually.
See the root README's Bootable Demo Installer ISO section for local QEMU testing and access details.

## Applying the Bundle (Replay Node, Offline)

The replay node is a fresh Ubuntu 24.04 amd64 machine with no route to the internet.
Copy the archive and its `.sha256` file to the replay node, then run these commands in order:

```bash
sha256sum --check o11y-demo-<date>-<gitsha>.tar.gz.sha256
mkdir -p ~/o11y-demo
tar --extract --gzip --file o11y-demo-<date>-<gitsha>.tar.gz --directory ~/o11y-demo
cd ~/o11y-demo
scripts/91-verify-bundle.sh
sudo scripts/00-prereqs.sh
sudo scripts/10-k3s.sh
sudo scripts/30-stack.sh --offline
sudo scripts/reset.sh
sudo scripts/verify-observability.sh
sudo scripts/95-preflight-offline.sh
```

`sudo scripts/30-stack.sh --offline` installs only from `charts/` and `bundle/`, sends any non-local HTTP(S) request to a closed port, and pushes every image in `bundle/oci/` to the local registry at `registry.lab.local:5000`.
`sudo scripts/reset.sh` deploys the demo namespace; it refuses to run until `manifests/app/` contains the demo app manifests.
`sudo scripts/verify-observability.sh` checks chart readiness and Hubble HTTP telemetry after the reset has started demo traffic.
`sudo scripts/95-preflight-offline.sh` confirms there is no default route, that the local registry serves every image in `manifest.json`, and that the demo is ready, then prints a single `✓` line.

## Removing the Deployment

Run `sudo scripts/90-teardown-cluster.sh` to remove the demo namespace, the local registry and its seeded images, and the Helm releases while leaving K3S installed.
