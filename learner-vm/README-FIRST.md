# Learner VM: First Run

This guide describes the RHEL 8.6 learner-VM repository workflow.
The Git repository carries the source; optional per-image archives may also be supplied locally for recovery, never committed to Git.
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
7. After report review, run scripts 10 through 80 in numeric order and transcribe each complete REPORT block.
8. When both parts of `80-verify-offline.sh` pass, shut down cleanly and snapshot the VM.

Set the required binary URL on the learner VM; the committed value remains empty.
The optional airgap-images URL also remains empty unless the Artifactory administrator supplies its exact generic-file endpoint.

```bash
K3S_BINARY_URL=""
K3S_AIRGAP_IMAGES_URL=""
```

Do not invent an endpoint or use a public release URL.
The binary SHA-256 authority is the `learner-k3s-binary-amd64` record in `versions.lock`.
`10-preflight.sh` fails with an administrator-directed fix hint if script 45 would need a download while the URL is unset.

## Java Toolchain

Script 20 installs both Java 11 and Java 17, then selects Java 17 for the system `java` and `javac` alternatives.
Script 20 v4 reads the RHEL `alternatives --display java` and `alternatives --display javac` candidate paths and explicitly selects Java 17, even when auto mode prefers Java 8 or Java 11.
If Java configuration or verification fails, it prints a failed REPORT block and exits before the remaining provisioning steps; review that report before retrying.
It sets `JAVA_HOME` in `/etc/environment` and `/etc/profile.d/java.sh` for future sessions, exports it with the JDK `bin` directory in `PATH` for the running script and child tools, and verifies both executables under `JAVA_HOME` report version 17.
Existing learner sessions need to log in again or source `/etc/profile.d/java.sh`; sudo and systemd tool environments must be verified separately rather than assuming they inherit those settings.
The verification uses `java -version`, which remains compatible with older Java releases if the default is not yet configured.
Both JDKs remain installed; use `alternatives --config java` and `alternatives --config javac` to select Java 11 when a workshop requires it.
Script 20 checks Firefox installation with `rpm -q firefox`, without launching the browser as root or initialising a root profile.
Script 70 remains responsible for the workshop bookmark and learner desktop shortcut; browser profile use belongs to `WORKSHOP_USER`, and SELinux remains enforcing.

## Runtime Recovery

The aggregate prebuilt-image, package-cache and generic-download workflow is specified in [DEPENDENCY-BUNDLE.md](DEPENDENCY-BUNDLE.md), including configurable pip/Maven/npm/Go Artifactory endpoints and offline profiles.
Upstream adaptations, Java 17 validation, cache-age policy and rebuild limitations are tracked in [UPSTREAM-DELTA.md](UPSTREAM-DELTA.md).
Diagnostic v17 checks representative package paths through the dedicated PyPI, Maven, npm and Go HTTPS endpoints; set `CHECK_PACKAGE_REPOSITORIES=no` only for an explicitly offline run, without treating that skip as verified cache completeness.
The dependency bundle is a separately transferred release asset, not a Git asset; configure its trusted checksum before enabling aggregate import.
When enabled, script 60 verifies the bundle, loads its lab images, seeds learner-owned Maven/npm/Go caches and installs a managed `/etc/profile.d/o11y-offline-profile.sh` selector for future login shells.
Build sessions that do not load `/etc/profile.d` must explicitly source the versioned bundle `profile.sh` to apply cache-only package settings.
The connected capture also builds the documented Fluent Bit version tags, OTel collector and OpenSearch integration images from checksum-pinned helper configs; see [UPSTREAM-DELTA.md](UPSTREAM-DELTA.md) for coverage and remaining offline acceptance limits.
The r6 bundle has been imported and tested in a disposable AlmaLinux 8.10 QEMU VM: after a temporary tooling bootstrap, the VM was restarted with QEMU egress restricted, then bundle verification, Podman image checks, cache-backed builds and the Java metrics smoke test passed.
This is EL8 cached-workload evidence, not certification of exact RHEL 8.6 provisioning, SELinux/firewalld policy or the separate k3s/containerd image store.
No RHEL 8.6 ISO or cloud disk was present on the connected host; use approved RHEL media for that target-specific test rather than treating AlmaLinux as RHEL.
To exercise rootful Podman on an EL8 guest, use `bash scripts/dev/test-learner-bundle-almalinux-vm.sh prepare`, `bootstrap`, and `wait-bootstrap` while preparing the guest tooling; then run `stop`, `offline-start`, `stage`, `import`, and `test` in that order.
The bootstrap phase temporarily permits QEMU user-network egress for AlmaLinux package setup; the actual bundle import and lab tests run after restarting with `restrict=on`, retaining only host-forwarded SSH.
The guest test covers image IDs, all Python rebuild variants, Maven POM/tests, npm and Go cache replay, and a Java metrics smoke test; it does not install k3s or certify the RHEL 8.6 installer workflow.

