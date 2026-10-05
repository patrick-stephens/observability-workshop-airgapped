=== BEGIN k3s-vendoring ===
artifact | version/URL | SHA-256 | status
--- | --- | --- | ---
k3s release | v1.37.1+k3s1 amd64; https://github.com/k3s-io/k3s/releases/tag/v1.37.1%2Bk3s1 | n/a | pinned
learner-k3s-binary-amd64 | https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/k3s | 92b94582eb7b34a8cf532e6006842b9ed215a6783cf56a3dd6271fd35243b2c0 | vendored and SHA-256 verified
learner-k3s-airgap-images-amd64.tar.zst | https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/k3s-airgap-images-amd64.tar.zst | 865b2a63ad7a63fc0db17b7fc2985bf4ae11d5ae93ca1472be6218d20aeb6b23 | vendored and SHA-256 verified
learner-k3s-install.sh | https://get.k3s.io | e5cc3b3d9dfc1662c2d9be6da5abc9a4cd317d6abc3a5ffc02e3dd3248207fee | vendored and SHA-256 verified
learner-k3s-images.txt | https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/k3s-images.txt | 377307d4039ccd04f0e27d2906595a8c7b7d49a79f7553c311f6f960ff3efb58 | vendored and SHA-256 verified
learner-k3s-selinux-rpm | 1.6-1.el8; https://rpm.rancher.io/k3s/stable/common/centos/8/noarch/k3s-selinux-1.6-1.el8.noarch.rpm | a1e24b0d82b1a6806cd420e2c0398a1796b055efe368fa4aebc8bb173850934f | vendored and SHA-256 verified
Registry probe (all eight HTTP 000 responses are connectivity failures: artifactory.internal is unresolved here, not image-not-found evidence):
image | tag | code
docker.io/rancher/klipper-helm:v0.13.3-build20260727 | v0.13.3-build20260727 | 000
docker.io/rancher/klipper-lb:v0.4.17 | v0.4.17 | 000
docker.io/rancher/local-path-provisioner:v0.0.37 | v0.0.37 | 000
docker.io/rancher/mirrored-coredns-coredns:1.14.7 | 1.14.7 | 000
docker.io/rancher/mirrored-library-busybox:1.37.0 | 1.37.0 | 000
docker.io/rancher/mirrored-library-traefik:3.7.13 | 3.7.13 | 000
docker.io/rancher/mirrored-metrics-server:v0.9.0 | v0.9.0 | 000
docker.io/rancher/mirrored-pause:3.10.2 | 3.10.2 | 000
Runtime constraint: k3s ctr does not honour registries.conf mirrors. Script 62 must explicitly pull through $DOCKER_REGISTRY, then run k3s ctr images tag to recreate the original image reference in k3s containerd.
Probe interpretation and ctr strategy are recorded in versions.lock; the probe measures mirror warm-cache confidence only.
=== END k3s-vendoring ===
=== BEGIN build-status-table ===
OpenTelemetry VERSION/[VERSION] contexts resolve to the vendored intro-to-instrumentation v1.4 archive root; the hello-otel builds are PRELOADABLE-VIA-VENDORED-CONTEXT.
otel-developers {VERSION} resolves to the vendored Java tracing v1.1 ZIP root; eligible builds have explicit extraction and docker build steps.
track | tag | status
--- | --- | ---
fluentbit | opensearch:fb-opensearch | INTERACTIVE
fluentbit | workshop-fb:v1 | INTERACTIVE
fluentbit | workshop-fb:v10 | INTERACTIVE
fluentbit | workshop-fb:v11 | INTERACTIVE
fluentbit | workshop-fb:v12 | INTERACTIVE
fluentbit | workshop-fb:v13 | INTERACTIVE
fluentbit | workshop-fb:v14 | INTERACTIVE
fluentbit | workshop-fb:v15 | INTERACTIVE
fluentbit | workshop-fb:v16 | INTERACTIVE
fluentbit | workshop-fb:v17 | INTERACTIVE
fluentbit | workshop-fb:v18 | INTERACTIVE
fluentbit | workshop-fb:v19 | INTERACTIVE
fluentbit | workshop-fb:v2 | INTERACTIVE
fluentbit | workshop-fb:v3 | INTERACTIVE
fluentbit | workshop-fb:v4 | INTERACTIVE
fluentbit | workshop-fb:v5 | INTERACTIVE
fluentbit | workshop-fb:v6 | INTERACTIVE
fluentbit | workshop-fb:v7 | INTERACTIVE
fluentbit | workshop-fb:v8 | INTERACTIVE
fluentbit | workshop-fb:v9 | INTERACTIVE
fluentbit | workshop-otel:v0.159 | INTERACTIVE
opentelemetry | hello-otel:auto | PRELOADABLE-VIA-VENDORED-CONTEXT
opentelemetry | hello-otel:auto-manual | PRELOADABLE-VIA-VENDORED-CONTEXT
opentelemetry | hello-otel:base | PRELOADABLE-VIA-VENDORED-CONTEXT
opentelemetry | hello-otel:manual | PRELOADABLE-VIA-VENDORED-CONTEXT
opentelemetry | hello-otel:metrics | PRELOADABLE-VIA-VENDORED-CONTEXT
opentelemetry | hello-otel:prog | PRELOADABLE-VIA-VENDORED-CONTEXT
opentelemetry | workshop-prometheus:v3.13.1 | PRELOADABLE-VIA-VENDORED-CONTEXT
otel-developers | java-demo | PRELOADABLE-VIA-VENDORED-DOWNLOAD
otel-developers | java-demo-prometheus:v3.13.1 | INTERACTIVE
otel-developers | java-demo:auto | PRELOADABLE-VIA-VENDORED-DOWNLOAD
otel-developers | java-demo:base | PRELOADABLE-VIA-VENDORED-DOWNLOAD
otel-developers | java-demo:java-tools | PRELOADABLE-VIA-VENDORED-DOWNLOAD
otel-developers | java-demo:manual | INTERACTIVE
otel-developers | java-demo:metrics | INTERACTIVE
prometheus | basic-java-metrics | PRELOADABLE-VIA-VENDORED-CONTEXT
prometheus | prometheus_services_demo:v1 | PRELOADABLE-VIA-VENDORED-DOWNLOAD
prometheus | workshop-prometheus:bad-target | PRELOADABLE-VIA-VENDORED-CONTEXT
prometheus | workshop-prometheus:v3.13 | PRELOADABLE-VIA-VENDORED-CONTEXT
=== END build-status-table ===
=== BEGIN expected-skips-final ===
Final expected-skip count: 0.
(empty; no expected build skips remain)
=== END expected-skips-final ===
=== BEGIN runtime-downloads ===
url=https://gitlab.com/o11y-workshops/opentelemetry-java-tracing-demo/-/archive/v1.1/opentelemetry-java-tracing-demo-v1.1.zip | sha256=86518c7cbc1d1966a4356b40a8e7ace3a5fba6d7360b1d09a7314345e967bb30 | vendored path=content/vendor/downloads/otel-developers/opentelemetry-java-tracing-demo-v1.1.zip | build=java-demo:auto | otel-developers/lab02.html | context=opentelemetry-java-tracing-demo-{VERSION} | dockerfile=Buildfile-AgentContainer
url=https://gitlab.com/o11y-workshops/opentelemetry-java-tracing-demo/-/archive/v1.1/opentelemetry-java-tracing-demo-v1.1.zip | sha256=86518c7cbc1d1966a4356b40a8e7ace3a5fba6d7360b1d09a7314345e967bb30 | vendored path=content/vendor/downloads/otel-developers/opentelemetry-java-tracing-demo-v1.1.zip | build=java-demo:java-tools | otel-developers/lab02.html | context=opentelemetry-java-tracing-demo-{VERSION} | dockerfile=Buildfile-AgentJavaTools
url=https://gitlab.com/o11y-workshops/opentelemetry-java-tracing-demo/-/archive/v1.1/opentelemetry-java-tracing-demo-v1.1.zip | sha256=86518c7cbc1d1966a4356b40a8e7ace3a5fba6d7360b1d09a7314345e967bb30 | vendored path=content/vendor/downloads/otel-developers/opentelemetry-java-tracing-demo-v1.1.zip | build=java-demo | otel-developers/lab02.html | context=opentelemetry-java-tracing-demo-{VERSION} | dockerfile=Buildfile
url=https://gitlab.com/o11y-workshops/opentelemetry-java-tracing-demo/-/archive/v1.1/opentelemetry-java-tracing-demo-v1.1.zip | sha256=86518c7cbc1d1966a4356b40a8e7ace3a5fba6d7360b1d09a7314345e967bb30 | vendored path=content/vendor/downloads/otel-developers/opentelemetry-java-tracing-demo-v1.1.zip | build=java-demo:base | otel-developers/lab02-rancher.html | context=opentelemetry-java-tracing-demo-{VERSION} | dockerfile=Buildfile
url=https://gitlab.com/o11y-workshops/opentelemetry-java-tracing-demo/-/archive/v1.1/opentelemetry-java-tracing-demo-v1.1.zip | sha256=86518c7cbc1d1966a4356b40a8e7ace3a5fba6d7360b1d09a7314345e967bb30 | vendored path=content/vendor/downloads/otel-developers/opentelemetry-java-tracing-demo-v1.1.zip | build=java-demo:auto | otel-developers/lab02-rancher.html | context=opentelemetry-java-tracing-demo-{VERSION} | dockerfile=Buildfile-AgentContainer
url=https://gitlab.com/o11y-workshops/opentelemetry-java-tracing-demo/-/archive/v1.1/opentelemetry-java-tracing-demo-v1.1.zip | sha256=86518c7cbc1d1966a4356b40a8e7ace3a5fba6d7360b1d09a7314345e967bb30 | vendored path=content/vendor/downloads/otel-developers/opentelemetry-java-tracing-demo-v1.1.zip | build=java-demo:java-tools | otel-developers/lab02-rancher.html | context=opentelemetry-java-tracing-demo-{VERSION} | dockerfile=Buildfile-AgentJavaTools
url=https://gitlab.com/o11y-workshops/prometheus-service-demo-installer/-/archive/v1.0/prometheus-service-demo-installer-v1.0.zip | sha256=a8098f487d651997ec8cf3a5322a8b70b3a3ac60d9edee4c740bf8b2351b0af1 | vendored path=content/vendor/downloads/prometheus/prometheus-service-demo-installer-v1.0.zip | build=prometheus_services_demo:v1 | prometheus/lab03-rancher.html | context=installs/demo | dockerfile=installs/demo/Buildfile
url=https://gitlab.com/o11y-workshops/prometheus-service-demo-installer/-/archive/v1.0/prometheus-service-demo-installer-v1.0.zip | sha256=a8098f487d651997ec8cf3a5322a8b70b3a3ac60d9edee4c740bf8b2351b0af1 | vendored path=content/vendor/downloads/prometheus/prometheus-service-demo-installer-v1.0.zip | build=prometheus_services_demo:v1 | prometheus/lab07-rancher.html | context=installs/demo | dockerfile=installs/demo/Buildfile
url=https://gitlab.com/o11y-workshops/prometheus-java-metrics-demo/-/archive/v0.5/prometheus-java-metrics-demo-v0.5.zip | sha256=806746b3b2565d3a8cd3bc02611814b27b2a87a22bde652d33eb60ac4fb5c302 | vendored path=content/vendor/downloads/prometheus/prometheus-java-metrics-demo-v0.5.zip | build=<untagged> | prometheus/lab08-rancher.html | context=prometheus-java-metrics-demo-v0.5 | dockerfile=Dockerfile
=== END runtime-downloads ===
=== BEGIN curated.json ===
{
  "opentelemetry": {
    "runs": [
      {
        "name": "jaeger",
        "exec": "docker",
        "image": "docker.io/jaegertracing/all-in-one:1.76.0",
        "ports": [
          "16686:16686"
        ],
        "env": {},
        "volumes": [],
        "cmd": [],
        "check": {
          "url": "http://localhost:16686",
          "expect": "Jaeger"
        },
        "exec_adaptations": [
          "Preserve the source podman play-kube operation through the rootful Podman runtime; this manifest start is not rewritten as docker run.",
          "Use the verified vendored Podman Pod manifest path instead of the source-relative programmatic/app_pod.yaml path.",
          "This is `podman play kube` for kind: Pod; it is not a kubectl/k3s workflow."
        ],
        "source": {
          "file": "lab04.html",
          "path_type": "docker",
          "engine": "podman",
          "raw": "$ podman play kube programmatic/app_pod.yaml",
          "cwd": ".",
          "manifest": "content/repos/opentelemetry/_vendored/app_pod.yaml",
          "manifest_present_in_repo": true,
          "manifest_kind": "Podman-native Pod",
          "manifest_source": "https://gitlab.com/o11y-workshops/intro-to-instrumentation/-/archive/v1.4/intro-to-instrumentation-v1.4.zip",
          "manifest_sha256": "47e8ded410413f08de1ae446c7a89f6c47a21d035375e0df16ae4b770a4cd597"
        },
        "verify_time_prep": [
          "Run `podman play kube content/repos/opentelemetry/_vendored/app_pod.yaml`; its kind: Pod resource is handled by Podman and does not require k3s.",
          "The manifest starts localhost/hello-otel:prog plus jaegertracing/all-in-one:1.76.0; the app image is built by the earlier lab command."
        ],
        "images": [
          "localhost/hello-otel:prog",
          "docker.io/jaegertracing/all-in-one:1.76.0"
        ]
      },
      {
        "name": "hello-otel-app",
        "exec": "docker",
        "image": "hello-otel:prog",
        "ports": [
          "8001:8000"
        ],
        "env": {
          "FLASK_RUN_PORT": "8000"
        },
        "volumes": [],
        "cmd": [],
        "check": {
          "type": "running",
          "url": "http://localhost:8001/",
          "reason": "The lab describes the root endpoint as a page-view counter; use container-running readiness because the displayed count changes per request."
        },
        "exec_adaptations": [
          "Use the docker shim for the source Podman command; both resolve to the same rootful Podman image store.",
          "-d added so the service remains available for verification.",
          "Interactive/TTY flags removed because verification has no interactive terminal."
        ],
        "source": {
          "file": "lab03.html",
          "path_type": "docker",
          "engine": "podman",
          "raw": "$ podman run -i -p 8001:8000 -e FLASK_RUN_PORT=8000 hello-otel:prog",
          "cwd": "."
        }
      },
      {
        "name": "otel-manifest",
        "requires_k3s": true,
        "exec": "kubectl",
        "steps": [
          "kubectl apply -f content/repos/opentelemetry/_vendored/app_pod.yaml",
          "kubectl wait --for=condition=Ready pod/hello-otel --timeout=120s",
          "kubectl port-forward --address 127.0.0.1 pod/hello-otel 18080:16686"
        ],
        "check": {
          "url": "http://localhost:18080",
          "expect": "Jaeger"
        },
        "exec_adaptations": [
          "The lab's Rancher path runs kubectl against k3s; execution requires the planned k3s-enabled learner VM.",
          "Manifest source path programmatic/app_pod.yaml is replaced by the verified vendored path.",
          "Manifest provides pod name 'hello-otel'; it defines no namespace (default namespace) and no labels (none), so wait targets the named Pod directly.",
          "Manifest Jaeger containerPort 16686 is forwarded to collision-free host port 18080; source manifest hostPort is not used for the host check."
        ],
        "source": {
          "file": "lab04-rancher.html",
          "path_type": "rancher",
          "engine": "kubectl",
          "raw": "$ kubectl apply -f programmatic/app_pod.yaml",
          "manifest": "content/repos/opentelemetry/_vendored/app_pod.yaml",
          "manifest_source": "https://gitlab.com/o11y-workshops/intro-to-instrumentation/-/archive/v1.4/intro-to-instrumentation-v1.4.zip",
          "manifest_sha256": "47e8ded410413f08de1ae446c7a89f6c47a21d035375e0df16ae4b770a4cd597"
        }
      }
    ],
    "unresolved": [],
    "notes": []
  },
  "otel-developers": {
    "runs": [
      {
        "name": "jaeger",
        "exec": "docker",
        "image": "jaegertracing/all-in-one:1.76.0",
        "ports": [
          "16686:16686",
          "4317:4317",
          "4318:4318"
        ],
        "env": {
          "COLLECTOR_OTLP_ENABLED": "true"
... [excerpt capped at 120 lines; complete JSON: content/extracted/curated.json]
=== END curated.json ===
=== BEGIN learner-vm/lab-vm.conf ===
# Operator-tunable values for the RHEL 8.6 learner VM.
HOSTNAME="o11y-lab.internal"
# Empty keeps the base image network configuration.
STATIC_IP=""
# Artifactory hostname used for registry and package repository checks.
ART_HOST="artifactory.internal"
# One anonymous pull-through endpoint for docker.io, ghcr.io, and quay.io.
DOCKER_REGISTRY="${ART_HOST}/artifactory/docker-registry"
# Optional Artifactory address; 30-ca-and-trust.sh can add it to /etc/hosts to bypass DNS.
ART_HOST_IP=""
# CA certificate installed in the operating system trust store.
CA_CERT_SOURCE="/etc/pki/ca-trust/source/anchors/airgap-ca.crt"
# ISO file path or CD-ROM device path attached to the VM.
ISO_PATH="/dev/cdrom"
# Existing workshop account used by the provisioning scripts.
WORKSHOP_USER="engineer"
# Required by the non-interactive auto-elevate wrappers in script 50.
PASSWORDLESS_SUDO="yes"
AUTOLOGIN="yes"
# Browser used to open workshop materials on the VM.
BROWSER="firefox"
# In-VM docs server port; Perses uses host port 8080 in its labs.
DOCS_PORT="8090"
# 11r: docs server + START-HERE must use $DOCS_PORT, never 8080 (Perses owns 8080).
=== END learner-vm/lab-vm.conf ===
=== BEGIN versions.lock-delta ===
runtime-download.otel-developers.opentelemetry-java-tracing-demo-v1.1.zip sha256:86518c7cbc1d1966a4356b40a8e7ace3a5fba6d7360b1d09a7314345e967bb30 - source=https://gitlab.com/o11y-workshops/opentelemetry-java-tracing-demo/-/archive/v1.1/opentelemetry-java-tracing-demo-v1.1.zip path=content/vendor/downloads/otel-developers/opentelemetry-java-tracing-demo-v1.1.zip
runtime-download.prometheus.prometheus-java-metrics-demo-v0.5.zip sha256:806746b3b2565d3a8cd3bc02611814b27b2a87a22bde652d33eb60ac4fb5c302 - source=https://gitlab.com/o11y-workshops/prometheus-java-metrics-demo/-/archive/v0.5/prometheus-java-metrics-demo-v0.5.zip path=content/vendor/downloads/prometheus/prometheus-java-metrics-demo-v0.5.zip
runtime-download.prometheus.prometheus-service-demo-installer-v1.0.zip sha256:a8098f487d651997ec8cf3a5322a8b70b3a3ac60d9edee4c740bf8b2351b0af1 - source=https://gitlab.com/o11y-workshops/prometheus-service-demo-installer/-/archive/v1.0/prometheus-service-demo-installer-v1.0.zip path=content/vendor/downloads/prometheus/prometheus-service-demo-installer-v1.0.zip
workshop.reveal.js-menu 2.1.0 - source=https://registry.npmjs.org/reveal.js-menu/-/reveal.js-menu-2.1.0.tgz menu.js-sha256=975e1d92515c5b99966abeb0ffd29a5b47d655eadfde662bed6b74fab5f31400; copied into all five documentation mirrors and all five repository trees.
learner-k3s v1.37.1+k3s1 - official release https://github.com/k3s-io/k3s/releases/tag/v1.37.1%2Bk3s1; stable amd64 pin for learner VM.
learner-k3s-binary-amd64 sha256:92b94582eb7b34a8cf532e6006842b9ed215a6783cf56a3dd6271fd35243b2c0 - source=https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/k3s path=content/vendor/k3s/k3s.
learner-k3s-airgap-images-amd64.tar.zst sha256:865b2a63ad7a63fc0db17b7fc2985bf4ae11d5ae93ca1472be6218d20aeb6b23 - source=https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/k3s-airgap-images-amd64.tar.zst path=content/vendor/k3s/k3s-airgap-images-amd64.tar.zst.
learner-k3s-install.sh sha256:e5cc3b3d9dfc1662c2d9be6da5abc9a4cd317d6abc3a5ffc02e3dd3248207fee - source=https://get.k3s.io path=content/vendor/k3s/install.sh; vendored for offline provisioning, not executed here.
learner-k3s-images.txt sha256:377307d4039ccd04f0e27d2906595a8c7b7d49a79f7553c311f6f960ff3efb58 - source=https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/k3s-images.txt path=content/vendor/k3s/k3s-images.txt.
learner-k3s-selinux-rpm sha256:a1e24b0d82b1a6806cd420e2c0398a1796b055efe368fa4aebc8bb173850934f - version=1.6-1.el8 source=https://rpm.rancher.io/k3s/stable/common/centos/8/noarch/k3s-selinux-1.6-1.el8.noarch.rpm path=content/vendor/k3s/k3s-selinux-1.6-1.el8.noarch.rpm.
learner-k3s-registry-probe all-8-http-000 - online host cannot resolve artifactory.internal; see content/vendor/k3s/registry-probe.txt. Script 62 must explicitly pull from $DOCKER_REGISTRY then use k3s ctr images tag to the original reference; ctr does NOT honor registries.conf mirrors. Probe outcome measures mirror warm-cache confidence only.
=== END versions.lock-delta ===
