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
The bundle captures immutable tag-plus-digest image pins, while replay manifests use the corresponding local tags with `imagePullPolicy: Never` because K3S containerd resolves the imported tag references without contacting a registry.

## Directory Map

- `charts/`: vendored Helm `.tgz` archives; never fetched during install.
- `values/`: one values file per chart.
- `manifests/`: Kubernetes objects applied directly.
- `scripts/`: numbered, idempotent VM, bootstrap, and demo scripts.
- `images/`: source Dockerfiles for locally built offline workload images.
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
The script installs pinned APT packages and checksum-verified Helm and kubectl binaries from `versions.lock`, enables Docker with its Buildx plugin, loads KVM, and adds the invoking account to the `docker` and `kvm` groups.
Log out and back in after the first run so the new group memberships apply to your session.
Docker-group membership grants effectively root-equivalent access, so only add a trusted build-host account.
The script is safe to rerun and does not alter the host network or swap configuration.

## End-to-End VM Setup

Run all host commands from the repository root on the connected Ubuntu 24.04 build node.
First run `sudo scripts/00-host-prereqs.sh`, then log out and back in so the `docker` and `kvm` group membership changes apply.
Capture the pinned offline dependencies with `scripts/05-capture-cluster-assets.sh` while the build node has network access.
Run `scripts/31-capture-plugins.sh` on the connected build node to capture and checksum the Perses Prometheus, Loki, and Tempo plugin archives.
The capture script verifies each download, vendors the Cilium, Tetragon, and observability charts into `charts/`, saves the image archive under `bundle/`, and writes `bundle/SHA256SUMS`.
Start the Ubuntu guest with `scripts/01-local-vm.sh start`.
The guest uses a qcow2 overlay under `$HOME/vm-images/observability-workshop` and QEMU user-mode networking with outbound traffic restricted.
The only forwarded connection is SSH from host `127.0.0.1:2222` to guest port 22.
Wait for the script to report that the guest is reachable over SSH before continuing.

Connect interactively with `scripts/01-local-vm.sh ssh` or `ssh -p 2222 -i ~/.ssh/id_ed25519 ubuntu@127.0.0.1`.
If your SSH key is not `~/.ssh/id_ed25519`, set `SSH_PUBLIC_KEY_FILE` and `SSH_PRIVATE_KEY_FILE` before starting the VM.
Copy the required scripts, manifests, and all captured assets into the guest with `scp -P 2222 -i ~/.ssh/id_ed25519 -r scripts charts values manifests bundle versions.lock ubuntu@127.0.0.1:/home/ubuntu/demo/`.
Then connect to the guest and run `cd /home/ubuntu/demo` before executing the bootstrap commands.

Inside the offline guest, run `sudo scripts/00-prereqs.sh`, `sudo scripts/10-k3s.sh`, and `sudo scripts/30-stack.sh` in that order.
`00-prereqs.sh` configures kernel modules and sysctls, adds the two local lab hostnames, and disables swap.
`10-k3s.sh` installs K3S from `bundle/tools/k3s` and imports its airgap images without enabling flannel, kube-proxy, Traefik, or ServiceLB.
It pins K3S to the guest's non-Cilium IPv4 address with IPv4 pod CIDR `10.42.0.0/16` and service CIDR `10.43.0.0/16`, preventing an IPv6-only service DNS address on hosts that advertise IPv6 but do not route it.
`20-cilium.sh` installs only the vendored Helm archives and images from the bundle, then verifies Cilium status.
After Cilium is ready, it starts the locally imported registry image on `registry.lab.local:5000`; this local-only endpoint is required by demo preflight.
Tetragon is a separate pinned release because the official Cilium chart does not deploy the Tetragon agent.

Rerun the bootstrap and verification commands to confirm the setup is idempotent.
Run `sudo scripts/90-teardown-cluster.sh` in the guest to uninstall the observability, Tetragon, and Cilium Helm releases while leaving K3S installed.
Run `scripts/01-local-vm.sh stop` on the host to stop the guest without deleting its disk.
Run `scripts/01-local-vm.sh destroy` to remove the guest overlay and generated SSH/cloud-init state while retaining the verified base image.

## Current State

The repository contains the three-service Go demo application, local hook setup, Ubuntu host provisioning, and a disposable KVM VM launcher.
The guest-side prerequisite, K3S, Cilium/Tetragon, and cluster verification scripts are present.
The Cilium, Tetragon, and observability charts are vendored, and the build-node capture script creates the offline image bundle.
The observability stack uses the dedicated `fluent-bit-collector` chart as a DaemonSet for node log collection and direct Loki forwarding.
The separate `fluent-bit-aggregator` chart is not deployed because this topology has no Fluent Bit forward-input tier; it remains an option for a future multi-tier logging design.
The local KVM guest has been used to verify the Ubuntu VM and K3S installer; chart rollout verification is recorded by `scripts/verify-cluster.sh`.
The chart teardown script removes the observability, Cilium, and Tetragon releases while preserving K3S.
Every future `kubectl apply` or `helm install` must have its matching teardown documented here.

