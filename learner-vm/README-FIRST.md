# Learner VM: First Run

This directory contains configuration and diagnostics for the RHEL 8.6 learner VM used with the offline observability workshop.
The existing repository scripts at the root manage a separate Ubuntu K3s replay VM.

## Transfer and Run Order

Copy the complete repository, including `learner-vm/`, workshop content, and captured offline artefacts, onto the RHEL VM.
Edit `learner-vm/lab-vm.conf` on the VM to match its hostname, Artifactory, ISO, and content locations.
Run `sudo learner-vm/scripts/00-diagnose.sh` first and resolve its reported failures before provisioning.
Run the provisioning scripts in order: `10` through `50`, then `60`, `70`, and `80`.
Review each report block before continuing, then take the requested VM snapshot after script `80` completes.
Do not run these scripts with an AI agent on the target VM; the scripts are transferred artefacts and the airgapped network has no AI.

## Transcription Protocol

For each run, copy the complete text from `===== REPORT BEGIN =====` through `===== REPORT END =====` into the online feedback record without editing the result.
Transcribe, don't improvise: follow the script's `NEXT` line and report evidence rather than making undocumented changes on the VM.

Example report block:

```text
===== REPORT BEGIN =====
SCRIPT: 00-diagnose 1.0.1
HOSTNAME: o11y-lab.internal
UTC: 2026-10-04T12:00:00Z
REPO_GIT_SHA: 0123456
RESULT: PASSED (ok=2 failed=0 skipped=1)
OK: 2 checks; full log: /var/log/lab-setup/00-diagnose.log
SKIPPED (1): optional tool inventory: skopeo is not installed
NEXT: Review the report and continue with the next numbered script.
===== REPORT END =====
```

## Online Feedback

On the connected side, create `feedback/airgap-run-00N.md` for each VM run, incrementing `00N` for each new record.
Record the date, VM/RHEL version, relevant configuration changes, and the exact `SCRIPT_VERSION` values run.
Paste each complete report block and add concise operator observations outside the block; do not replace report evidence with a summary.
Before changing learner-vm scripts, read these feedback records newest first and inspect each affected script's `SCRIPT_VERSION` comment.