Script 45 v9 installs or repairs `/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/10-learner-cgroup-v1.conf` with `failCgroupV1: false`, owned by root with mode `0600`, before starting k3s.
This RHEL 8.6 learner-only exception permits deprecated cgroup v1 operation after [Kubernetes 1.35 changed the default](https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.35.md#deprecation); it does not restore upstream support or apply to the Ubuntu presenter demo.
The [k3s kubelet drop-in mechanism](https://docs.k3s.io/installation/configuration#kubelet-configuration-files) is available in k3s v1.32 and newer.
Reruns repair missing or incorrect managed drop-in contents and permissions, then restart an installed service if configuration changed or it is inactive, failed or activating, without rerunning the installer or deleting cluster data.
Healthy services with unchanged managed configuration are left running; unrecognised unit states and failed repairs produce a report and stop before readiness checks.
Dry-run previews these changes without writing files or managing services; no host reboot or version-pin change is needed, and actual readiness still requires operator-transcribed evidence.
Other kubelet overrides, custom config directories and service arguments are preserved, so conflicting operator settings require review rather than being silently overwritten.
After startup, script 45 retries API access, node discovery and Ready checks within one 180-second deadline instead of failing immediately when the API is unavailable or no nodes have registered.
Each request and readiness attempt is bounded by the remaining deadline; a timeout report retains the last command error, node conditions and recent service logs.

Script 40 v3 checks the pinned BusyBox manifest through the configured mirror using `skopeo inspect --no-tags`, including its failure diagnostics.
Disabling tag enumeration avoids Docker Hub tag-list requests after mirror manifest access; the operator reported this option succeeds with Skopeo 1.9.1.
This probe checks manifest access, not a complete image pull; no reboot or containerised Skopeo is required for this change.

Standalone files use local-first resolution; invalid staged checksums fail without a network fallback, and absent files use their configured Artifactory URL where applicable.
Stage optional per-image archives at `$MANUAL_FETCH_DIR/images/`; script 60 loads them through the rootful Podman Docker wrapper and pulls only missing references, and script 62 imports matching Podman images before CRI pulls.
Script 60 v7 includes every recorded external build base from `commands.json` in the preload checks, including bases for interactive labs, before starting any recorded builds.
Stage Python and Java base archives as `$MANUAL_FETCH_DIR/images/library-python-3.13-bullseye.tar` and `$MANUAL_FETCH_DIR/images/library-eclipse-temurin-17.tar`, preserving the `python:3.13-bullseye` and effective `eclipse-temurin:17` image references in Docker-save or OCI archives.
Base archives use the same catalogue, checksum and embedded image validation as runtime images; missing archives use mirror recovery, corrupt archives fail before pulls, and builds with unresolved external bases are recorded as `BASE-IMAGES-MISSING` and skipped.
See [MANUAL-FETCH.md](../content/vendor/MANUAL-FETCH.md) Section C for connected-machine Docker save commands, staging, and the optional online publisher; prefer the derived `docker-registry.${ART_REPO_DOMAIN}` endpoint or the supported path form, retaining SELinux enforcing while script 20 performs the planned firewalld change.

## Report Protocol

Run the initial diagnostic from the repository's `learner-vm/` directory:

```bash
cd /path/to/repository/learner-vm
sudo bash scripts/00-diagnose.sh
```

Copy every complete REPORT block verbatim into the corresponding feedback record.
The default diagnostic verifies availability using real `podman pull` commands against explicit Artifactory image references, reports duration, and notes when it warms the rootful Podman store.
Diagnostic v16 strips the original registry host and prefixes the image path with `DOCKER_REGISTRY`, so initial pulls do not depend on script 40 having installed system mirror rules.
This verifies direct Artifactory access, not original-reference mirror routing; script 40 configures and checks that routing after tooling and CA trust are installed.
After a failed pull, diagnostics running as root validate and load the matching catalogued archive from `$MANUAL_FETCH_DIR/images/` through Podman, then check that it supplies the original image reference.
Successful archive recovery is reported separately from registry availability; it warms the rootful store and does not prove that Artifactory access works.
Missing archives leave the pull failure unresolved, while corrupt archives or load/reference failures remain failures; Python 3 and `sha256sum` are required for archive validation.
For the previous probe-only mode, run `sudo bash scripts/00-diagnose.sh --no-pull-verification`; this does not pull or change the container store.
Both modes exit 0; the REPORT block, not the exit code, classifies diagnostic failures.
Follow each `NEXT` line and stop after any failure until the report has been reviewed.
The connected-machine registry probe returned HTTP 000 because its resolver could not resolve the configured host; this is not learner-network evidence.
The learner VM has not been validated until its own diagnostic and provisioning reports are reviewed.
