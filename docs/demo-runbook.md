# Demo Runbook

This runbook is generated from the repository state.
Beat numbering matches `slides/components/BeatCounter.vue`.
Run every command from the repository root on the K3S node unless the step says otherwise.
Every `scripts/break.sh` case used below exists in `scripts/break.sh`; the script requires `sudo`.
Anything that could not be verified is listed in `docs/runbook-gaps.md`.

Tabs are referred to by the names in the pre-demo checklist tab order.
Perses dashboards are referred to by their titles: "Demo Overview", "Network", and "One incident, four layers".

## Beat 0 — Baseline · 0:00–0:02

**Screen:** Perses overview dashboard tab, "Demo Overview", panels "Request rate by service" and "Active chaos state".

**Do:**

```bash
sudo scripts/break.sh baseline
```

**Say:**
We start from a known-good state.
The load generator is a `hey` Job sending a steady stream of requests to the frontend, which calls the api, which calls the backend.
"Request rate by service" comes from `app_http_requests_total`, scraped from each service's `/metrics` endpoint.
"Active chaos state" reads `app_chaos_mode`, and every service reports `ok`.

**Point at:** Perses overview dashboard tab, "Demo Overview": "Request rate by service", then "Active chaos state".

**Contingency:** If "Request rate by service" is flat at zero, the load generator is not running; run `sudo scripts/loadgen-restart.sh` and narrate the baseline while the line recovers.

**Cut table entry:** 2 min; not cut.

## Beat 1 — Latency · 0:02–0:05

**Screen:** Perses overview dashboard tab, "Demo Overview", panel "Frontend latency p50 / p95 / p99".

**Do:**

```bash
sudo scripts/break.sh latency
```

**Say:**
I have put the backend into slow mode, so every backend request now waits two seconds before it answers.
Watch "Frontend latency p50 / p95 / p99", which is a histogram quantile over `app_http_request_duration_seconds`.
The frontend never changed, yet its latency follows the backend, because the delay propagates up the call chain.
This is the cheapest signal we have, it is always on, and it shows the degradation before anyone is paged.

**Point at:** Perses overview dashboard tab, "Demo Overview": "Frontend latency p50 / p95 / p99", then "Active chaos state" showing the backend in `slow`.

**Contingency:** If the latency lines do not rise within a minute, check "Active chaos state"; if the backend is not in `slow`, run `sudo scripts/break.sh latency` again.

**Cut table entry:** 3 min; not cut.

## Beat 2 — Errors · 0:05–0:09

**Screen:** Perses overview dashboard tab, "Demo Overview", then the "Network" dashboard.

**Do:**

```bash
sudo scripts/break.sh errors
```

**Say:**
The backend now returns HTTP 500 on every request, and the api and frontend pass that failure upstream.
"Error rate % (Hubble 5xx / total)" is not computed from application metrics; it is `hubble_http_requests_total` as Cilium observed it on the wire, the same ratio the `DemoHighErrorRate` alert rule evaluates.
On the "Network" dashboard, "Cilium Hubble: HTTP 5xx by destination workload" shows which workload is answering with errors, and the application did nothing to report it.
"Countermeasure launches" now moves too: `countermeasure_launches_total` is an OTLP business counter that the backend only increments while it is failing, so the failure has an operational signature as well as a technical one.

**Point at:** Perses overview dashboard tab, "Demo Overview": "Error rate % (Hubble 5xx / total)" and "Countermeasure launches"; then the "Network" dashboard: "Cilium Hubble: HTTP 5xx by destination workload".

**Contingency:** If the error rate stays at zero, check "Active chaos state" for the backend in `error` and run `sudo scripts/break.sh errors` again; if Hubble panels stay empty, narrate from "Countermeasure launches", which comes from the application rather than the network.

**Cut table entry:** 4 min; not cut.

## Beat 3 — Alert lifecycle · 0:09–0:12

**Screen:** Alertmanager tab, then the Frontend UI tab, then the Terminal (echo sink logs) tab.

