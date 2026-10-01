# Alerting Demo Runbook

## Prerequisites

The cluster and observability stack are installed with `sudo scripts/30-stack.sh`.
The demo application and request load generator are running in namespace `demo`.
The application deployment must expose `frontend`, `api`, and `backend` Services on port 8080.
Prometheus has discovered the Cilium Hubble ServiceMonitor and reports Hubble HTTP request series.
Alertmanager is available at `http://localhost:9093` using `kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager 9093:9093`.

## Demo Sequence

1. Show `manifests/alert-rules.yaml`.
Explain that `for: 1m` keeps the alert Pending until the threshold remains true for a minute; firing an alert and sending a notification are separate stages.

2. Generate HTTP traffic from the demo workload, then force the network path to return 5xx responses.
Use `kubectl -n demo port-forward svc/api 8081:8080` in one terminal and call `curl 'http://localhost:8081/chaos?mode=error'` in another.
Keep the load generator running against the frontend while the API remains in error mode.
To create a second destination alert instance, port-forward `svc/backend` to `8082:8080` and call `curl 'http://localhost:8082/chaos?mode=error'` while the API continues calling it.
Restore both services with `curl 'http://localhost:8081/chaos?mode=ok'` and `curl 'http://localhost:8082/chaos?mode=ok'` after the demonstration.
In Prometheus, query `hubble_http_requests_total{reporter="server",destination_namespace="demo",status=~"5.."}` to confirm Hubble is recording the failing requests.
Open Alertmanager and show `DemoHighErrorRate` transition through Inactive, Pending, and Firing.

3. Generate failures for at least two destination workloads in the same namespace.
Show that Alertmanager groups those alert instances into one notification by `alertname` and `namespace`.
The alert instances retain their `destination_workload` labels while sharing those group labels.

4. Create a silence from the Alertmanager UI for `alertname="DemoHighErrorRate"`.
Keep generating failures and show that the firing alert remains visible while notifications are silenced.

5. Follow the webhook receiver output with `kubectl logs -f deploy/echo-sink -n demo`.
Show the pretty-printed JSON received by the local sink.
The payload below was captured from the local Alertmanager route smoke test with two grouped destination alerts.
Those test alerts were posted to Alertmanager’s API and did not originate from a Prometheus/Hubble rule firing.
After the demo workload acceptance run, replace this reference with the exact JSON printed by `kubectl logs -f deploy/echo-sink -n demo`.

```json
{
  "alerts": [
    {
      "annotations": {
        "description": "Source: Cilium Hubble. No application instrumentation.",
        "summary": "5xx above 5% on api"
      },
      "endsAt": "0001-01-01T00:00:00Z",
      "fingerprint": "c0d7b1d437a92ab6",
      "generatorURL": "http://prometheus/demo-test",
      "labels": {
        "alertname": "DemoHighErrorRate",
        "destination_workload": "api",
        "namespace": "demo",
        "pillar": "network",
        "severity": "warning"
      },
      "startsAt": "2026-10-01T09:23:26Z",
      "status": "firing"
    },
    {
      "annotations": {
        "description": "Source: Cilium Hubble. No application instrumentation.",
        "summary": "5xx above 5% on backend"
      },
      "endsAt": "0001-01-01T00:00:00Z",
      "fingerprint": "3a0d78bbf49ca12e",
      "generatorURL": "http://prometheus/demo-test",
      "labels": {
        "alertname": "DemoHighErrorRate",
        "destination_workload": "backend",
        "namespace": "demo",
        "pillar": "network",
        "severity": "warning"
      },
      "startsAt": "2026-10-01T09:24:43Z",
      "status": "firing"
    }
  ],
  "commonAnnotations": {
    "description": "Source: Cilium Hubble. No application instrumentation."
  },
  "commonLabels": {
    "alertname": "DemoHighErrorRate",
    "namespace": "demo",
    "pillar": "network",
    "severity": "warning"
  },
  "externalURL": "http://kube-prometheus-stack-alertmanager.observability:9093",
  "groupKey": "{}/{namespace=\"demo\",pillar=\"network\"}:{alertname=\"DemoHighErrorRate\", namespace=\"demo\"}",
  "groupLabels": {
    "alertname": "DemoHighErrorRate",
    "namespace": "demo"
  },
  "notification_reason": "new alerts added",
  "receiver": "demo/demo-local-webhook/echo",
  "routeLabels": {},
  "status": "firing",
  "truncatedAlerts": 0,
  "version": "4"
}
```
```

6. Inhibition suppresses lower-priority notifications when a related higher-priority alert is firing; it is configured policy, not a demonstrated step in this run.

## Teardown

Run `sudo scripts/90-teardown-cluster.sh` to remove the alert manifests, echo sink, and Helm releases while leaving K3S installed.
