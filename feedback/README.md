# Learner VM Feedback Protocol

The `feedback/` directory stores verbatim learner-VM report transcriptions and operator observations so later work can use actual VM evidence.

Name each record `airgap-run-00N.md`, incrementing per VM run; do not overwrite an existing run record.

Transcribe verbatim; paste the full REPORT BEGIN/END block; observations go outside the block; do not summarise or replace evidence with prose.
The agent reads these files newest-first before changing any learner-VM script or `00-diagnose`.

Every record includes these metadata fields: date, operator, VM / RHEL version, package ZIP SHA-256, package ZIP size, transfer method, `lab-vm.conf` deviations from defaults, `SCRIPT_VERSION` values run, purpose of run, and VM-side commands run.
Start from [airgap-run-template.md](airgap-run-template.md).
The run-001 record is [airgap-run-001.md](airgap-run-001.md).

## Interpreting the First Diagnostic

- A COMPOSE-related line should be absent entirely; if one appears, treat it as a bug and escalate it.
- EXPECTED / OPTIONAL: A message about a missing fallback payload under `$MANUAL_FETCH_DIR` is not itself a failure because normal payloads are embedded under `learner-vm/content/vendor/payload/`; check whether the ZIP payload was found first.
- A required binary absent from both the ZIP and manual fallback, or a payload hash mismatch, is a REAL FAIL to escalate.
- Real failures to escalate include `$DOCKER_REGISTRY` catalogue/registry unreachability, the CA missing from the OS trust store, DNF repository failures, ISO mount failures, missing in-repo repositories/docs/extracted content, and payload hash mismatches.
- Arrow and SKIPPED lines are informational, not failures.
- Paste the complete report even when it contains expected failures; the FAILED result is the point of the initial diagnostic run.
