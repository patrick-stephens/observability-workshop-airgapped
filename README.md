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

## Local Checks

The pre-commit configuration uses the pinned upstream hook repositories listed
in `versions.lock`. On the connected build node, provision pre-commit 4.2.0,
then run `bash scripts/00-install-hooks.sh` to validate the config and fetch the
pinned hook environments. The script installs Git hooks unless a custom
`core.hooksPath` is already configured; it leaves an existing hooks path
unchanged. Subsequent checks use the installed environments without outbound
access. For offline use on another node, transfer the pre-commit cache from
`$HOME/.cache/pre-commit` along with the captured tools.

Before completing a change, run `pre-commit run --all-files` and confirm it
passes. This runs all applicable file hooks; the Conventional Commits hook is
run for commit messages when a commit is created.

## Current State

This repository is a skeleton. The only script is
`scripts/00-install-hooks.sh`, which validates the hook config and installs its
pinned environments and Git hooks. No bootstrap or demo scripts exist yet. No
charts or Kubernetes manifests exist, and no resources are installed or
applied. Accordingly, there are no active teardowns; every future
`kubectl apply` or `helm install` must have its matching teardown documented
here.

`versions.lock` records the pinned local development tools and the reason for
each dependency.