**Do:**
Leave the backend in error mode from beat 2 until `DemoHighErrorRate` is firing, then run:

```bash
sudo scripts/break.sh ok
```

**Say:**
`DemoHighErrorRate` has a one-minute `for` clause, so the condition had to hold for a full minute before Prometheus moved it from pending to firing.
Alertmanager grouped it and sent one notification to two webhooks.
The echo sink prints the raw JSON payload, exactly what Alertmanager sent.
The frontend receiver translated the same notification into an operator event, "Contact lost — elevated error rate".
Now I return every service to `ok`, and when Alertmanager sends the resolved notification, the event feed shows "CLEAR — Contact lost — elevated error rate".

**Point at:** Alertmanager tab: the `DemoHighErrorRate` alert group; Terminal (echo sink logs) tab: the JSON payload with `"alertname": "DemoHighErrorRate"`; Frontend UI tab: the event feed entry "Contact lost — elevated error rate".

**Contingency:** If the alert is still pending when the beat time runs out, show it as pending in the Alertmanager tab, explain the one-minute `for`, run `sudo scripts/break.sh ok`, and narrate the rest of the lifecycle from the captured payload in `docs/alerting-runbook.md`.

**Cut table entry:** 3 min; not cut.

## Beat 4 — Torpedo · 0:12–0:15

**Screen:** Frontend UI tab (alert banner and event feed), with the Perses overview dashboard tab, "Demo Overview", panel "Torpedo detections" beside it.

**Do:**

```bash
sudo scripts/break.sh torpedo
```

The script prints `backend: torpedo contacts spiking — no request impact`.
In rehearsal the banner turned red about 50 seconds later.
After the banner has been seen, run:

```bash
sudo scripts/break.sh ok
```

In rehearsal the "CLEAR — TORPEDO DETECTED" event arrived about 61 seconds after `ok`, so it lands during beat 5.

**Say:**
Nothing is broken here: requests still return 200, latency is flat, and the service is healthy, yet an alert fires and the operator is told "TORPEDO DETECTED".
That is the argument for observability over monitoring in one move: the system reports what is happening in the business, not only what has failed.

**Point at:** Frontend UI tab: the red banner "TORPEDO DETECTED" and the newest event feed entry with source `TorpedoDetected`; Perses overview dashboard tab, "Demo Overview": "Torpedo detections" rising, while "Error rate % (Hubble 5xx / total)" and "Frontend latency p50 / p95 / p99" stay flat.

**Contingency:**

- The alert fires but the frontend banner does not update: open `/status` in the Frontend UI tab and look for the event with text "TORPEDO DETECTED"; if it is there, the page's poll is stale rather than the pipeline, so reload `/index.html`.
- The alert does not fire: in the Prometheus tab, query `app_chaos_mode` and confirm the backend series with `mode="torpedo"` is 1; then query `torpedoes_detected_total`; if it is missing or not increasing, the OTLP metrics path is broken, and "Torpedo detections" will be flat too.
- The alert fires but resolves immediately: the rate is hovering near the threshold of 5 per second; widening the margin means changing `manifests/alert-rules.yaml`, which is not done live, so accept it and narrate the firing that was seen.

**Cut table entry:** 3 min; never cut.

## Beat 5 — DNS · 0:15–0:20

**Screen:** Hubble UI tab filtered to namespace `demo`, then the terminal running `hubble observe`, then the Perses overview dashboard tab.

**Do:**

```bash
sudo scripts/break.sh dns
hubble observe --namespace demo --verdict DROPPED --last 20
```

`hubble observe` reaches Hubble Relay through the `localhost:4245` forward from `scripts/41-perses-portforwards.sh`.
When the drops have been shown, run:

```bash
sudo scripts/break.sh ok
```

