# Metrics Paths

Every number on the dashboards reaches Prometheus by exactly one of three paths.
Knowing which path a metric took tells you who produced it and what it can prove.

## Scrape Path: App Request Metrics

Each service exposes Prometheus-native metrics at `/metrics` on port 8080.
`manifests/app/servicemonitor.yaml` tells kube-prometheus-stack to scrape all three services every 15 seconds.
The names are hand-picked and stable, so the dashboards depend on them:

- `app_http_requests_total{service, code}` counts requests on the API path `/`.
- `app_http_request_duration_seconds{service}` is the latency histogram behind p50, p95, and p99.
- `app_chaos_mode{service, mode}` is 1 for each service's active chaos mode and 0 for the others.

Prometheus also attaches the scraped Service's name as `service`, so the app's own `service` label appears as `exported_service`; both carry the same value.

## OTLP Path: Traces and Business Metrics

The app exports through one OTLP gRPC connection to `otel-collector.observability.svc.cluster.local:4317`.
The Go SDK has one exporter per signal, so the trace exporter and the metric exporter share that single connection.
Traces go from the Collector to Tempo.
Business metrics go from the Collector's `otlp_http/prometheus` exporter to Prometheus's native OTLP receiver at `/api/v1/otlp/v1/metrics`, enabled by `enableOTLPReceiver` in `values/kube-prometheus-stack.yaml`.
Scraped metrics never pass through the Collector, and there is no remote-write exporter.

The business counters come from one Meter named `demo` in `app/internal/telemetry` and are deliberately absent from `/metrics`:

| OTel name | Prometheus name | Emitted by | Increment |
| --- | --- | --- | --- |
| `torpedoes.detected` | `torpedoes_detected_total` | backend | background sensor: ~0.3/s, ~50/s in torpedo mode |
| `sonar.contacts.detected` | `sonar_contacts_detected_total` | api | every request |
| `surface.ship.contacts.detected` | `surface_ship_contacts_detected_total` | api | 1 in 3 requests |
| `submarine.contacts.detected` | `submarine_contacts_detected_total` | api | 1 in 5 requests |
| `countermeasure.launches` | `countermeasure_launches_total` | backend | every request in error mode |

### The Name Translation

Prometheus 3 uses the `UnderscoreEscapingWithSuffixes` translation strategy, set explicitly in `values/kube-prometheus-stack.yaml`.
Dots become underscores, and counters gain `_total`.
Units written in braces, such as `{torpedo}`, are annotations and add no suffix.
The `service.name` resource attribute becomes the `job` label.

Narration:

> This metric never touched the scrape path.
> It was emitted as torpedoes.detected, travelled OTLP through the Collector, and Prometheus 3 materialized it as torpedoes_detected_total.
> The _total suffix is Prometheus's translation of an OTel counter.

### The Countermeasure Tie-In

`countermeasure.launches` only moves while the backend is in error mode.
In error mode the failure has an operational signature, not just a technical one: the 5xx rate rises, and so does the rate of countermeasures launched in response.
In a rehearsal, `scripts/break.sh errors` took the total from 0 to 3220 after 30 seconds and 5960 after 45 seconds.
After `scripts/break.sh ok` it stayed at 6257 across a 30-second interval.

## Kernel Path: Cilium and Hubble

The Cilium agent exports Hubble metrics on its `hubble-metrics` port, scraped by the `cilium-hubble` ServiceMonitor in `values/kube-prometheus-stack.yaml`.
Hubble only decodes HTTP and DNS for flows that pass through Cilium's proxies.
Cilium 1.16 and later ignore the `policy.cilium.io/proxy-visibility` annotation, so `manifests/app/l7-visibility.yaml` enables L7 visibility with an L7 CiliumNetworkPolicy.
`values/cilium.yaml` sets `httpV2:labelsContext=source_namespace,source_workload,destination_namespace,destination_workload` so HTTP metrics carry workload labels.
On Cilium 1.17 the HTTP metric labels are `status` and `reporter="server"` or `reporter="client"`, which the alert rule and dashboards use.
Cilium also exports `hubble_dns_queries_total`, labelled only by `qtypes` and `ips_returned`, so the "Network" dashboard uses `hubble_dns_responses_total`, which carries `rcode`.
During the DNS beat, `hubble_drop_total` records the denied queries with `reason="POLICY_DENY"`.

## Which Dashboard Metric Came From Which Path

| Dashboard panel | Metric | Path |
| --- | --- | --- |
| Overview: request rate by service | `app_http_requests_total` | scrape |
| Overview: error rate % | `hubble_http_requests_total` | kernel |
| Overview: frontend latency | `app_http_request_duration_seconds` | scrape |
| Overview: active chaos state | `app_chaos_mode` | scrape |
| Overview: business telemetry row | `torpedoes_detected_total`, `sonar_contacts_detected_total`, `submarine_contacts_detected_total`, `surface_ship_contacts_detected_total`, `countermeasure_launches_total` | OTLP |
| Network: all four panels | `hubble_http_requests_total`, `hubble_dns_responses_total`, `hubble_drop_total` | kernel |
| Signals: metrics | `app_http_request_duration_seconds` | scrape |
| Signals: network | `hubble_http_requests_total` | kernel |
| Signals: traces | Tempo traces | OTLP |
| Signals: logs | Loki log lines | Fluent Bit |

