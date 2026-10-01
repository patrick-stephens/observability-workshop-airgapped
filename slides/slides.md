---
theme: default
layout: cover
title: Introduction to Observability
author: "Presenter name (replace before presenting)"
highlighter: shiki
lineNumbers: false
colorSchema: dark
routerMode: hash
wakeLock: false
fonts:
  provider: none
  sans: Inter
  mono: JetBrains Mono
---

# Introduction to Observability

<p class="track-line">OpenTelemetry · OpenTelemetry for Java · Prometheus · Fluent Bit · Perses</p>

<!-- We have 45 minutes together. We will demo for 40 minutes, then the room opens up and you can choose a track. Nothing you are about to see is reaching the internet. -->

<!-- Slide 2 -->
---
layout: statement
---

# In a disconnected environment, you cannot call support. You can only know.

Monitoring covers the failures you predicted. Observability covers the ones you didn't.

<!-- The operative distinction is not tooling; it is whether we can ask a question we did not anticipate. That requires high-cardinality data, no pre-aggregation, and signals that are causally linked. Four tools that do not talk to each other are four monitoring tools. -->

<!-- Slide 3 -->
---
layout: default
---

# The signals

<table class="signal-table">
  <tbody>
    <tr><td><code>Metrics</code></td><td>Is something wrong, and how much?</td></tr>
    <tr><td><code>Traces</code></td><td>Where in the request path?</td></tr>
    <tr><td><code>Logs</code></td><td>What exactly happened?</td></tr>
    <tr><td><code>Profiles</code></td><td>Which line of code is burning CPU?</td></tr>
  </tbody>
</table>

<!-- These signals answer different questions; the value is moving between them in one click. Metrics are cheap and always on, but cardinality-blind. Traces pinpoint a path, but cost more to retain. Logs are ground truth nobody wants to grep. Exemplars link metrics to traces, and the OpenTelemetry for Java workshop covers that workflow. We will move on before this becomes a taxonomy debate. There is a fifth thing you will see in a moment that is not on this list: an operational event. It is not a signal; it is a notification. Watch for it. -->

<!-- Slide 4 -->
---
layout: default
---

# What's actually new

<div class="position-list">
  <div class="position-item">
    <span class="position-number">1.</span>
    <div><strong class="position-lead">Telemetry from the kernel.</strong><span class="position-detail">eBPF means the CNI sees L7: status, latency, DNS, and flow verdicts, with no client library, no sidecar, and no way for the application to alter the record.</span></div>
  </div>
  <div class="position-item">
    <span class="position-number">2.</span>
    <div><strong class="position-lead">Policy as code, verified continuously.</strong><span class="position-detail">Cilium enforces segmentation; Hubble shows the verdicts. Declare the boundary, then prove it holds, every flow, every second.</span></div>
  </div>
  <div class="position-item">
    <span class="position-number">3.</span>
    <div><strong class="position-lead">OTLP as the sovereign interface.</strong><span class="position-detail">Instrument once, route to backends you control, over transports you control. Nothing has to phone home.</span></div>
  </div>
</div>

<!-- This slide justifies the demo, so I will land each point deliberately and pause. For fifteen years, network visibility meant a proxy; now it is the kernel. The control and the evidence are the same system. You are not choosing between Fluent Bit and the OpenTelemetry Collector; Fluent Bit speaks OTLP. And note: an alert is not necessarily a failure. You will see that in a moment. -->

<!-- Slide 5 -->
---
layout: default
---

# Why this stack

<table class="criterion-table">
  <thead><tr><th>Criterion</th><th>Position</th></tr></thead>
  <tbody>
    <tr><td>Licence</td><td>Apache-2.0 across every component</td></tr>
    <tr><td>Source</td><td>Available. Auditable. Forkable.</td></tr>
    <tr><td>Transport</td><td>Nothing requires a hosted endpoint</td></tr>
    <tr><td>Data residency</td><td>Everything in-boundary</td></tr>
    <tr><td>Notification path</td><td>In-boundary. Alertmanager to your own receivers</td></tr>
    <tr><td>Longevity</td><td>CNCF projects, not a single-vendor bet</td></tr>
  </tbody>
</table>

<!-- You could build this on a commercial platform. This is what it looks like when you do not want to. That includes where your alerts go. The notification path is part of the boundary, not an afterthought. -->

<!-- Slide 6 -->
---
layout: section
---

# Let's break something.

<!-- Everything from here is live. We have one app and three services, and we are going to make it fail in three different ways. One of them is not a failure at all. Watch where each one shows up first. -->

<!-- Slide 7 -->
---
layout: demo
beat: 1
---

# Metrics

<!-- The p99 panel shows degradation before anyone is paged. -->

<!-- Slide 8 -->
---
layout: demo
beat: 4
---

# Operational events

<!-- This is the operator's view. The system is about to report something that is not a failure. -->

<!-- Slide 9 -->
---
layout: demo
beat: 5
---

# Network

<!-- This is the money beat: the policy causing the failure and the evidence proving it are in the same system. -->

<!-- Slide 10 -->
---
layout: demo
beat: 6
---

# Traces

<!-- Follow the request path across services, answering a question metrics cannot answer. -->

<!-- Slide 10 -->
---
layout: end
---

# Questions

<!-- We have reached the end of the core session. I will take questions before we open the optional tracks. -->

<!-- Backup B1 -->
---
layout: default
---

# Component versions and licences

