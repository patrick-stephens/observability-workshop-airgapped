# Upstream Workshop Delta Log

## Purpose

Record local compatibility and offline adaptations independently of immutable captured workshop sources.
Generated contexts under `dist/learner-dependencies/build-contexts/` are disposable derived artefacts; do not treat them as upstream source or commit caches/images to Git.
Each future change should record affected lab/source, upstream revision, transformation, reason, validation evidence and remaining limitations.
Runtime evidence from the RHEL learner VM belongs in transcribed feedback, not inferred from connected-node tests.

## Applied Build Adaptations

| Area | Source or lab | Local change | Reason and evidence |
| --- | --- | --- | --- |
| Python dependency installation | OpenTelemetry labs 02/03/05/06, standard/Rancher | Generated recipes copy the captured wheelhouse and set `PIP_NO_INDEX` and `PIP_FIND_LINKS`. | The initial Python recipes fetch packages during image builds; connected capture produced the five recipes and the auto-manual alias with package access disabled during build steps. |
| Python 3.13 compatibility | Shared requirements | Build a target-compatible wheel for the existing MarkupSafe 2.1.5 pin. | No published binary wheel was available for Python 3.13; a wheel was built in the digest-resolved Python base without changing the package version. |
| Programmatic Python dependencies | OpenTelemetry lab 03 | Generated programmatic recipe adds the API, SDK, OTLP exporter and Flask/Jinja2/requests instrumentation shown in the lesson. | The captured Buildfile lacks those additions; generated recipe checks passed, while exact learner-created variants still require validation. |
| Runtime API dependency | Python/Java image-API exercises | Generated source uses configurable `O11Y_DOG_API_URL`; Java also accepts the `o11y.dog.api` system property. | Hard-coded public API requests caused Java offline test failures; an approved deterministic local API and PNG fixture keeps the HTTP paths testable. |
| Java agent | Tracing image recipes | Replace remote Dockerfile `ADD` with a verified local agent JAR in derived contexts. | Container registry and Maven mirrors do not redirect arbitrary GitHub downloads. |
| Java build prerequisite | Java tracing and metrics ZIPs | Compile application JARs before image assembly and preserve outputs from alternate POMs. | The ZIPs contain source but no built JARs; connected and Maven offline replays passed with the pinned JDK 17 builder. |
| Java 17 target | Java tracing/metrics derived POMs and images | Preserve upstream Java 21 provenance, emit Java 17 as the effective captured base, set generated compiler source/target/release to 17, and reject base bytecode above class version 61. | Both captured projects passed JDK 17 Maven tests and offline replay (14 tests, 0 failures/errors), and five JDK 17 final image builds passed. This does not verify later learner POM edits or native RHEL execution. |
| Java metrics learner image | OpenTelemetry Developers lab 06 Rancher | Build `java-demo:metrics` from a separate source copy with the documented counter, histogram and Prometheus reader enabled; adapt the lesson's removed `ResourceAttributes` symbol to pinned semconv `ServiceAttributes`. | The metrics-enabled app compiled and passed offline Maven tests with the captured repository, then built as its own Java 17 image. A network-none smoke test confirmed `app_hits_total` and `http_request_duration_seconds` output. The source ZIP remains unchanged. |
| Go service build | Prometheus labs 03/07 and Perses source | Capture Go modules and transparency proofs, keep `GOSUMDB` verification enabled, use the local module proxy to prime any remaining proofs, then build with networking disabled. | Earlier replay lacked a sum.golang.org inclusion tile; r5 capture completed the network-disabled service and Perses builds without disabling checksum verification. |
| Perses source build | Perses lab 02 source variant | Capture npm/Go caches, run UI compilation and the upstream asset-compression step before the Go build. | Omitting asset generation left `embedFS` undefined; offline UI and Go builds passed after adding the documented step. |
| Perses plugins | Source-build plugin installer | Verify every declared plugin archive independently and record checksums. | The upstream downloader can log errors and still return success; 30 archives were captured and checked. |
| Fluent Bit configuration images | Fluent Bit labs 03–10 | Capture the SHA-256-pinned helper v2.9 archive, build each version tag from its documented configuration stage, and parse configs with the pinned Fluent Bit/OTel images before offline image builds. | The r5 archive audit now verifies all 39 recorded build tags (56 image tags total), including v1–v19, `workshop-otel:v0.159`, `opensearch:fb-opensearch` and `java-demo:metrics`; intermediate stages absent from helper snapshots are represented by local fixtures derived from workshop examples. |

## Repository Workflow Repairs

