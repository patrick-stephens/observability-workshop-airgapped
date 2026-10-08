# Learner Dependency Bundle

## Scope

The RHEL learner workflow uses prebuilt final lab images, local package-manager caches and verified generic downloads delivered separately from Git as one GitHub Release tarball.
This is separate from the Ubuntu presenter demo and installer ISO.
The outer archive contains a multi-image Docker-save archive, not a set of independently duplicated image archives.
The learner VM receives the release asset through the approved transfer process and does not download from GitHub.
The capture host may use public upstreams with explicit operator approval; the learner uses offline caches or an explicitly selected Artifactory profile, never public fallback.
Capturing and publishing are separate actions, and publication requires an explicit release repository and tag.

## Bundle Contract

The archive must include an inventory identifying the source commit, architecture, image references/config IDs, package-manager versions, cache contents, build contexts, generic downloads and lab coverage.
Every regular file must have a recorded SHA-256, and the outer archive has a separate trusted checksum configured through `DEPENDENCY_BUNDLE_SHA256`.
Large generated archives and caches stay outside Git.
Safe import rejects traversal, absolute paths, unexpected links and unsupported archive members before extraction.
Incomplete or corrupt bundles must not replace an installed, verified bundle.
No credentials, authenticated URLs, private keys or connected-machine home-directory caches may enter the release asset.
Preserve redistribution notices and review upstream licences before public publication.

## Capture Requirements

Build all covered standard/Rancher lab variants from their actual recipes, not only the current extracted command metadata.
Prepare Java application JARs with Maven before image recipes copy them; the source ZIPs contain no prebuilt JARs.
Capture the exact OpenTelemetry agent JAR and use local copies rather than remote Dockerfile `ADD` in derived build contexts.
Capture wheels for the container's Python version and architecture, including transitive dependencies and bootstrap-selected instrumentation.
Capture Maven dependencies, parent POMs, BOMs, lifecycle/test plugins and plugin dependencies for each recorded goal/POM variant.
Capture Go modules and checksum material, including the service demo's `golang:1.17-alpine` builder and `alpine:3` runtime stages.
Capture Perses source-build npm and Go dependencies and its plugin downloads, not just the final Perses image.
The capture workflow verifies the workshop-referenced `fluentbit-install-demo` v2.9 archive by SHA-256, uses its lab 3–7 and lab 10 configs for the corresponding image stages, and derives the documented intermediate Fluent Bit configs where that archive only carries a final-stage snapshot.
Every generated Fluent Bit/OpenSearch and OTel collector config is parsed by its pinned image before the network-disabled image build.
Keep coverage tag-specific: alias only stages whose documented runtime configuration is unchanged, and preserve distinct tags for each edited configuration stage.
Resolve the captured programmatic Python recipe discrepancy before claiming learner-edited variants are covered; `basic-java-metrics` now builds from its actual Prometheus Java metrics project, separately from OTel `java-demo:metrics`.
Use derived contexts/explicit patches rather than rewriting captured upstream sources.

## Offline Profiles

| Manager | Required offline configuration |
| --- | --- |
| pip | `PIP_NO_INDEX=1`, `PIP_FIND_LINKS` pointing at the verified wheelhouse inside the build stage, and locked/hash-verified requirements. |
| Maven | A learner-owned working copy of the captured local repository and `mvn -o -Dmaven.repo.local=<cache>` for the exact goals/profiles. |
| npm | A captured cache with the matching Node/npm version; use `--offline --cache <cache>` and validate lockfile URLs and lifecycle downloads. |
| Go | A captured module proxy/cache, `GOPROXY=file://<proxy>` without `direct`, retained `go.sum` and checksum verification material. |
| Generic files | Verified local JARs, ZIPs and plugins copied into build contexts or read from installed bundle paths. |