`versions.lock` records the pinned local development tools and the reason for each dependency.

## Alerting Demo

`scripts/30-stack.sh` installs the PrometheusRule, AlertmanagerConfig, and JSON echo sink after the kube-prometheus-stack CRDs are ready.
Run `docs/alerting-runbook.md` with the demo application and load generator running to demonstrate the Hubble 5xx alert, grouping, silence, and local webhook payload.
The webhook receiver is restricted to `http://echo-sink.demo.svc.cluster.local:8080/alerts`; there is no internet-facing receiver.
Use `kubectl logs -f deploy/echo-sink -n demo` to display each pretty-printed notification body.
`scripts/90-teardown-cluster.sh` removes the alerting manifests and echo sink before uninstalling the observability charts.
The alerting demo requires the application and load generator from the demo deployment to be running in namespace `demo`.
The current application build target runs services locally and does not create cluster workloads; complete the demo workload deployment before presenting this alerting beat.
The alert definition and ordered presenter steps are in `docs/alerting-runbook.md`.

## Demo Rehearsal

After `manifests/app/` contains the frontend, API, backend, and ServiceMonitor resources, run `sudo scripts/reset.sh` followed by `sudo scripts/preflight.sh` from the repository root on the K3S node.
`reset.sh` completes the demo namespace reset in under 60 seconds and refuses to delete namespace `demo` if the app, loadgen, alert, or sink manifests are missing.
`preflight.sh` checks the local registry, Cilium, Prometheus, Loki, Tempo, Perses, and demo pod readiness before establishing a clean baseline.
Use `sudo scripts/break.sh latency`, `errors`, `dns`, or `ok` to perform a named beat and its matching reset.
The DNS beat applies `manifests/chaos-dns-block.yaml` and should be demonstrated with `hubble observe --namespace demo --verdict DROPPED --last 20`.
The load generator image is built reproducibly from `images/hey/Dockerfile` by `scripts/05-capture-cluster-assets.sh`, pinned in `versions.lock`, and included in the offline image archive.
The official `rakyll/hey` container image is unavailable, so the connected build node builds the pinned v0.1.4 binary into a minimal scratch image.
The run-of-show, cut order, and presenter narration are in `docs/demo-runbook.md`.

## Offline Bundle Pipeline

On the connected build node, `scripts/90-capture.sh` runs `scripts/05-capture-cluster-assets.sh`, renders every chart in `charts/` with `helm template` including hook and test resources, and unions those images with `images.txt` and the images in `manifests/`.
It copies each pinned image with `skopeo copy --all --preserve-digests` into `bundle/oci/`, writes `bundle/manifest.json`, and produces `bundle/o11y-demo-<date>-<gitsha>.tar.gz`.
`skopeo` runs from the pinned `image.skopeo` container image through Docker, so it adds no host package.
`scripts/91-verify-bundle.sh` checks that every image in `manifest.json` is complete in `bundle/oci/` and that every chart in `charts/` is recorded, listing anything missing.
`images.txt` is rewritten by every `scripts/30-stack.sh` run with the images running in the cluster, each resolved to its `versions.lock` pin; commit it after a validated run.
On the replay node, `sudo scripts/30-stack.sh --offline` verifies the bundle, disables Helm repositories, sends non-local HTTP(S) to a closed port, and seeds `registry.lab.local:5000` from `bundle/oci/` before installing the stack.
`sudo scripts/95-preflight-offline.sh` then asserts there is no default route, that the registry serves every bundle image, and that `scripts/preflight.sh` passes.
The seeded images live in the local registry's `emptyDir` volume, so `scripts/90-teardown-cluster.sh` removes them with the registry.
The full replay procedure is in `bundle/README.md`.

## Enterprise Mirrors and Proxies

The capture scripts honour the standard `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` environment variables used by `curl`, Helm, and Docker.
Set `CHART_REPO_CILIUM`, `CHART_REPO_GRAFANA`, `CHART_REPO_OPENTELEMETRY`, `CHART_REPO_PERSES`, `CHART_REPO_PROMETHEUS`, and `CHART_REPO_FLUENT_BIT` to internal Helm repository URLs when public chart repositories are not reachable.
Set `GITHUB_RELEASE_BASE_URL`, `HELM_BINARY_BASE_URL`, and `K3S_RELEASE_BASE_URL` to internal mirrors for GitHub releases, Helm archives, and K3S assets.
Set `PERSES_PLUGIN_BASE_URL` to the internal Perses plugin release mirror.
Set `IMAGE_REGISTRY_PREFIX` to pull locked images from a private registry namespace during capture; the resulting bundle is still imported under the original locked references for offline replay.
Set `HEY_BUILDER_IMAGE` and `BUILDKIT_IMAGE` to internal mirrors of their pinned build images when Docker Hub is not reachable.
For example, an enterprise capture can export `HTTPS_PROXY`, `CHART_REPO_GRAFANA`, `CHART_REPO_FLUENT_BIT`, `PERSES_PLUGIN_BASE_URL`, and `IMAGE_REGISTRY_PREFIX` before running the capture scripts.

