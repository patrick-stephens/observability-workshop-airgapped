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
- `manifests/`: Kubernetes objects applied directly; `manifests/app/` holds the demo app Deployments, Services, ServiceMonitor, and L7 visibility policy.
- `dashboards/`: Perses project, datasources, and dashboards for the host-side Perses.
- `scripts/`: numbered, idempotent VM, bootstrap, and demo scripts.
- `learner-vm/`: RHEL learner VM configuration, operator run order, and read-only diagnostics; see [learner-vm/README-FIRST.md](learner-vm/README-FIRST.md).
- `images/`: source Dockerfiles for locally built offline workload images.
- `app/`: demo application source.
- `bundle/`: output from offline capture; generated contents are gitignored.
- `docs/`: speaker notes, runbooks, and the appliance syslog design note.

## License

Original material authored for this repository is licensed under Apache-2.0; see [LICENSE](LICENSE).
Third-party workshop content, images, charts, container images, and packages retain their upstream terms; see [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).

## Local Checks

The pre-commit configuration uses the pinned upstream hook repositories listed in `versions.lock`.
On the connected build node, provision pre-commit 4.2.0, then run `bash scripts/00-install-hooks.sh` to validate the config and fetch the pinned hook environments.
The script installs Git hooks unless a custom `core.hooksPath` is already configured; it leaves an existing hooks path unchanged.
Subsequent checks use the installed environments without outbound access.
For offline use on another node, transfer the pre-commit cache from `$HOME/.cache/pre-commit` along with the captured tools.

Before completing a change, run `pre-commit run --all-files` and confirm it passes.
This runs all applicable file hooks; the Conventional Commits hook is run for commit messages when a commit is created.
The generic JSON key sorter excludes the npm-generated `slides/package-lock.json` to preserve npm's lockfile serialization; JSON syntax and other file checks still run.
Byte-rewriting hooks, source-mode/name checks, YAML style checks, and the generic large-file threshold exclude `content/` so upstream snapshots and generated outputs remain intact; gitleaks, JSON checks, and other applicable validation still run.
The learner VM receives a repository ZIP and a separately checksummed k3s payload archive, so Git and Git LFS are not required on that VM.

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
Run `sudo scripts/90-teardown-cluster.sh` in the guest to remove the directly applied Fluent Bit syslog Service, then uninstall the observability, Tetragon, and Cilium Helm releases while leaving K3S installed.
Run `scripts/01-local-vm.sh stop` on the host to stop the guest without deleting its disk.
Run `scripts/01-local-vm.sh destroy` to remove the guest overlay and generated SSH/cloud-init state while retaining the verified base image.

## Current State

The repository contains the three-service Go demo application, local hook setup, Ubuntu host provisioning, and a disposable KVM VM launcher.
The guest-side prerequisite, K3S, Cilium/Tetragon, and cluster verification scripts are present.
The Cilium, Tetragon, and observability charts are vendored, and the build-node capture script creates the offline image bundle.
The observability stack uses the dedicated `fluent-bit-collector` chart as a DaemonSet for node log collection and direct Loki forwarding.
That single DaemonSet receives container logs from `/var/log/containers/*.log` and RFC5424 appliance syslog over TCP 5140, using one ConfigMap and the same Loki backend.
The `sensor-sim` Deployment uses the existing `image.demo-app` image, so this adds no image, chart, or version to the air-gapped bundle.
`manifests/fluent-bit-syslog.yaml` exposes the in-cluster listener as a ClusterIP; a real external appliance would require a deliberate NodePort or LoadBalancer network-policy decision.
The separate `fluent-bit-aggregator` chart is not deployed because this topology has no Fluent Bit forward-input tier; it remains an option for a future multi-tier logging design.
Pyroscope's v2 metastore can wedge with `non-monotonic log entries` after a disk write stall, which only a restart clears (grafana/pyroscope#5432).
`scripts/21-observability.sh` therefore patches a `/ready` liveness probe onto the Pyroscope StatefulSet, so kubelet restarts a wedged pod after about two minutes.
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
The alerting demo requires the application and load generator from the demo deployment to be running in namespace `demo`; `sudo scripts/reset.sh` deploys them.
The alert definition and ordered presenter steps are in `docs/alerting-runbook.md`.

