# Learner VM: First Run

This directory contains the operator configuration and read-only diagnostics for the RHEL 8.6 offline observability workshop VM.
The root-level scripts manage a separate Ubuntu K3s replay VM.

The learner VM uses rootful Podman only; the `docker` command is the `podman-docker` shim installed by script 20.
All lab images are preloaded into the same rootful image store, so workshop operation requires no runtime pulls.
All upstream registries use the single Artifactory endpoint in `lab-vm.conf`; pulls are anonymous and images remain under their original references.
The base image supplies OS CA trust, DNF repositories, hostname, and network configuration; script 30 installs the Podman registry CA file.

## Transfer and Run Order

On the connected machine, prepare and commit the complete repository and the `content/` artifacts before transferring them to the VM.
Copy the repository, including `learner-vm/`, `content/`, and `versions.lock`, to the RHEL VM.
Edit `learner-vm/lab-vm.conf` only when an operator-tunable value differs from the supplied default; content paths are derived from the repository location and must not be configured here.
Run the scripts as the human operator, with `sudo`, in this order: `00-diagnose.sh`, `10-preflight.sh`, `20-install-tooling.sh`, `30-ca-and-trust.sh`, `40-podman-config.sh`, `50-user-setup.sh`, `60-load-images.sh`, `70-quickstart.sh`, and `80-verify-offline.sh`.
The later numbered provisioning scripts are authored and reviewed as artifacts; they are not run by an AI agent on the VM.
Review each report and follow its `NEXT` line before continuing; after script 80 passes, shut down cleanly and snapshot the VM as the shipped artifact.

## Transcription Protocol

For each run, copy the complete text from `==================== REPORT BEGIN ====================` through `==================== REPORT END ======================` into the online feedback record without editing the report.
Transcribe, do not improvise: follow the `NEXT` line and report evidence rather than making undocumented VM changes.
If a script reports a failure, transcribe the block and stop until the online team reviews it.
Every provisioning script is idempotent; reruns are safe after following the report guidance.

Example report block:

```text
==================== REPORT BEGIN ====================
SCRIPT: 00-diagnose 3
HOST: o11y-lab.internal 2026-10-04T12:00:00Z git: 0123456
RESULT: FAILED (ok=2 failed=1 skipped=1)
F1: registry unavailable | FIX: Check DOCKER_REGISTRY in learner-vm/lab-vm.conf | DIAG[getent hosts artifactory.internal]: 192.0.2.10 artifactory.internal
OK: 2 steps - full log: /var/log/lab-setup/00-diagnose.log
SKIPPED (1): optional binary absent (skopeo inventory)
NEXT: transcribe this report block; provisioning scripts (10-80) are finalised after this report is reviewed
==================== REPORT END ======================
```

## Online Feedback

On the connected side, create `feedback/airgap-run-00N.md` for each operator VM run, incrementing `00N` for each new record.
Record the date, VM/RHEL version, relevant configuration changes, and the exact `SCRIPT_VERSION` values run.
Paste each complete report block and add concise operator observations outside it; do not replace report evidence with a summary.
Before changing learner-VM scripts, read feedback records newest first and inspect the current version comment in each affected script.
