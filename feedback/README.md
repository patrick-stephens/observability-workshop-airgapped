# Learner VM Feedback Protocol

The `feedback/` directory stores verbatim learner-VM report transcriptions and operator observations so later work can use actual VM evidence.

Name each record `airgap-run-00N.md`, incrementing per VM run; do not overwrite an existing run record.

Transcribe verbatim; paste the full REPORT BEGIN/END block; observations go outside the block; do not summarise or replace evidence with prose.
The agent reads these files newest-first before changing any learner-VM script or `00-diagnose`.

Every record includes these metadata fields: date, operator, VM / RHEL version, repository revision, approved repository transfer method, `lab-vm.conf` deviations from defaults, `SCRIPT_VERSION` values run, purpose of run, and VM-side commands run.
Start from [airgap-run-template.md](airgap-run-template.md).
The run-001 record is [airgap-run-001.md](airgap-run-001.md).

## Interpreting the First Diagnostic

- A COMPOSE-related line should be absent entirely; if one appears, treat it as a bug and escalate it.
- A missing staged k3s binary is not itself a failure when `K3S_BINARY_URL` is configured and the bounded Artifactory HEAD probe succeeds.
- A missing staged binary with an unset URL, a staged checksum mismatch, or a failed Artifactory response is a REAL FAIL to escalate.
- Real failures to escalate include `$DOCKER_REGISTRY` catalogue/registry unreachability, the CA missing from the OS trust store, DNF repository failures, ISO mount failures, and missing repository/docs/extracted content.
- Arrow and SKIPPED lines are informational, not failures.
- Paste the complete report even when it contains expected failures; the FAILED result is the point of the initial diagnostic run.