**Say:**
I have applied a CiliumNetworkPolicy, `api-deny-dns`, that denies DNS egress from the api over UDP and TCP port 53.
Hubble shows the api's queries to kube-dns as DROPPED, with the reason "Policy denied by denylist", at the policy boundary.
The api opens a new connection for every call, so every call needs a DNS lookup, and now none of them can resolve the backend.
The api logs "upstream request failed", the frontend answers 502, and "Request rate by service" collapses as requests wait for their timeouts.
The policy that causes the failure and the evidence that proves it are the same system.
When I remove the policy, the same flows are forwarded again, and Hubble shows the recovery as well as the fault.

**Point at:** Hubble UI tab: the dropped flows from the api to kube-dns; terminal: the `Policy denied by denylist DROPPED` lines from `hubble observe`; Perses overview dashboard tab, "Demo Overview": "Request rate by service" falling; "Network" dashboard: "Cilium Hubble: packet drops by reason" showing `POLICY_DENY`.

**Contingency:** If the Hubble UI tab or `hubble observe` reports a connection error, run `sudo scripts/41-perses-portforwards.sh` to restart the forwards; if no DROPPED lines appear within ten seconds, run `sudo scripts/break.sh dns` again, which reapplies `manifests/chaos-dns-block.yaml`, and rerun the `hubble observe` command.

**Cut table entry:** 5 min; never cut.

## Beat 6 — Traces · 0:20–0:24

**Screen:** Perses overview dashboard tab, "One incident, four layers" dashboard, panel "Traces: traces by service".

**Do:**
No command.
Set the dashboard time range to Last 30 minutes so the latency and error beats are in view.

**Say:**
Traces answer where in the request path the time or the error went.
Each point in "Traces: traces by service" is one trace exported by the services over OTLP through the Collector to Tempo, coloured by service.
Next to it, "Metrics: p99 latency" and "Network: Hubble HTTP 5xx rate" show the latency and error beats from the application and from the kernel, over the same time window.

**Point at:** Perses overview dashboard tab, "One incident, four layers": "Traces: traces by service", then "Metrics: p99 latency" and "Network: Hubble HTTP 5xx rate".

To show individual traces, switch to the Tempo tab, which lists recent traces for the three services in the Perses Explore view.

**Contingency:** If "Traces: traces by service" is empty, open the Tempo tab and widen its time range; if that is empty too, advance to the next beat and narrate.

**Cut table entry:** 4 min; can be cut, second in the cut order.

## Beat 7 — Logs · 0:24–0:28

**Screen:** Perses overview dashboard tab, "One incident, four layers" dashboard, panel "Logs: log volume by level".

**Do:**
No command.
Keep the time range at Last 30 minutes.

**Say:**
Logs answer what exactly the failing component said.
"Logs: log volume by level" counts the demo namespace's application log lines in Loki, shipped by Fluent Bit, grouped by the `level` field of each JSON log line.
The healthy app is quiet, so the ERROR lines line up with the errors beat, where the backend logged "chaos mode returned HTTP 500" for every failed request.

**Point at:** Perses overview dashboard tab, "One incident, four layers": "Logs: log volume by level", alongside "Network: Hubble HTTP 5xx rate".

To show the raw lines, switch to the Loki tab, which runs `{kubernetes_namespace_name="demo"}` in the Perses Explore view.

**Contingency:** If "Logs: log volume by level" shows only the zero line, run `sudo kubectl logs deploy/backend -n demo --tail 20` in the terminal and narrate from the raw lines.

**Cut table entry:** 4 min; can be cut, first in the cut order.

## Beat 8 — Perses · 0:28–0:32

**Screen:** Perses overview dashboard tab, "Demo Overview", business telemetry row, then the "Network" and "One incident, four layers" dashboards.

**Do:**
No command.

**Say:**
These dashboards run in Perses on this host, outside the cluster, and they are YAML files under `dashboards/`, applied by `scripts/40-perses.sh`.
Each one uses named datasources for Prometheus, Loki, and Tempo, reached through local port-forwards, so nothing leaves the boundary.
The business telemetry row is the OTLP path: "Torpedo detections", "Sonar contacts", "Detection mix", and "Countermeasure launches" were emitted with dotted OTel names such as `torpedoes.detected` and stored by Prometheus 3 as `torpedoes_detected_total`; this metric never touched the scrape path.
"Detection mix" divides `submarine_contacts_detected_total` by `surface_ship_contacts_detected_total` and sits at roughly 0.6 under steady load.

