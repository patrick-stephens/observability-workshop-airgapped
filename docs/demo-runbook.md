# Demo Runbook

## Preflight

Complete this before attendees arrive.
Run `sudo scripts/reset.sh` followed by `sudo scripts/preflight.sh` from the repository root.
Keep a terminal on `kubectl -n demo get pods -w` and another on `hubble observe --namespace demo --last 10`.
Open Prometheus, Perses, and the Hubble UI in separate browser tabs.
The DNS beat is never cut.

## Beat Sheet

### 1. Baseline, 00:00-03:00

**Screen:** Perses service overview and the demo frontend status page.
**Action:** Run `scripts/break.sh baseline` and confirm the `hey` load generator is steady.
**Say:** “We start from a known-good request path, then follow each symptom to the layer that can explain it.”

### 2. Four signals, 03:00-07:00

**Screen:** Perses overview.
**Action:** Compare request rate and error rate, then show a representative trace and log stream.
**Say:** “Metrics tell us how much, traces where, logs what happened, and profiles which code consumed the resources.”

### 3. Network visibility, 07:00-11:00

**Screen:** Hubble UI and the terminal running `hubble observe`.
**Action:** Filter to namespace `demo` and identify the frontend-to-api-to-backend flows.
**Say:** “These HTTP observations come from Cilium at the network boundary, not application instrumentation.”

### 4. Errors and alert state, 11:00-17:00

**Screen:** Terminal running `hubble observe`, Prometheus query UI, then Alertmanager.
**Action:** Run `scripts/break.sh errors`; follow the `hubble_http_requests_total` 5xx rate and the `DemoHighErrorRate` Inactive → Pending → Firing transition.
**Say:** “The one-minute `for` period separates a brief alert condition from a sustained condition worth notifying on.”

### 5. Grouping and silence, 17:00-22:00

**Screen:** Alertmanager UI and echo sink log terminal.
**Action:** Keep failures active on two destination workloads, inspect the single grouped notification, then create a silence for `alertname="DemoHighErrorRate"`.
**Say:** “Grouping reduces duplicate pages; silencing suppresses notifications temporarily without hiding the firing alert.”

### 6. Trace the failing request, 22:00-27:00

**Screen:** Tempo trace view, then the application status page.
**Action:** Select a failed request and follow its spans across frontend, api, and backend.
**Say:** “The trace narrows the request path; Hubble independently shows the network response that carried the failure.”

### 7. Latency, 27:00-31:00

**Screen:** Perses latency panels and Tempo.
**Action:** Run `scripts/break.sh latency`, observe the latency distribution, and open one slow trace.
**Say:** “A latency symptom is visible in metrics first, and the trace shows where the time accumulated.”

### 8. DNS policy, 31:00-38:00

**Screen:** Terminal running `hubble observe --namespace demo --verdict DROPPED --last 20`, then Hubble UI.
**Action:** Run `scripts/break.sh dns`; within ten seconds show dropped UDP/TCP DNS flows from `app=api`.
Run `scripts/break.sh ok` and show the same flow succeeding after the CiliumNetworkPolicy is removed.
**Say:** “The policy causes the failure, and Hubble proves both the deny and the recovery.”
**Cut status:** Never cut this beat.

### 9. Recovery and handoff, 38:00-45:00

**Screen:** Perses overview, Alertmanager, and echo sink logs.
**Action:** Run `scripts/break.sh ok`, verify alerts resolve, show the captured webhook JSON, and point to the optional workshop links.
**Say:** “We can explain this incident from application, telemetry, and kernel evidence while keeping every dependency inside the boundary.”

## Cut Order

If the session is running long, cut Beat 7 first.
Next shorten Beat 6 to one trace.
Then shorten Beat 2 to the four-signal overview.
Then omit the inhibition explanation in Beat 5.
Do not cut Beat 8, the DNS policy and Hubble verdict demonstration.

## Reset

Run `scripts/break.sh ok` to clear service chaos modes and remove the DNS policy.
Run `scripts/reset.sh` to recreate the demo namespace, app, alerting objects, echo sink, and load generator from the committed files.
Run `scripts/90-teardown-cluster.sh` only when the workshop stack is being removed; it uninstalls the observability and Cilium/Tetragon releases while leaving K3S installed.
