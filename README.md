# Airgapped Observability Workshop

This repository contains the source and offline artefacts for a live observability workshop demo, presented on an Ubuntu VM running K3S and replayed on a network-isolated node.
The repository is designed so the environment can be prepared on a build node, then deployed and operated without outbound network access.

## Demo Premise

The demo follows one incident across four layers: the application, Kubernetes, the telemetry pipeline, and the observability backend.
Three deliberate breaks show how symptoms from one incident appear across those layers.

## Build and Replay Nodes

The build node is used for the initial capture of dependencies and artefacts.
This is the only stage allowed outbound network access.
Captured artefacts are transferred with the repository to the replay node.

The replay node is the Ubuntu VM running K3S where the workshop demo is presented and replayed offline.
It must deploy from the captured artefacts and operate without outbound network access.

## Directory Map

- `charts/`: vendored Helm `.tgz` archives; never fetched during install.
- `values/`: one values file per chart.
- `manifests/`: Kubernetes objects applied directly.
- `scripts/`: numbered, idempotent VM, bootstrap, and demo scripts.
- `app/`: demo application source.
- `bundle/`: output from offline capture; generated contents are gitignored.
- `docs/`: speaker notes and runbooks.

## Local Checks

The pre-commit configuration uses the pinned upstream hook repositories listed in `versions.lock`.
On the connected build node, provision pre-commit 4.2.0, then run `bash scripts/00-install-hooks.sh` to validate the config and fetch the pinned hook environments.
The script installs Git hooks unless a custom `core.hooksPath` is already configured; it leaves an existing hooks path unchanged.
Subsequent checks use the installed environments without outbound access.
For offline use on another node, transfer the pre-commit cache from `$HOME/.cache/pre-commit` along with the captured tools.

Before completing a change, run `pre-commit run --all-files` and confirm it passes.
This runs all applicable file hooks; the Conventional Commits hook is run for commit messages when a commit is created.
The generic JSON key sorter excludes the npm-generated `slides/package-lock.json` to preserve npm's lockfile serialization; JSON syntax and other file checks still run.

## Host Prerequisites

On the connected Ubuntu 24.04 build host, run `sudo scripts/00-host-prereqs.sh` before starting the validation VM or capturing images.
The script installs pinned APT packages and checksum-verified Helm and kubectl binaries from `versions.lock`, enables Docker, loads KVM, and adds the invoking account to the `docker` and `kvm` groups.
Log out and back in after the first run so the new group memberships apply to your session.
Docker-group membership grants effectively root-equivalent access, so only add a trusted build-host account.
The script is safe to rerun and does not alter the host network or swap configuration.

## Current State

The repository contains the three-service Go demo application, local hook setup, Ubuntu host provisioning, and a disposable KVM VM launcher.
The guest-side prerequisite, K3S, Cilium/Tetragon, and cluster verification scripts are present.
The Cilium and Tetragon charts are vendored, and the build-node capture script creates the offline image bundle.
The local KVM guest has been used to verify the Ubuntu VM and K3S installer; chart rollout verification is recorded by `scripts/verify-cluster.sh`.
The chart teardown script removes Cilium and Tetragon while preserving K3S.
Every future `kubectl apply` or `helm install` must have its matching teardown documented here.

`versions.lock` records the pinned local development tools and the reason for each dependency.

## Local KVM Validation VM

Run the host prerequisite script above to install `qemu-system-x86`, `qemu-utils`, `cloud-image-utils`, `curl`, and `openssh-client` on the Ubuntu host.
Run `scripts/01-local-vm.sh start` to verify or download the pinned Ubuntu 24.04 cloud image, create a qcow2 overlay, configure SSH with your existing public key, and boot the VM.
The launcher uses QEMU user-mode networking and forwards host `127.0.0.1:2222` to guest port 22 without changing host networking or requiring sudo.
The VM image, disk overlay, cloud-init data, and logs are stored under `$HOME/vm-images/observability-workshop`, outside this repository.

Connect with `scripts/01-local-vm.sh ssh`.
For a manual SSH connection, run `ssh -p 2222 -i ~/.ssh/id_ed25519 ubuntu@127.0.0.1`.
Copy the bootstrap files and captured assets into the guest with `scp -P 2222 -r scripts charts values bundle versions.lock ubuntu@127.0.0.1:/home/ubuntu/demo/`.
Use `scripts/01-local-vm.sh status` to inspect the QEMU process, `stop` to stop the guest, and `destroy` to remove the guest disk and cloud-init state while retaining the verified base image.

## K3S Cluster Bootstrap

On the connected build node, run `scripts/05-capture-cluster-assets.sh` to capture the pinned K3S artifacts, vendored Cilium and Tetragon charts, CLI tools, and container images.
Copy `scripts/`, `charts/`, `values/`, `bundle/`, and `versions.lock` into the running guest before disconnecting it from the network.
Inside the guest, run `sudo scripts/00-prereqs.sh`, `sudo scripts/10-k3s.sh`, `sudo scripts/20-cilium.sh`, and `sudo scripts/verify-cluster.sh` in that order.
K3S starts with Flannel, Kubernetes network policy, kube-proxy, Traefik, and ServiceLB disabled; Cilium supplies the CNI and service proxy.
Tetragon is installed as a separate pinned chart because the official Cilium chart does not deploy the Tetragon agent.

Run `sudo scripts/90-teardown-cluster.sh` inside the guest to uninstall the Tetragon and Cilium Helm releases.
The teardown leaves K3S installed and does not remove the VM, captured artifacts, or host configuration.