Configure host tools, sudo sessions and every image build stage separately; host environment/configuration does not automatically propagate into image builds.
Container `localhost` is not the host, so any optional local cache server needs a deliberately reachable hostname/address.
Prefer filesystem caches to avoid introducing a repository-server bootstrap dependency.
The offline profile treats the verified downloaded cache as authoritative regardless of age: pip uses the wheelhouse without an index and disables its version check, Maven runs offline with `never` update policies and no snapshot updates, npm runs offline with stale-cache preference and background audit/funding/update checks disabled, and Go uses the file proxy without network fallback.
Keep Maven's capture/replay mirror ID stable so repository provenance tracking does not reject otherwise present cached artefacts.
In explicitly connected Artifactory mode, npm prefers cached data without freshness checks and Maven avoids scheduled updates, but missing dependencies may still require the approved repository.
pip does not promise cache-first selection when an index is enabled; strict cache-only installs must select the offline profile, and unpinned/new requirements need reviewed recapture.
Go module versions and checksums do not expire; preserve their integrity data and prohibit automatic toolchain downloads rather than disabling verification.
These settings do not disable cache integrity, lockfile/checksum checks, TLS certificate expiry or signature validation, and cannot override Artifactory's server-side cache retention policy.
Never use a warmed developer cache as evidence that a supplied cache is complete.
Do not disable Go checksums or permit automatic toolchain/public downloads to hide an incomplete cache.
Preserve SELinux enforcing and restrictive kubeconfig permissions.

## Optional Artifactory Profiles

The package endpoints below are independently configurable in `lab-vm.conf` and do not use `DOCKER_REGISTRY`.
The administrator supplied these path defaults; verify the PyPI endpoint's repository-key layout on the actual deployment before relying on it.

| Setting | Default |
| --- | --- |
| `ART_PYPI_INDEX_URL` | `https://${ART_HOST}/artifactory/api/pypi/simple` |
| `ART_MAVEN_URL` | `https://${ART_HOST}/artifactory/maven/maven2` |
| `ART_NPM_URL` | `https://${ART_HOST}/artifactory/api/npm/node-js` |
| `ART_GO_PROXY_URL` | `https://${ART_HOST}/artifactory/api/go/gocenter` |
| `ART_PACKAGE_CA_CERT` | Empty: use the configured client/system trust. |

Use pip's single approved index without a public `extra-index-url`.
Use a Maven `settings.xml` mirror with `mirrorOf` set to `*`, and configure the approved CA in Java trust where OS trust is insufficient.
Use npm registry/scope configuration with `strict-ssl=true`, checking lockfile `resolved` URLs and install scripts for bypasses.
Use Go's approved proxy with no `direct` fallback and an explicitly agreed checksum-service/private-module policy.
Do not infer package endpoints from a generic host or Docker registry URL.
Do not copy connected-machine credentials into the VM, caches, image layers, build arguments or reports.
Self-signed certificates should use the approved CA rather than disabling verification; insecure capture exceptions must be explicit and never become a learner default.
Artifactory reachability and cache completeness are independent checks; partial repositories are not an offline guarantee.

## Import and Validation

Configure the separately transferred archive path, trusted outer checksum and versioned installation root through `DEPENDENCY_BUNDLE_PATH`, `DEPENDENCY_BUNDLE_SHA256` and `DEPENDENCY_BUNDLE_ROOT`.
An empty checksum means the aggregate import is not enabled and the existing per-image workflow remains available.
Verify the outer checksum, validate archive paths, extract to a new staging directory, verify inner checksums and inventory, then activate the bundle.
Load the nested image archive into rootful Podman and verify every expected reference/config ID.
Populate k3s using the existing Podman save/import route and verify exact references in the separate containerd store.
Retain local caches/generic files for interactive builds even when ordinary provisioning uses final prebuilt images.
The Perses datasource lab also requires the workshop installer archive, not just Perses application source or its container image.
The connected capture's `lab-files` component verifies `perses-install-demo-v1.10.zip` against `capture.perses-install-demo.sha256` in `versions.lock`, records provenance in `lab-files-inventory.json`, and extracts the lab under `build-contexts/perses-lab`.
The archive is retained under `downloads` for learner replay; its `support/workshop-prometheus.yml` must be available in the Perses lab working directory before running the documented bind-mount command.
The disposable AlmaLinux `curated-test` helper prepares these support files from the verified installed bundle without downloading anything inside the guest.
Reruns must reuse matching installed artefacts and never erase unrelated image stores, cluster data or learner files.

