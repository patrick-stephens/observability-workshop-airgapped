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
Script 20 v3 reads the RHEL `alternatives --display java` and `alternatives --display javac` candidate paths and explicitly selects Java 17, even when auto mode prefers Java 8 or Java 11.
If Java configuration or verification fails, it prints a failed REPORT block and exits before the remaining provisioning steps; review that report before retrying.
It sets `JAVA_HOME` in `/etc/environment` for sudo/PAM sessions and `/etc/profile.d/java.sh` for login shells, so Java-dependent tools use the selected JDK consistently.
The verification uses `java -version`, which remains compatible with older Java releases if the default is not yet configured.
Both JDKs remain installed; use `alternatives --config java` and `alternatives --config javac` to select Java 11 when a workshop requires it.

## Runtime Recovery

Standalone files use local-first resolution; invalid staged checksums fail without a network fallback, and absent files use their configured Artifactory URL where applicable.
Stage optional per-image archives at `$MANUAL_FETCH_DIR/images/`; script 60 loads them through the rootful Podman Docker wrapper and pulls only missing references, and script 62 imports matching Podman images before CRI pulls.
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
