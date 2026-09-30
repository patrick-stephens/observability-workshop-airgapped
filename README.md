# Airgapped Observability Workshop

This repository contains the source and offline artefacts for a live observability workshop demo, presented on an Ubuntu VM running K3S and replayed on a network-isolated node. The repository is designed so the environment can be prepared on a build node, then deployed and operated without outbound network access.

## Demo Premise

The demo follows one incident across four layers: the application, Kubernetes, the telemetry pipeline, and the observability backend. Three deliberate breaks show how symptoms from one incident appear across those layers.

## Build and Replay Nodes

The build node is used for the initial capture of dependencies and artefacts. This is the only stage allowed outbound network access. Captured artefacts are transferred with the repository to the replay node.

The replay node is the Ubuntu VM running K3S where the workshop demo is presented and replayed offline. It must deploy from the captured artefacts and operate without outbound network access.

## Directory Map

- `charts/`: vendored Helm `.tgz` archives; never fetched during install.
- `values/`: one values file per chart.
- `manifests/`: Kubernetes objects applied directly.
- `scripts/`: numbered, idempotent bootstrap and demo scripts.
- `app/`: demo application source.
- `bundle/`: output from offline capture; generated contents are gitignored.
- `docs/`: speaker notes and runbooks.

## Current State

This repository is a skeleton. No scripts exist yet, so there are no scripts to run. No charts or Kubernetes manifests exist, and no resources are installed or applied. Accordingly, there are no active teardowns; every future `kubectl apply` or `helm install` must have its matching teardown documented here.

`versions.lock` currently has no dependency entries. Add dependencies only with an explicit instruction, recording the reason for each entry.
