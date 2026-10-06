# Airgap run <NNN> — <script name>

## Metadata
<!-- Date the VM run was performed. -->
- Date:
<!-- Name of the operator who ran the commands. -->
- Operator:
<!-- Use a generic VM label, not a hostname or internal asset identifier; include the RHEL release. -->
- VM / RHEL version:
<!-- Commit SHA; run git rev-parse HEAD in the cloned repository. -->
- Repository commit SHA:
<!-- Approved method by which the repository reached the airgapped network. -->
- Transfer method (how the repo reached the airgapped network):
<!-- List lab-vm.conf values changed from repository defaults; do not include secrets. -->
- lab-vm.conf deviations from defaults:
<!-- Record yes or no only; never paste the K3S_BINARY_URL value. -->
- K3S_BINARY_URL set:
<!-- Record every script name and SCRIPT_VERSION shown in its report. -->
- Script versions run:
<!-- State the purpose of this VM run. -->
- Purpose of this run:
<!-- Paste exact VM-side commands, including sudo and working directory. -->
- VM-side commands run:

The default `00-diagnose.sh` performs real Podman pulls to distinguish true image failures from manifest-probe false positives and may warm the rootful Podman store.
`--no-pull-verification` restores probe-only mode without pulling or warming images.
An individual manifest-probe 404 alone is informational; the actual pull result determines image availability.

## Report block
<!-- Preserve the report and diagnostic meaning, but redact the HOST value, internal network identifiers, secrets, and host-specific paths before committing. -->
```text
<EMPTY: operator pastes the complete REPORT BEGIN/END block here, verbatim, as a single block>
```

## Operator observations
<!-- Record observations outside the report block; redact internal network identifiers and secrets, or state none. -->
<operator fills in>

## Follow-up required
<!-- Record whether 10-preflight will be run next and list any blocker. -->
<operator fills in>