| Area | Local repair | Upstream relevance |
| --- | --- | --- |
| Initial image diagnostics | Explicit registry references, optional validated local-archive recovery, and tag-free Skopeo inspection where applied. | Initial checks must not assume mirror configuration already exists; remaining Skopeo calls need an audit before claiming complete coverage. |
| Java selection | RHEL `alternatives --display` parsing, explicit Java 17 selection, exported `JAVA_HOME`, and failure reports. | Installer portability and preserving diagnostics under shell error handling. |
| Firefox verification | Query the installed RPM rather than launching Firefox as root. | Browser wrappers can emit SELinux/profile warnings before version output. |
| k3s cgroup compatibility | Learner-only `failCgroupV1: false` drop-in, installed-service repair and bounded node-discovery/readiness retries. | RHEL cgroup v1 remains deprecated; this is not restored upstream support. |
| Base tarball coverage | Catalogue Python/Temurin bases, collect recorded build bases, and skip builds with unresolved bases. | Metadata should inspect ZIP-contained and multi-stage recipes, not only slides. |
| Package endpoint probes | Diagnostic v17 checks dedicated PyPI, Maven, npm and Go HTTPS paths with package-specific failure hints. | HTTP success is not proof of native client trust, complete repositories or cache coverage; actual learner-network results remain operator evidence. |

## Cache and Endpoint Boundaries

Prebuilt application containers do not need package-cache runtime mounts merely to run.
Image rebuilds need cache content inside every build stage: generated Python recipes copy wheels, while capture invokes Maven/npm/Go builders with explicit cache mounts and client settings.
A normal runtime `--volume` does not automatically supply data to a later `podman build` or Dockerfile `RUN`.
Learner image definitions and shell commands must explicitly select the generated offline recipes, package profiles and cache inputs; raw upstream rebuild commands are not transparently repaired yet.
Artifactory mode needs client configuration inside each applicable build stage as well as the host; mounting a config file requires its associated environment flag or command option.
Host, rootful builder and container CA trust must be checked independently; do not disable verification by default.
Offline caches are fixed dependency closures, not general mirrors: new packages, versions, CPU architectures or lockfile/POM variants need recapture.
Cache age is not a reason to contact upstream during replay: profiles disable package freshness/background checks where supported and keep offline mode authoritative, while retaining checksum, lockfile and TLS validation.
Artifactory's own cache retention is an administrator responsibility; learner filesystem caches avoid that dependency, and connected pip index mode cannot guarantee cached-wheel preference for unpinned requirements.

## Learner Iteration and Limitations

- OpenTelemetry learners edit application code, instrumentation, requirements and Buildfiles; changed requirements may fall outside the supplied wheelhouse, and bootstrap can select new instrumentation.
- Java tracing/metrics learners modify code and POMs; new Maven coordinates/plugins/goals require cache coverage, and Java 21 language/API use is not accepted by the Java 17 host target.
- Fluent Bit learners repeatedly rebuild tagged configuration images; new or edited requirements beyond the captured examples need a reviewed recapture.
- Prometheus learners edit scrape configurations and rebuild Go/Java examples; `basic-java-metrics` and OTel `java-demo:metrics` are distinct images from their respective captured projects.
- Perses source learners edit UI/plugins/Go code; npm lifecycle scripts, Git dependencies, plugin downloads and new lockfile entries can bypass a simple registry setting or exhaust the offline cache.
- No host Java 21 installation or Java 21 learner bundle default is planned; all captured Java final images use the Java 17 pin.
- The fixture replaces public service behaviour with deterministic local data; it preserves request instrumentation, not public-service variability, and its hostname/image endpoint must be configured for host, Podman and Kubernetes paths.
- Existing generated JDK 21 artefacts are historical capture output, not Java 17 verification evidence; do not include stale JARs or builder references in a release inventory.
- A disposable AlmaLinux 8.10 QEMU VM was bootstrapped for OS tooling, stopped, then restarted with QEMU `restrict=on`; over forwarded SSH it imported r6, verified all 56 rootful Podman image IDs, seeded learner caches, rebuilt cached workloads and passed the Java metrics smoke test.
- Aggregate import/cache wiring, 39/39 recorded build-tag coverage and the offline EL8 workload checks are complete. Exact RHEL 8.6 provisioning, SELinux/firewalld behavior, numbered scripts 00–80, k3s/containerd import and full workshop runtime remain unverified; review those target-specific checks before publication.

## Upstream Candidates

Use portable alternatives discovery and retain final reports on failure.
Avoid tag enumeration when checking a pinned registry reference.
Document prerequisite JAR builds and derive base-image metadata from all Dockerfile stages and archive members.
Make external API endpoints configurable and mock network-dependent unit tests or supply a deterministic fixture.
Make plugin downloader failures produce a nonzero exit and an exact missing-asset list.
Document supported Java/compiler versions and the host/build-stage distinction for package repository configuration.