## Reference Responses

The following raw samples use synthetic pod names and documentation-only addresses.

`curl 'localhost:9090/api/v1/query?query=torpedoes_detected_total'`, raw response:

```json
{"status":"success","data":{"resultType":"vector","result":[{"metric":{"__name__":"torpedoes_detected_total","job":"backend"},"value":[1700000000.872,"6742"]}]}}
```

`curl 'localhost:9090/api/v1/query?query=app_chaos_mode'`, the same raw response with each element of `data.result` on its own line:

```json
{"status":"success","data":{"resultType":"vector","result":[
{"metric":{"__name__":"app_chaos_mode","container":"backend","endpoint":"http","exported_service":"backend","instance":"192.0.2.10:8080","job":"backend","mode":"dns","namespace":"demo","pod":"backend-demo-001","service":"backend"},"value":[1700000000.879,"0"]},
{"metric":{"__name__":"app_chaos_mode","container":"backend","endpoint":"http","exported_service":"backend","instance":"192.0.2.10:8080","job":"backend","mode":"error","namespace":"demo","pod":"backend-demo-001","service":"backend"},"value":[1700000000.879,"0"]},
{"metric":{"__name__":"app_chaos_mode","container":"backend","endpoint":"http","exported_service":"backend","instance":"192.0.2.10:8080","job":"backend","mode":"ok","namespace":"demo","pod":"backend-demo-001","service":"backend"},"value":[1700000000.879,"1"]},
{"metric":{"__name__":"app_chaos_mode","container":"backend","endpoint":"http","exported_service":"backend","instance":"192.0.2.10:8080","job":"backend","mode":"slow","namespace":"demo","pod":"backend-demo-001","service":"backend"},"value":[1700000000.879,"0"]},
{"metric":{"__name__":"app_chaos_mode","container":"backend","endpoint":"http","exported_service":"backend","instance":"192.0.2.10:8080","job":"backend","mode":"torpedo","namespace":"demo","pod":"backend-demo-001","service":"backend"},"value":[1700000000.879,"0"]},
{"metric":{"__name__":"app_chaos_mode","container":"frontend","endpoint":"http","exported_service":"frontend","instance":"192.0.2.11:8080","job":"frontend","mode":"dns","namespace":"demo","pod":"frontend-demo-001","service":"frontend"},"value":[1700000000.879,"0"]},
{"metric":{"__name__":"app_chaos_mode","container":"frontend","endpoint":"http","exported_service":"frontend","instance":"192.0.2.11:8080","job":"frontend","mode":"error","namespace":"demo","pod":"frontend-demo-001","service":"frontend"},"value":[1700000000.879,"0"]},
{"metric":{"__name__":"app_chaos_mode","container":"frontend","endpoint":"http","exported_service":"frontend","instance":"192.0.2.11:8080","job":"frontend","mode":"ok","namespace":"demo","pod":"frontend-demo-001","service":"frontend"},"value":[1700000000.879,"1"]},
{"metric":{"__name__":"app_chaos_mode","container":"frontend","endpoint":"http","exported_service":"frontend","instance":"192.0.2.11:8080","job":"frontend","mode":"slow","namespace":"demo","pod":"frontend-demo-001","service":"frontend"},"value":[1700000000.879,"0"]},
{"metric":{"__name__":"app_chaos_mode","container":"frontend","endpoint":"http","exported_service":"frontend","instance":"192.0.2.11:8080","job":"frontend","mode":"torpedo","namespace":"demo","pod":"frontend-demo-001","service":"frontend"},"value":[1700000000.879,"0"]},
{"metric":{"__name__":"app_chaos_mode","container":"api","endpoint":"http","exported_service":"api","instance":"192.0.2.12:8080","job":"api","mode":"dns","namespace":"demo","pod":"api-demo-001","service":"api"},"value":[1700000000.879,"0"]},
{"metric":{"__name__":"app_chaos_mode","container":"api","endpoint":"http","exported_service":"api","instance":"192.0.2.12:8080","job":"api","mode":"error","namespace":"demo","pod":"api-demo-001","service":"api"},"value":[1700000000.879,"0"]},
{"metric":{"__name__":"app_chaos_mode","container":"api","endpoint":"http","exported_service":"api","instance":"192.0.2.12:8080","job":"api","mode":"ok","namespace":"demo","pod":"api-demo-001","service":"api"},"value":[1700000000.879,"1"]},
{"metric":{"__name__":"app_chaos_mode","container":"api","endpoint":"http","exported_service":"api","instance":"192.0.2.12:8080","job":"api","mode":"slow","namespace":"demo","pod":"api-demo-001","service":"api"},"value":[1700000000.879,"0"]},
{"metric":{"__name__":"app_chaos_mode","container":"api","endpoint":"http","exported_service":"api","instance":"192.0.2.12:8080","job":"api","mode":"torpedo","namespace":"demo","pod":"api-demo-001","service":"api"},"value":[1700000000.879,"0"]}
]}}
```
