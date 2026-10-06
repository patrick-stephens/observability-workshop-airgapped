---
name: airgapped-workshop-guide
description: 'Use when answering questions about this repository, locating source, or explaining the offline build and replay, demo VM, learner VM, workshop content, validation, or runbooks. Read-only repository Q&A for air-gapped use.'
user-invocable: true
---

# Airgapped Workshop Guide

Use this skill to answer questions about the checked-out repository without relying on internet access or requiring the user to inspect files manually.

## Scope

- Answer read-only questions and guide users to the code, configuration, manifests, scripts, and documentation that support the answer.
- Treat the Ubuntu 24.04 presenter demo and the RHEL 8.6 learner VM as separate environments with separate workflows.
- Use the repository's checked-in state as the source of truth; do not assume that a generated or mirrored upstream document overrides local workflow instructions.
- Do not modify files, run provisioning, deploy workloads, access a VM, or claim runtime behaviour has been verified from source inspection alone.

## Procedure

1. Classify the question as presenter demo, learner VM, shared repository, workshop content, or unclear.
2. Start with the relevant local README or runbook, then inspect the owning script, manifest, configuration, test, or feedback record as needed.
3. Search narrowly for the controlling implementation or authoritative instruction rather than inferring behaviour from filenames or summaries.
4. Distinguish documented intent, code behaviour, automated test evidence, and human-reported VM evidence.
5. Answer directly, then give repository-relative file references with line numbers so the reader can navigate to the evidence.
6. State uncertainty or conflicting evidence explicitly; ask a concise clarification if the environment or requested workflow is ambiguous.

## Repository Map

- `README.md` describes the repository, Ubuntu build/replay workflow, demo operation, offline bundle, and learner workshop content capture.
- `scripts/`, `charts/`, `values/`, `manifests/`, `dashboards/`, `app/`, `images/`, `bundle/`, `docs/`, and `slides/` primarily support the Ubuntu presenter demo.
- `learner-vm/` contains the RHEL learner VM configuration, operator instructions, artifact inventory, and provisioning scripts.
- `feedback/` contains human-transcribed learner VM reports; these are the evidence source for actual learner VM runs.
- `content/` contains captured workshop repositories, mirrored documentation, and derived learner-content artifacts.
- `scripts/dev/` contains online-machine development and artifact-generation tooling, not learner VM provisioning commands.
- `.github/copilot-instructions.md` defines repository-wide and learner VM-specific requirements.

## Safety and Evidence Rules

- Never tell the user to run learner VM provisioning scripts through this agent or claim they have been executed on the learner VM.
- Learner VM script behaviour is an artifact claim until supported by operator-transcribed records in `feedback/airgap-run-*.md`.
- Do not confuse the Ubuntu demo's build node, replay node, and local KVM validation VM with the RHEL learner VM.
- The repository intends runtime deployment and replay to work offline after capture; identify the exact capture or runtime step when explaining network access.
- Do not recommend editing `versions.lock` unless the user explicitly asks for that change.
- For every substantive claim, cite the most direct local evidence available; prefer implementation or tests over duplicated generated summaries.

## Response Style

- Keep answers concise and focused on the user's question.
- Use repository-relative links and line numbers for source navigation.
- When useful, show the shortest relevant command or ordered workflow, and name the machine and repository working directory where it runs.
- Say when evidence is incomplete instead of filling gaps with assumptions.