| Component | Version | Licence | Role |
|:--|:--|:--|:--|
| Kubernetes / K3S | [fill from versions.lock] | Apache-2.0 | Cluster runtime |
| Cilium | [fill from versions.lock] | Apache-2.0 | CNI, policy, and flow visibility |
| OpenTelemetry Collector | [fill from versions.lock] | Apache-2.0 | Telemetry pipeline |
| Prometheus | [fill from versions.lock] | Apache-2.0 | Metrics storage and alerting |
| Fluent Bit | [fill from versions.lock] | Apache-2.0 | Log collection and routing |
| Perses | [fill from versions.lock] | Apache-2.0 | Dashboards |

<!-- Before this session, fill the component versions from the parent repository's versions.lock and verify each licence against component metadata. -->

<!-- Backup B2 -->
---
layout: default
---

# The alert rules

<div class="compact-code">

```yaml
alert: DemoHighErrorRate
expr: |
  sum(rate(hubble_http_requests_total{reporter="destination",
    http_status_code=~"5.."}[1m]))
  /
  sum(rate(hubble_http_requests_total{reporter="destination"}[1m]))
  > 0.05
for: 1m
```

```yaml
alert: TorpedoDetected
expr: sum(rate(torpedoes_detected_total[1m])) > 5
for: 30s
```

</div>

<p class="backup-note">Block 1 numerator: 5xx requests seen by the CNI, not the app.</p>
<p class="backup-note">Block 1 denominator: all requests seen by the CNI.</p>
<p class="backup-note">The two <code>for</code> values differ deliberately: tolerance is a per-alert decision, not a global setting.</p>

<!-- DemoHighErrorRate counts 5xx requests observed by the CNI over one minute and divides them by all destination requests observed by the CNI. TorpedoDetected fires when the one-minute rate exceeds five per second for thirty seconds. The different for durations are deliberate because tolerance belongs to each alert, not to a global setting. -->

<!-- Backup B3 -->
---
layout: default
---

# api-deny-dns

<div class="compact-code">

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-deny-dns
  namespace: demo
spec:
  endpointSelector:
    matchLabels:
      app: api
  egressDeny:
    - toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
```

</div>

<p class="backup-note">Denies DNS egress from the <code>api</code> endpoint over UDP and TCP port 53.</p>
<p class="backup-note">Hubble shows the API's DNS flows as <code>DROPPED</code> at the policy boundary.</p>

<!-- This policy denies DNS egress from the API endpoint over both UDP and TCP port 53. In Hubble, the corresponding flows appear with a DROPPED verdict at the policy boundary. -->

<!-- Backup B4 -->
---
layout: default
---

# Links

<div class="backup-links">
  <p>o11y-workshops.gitlab.io</p>
  <p>OpenTelemetry: https://o11y-workshops.gitlab.io/workshop-opentelemetry/</p>
  <p>OpenTelemetry for Java: https://o11y-workshops.gitlab.io/workshop-otel-developers/</p>
  <p>Prometheus: https://o11y-workshops.gitlab.io/workshop-prometheus/</p>
  <p>Fluent Bit: https://o11y-workshops.gitlab.io/workshop-fluentbit/</p>
  <p>Perses: https://o11y-workshops.gitlab.io/workshop-perses/</p>
</div>

<!-- These are the five optional workshop tracks. The links are included for attendees to use after the live session. -->

<!-- Backup B5 -->
---
layout: default
---

# How the demo was built

<div class="build-details">

| Element | Implementation |
|:--|:--|
| Kubernetes | K3S |
| Networking | Cilium with kube-proxy replaced |
| Packaging | Helm |
| Runtime | Airgapped |
| Build node | Captures and stages dependencies |
| Replay node | Runs the workshop demo inside the boundary |

<h2>The business metrics path</h2>

<div class="compact-code">

```text
torpedoes.detected (OTel, dotted name)
  -> OTLP to the Collector
  -> Prometheus 3 native OTLP receiver
  -> torpedoes_detected_total (Prometheus name, _total appended)
```

</div>

<p class="backup-note">This metric never touched the scrape path.</p>

</div>

<!-- The build node captures and stages dependencies while it is connected. We carry those artefacts to the replay node, where K3S, Cilium with kube-proxy replaced, and Helm run the demo without outbound access. The business metric starts as torpedoes.detected, travels over OTLP to the Collector, and enters Prometheus 3 through its native OTLP receiver as torpedoes_detected_total. It never touches the scrape path. -->

<!-- Backup B6 -->
---
layout: default
---

# The event path

<div class="event-flow">
  <div><code>app metric (OTLP)</code><span>emitted by backend, travels via Collector</span></div>
  <div class="flow-connector">|</div>
  <div><code>Prometheus</code><span>ingests via native OTLP receiver</span></div>
  <div class="flow-connector">|</div>
  <div><code>alert rule</code><span>TorpedoDetected, rate &gt; 5/s for 30s</span></div>
  <div class="flow-connector">|</div>
  <div><code>Alertmanager</code><span>groups, routes, fires</span></div>
  <div class="flow-connector">|</div>
  <div><code>webhook</code><span>POST to frontend /webhook/alertmanager</span></div>
  <div class="flow-connector">|</div>
  <div><code>frontend receiver</code><span>translates alertname to operational text</span></div>
  <div class="flow-connector">|</div>
  <div><code>UI banner</code><span>TORPEDO DETECTED in red</span></div>
</div>

<p class="backup-note">Application event to operator notification, six hops, all in-boundary, all observable.</p>

<!-- The backend emits a business metric over OTLP. The Collector carries it to Prometheus, where the TorpedoDetected rule evaluates the rate and Alertmanager groups, routes, and fires the alert. A webhook posts to the frontend receiver, which translates the alert name into operational text and displays the red TORPEDO DETECTED banner. That is an application event becoming an operator notification in six hops, all inside the boundary and all observable. -->
