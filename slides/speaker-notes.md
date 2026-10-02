# Speaker Notes

These notes follow the slide order and titles in `slides/slides.md`.
Demo steps live in `docs/demo-runbook.md`.

## Slide 1 — Introduction to Observability

We have forty-five minutes together.
The first forty are a live demonstration, and then the room opens up and you can choose one of the workshop tracks on the screen.

Everything you are about to see runs on a single K3S node inside a closed boundary.
Every image, chart, and dashboard was captured before we disconnected, and nothing you see is reaching the internet.

## Slide 2 — In a disconnected environment, you cannot call support. You can only know.

The operative distinction is not tooling; it is whether we can ask a question we did not anticipate.
Monitoring answers the questions we wrote down in advance, and in a disconnected environment there is nobody to escalate to when the question is new.

Asking a new question needs high-cardinality data, no pre-aggregation, and signals that are causally linked.
Four tools that do not talk to each other are four monitoring tools.

## Slide 3 — The signals

These signals answer different questions, and the value is in moving between them in one click.
Metrics are cheap and always on, but they are blind to cardinality.
Traces pinpoint a path, but they cost more to retain.
Logs are the ground truth nobody wants to grep.
Profiles answer which line of code is burning CPU; Pyroscope is deployed in this stack, but today's beats do not use it.

Exemplars link metrics to traces, and the OpenTelemetry for Java workshop covers that workflow, so I will not go further into the taxonomy here.

There is a fifth thing you will see in a moment that is not on this list: an operational event.
It is not a signal; it is a notification, and I will point it out when it appears.

## Slide 4 — What's actually new

This slide justifies the demo, so I will take each point in turn.

For fifteen years, network visibility meant a proxy in the path.
Now it is the kernel: with eBPF, Cilium sees HTTP status, latency, DNS, and flow verdicts with no client library and no sidecar, and the application cannot alter that record.

Cilium enforces the segmentation and Hubble shows the verdicts, so the control and the evidence are the same system.
You declare the boundary and then prove it holds, flow by flow.

OTLP is the interface we instrument against once and route to backends we control.
You are not choosing between Fluent Bit and the OpenTelemetry Collector, because Fluent Bit speaks OTLP as well.

And note that an alert is not necessarily a failure.
You will see that in the demo.

## Slide 5 — Why this stack

You could build all of this on a commercial platform.
This is what it looks like when you do not want to.

Every component is open source, auditable, and forkable, nothing requires a hosted endpoint, and every byte of telemetry stays inside the boundary.

That includes where the alerts go.
Alertmanager delivers to receivers we run ourselves, so the notification path is part of the boundary, not an afterthought.

## Slide 6 — Let's break something.

Everything from here is live.
We have one application made of three services, a frontend, an api, and a backend, with a load generator sending steady traffic through them.

We are going to slow it down, make it fail, and cut off its DNS, and in between we will trigger one alert that is not a failure at all.
Watch where each one shows up first.

## Slide 7 — Metrics

Advance to Beat 1 — see docs/demo-runbook.md.

## Slide 8 — Operational events

Advance to Beat 4 — see docs/demo-runbook.md.

## Slide 9 — Network

Advance to Beat 5 — see docs/demo-runbook.md.

## Slide 10 — Traces

Advance to Beat 6 — see docs/demo-runbook.md.

## Slide 11 — Questions

That is the end of the core session.
I will take questions now, and then we will open the optional workshop tracks.

## Slide 12 — Component versions and licences

Every version on this slide comes from `versions.lock` in the repository, which pins each image by tag and digest.
Every component listed is Apache-2.0 licensed.

## Slide 13 — The alert rules

The deployed `DemoHighErrorRate` rule divides Hubble's server-side 5xx request rate by its total request rate for each destination workload in the demo namespace, and fires when that ratio stays above five percent for one minute.
`TorpedoDetected` fires when the one-minute rate of `torpedoes_detected_total` stays above five per second for thirty seconds, and the two different `for` durations are deliberate.

## Slide 14 — api-deny-dns

This policy denies DNS egress from the api to kube-dns over both UDP and TCP port 53.
In Hubble, those queries appear as DROPPED with the reason "Policy denied by denylist".

## Slide 15 — Links

These are the five optional workshop tracks.
The links are here for you to use after the session.

## Slide 16 — How the demo was built

A connected build node captured every chart, image, and binary, and we replayed them on a node with K3S, Cilium replacing kube-proxy, and Helm, with no outbound access.
The business metric starts as `torpedoes.detected`, travels over OTLP to the Collector, and enters Prometheus 3 through its native OTLP receiver as `torpedoes_detected_total`, without ever touching the scrape path.

## Slide 17 — The event path

The backend emits a business metric over OTLP, Prometheus evaluates `TorpedoDetected`, and Alertmanager groups the alert and posts it to the frontend's webhook receiver.
The receiver translates the alert name into operational text and the operator screen shows the red TORPEDO DETECTED banner, all inside the boundary.