**Point at:** Perses overview dashboard tab, "Demo Overview": "Torpedo detections", "Sonar contacts", "Detection mix", "Countermeasure launches".

**Contingency:** If Perses does not respond, run `scripts/40-perses.sh` on the host to restart it; if panels show no data, run `sudo scripts/41-perses-portforwards.sh` to restart the port-forwards.

**Cut table entry:** 4 min; can be cut, third in the cut order.

## Beat 9 — Recovery · 0:32–0:35

**Screen:** Perses overview dashboard tab, "Demo Overview", then the Alertmanager tab and the Frontend UI tab.

**Do:**

```bash
sudo scripts/break.sh ok
sudo scripts/break.sh baseline
```

**Say:**
Every chaos mode is back to `ok`, the DNS policy is gone, and the load generator has been restarted from a clean state.
The request rate returns, the error rate falls back to zero, and the alerts resolve in Alertmanager.
We explained each incident from application metrics, network evidence, traces, logs, and operational events, and every one of those signals stayed inside the boundary.

**Point at:** Perses overview dashboard tab, "Demo Overview": "Request rate by service", "Error rate % (Hubble 5xx / total)", "Active chaos state"; Alertmanager tab: no active alerts; Frontend UI tab: the clear banner and the CLEAR events.

**Contingency:** If alerts are still listed as active, Alertmanager has not yet sent the resolved notification; narrate the recovery from "Error rate % (Hubble 5xx / total)" and "Active chaos state".

**Cut table entry:** 3 min; not cut.

## Cut lines

Beats 4 (Torpedo) and 5 (DNS) are never cut.
Cut in this order: beat 7 (Logs), then beat 6 (Traces), then beat 8 (Perses).

| Beat | Nominal duration | Cut priority |
| --- | --- | --- |
| 0 Baseline | 2 min | not cut |
| 1 Latency | 3 min | not cut |
| 2 Errors | 4 min | not cut |
| 3 Alert lifecycle | 3 min | not cut |
| 4 Torpedo | 3 min | never cut |
| 5 DNS | 5 min | never cut |
| 6 Traces | 4 min | cut second |
| 7 Logs | 4 min | cut first |
| 8 Perses | 4 min | cut third |
| 9 Recovery | 3 min | not cut |

The beats total 35 minutes, leaving 5 minutes of slack in a 40-minute slot.

## Pre-demo checklist

Run these before doors, in order:

```bash
sudo scripts/reset.sh
sudo scripts/41-perses-portforwards.sh
scripts/40-perses.sh
sudo scripts/preflight.sh
```

`scripts/reset.sh` recreates the frontend pod, which ends the frontend forward, so `scripts/41-perses-portforwards.sh` must run after it.
`sudo scripts/preflight.sh` must print `✓ preflight passed — demo ready`.
That line means every assertion in `scripts/preflight.sh` held:

- the local registry answers at `registry.lab.local:5000`;
- the Cilium agent DaemonSet is fully ready;
- Prometheus, Loki, and Tempo report ready, and the in-cluster Perses answers `/api/v1/health`;
- every pod in namespace `demo` is Running and ready, and the frontend, api, and backend Services exist;
- the loadgen Job exists and its pod is Running and ready;
- the host Perses answers `http://localhost:8080/api/v1/health`;
- the prometheus, loki, tempo, alertmanager, hubble-relay, hubble-ui, and frontend port-forward PIDs in `/tmp/perses-pf/` are alive;
- Hubble Relay answers `hubble status` on `localhost:4245`;
- the frontend UI is served at `http://localhost:8082/index.html`;
- `torpedoes_detected_total` is present in Prometheus at `localhost:9090`, so the OTLP metrics path works;
- the frontend webhook receiver at `localhost:8082` accepted the synthetic `PreflightTest` alert from `scripts/preflight-test-payload.json` and showed it in `/status`; preflight then resolves it so the banner starts clear;
- finally, preflight runs `scripts/break.sh baseline`.