## Local KVM Validation VM

Run the host prerequisite script above to install `qemu-system-x86`, `qemu-utils`, `cloud-image-utils`, `curl`, and `openssh-client` on the Ubuntu host.
Run `scripts/01-local-vm.sh start` to verify or download the pinned Ubuntu 24.04 cloud image, create a qcow2 overlay, configure SSH with your existing public key, and boot the VM.
The launcher uses restricted QEMU user-mode networking and forwards only host `127.0.0.1:2222` to guest port 22 without changing host networking or requiring sudo.
The VM image, disk overlay, cloud-init data, and logs are stored under `$HOME/vm-images/observability-workshop`, outside this repository.

Connect with `scripts/01-local-vm.sh ssh`.
For a manual SSH connection, run `ssh -p 2222 -i ~/.ssh/id_ed25519 ubuntu@127.0.0.1`.
Copy the bootstrap files, manifests, and captured assets into the guest with `scp -P 2222 -r scripts charts values manifests bundle versions.lock ubuntu@127.0.0.1:/home/ubuntu/demo/`.
Use `scripts/01-local-vm.sh status` to inspect the QEMU process, `stop` to stop the guest, and `destroy` to remove the guest disk and cloud-init state while retaining the verified base image.

## K3S Cluster Bootstrap

On the connected build node, run `scripts/05-capture-cluster-assets.sh` to capture the pinned K3S artifacts, vendored cluster and observability charts, CLI tools, and container images.
Run `scripts/31-capture-plugins.sh` before disconnecting the build node so the Perses plugin archives are included in `bundle/`.
Copy `scripts/`, `charts/`, `values/`, `manifests/`, `bundle/`, and `versions.lock` into the running guest before disconnecting it from the network.
Inside the guest, run `sudo scripts/00-prereqs.sh`, `sudo scripts/10-k3s.sh`, and `sudo scripts/30-stack.sh` in that order.
K3S starts with Flannel, Kubernetes network policy, kube-proxy, Traefik, and ServiceLB disabled; Cilium supplies the CNI and service proxy.
Tetragon is installed as a separate pinned chart because the official Cilium chart does not deploy the Tetragon agent.

Run `sudo scripts/90-teardown-cluster.sh` inside the guest to remove the demo namespace and local registry, then uninstall the observability, Tetragon, and Cilium Helm releases.
The teardown leaves K3S installed and does not remove the VM, captured artifacts, or host configuration.

## Direct Ubuntu 24.04 Node Deployment

Use this path when an Ubuntu 24.04 node is the K3S host itself; do not run `scripts/01-local-vm.sh` on that node.
The simplest supported workflow is to use the target node as the connected build node for initial preparation and capture, then disconnect it before cluster installation.
While connected, run `sudo scripts/00-host-prereqs.sh`, log out and back in for the new group memberships, and run `scripts/05-capture-cluster-assets.sh` from the repository root.
The host prerequisite script uses APT and downloads pinned Helm and kubectl binaries, so it must run while the target node can reach its approved package/download sources.
If a different machine performs capture, transfer the repository and `bundle/` to the target node using removable media or an approved file-transfer path, and ensure its host prerequisites are already installed before disconnecting it.
The current bundle contains K3S, charts, container images, and cluster CLIs, but not Ubuntu `.deb` packages for host setup.
After capture and host preparation, disconnect the target node from external networks before deploying the cluster.
If the node has multiple IPv4 interfaces, set `K3S_NODE_IP` to the address that should serve the cluster before running `sudo scripts/10-k3s.sh`.
The installer automatically selects the first non-Cilium global IPv4 address when `K3S_NODE_IP` is unset.

From the repository root on the target node, run `sudo scripts/00-prereqs.sh`, `sudo scripts/10-k3s.sh`, and `sudo scripts/30-stack.sh` in that order.
This installs K3S directly on the target node and imports the captured cluster images and vendored charts without contacting an external registry.
No network connection is required for K3S to start after the locked binary and airgap image bundle have been staged; outbound access is only needed during connected capture and host prerequisite installation.
Use `sudo scripts/90-teardown-cluster.sh` to remove the demo namespace and local registry, then remove the observability, Cilium, and Tetragon Helm releases while leaving K3S installed.

The cluster bundle does not contain Ubuntu APT packages or the host Helm/kubectl downloads.
A target node that is offline from first boot must be preprovisioned with those locked host prerequisites by its administrator before following this deployment procedure.