The acceptance gate is a clean environment with upstream and Artifactory access blocked, using only the verified bundle as dependency input.
Exercise every baseline image and documented host/container build, including pip bootstrap, Maven plugins, npm lifecycle hooks and Go checksum handling.
Record supported architecture/toolchains, exact lab coverage and excluded exercises; fail publication on incomplete declared coverage.
Test corrupt archives, missing tags/packages, incompatible platforms and repeated import.
Learner runtime verification is still human-operated and recorded through transcribed feedback, not inferred from connected-node builds.
The r6 candidate was imported into a disposable AlmaLinux 8.10 QEMU VM after package tooling was bootstrapped; the VM was rebooted with QEMU egress restricted before staging the bundle.
In that offline VM, the archive checksum and inner manifest verified under Python 3.6.8, all 56 Podman image references/config IDs passed, and the learner-owned caches and offline profiles were activated.
The VM rebuilt all five Python variants, ran Java 17 Maven tests/builds for tracing, metrics and Prometheus POMs, installed/built the Perses UI from `npm ci --offline`, and built the Go service and Perses binary with `GOSUMDB` enabled and `GOPROXY=file`.
The `java-demo:metrics` runtime smoke test produced its counter and request-duration histogram with guest egress restricted.
The incremental r7 archive retains those image/cache payloads and adds the pinned Perses workshop files; its sealed archive verified on the host and guest, and all nine non-k3s curated entries passed readiness and recorded-resource teardown in the restricted AlmaLinux VM.
This validates the bundle's core cached-build goal on EL8, but does not certify exact RHEL 8.6 provisioning, SELinux/firewalld policy, the numbered provisioning scripts, k3s/containerd image import or full workshop runtime.

## Publication

Create and upload the archive, trusted SHA-256 and inventory to an explicitly selected GitHub Release using the connected machine's `gh` authentication.
Use the documented `scripts/dev/publish-image-release.sh --repo <owner/name> --tag <tag> --out <asset-directory>` workflow rather than manual release commands.
The publisher automatically packs the offline-verified capture tree `dist/learner-dependencies-java17-r7` into `<asset-directory>/learner-dependencies-<tag>.tar.gz` and generates its trusted checksum.
Use `--bundle-source <directory>` for a different verified capture tree; fresh captures must pass offline validation first, and incomplete or unverified manifests are refused before GitHub is called.
Existing generated archives are reused only when the capture inventory, file set and checksums still match; changed capture trees require a new output directory.
The optional `--bundle <archive.tar.gz>` mode retains support for an existing archive with a trusted adjacent `.sha256` sidecar.
The publisher verifies the bundle before generating release assets or calling GitHub.
Its bundle mode splits the archive into parts below GitHub's per-asset limit and publishes `bundle-publication.json`, `SHA256SUMS`, the archive checksum, bundle/lab-file inventories, generic-download checksums and `REASSEMBLE.md`.
The manifest records each part's name, size and SHA-256 plus the reassembled archive checksum.
Download all listed assets together, verify `SHA256SUMS`, then follow the generated `REASSEMBLE.md` before running the normal bundle verifier/import workflow.
The release remains draft until every remote asset digest and size matches the local artefacts; reruns reuse matching assets and refuse mismatches or changes to an incomplete already-public release.
The existing image-only mode remains available through `--image-only` or an explicit `--images-file`, but it does not publish package caches or generic lab files.
GitHub's automatic source archives come from the release tag; the publisher does not create a separate source snapshot.
The publisher resolves the target repository's latest remote `main` commit by default, or resolves an explicit `--commit <SHA>` there.
It creates and verifies the required tag before creating a missing release, and both archive and image-only modes pass the resolved full SHA as the release target.
Existing tags must already point to that commit; they are never moved, and conflicting tags stop publication before release creation or uploads.
For a rerun after `main` advances, select the original tag commit with `--commit`.
Verify uploaded asset digests and completeness, and distinguish release upload failures from learner provisioning failures.
Check GitHub per-asset limits and learner disk requirements; a split release requires an explicit manifest and independently verified parts.
OS package repositories, the k3s binary and k3s system-image archive remain separate bootstrap prerequisites unless explicitly declared in this bundle's inventory.