## Demo Rehearsal

After `manifests/app/` contains the frontend, API, backend, sensor simulator, and ServiceMonitor resources, run `sudo scripts/reset.sh` followed by `sudo scripts/preflight.sh` from the repository root on the K3S node.
`scripts/05-capture-cluster-assets.sh` builds the frontend, api, backend, and sensor-sim binaries reproducibly into one image from `images/app/Dockerfile`, pinned as `image.demo-app` in `versions.lock`.
After changing anything under `app/`, rebuild with that script and update the `image.demo-app` digest it reports.
The frontend serves an operator status page at `/index.html`, which polls the `/status` JSON endpoint every 2 seconds.
`manifests/app/l7-visibility.yaml` is required for Hubble HTTP and DNS metrics because Cilium 1.16 and later ignore the proxy-visibility annotation.
The three metrics paths are explained in `docs/metrics-path.md`.
The Fluent Bit multi-source design, transport caveats, and cardinality rule are in `docs/syslog-notes.md`.
`reset.sh` completes the demo namespace reset in under 60 seconds and refuses to delete namespace `demo` if the app, sensor-sim, loadgen, alert, or sink manifests are missing.
`preflight.sh` checks the local registry, Cilium, Prometheus, Loki, Tempo, Perses, and demo pod readiness before establishing a clean baseline.
Use `sudo scripts/break.sh latency`, `errors`, `dns`, `torpedo`, or `ok` to perform a named beat and its matching reset.
`torpedo` is a signal generator rather than a failure: requests keep returning 200 while `TorpedoDetected` fires.
Alertmanager sends each notification to both the echo sink and the frontend's `POST /webhook/alertmanager`, which feeds the alert banner and event feed on `/index.html`; see `docs/alerting-events.md`.
The DNS beat applies `manifests/chaos-dns-block.yaml` and should be demonstrated with `hubble observe --namespace demo --verdict DROPPED --last 20`, which reaches Hubble Relay through the `localhost:4245` forward described below.
The app's HTTP client disables keep-alive, so every upstream call resolves DNS and the DNS beat produces real request failures.
The load generator image is built reproducibly from `images/hey/Dockerfile` by `scripts/05-capture-cluster-assets.sh`, pinned in `versions.lock`, and included in the offline image archive.
The official `rakyll/hey` container image is unavailable, so the connected build node builds the pinned v0.1.4 binary into a minimal scratch image.
Run `sudo scripts/syslog-send-test.sh` to send one RFC5424 marker through the `fluent-bit-syslog` Service and confirm it is queryable in Loki.
`scripts/preflight.sh` runs the same check after restoring the baseline.
The run-of-show, cut order, and presenter narration are in `docs/demo-runbook.md`.

## Host-Side Perses

The presenter's Perses runs on the K3S host as a Docker container, outside the cluster.
Run `sudo scripts/41-perses-portforwards.sh` to start these localhost-only forwards, with PIDs in `/tmp/perses-pf/`:

| Local address | Target |
| --- | --- |
| `localhost:9090` | Prometheus |
| `localhost:3100` | Loki gateway |
| `localhost:3200` | Tempo |
| `localhost:9093` | Alertmanager UI |
| `localhost:4245` | Hubble Relay, the `hubble` CLI's default server |
| `localhost:12000` | Hubble UI |
| `localhost:8082` | Frontend operator UI, `/index.html` |

Run it after `scripts/reset.sh`, because recreating the frontend pod ends the frontend forward.
From the presenter host, open a second terminal and keep this SSH tunnel running so the browser can reach the guest's forwarded services:

```bash
ssh -N -p 2222 -i ~/.ssh/id_ed25519 \
	-L 9090:127.0.0.1:9090 -L 3100:127.0.0.1:3100 -L 3200:127.0.0.1:3200 \
	-L 9093:127.0.0.1:9093 -L 4245:127.0.0.1:4245 \
	-L 12000:127.0.0.1:12000 -L 8082:127.0.0.1:8082 \
	-R 8080:127.0.0.1:8080 ubuntu@127.0.0.1
```

