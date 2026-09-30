---
theme: default
layout: cover
title: Introduction to Observability
author: Patrick Stephens
highlighter: shiki
lineNumbers: false
colorSchema: dark
routerMode: hash
fonts:
  provider: none
  sans: Inter
  mono: JetBrains Mono
---

# Introduction to Observability

<p class="track-line">OpenTelemetry · OpenTelemetry for Java · Prometheus · Fluent Bit · Perses</p>

<!-- We have 45 minutes together. We will demo for 40 minutes, then the room opens up and you can choose a track for the remaining time. Nothing you are about to see reaches the internet. -->

<!-- Slide 2 -->
---
layout: statement
---

# In a disconnected environment, you cannot call support. You can only know.

Monitoring covers the failures you predicted. Observability covers the ones you didn't.

<!-- The operative distinction is not which tools we use; it is whether we can ask a question we did not anticipate. That requires high-cardinality data, no pre-aggregation that discards the dimensions we need, and signals that are causally linked. Four tools that do not talk to each other are four monitoring tools. -->

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

<!-- These signals answer different questions; the value comes from moving between them in one click. Metrics are cheap and always on, but blind to cardinality. Traces pinpoint a path, but they cost more to retain. Logs are ground truth that nobody wants to grep. Exemplars link a metric sample to its trace, and the OpenTelemetry for Java workshop covers that workflow. We will move on before this becomes a taxonomy debate. -->

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

<!-- This slide justifies the demo, so I will land each point deliberately and pause. For fifteen years, network visibility meant a proxy; now it is the kernel. The control and the evidence are the same system. You are not choosing between Fluent Bit and the OpenTelemetry Collector; Fluent Bit speaks OTLP. -->

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
    <tr><td>Longevity</td><td>CNCF projects, not a single-vendor bet</td></tr>
  </tbody>
</table>

<!-- You could build this on a commercial platform. This is what it looks like when you do not want to. -->

<!-- Slide 6 -->
---
layout: section
---

# Let's break something.

<!-- Everything from here is live. We have one app, three services, and we are going to make it fail in three different ways. Watch where each failure shows up first. -->

<!-- Slide 7 -->
---
layout: demo
beat: 1
---

# Metrics

<!-- First, watch the request metrics expose the injected latency before we open the trace. -->

<!-- Slide 8 -->
---
layout: demo
beat: 4
---

# Network

<!-- Next, watch Hubble show the DNS flow being denied at the network boundary. -->

<!-- Slide 9 -->
---
layout: demo
beat: 5
---

# Traces

<!-- Now follow the failed request across the three services in the trace view. -->

<!-- Slide 10 -->
---
layout: end
---

# Questions

<!-- We have reached the end of the core session. I will take questions before we open the optional tracks. -->

<!-- Backup B1 -->
<!-- Presenter note: versions and licences are pinned in versions.lock and the corresponding component metadata. -->
---
layout: default
---

# Component versions and licences

| Component | Version | Licence | Role |
|:--|:--|:--|:--|
| Kubernetes / K3S | v1.32.10+k3s1 | Apache-2.0 | Cluster runtime |
| Cilium | 1.17.6 | Apache-2.0 | CNI, policy, and flow visibility |
| OpenTelemetry Collector | 0.174.0 | Apache-2.0 | Telemetry pipeline |
| Prometheus | v3.15.0 | Apache-2.0 | Metrics storage and alerting |
| Fluent Bit | 5.1.2 | Apache-2.0 | Log collection and routing |
| Perses | v0.54.0 | Apache-2.0 | Dashboards |

<!-- Presenter note: versions and licences are pinned in versions.lock and the corresponding component metadata. -->

<!-- Backup B2 -->
---
layout: default
---

# DemoHighErrorRate

<div class="compact-code">

```yaml
alert: DemoHighErrorRate
expr: |
  sum(rate(http_server_requests_total{service="api", status=~"5.."}[5m]))
  /
  sum(rate(http_server_requests_total{service="api"}[5m])) > 0.05
for: 2m
```

</div>

<p class="backup-note"><code>Numerator</code> — API requests returning 5xx, measured over five minutes.</p>
<p class="backup-note"><code>Denominator</code> — all API requests over the same window.</p>
<p class="backup-note"><code>for: 2m</code> — the ratio must remain above 5% for two minutes before firing.</p>

<!-- This is a representative alert rule for the demo. The numerator counts API requests returning a 5xx status over five minutes, and the denominator counts all API requests over the same window. The condition must remain true for two minutes before the alert fires. -->

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

| Element | Implementation |
|:--|:--|
| Kubernetes | K3S |
| Networking | Cilium with kube-proxy replaced |
| Packaging | Helm |
| Runtime | Airgapped |
| Build node | Captures and stages dependencies |
| Replay node | Runs the workshop demo inside the boundary |

<!-- The build node captures and stages dependencies while it is connected. We carry those artefacts to the replay node, where K3S, Cilium with kube-proxy replaced, and Helm run the demo without outbound access. -->

<!-- Backup B6 -->
---
layout: default
---

# Offline acceptance checklist

<div class="position-list">
  <div class="position-item"><span class="position-number">1.</span><div><strong class="position-lead">Capture.</strong><span class="position-detail">Charts, plugins, and tag-plus-digest images are verified before transfer.</span></div></div>
  <div class="position-item"><span class="position-number">2.</span><div><strong class="position-lead">Deploy.</strong><span class="position-detail">K3S, Cilium, Tetragon, and the observability stack install from local artefacts.</span></div></div>
  <div class="position-item"><span class="position-number">3.</span><div><strong class="position-lead">Verify.</strong><span class="position-detail">Metrics, logs, traces, profiles, Hubble flows, and dashboard datasources remain inside the boundary.</span></div></div>
</div>

<!-- This is the handoff: the build node is connected only during capture, and the replay node is accepted only after the complete verification scripts pass. -->
