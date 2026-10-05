# Repository Rules

1. Every container image is pinned by tag AND digest. No :latest anywhere, ever. New dependencies must be added to versions.lock with the reason, and versions.lock is never edited without an explicit instruction.
2. Every shell script uses `set -euo pipefail`, is safe to re-run, and logs with a consistent prefix. Never `curl | sh`.
3. Nothing is applied by hand. If a step exists, it exists as a script or a committed manifest. If you do something manually to debug, commit it as a script afterwards.
4. Every `kubectl apply` or `helm install` has a matching, documented teardown in the README.
5. The repo must build and deploy with no outbound network access, other than the initial capture step on the build node. Any network access at runtime is a bug.
6. Prefer explicit over clever. Long, obvious scripts beat short, clever ones. This repo will be read under pressure.
7. Do not add features, dependencies, or abstractions that are not requested. When in doubt, do less and ask.
8. Always run the appropriate linting locally across all files, and resolve any issues found.
9. Before completing a task, run `pre-commit run --all-files` and confirm it passes. If the checks cannot be run, state why and do not claim they passed.
10. In Markdown files, keep each sentence on a single line, with each new sentence starting on a new line.
11. Keep `scripts/00-host-prereqs.sh`, `versions.lock`, and the README in sync whenever adding or changing a host prerequisite, development tool, or VM runtime dependency.

## Learner VM

12. Learner-vm scripts are artifacts. Never execute them on the target VM; there is no AI on the airgapped network, and execution evidence arrives only via `feedback/airgap-run-*.md`. Never claim a script “works”; say it “validates and self-diagnoses”.
13. Before any learner-vm change, read `feedback/airgap-run-*.md` newest first and inspect the `SCRIPT_VERSION` comments in the scripts.
14. On every edit to a learner-vm script, bump its `SCRIPT_VERSION` and add a one-line comment describing the change.
15. Every learner-vm script must source `scripts/lib.sh`, be idempotent, support `--dry-run`, and emit the `REPORT BEGIN`/`END` block per the transcription protocol.

## Workshop Content Artifacts

16. Learner-vm provisioning scripts are artifacts. There is no AI on the airgapped network, so the agent never executes them against the VM; the human operator does. Execution evidence arrives only via hand transcriptions in `feedback/airgap-run-*.md`. Never claim a provisioning script “works on the VM”; say it “validates and self-diagnoses”.
17. `scripts/dev/*` are the exception: they run on this online machine, and their outputs are committed artifacts consumed by the airgap VM.
18. Every learner-vm provisioning script sets `SCRIPT_NAME` and `SCRIPT_VERSION` before sourcing `scripts/lib.sh`, is idempotent, and ends with a `REPORT BEGIN`/`END` block of no more than 60 lines, with no ANSI colour. Report failures as `F<n>` with a fix hint and automatically run diagnostics; report successful steps as a count, skipped steps with reasons, and a `NEXT` line naming the next action.
19. `step_fail` always runs its attached diagnostic commands and includes capped output of no more than 15 lines per command in the report.
20. On every edit to a learner-vm script, bump `SCRIPT_VERSION` and add a one-line comment above it describing the change.
21. Before touching learner-vm code, read `feedback/airgap-run-*.md` newest first and inspect the current `SCRIPT_VERSION` comments.

## Learner VM K3s Decision

The learner VM will include k3s.
Kubernetes-dependent lab steps are runnable once k3s is provisioned by the planned script 45.
The fully preloaded guarantee extends to k3s workloads: script 62 loads manifest images into the k3s containerd store, and script 80 verifies k3s pods while the registry is blocked.
