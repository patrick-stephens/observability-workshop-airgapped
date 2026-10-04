=== BEGIN selftest-report ===
==================== REPORT BEGIN ====================
SCRIPT: 00-diagnose 3
HOST: selftest synthetic git: not-read
RESULT: FAILED (ok=2 failed=1 skipped=1)
F1: synthetic dependency failure | FIX: Install the missing dependency from learner-vm/lab-vm.conf. | DIAG[printf 'synthetic diagnostic output\n']: synthetic diagnostic output | DIAG[lab-selftest-command-that-does-not-exist]: bash: line 1: lab-selftest-command-that-does-not-exist: command not found
OK: 2 steps — full log: /var/log/lab-setup/00-diagnose.log
SKIPPED (1): optional self-test tool (synthetic optional dependency is absent)
NEXT: transcribe this report block; provisioning scripts (10-80) are finalised after this report is reviewed
==================== REPORT END ======================
=== END selftest-report ===
=== BEGIN grep-audits ===
$ grep -rn docker-ce learner-vm/scripts learner-vm/lab-vm.conf
(no matches)
$ grep -rn /etc/docker learner-vm/scripts
(no matches)
$ grep -rn daemon.json learner-vm/scripts
(no matches)
$ grep -rn registry-mirrors learner-vm/scripts
(no matches)
=== END grep-audits ===
=== BEGIN lab-vm.conf ===
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
=== END lab-vm.conf ===
=== BEGIN README-FIRST.md ===
# Learner VM: First Run

This directory contains the operator configuration and read-only diagnostics for the RHEL 8.6 offline observability workshop VM.
The root-level scripts manage a separate Ubuntu K3s replay VM.

The learner VM uses rootful Podman only; the `docker` command is the `podman-docker` shim installed by script 20.
All lab images are preloaded into the same rootful image store, so workshop operation requires no runtime pulls.
All upstream registries use the single Artifactory endpoint in `lab-vm.conf`; pulls are anonymous and images remain under their original references.
The base image supplies OS CA trust, DNF repositories, hostname, and network configuration; script 30 installs the Podman registry CA file.

## Transfer and Run Order

On the connected machine, prepare and commit the complete repository and the `content/` artifacts before transferring them to the VM.
Copy the repository, including `learner-vm/`, `content/`, and `versions.lock`, to the RHEL VM.
Edit `learner-vm/lab-vm.conf` only when an operator-tunable value differs from the supplied default; content paths are derived from the repository location and must not be configured here.
Run the scripts as the human operator, with `sudo`, in this order: `00-diagnose.sh`, `10-preflight.sh`, `20-install-tooling.sh`, `30-ca-and-trust.sh`, `40-podman-config.sh`, `50-user-setup.sh`, `60-load-images.sh`, `70-quickstart.sh`, and `80-verify-offline.sh`.
The later numbered provisioning scripts are authored and reviewed as artifacts; they are not run by an AI agent on the VM.
Review each report and follow its `NEXT` line before continuing; after script 80 passes, shut down cleanly and snapshot the VM as the shipped artifact.

## Transcription Protocol

For each run, copy the complete text from `==================== REPORT BEGIN ====================` through `==================== REPORT END ======================` into the online feedback record without editing the report.
Transcribe, do not improvise: follow the `NEXT` line and report evidence rather than making undocumented VM changes.
If a script reports a failure, transcribe the block and stop until the online team reviews it.
Every provisioning script is idempotent; reruns are safe after following the report guidance.

Example report block:

```text
==================== REPORT BEGIN ====================
SCRIPT: 00-diagnose 3
HOST: o11y-lab.internal 2026-10-04T12:00:00Z git: 0123456
RESULT: FAILED (ok=2 failed=1 skipped=1)
F1: registry unavailable | FIX: Check DOCKER_REGISTRY in learner-vm/lab-vm.conf | DIAG[getent hosts artifactory.internal]: 192.0.2.10 artifactory.internal
OK: 2 steps - full log: /var/log/lab-setup/00-diagnose.log
SKIPPED (1): optional binary absent (skopeo inventory)
NEXT: transcribe this report block; provisioning scripts (10-80) are finalised after this report is reviewed
==================== REPORT END ======================
```