Press `Ctrl-C` in that terminal to close the tunnel after the workshop.
Run `scripts/40-perses.sh` to start Perses on `http://localhost:8080`, bound to localhost only, and apply everything in `dashboards/`.
Perses Explore is enabled and uses the pinned image's built-in Prometheus, Loki, and Tempo plugins, so traces and log lines can be browsed without a dashboard.
Both scripts replace any previous instance, so they are safe to rerun.
`scripts/preflight.sh` checks that Perses, every port-forward, Hubble Relay, the frontend UI, the load generator, and the OTLP business metrics are present.
Run `sudo scripts/42-perses-stop.sh` to stop the port-forwards and remove the Perses container.

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

## Learner Workshop Content Capture

On the connected online machine, run `scripts/dev/import-content.sh` to clone or reuse the five public workshop repositories and mirror their documentation.
The script records source SHAs and mirror dates in `versions.lock`; use `--refresh` to replace the captured sources and documentation.
Run `python3 scripts/dev/parse-labs.py` to extract every Docker and Podman command path, cwd, base image, and runtime download into `content/extracted/`.
Run `python3 scripts/dev/patch-docs.py` to patch both mirrored documentation and repository lab pages, `python3 scripts/dev/curate.py` to generate the curated service run set, and `python3 scripts/dev/check-docs.py` to verify local page and asset references.
`check-docs.py` retries missing `otel-developers` mirror assets once and records any remaining gaps in `content/extracted/docs-gaps.txt`.
Run `python3 scripts/dev/create-reviewer-packet.py` after regenerating parser and curation outputs to assemble the bounded k3s, build-status, runtime-download, and curation evidence in `content/extracted/reviewer-packet.md`.
Run `bash scripts/dev/vendor-k3s.sh` online to fetch and verify the small pinned installer, system-image list, and RHEL 8 SELinux RPM; the large executable and optional image archive are not stored in the repository.
Run `bash scripts/dev/package-vm-transfer.sh --dry-run` to review the guarded transfer and cleanup actions, then run it without `--dry-run` to fetch and verify the required executable, build the ZIP and payload archive, and stage obsolete-file removals.
Use `--manual-bundle DIR` to create a separate k3s staging archive and `--manual-instructions` to write payload-only hand-fetch steps from the generated catalog.
See [content/vendor/MANUAL-FETCH.md](content/vendor/MANUAL-FETCH.md) for the staging-before-network recovery contract and exact artifact pins.
Use `--include-k3s-airgap-tarball` only when the optional bootstrap fallback is needed; see [content/vendor/README.md](content/vendor/README.md) and [learner-vm/README-FIRST.md](learner-vm/README-FIRST.md) for transfer and verification instructions.
Run `python3 scripts/dev/vendor-runtime-downloads.py` online to vendor lab-linked ZIPs needed for preloading attendee-created build contexts and record their hashes in `versions.lock`.
Run `python3 scripts/dev/write-vendored-files.py` after capture to refresh the source and SHA-256 inventory for vendored and generated content.
Run `python3 scripts/dev/generate-manual-fetch.py` whenever repository files, payload pins, curated manifests, or image inventories change; it regenerates `content/vendor/MANUAL-FETCH.md` and `manual-fetch.json`.
Run `scripts/dev/make-image-bundles.sh --list` to print the fallback image set, or use `--both` on the connected Docker build host to create Docker-archive bundles using the pinned Skopeo container; the resulting archives load into the separate Podman and k3s containerd stores.
The k3s image probe is recorded at `content/vendor/k3s/registry-probe.txt`; the pinned k3s service uses `/etc/rancher/k3s/registries.yaml` for containerd CRI mirror pulls, which can be exercised with `k3s crictl pull`.
The online probe returned HTTP 000 due to name resolution failure, so Artifactory mirror access must be verified on the learner network before provisioning relies on it.
The complete `content/` tree is an online-produced committed artifact for the learner VM; these development scripts are not provisioning scripts and must not be run on the airgapped VM.

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
