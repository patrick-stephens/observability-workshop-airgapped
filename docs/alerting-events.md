# Alerting Events

The frontend's operator view turns Alertmanager notifications into plain operational events.
This is the "what the operator sees" screen beside the observability stack.

## From Application Event to Operator UI

```text
app metric -> Prometheus -> alert rule -> Alertmanager -> webhook -> frontend receiver -> translation -> UI event feed
```

1. The backend emits `torpedoes.detected` over OTLP, and Prometheus stores it as `torpedoes_detected_total`; Hubble produces `hubble_http_requests_total` for the network alert.
2. `manifests/alert-rules.yaml` evaluates `TorpedoDetected` and `DemoHighErrorRate` in Prometheus.
3. Alertmanager routes alerts with `pillar` `network` or `business` in namespace `demo` to the `echo` receiver, as set in `manifests/alertmanager-config.yaml`.
4. The `echo` receiver has two webhooks that receive the same notification.
5. The echo sink logs the raw JSON payload, which beat 3 of the demo shows with `kubectl logs deploy/echo-sink -n demo`.
6. The frontend's `POST /webhook/alertmanager` handler translates each alert and adds it to an in-memory store of the last 50 events.
7. `/index.html` polls `/status` every 2 seconds, colours the banner by the most severe firing alert, and lists the event feed newest first.

The webhook requests from Alertmanager to the frontend also appear as L7 HTTP flows in Hubble.

## Translation Table

| Alert name | Event text | Severity |
| --- | --- | --- |
| `DemoHighErrorRate` | Contact lost — elevated error rate | from the alert's `severity` label (`warning`) |
| `TorpedoDetected` | TORPEDO DETECTED | from the alert's `severity` label (`critical`) |
| anything else | the alert name itself | `warning` |

A resolved alert is shown as `CLEAR — ` followed by its text, with severity `ok`.
The table is the `Translations` variable in `app/internal/alerts/translate.go`.

## Unmapped Alerts Pass Through

The receiver never drops an alert it does not recognise.
An unmapped alert appears under its own name with severity `warning`.
Operationally, adding a new PrometheusRule is enough to put it on the operator screen with no code change or redeploy.
A translation entry only improves the wording.

## Torpedo Mode

`sudo scripts/break.sh torpedo` switches the backend into torpedo mode.
The backend keeps serving every request normally with HTTP 200; only its background torpedo sensor speeds up, from about 0.3 to about 50 detections per second.
`TorpedoDetected` fires when the rate stays above 5 per second for 30 seconds.
This shows that an alert can describe the business, not just a failure.
Nothing is broken, error rates stay flat, yet the operator screen turns red with TORPEDO DETECTED.
The contrast with `DemoHighErrorRate` is deliberate: one alert reports a technical failure, the other an operational situation, and their different `for` durations show that tolerance is chosen per alert.
`sudo scripts/break.sh ok` returns the backend to normal, and the frontend shows `CLEAR — TORPEDO DETECTED` once Alertmanager sends the resolved notification.