## Online Feedback

On the connected side, create `feedback/airgap-run-00N.md` for each operator VM run, incrementing `00N` for each new record.
Record the date, VM/RHEL version, relevant configuration changes, and the exact `SCRIPT_VERSION` values run.
Paste each complete report block and add concise operator observations outside it; do not replace report evidence with a summary.
Before changing learner-VM scripts, read feedback records newest first and inspect the current version comment in each affected script.
=== END README-FIRST.md ===
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
        },
        "volumes": [],
        "cmd": [],
        "check": {
          "url": "http://localhost:16686",
          "expect": "Jaeger"
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
          "raw": "$ podman run --rm -it --name jaeger \\\n-p 16686:16686 \\\n-p 4317:4317 \\\n-p 4318:4318 \\\n-e COLLECTOR_OTLP_ENABLED=true \\\njaegertracing/all-in-one:1.76.0",
          "cwd": "."
        }
      }
    ],
    "unresolved": [],
    "notes": []
  },
  "prometheus": {
    "runs": [
      {
        "name": "prometheus",
        "exec": "docker",
        "image": "workshop-prometheus:v3.13",
        "ports": [
          "9090:9090"
        ],
        "env": {},
        "volumes": [],
        "cmd": [
          "--config.file=/etc/prometheus/workshop-prometheus.yml"
        ],
        "check": {
          "url": "http://localhost:9090/-/ready",
          "expect": "Prometheus"
        },
        "exec_adaptations": [
          "Use the docker shim for the source Podman command; both resolve to the same rootful Podman image store.",
          "-d added so the service remains available for verification."
        ],
        "source": {
          "file": "lab05.html",
          "path_type": "docker",
          "engine": "podman",
          "raw": "$ podman run -p 9090:9090 workshop-prometheus:v3.13 --config.file=/etc/prometheus/workshop-prometheus.yml",
          "cwd": "."
        }
      },
      {
        "name": "prometheus-services-demo",
        "exec": "docker",
        "image": "prometheus_services_demo:v1",
        "ports": [
          "8080:8080"
        ],
        "env": {},
        "volumes": [],
        "cmd": [],
        "check": {
          "type": "running",
          "reason": "The lab documents the container port mapping but does not give a stable response substring for this service."
        },
        "exec_adaptations": [
          "Use the docker shim for the source Podman command; both resolve to the same rootful Podman image store.",
          "-d added so the service remains available for verification."
        ],
        "source": {
          "file": "lab03-podman.html",
          "path_type": "podman",
          "engine": "podman",
          "raw": "$ podman run -p 8080:8080 prometheus_services_demo:v1",
          "cwd": ".",
          "build_sources": [
... [truncated, full file at content/extracted/curated.json] ...
              "raw": "$ docker build  -t prometheus_services_demo:v1 -f installs/demo/Buildfile installs/demo"
            }
          ]
        }
      }
    ],
    "unresolved": [],
    "notes": []
  },
  "fluentbit": {
    "runs": [
      {
        "name": "fluentbit",
        "exec": "docker",
        "image": "workshop-fb:v7",
        "ports": [
          "9999:9999"
        ],
        "env": {},
        "volumes": [],
        "cmd": [],
        "check": {
          "type": "running",
          "reason": "The lab run publishes host port 9999 but does not document a stable HTTP response substring for this container."
        },
        "exec_adaptations": [
          "Use the docker shim for the source Podman command; both resolve to the same rootful Podman image store.",
          "-d added so the service remains available for verification."
        ],
        "source": {
          "file": "lab04.html",
          "path_type": "docker",
          "engine": "podman",
          "raw": "$ podman run --rm -p 9999:9999 workshop-fb:v7",
          "cwd": "."
        }
      }
    ],
    "unresolved": [],
    "notes": [
      "No container run publishes host port 2020; lab04.html runs workshop-fb:v7 with `-p 9999:9999`, so the curated check is container-running rather than an invented metrics URL."
    ]
  },
  "perses": {
    "runs": [
      {
        "name": "perses",
        "exec": "docker",
        "image": "persesdev/perses:v0.54.0",
        "ports": [
          "127.0.0.1:8080:8080"
        ],
        "env": {},
        "volumes": [],
        "cmd": [],
        "check": {
          "url": "http://localhost:8080",
          "expect": "Perses"
        },
        "exec_adaptations": [
          "Use the docker shim for the source Podman command; both resolve to the same rootful Podman image store.",
          "-d added so the service remains available for verification."
        ],
        "source": {
          "file": "lab02-podman.html",
          "path_type": "podman",
          "engine": "podman",
          "raw": "$ podman run --name perses --rm -p 127.0.0.1:8080:8080 persesdev/perses:v0.54.0",
          "cwd": "."
        },
        "verify_time_prep": [
          "Run the lab's pod creation command before its container commands if the shared datasource pod is needed.",
          "Lab archive link: https://gitlab.com/o11y-workshops/perses-install-demo/-/archive/v1.10/perses-install-demo-v1.10.zip"
        ]
      },
      {
        "name": "prometheus",
        "exec": "docker",
        "image": "docker.io/prom/prometheus:v3.13.1",
        "ports": [
          "127.0.0.1:9090:9090"
        ],
        "env": {},
        "volumes": [
          "$(pwd)/support/workshop-prometheus.yml:/etc/prometheus/prometheus.yml:ro,Z"
        ],
        "cmd": [],
        "check": {
          "url": "http://localhost:9090/-/ready",
          "expect": "Prometheus"
        },
        "exec_adaptations": [
          "Use the docker shim for the source Podman command; both resolve to the same rootful Podman image store."
        ],
        "source": {
          "file": "lab05-podman.html",
          "path_type": "podman",
          "engine": "podman",
          "raw": "$ podman run -d --pod workshop-datasource --name prometheus \\\n-v \"$(pwd)/support/workshop-prometheus.yml:/etc/prometheus/prometheus.yml:ro,Z\" \\\ndocker.io/prom/prometheus:v3.13.1",
          "cwd": ".",
          "pod_create_raw": "$ podman pod create --name workshop-datasource \\\n-p 127.0.0.1:9090:9090 \\\n-p 127.0.0.1:9100:9100"
        },
        "verify_time_prep": [
          "Ensure support/workshop-prometheus.yml exists; the exact source run mounts this lab-provided configuration read-only.",
          "Lab archive link: https://gitlab.com/o11y-workshops/perses-install-demo/-/archive/v1.10/perses-install-demo-v1.10.zip"
        ]
      },
      {
        "name": "node-exporter",
        "exec": "docker",
        "image": "quay.io/prometheus/node-exporter:v1.12.1",
        "ports": [
          "127.0.0.1:9100:9100"
        ],
        "env": {},
        "volumes": [],
        "cmd": [],
        "check": {
          "url": "http://localhost:9100/metrics",
          "expect": "node_"
        },
        "exec_adaptations": [
          "Use the docker shim for the source Podman command; both resolve to the same rootful Podman image store.",
          "Host port 9100 is published by the source pod-create command; the container command itself joins that pod."
        ],
        "source": {
          "file": "lab05-podman.html",
          "path_type": "podman",
          "engine": "podman",
          "raw": "$ podman run -d --pod workshop-datasource --name node-exporter \\\nquay.io/prometheus/node-exporter:v1.12.1",
          "cwd": ".",
          "pod_create_raw": "$ podman pod create --name workshop-datasource \\\n-p 127.0.0.1:9090:9090 \\\n-p 127.0.0.1:9100:9100"
        }
      }
    ],
    "unresolved": [],
    "notes": []
  }
}
=== END curated.json ===
=== BEGIN build-failures-expected.txt ===
prometheus/lab02-podman.html: context=workshop-prometheus cwd=workshop-prometheus command=$ podman build -t workshop-prometheus:v3.13 -f Buildfile
prometheus/lab02-podman.html: context=workshop-prometheus cwd=workshop-prometheus command=$ podman build -t workshop-prometheus:bad-target -f Buildfile
=== END build-failures-expected.txt ===
=== BEGIN runtime-downloads.txt ===
otel-developers/lab02.html: context=opentelemetry-java-tracing-demo-{VERSION} urls=https://gitlab.com/o11y-workshops/opentelemetry-java-tracing-demo/-/archive/v1.1/opentelemetry-java-tracing-demo-v1.1.zip
otel-developers/lab02-rancher.html: context=opentelemetry-java-tracing-demo-{VERSION} urls=https://gitlab.com/o11y-workshops/opentelemetry-java-tracing-demo/-/archive/v1.1/opentelemetry-java-tracing-demo-v1.1.zip
prometheus/lab03-rancher.html: context=installs/demo urls=https://gitlab.com/o11y-workshops/prometheus-service-demo-installer/-/archive/v1.0/prometheus-service-demo-installer-v1.0.zip
prometheus/lab07-rancher.html: context=installs/demo urls=https://gitlab.com/o11y-workshops/prometheus-service-demo-installer/-/archive/v1.0/prometheus-service-demo-installer-v1.0.zip
prometheus/lab08-podman.html: context=prometheus-java-metrics-demo-v0.5 urls=https://gitlab.com/o11y-workshops/prometheus-java-metrics-demo/-/archive/v0.5/prometheus-java-metrics-demo-v0.5.zip
prometheus/lab08-podman.html: context=prometheus-java-metrics-demo-v0.5/prometheus-java-metrics-demo-v0.5 urls=https://gitlab.com/o11y-workshops/prometheus-java-metrics-demo/-/archive/v0.5/prometheus-java-metrics-demo-v0.5.zip
prometheus/lab08-rancher.html: context=prometheus-java-metrics-demo-v0.5 urls=https://gitlab.com/o11y-workshops/prometheus-java-metrics-demo/-/archive/v0.5/prometheus-java-metrics-demo-v0.5.zip
prometheus/lab08-rancher.html: context=prometheus-java-metrics-demo-v0.5/prometheus-java-metrics-demo-v0.5 urls=https://gitlab.com/o11y-workshops/prometheus-java-metrics-demo/-/archive/v0.5/prometheus-java-metrics-demo-v0.5.zip
=== END runtime-downloads.txt ===
=== BEGIN docs-patched.txt ===
opentelemetry: docs_pages=12 repo_pages=12 banners_present=24 pull_markers_present=0 docker_build_load_notes=0 docs+0 repo load_rewrites_this_run=0
otel-developers: docs_pages=12 repo_pages=12 banners_present=24 pull_markers_present=0 docker_build_load_notes=0 docs+0 repo load_rewrites_this_run=0
prometheus: docs_pages=23 repo_pages=23 banners_present=46 pull_markers_present=0 docker_build_load_notes=10 docs+10 repo load_rewrites_this_run=0
fluentbit: docs_pages=19 repo_pages=19 banners_present=38 pull_markers_present=0 docker_build_load_notes=0 docs+0 repo load_rewrites_this_run=0
perses: docs_pages=16 repo_pages=16 banners_present=32 pull_markers_present=0 docker_build_load_notes=0 docs+0 repo load_rewrites_this_run=0
=== END docs-patched.txt ===
=== BEGIN docs-gaps.txt ===
(empty)
=== END docs-gaps.txt ===