Set the browser tab order before doors.
Every URL is served by `scripts/41-perses-portforwards.sh` or `scripts/40-perses.sh`.
When the K3S node is the local VM, keep this SSH tunnel open on the presenter host so the browser can reach the guest's localhost forwards:

```bash
ssh -N -p 2222 -i ~/.ssh/id_ed25519 \
	-L 9090:127.0.0.1:9090 -L 3100:127.0.0.1:3100 -L 3200:127.0.0.1:3200 \
	-L 9093:127.0.0.1:9093 -L 4245:127.0.0.1:4245 \
	-L 12000:127.0.0.1:12000 -L 8082:127.0.0.1:8082 \
	-R 8080:127.0.0.1:8080 ubuntu@127.0.0.1
```

Press `Ctrl-C` in that terminal to close the tunnel after the workshop.

| Order | Tab | URL |
| --- | --- | --- |
| 1 | Hubble UI | `http://localhost:12000/?namespace=demo` |
| 2 | Perses overview dashboard | `http://localhost:8080`, project `demo`, dashboard "Demo Overview" |
| 3 | Alertmanager | `http://localhost:9093` |
| 4 | Frontend UI | `http://localhost:8082/index.html` |
| 5 | Prometheus | `http://localhost:9090` |
| 6 | Tempo | Perses Explore, Tempo query, URL below |
| 7 | Loki | Perses Explore, Loki query, URL below |
| 8 | Terminal (echo sink logs) | `sudo kubectl logs -f deploy/echo-sink -n demo` |

The Frontend UI is the beat-4 surface.
If it is not open, the torpedo beat has no visual.

Tempo tab, traces for the frontend, api, and backend over the last 15 minutes:

```text
http://localhost:8080/explore?start=15m&refresh=0s&explorer=Tempo-TempoExplorer&data=%7B%22queries%22%3A%5B%7B%22kind%22%3A%22TraceQuery%22%2C%22spec%22%3A%7B%22plugin%22%3A%7B%22kind%22%3A%22TempoTraceQuery%22%2C%22spec%22%3A%7B%22datasource%22%3A%7B%22kind%22%3A%22TempoDatasource%22%2C%22name%22%3A%22tempo%22%7D%2C%22query%22%3A%22%7B+resource.service.name+%3D~+%5C%22frontend%7Capi%7Cbackend%5C%22+%7D%22%2C%22limit%22%3A50%7D%7D%7D%7D%5D%7D&project=demo
```

Loki tab, log lines from namespace `demo` over the last 15 minutes:

```text
http://localhost:8080/explore?start=15m&refresh=0s&explorer=LogExplorer-LogExplorer&data=%7B%22queries%22%3A%5B%7B%22kind%22%3A%22LogQuery%22%2C%22spec%22%3A%7B%22plugin%22%3A%7B%22kind%22%3A%22LokiLogQuery%22%2C%22spec%22%3A%7B%22datasource%22%3A%7B%22kind%22%3A%22LokiDatasource%22%2C%22name%22%3A%22loki%22%7D%2C%22query%22%3A%22%7Bkubernetes_namespace_name%3D%5C%22demo%5C%22%7D%22%7D%7D%7D%7D%5D%7D&project=demo
```

## Post-demo reset

```bash
sudo scripts/break.sh ok
sudo scripts/reset.sh
sudo scripts/42-perses-stop.sh
```

`scripts/break.sh ok` returns every service to `ok` and removes the DNS policy.
`scripts/reset.sh` deletes and recreates namespace `demo`, reapplies the L7 visibility policy, the app, the ServiceMonitor, the alert rules, the AlertmanagerConfig, and the echo sink, then runs `scripts/break.sh baseline`, which resets the chaos modes again and recreates the load generator through `scripts/loadgen-restart.sh`.
