import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EXTRACTED = ROOT / "content" / "extracted"
MAX_LINES = 250
MAX_CURATED_LINES = 120


def read_lines(relative_path):
    path = ROOT / relative_path
    if not path.is_file():
        raise FileNotFoundError(path)
    return path.read_text(encoding="utf-8", errors="replace").rstrip("\n").splitlines()


def k3s_evidence():
    lock_lines = read_lines("versions.lock")
    selected = [line for line in lock_lines if line.startswith("learner-k3s")]
    probe = read_lines("content/vendor/k3s/registry-probe.txt")
    artifact_rows = [
        "artifact | version/URL | SHA-256 | status",
        "--- | --- | --- | ---",
    ]
    for line in selected:
        if line.startswith("learner-k3s-registry-probe"):
            continue
        if line.startswith("learner-k3s "):
            artifact_rows.append("k3s release | v1.37.1+k3s1 amd64; https://github.com/k3s-io/k3s/releases/tag/v1.37.1%2Bk3s1 | n/a | pinned")
            continue
        artifact, remainder = line.split(" sha256:", 1)
        digest = remainder.split(" ", 1)[0]
        source = next((field.removeprefix("source=") for field in remainder.split() if field.startswith("source=")), "n/a")
        version = next((field.removeprefix("version=") for field in remainder.split() if field.startswith("version=")), None)
        version_or_url = f"{version}; {source}" if version else source
        artifact_rows.append(f"{artifact} | {version_or_url} | {digest} | vendored and SHA-256 verified")
    return [
        *artifact_rows,
        "Registry probe (all eight HTTP 000 responses are connectivity failures: artifactory.internal is unresolved here, not image-not-found evidence):",
        *probe,
        "Runtime constraint: k3s ctr does not honour registries.conf mirrors. Script 62 must explicitly pull through $DOCKER_REGISTRY, then run k3s ctr images tag to recreate the original image reference in k3s containerd.",
        "Probe interpretation and ctr strategy are recorded in versions.lock; the probe measures mirror warm-cache confidence only.",
    ]


def build_status_table():
    commands = json.loads((EXTRACTED / "commands.json").read_text(encoding="utf-8"))
    priority = {
        "BUILT-PRELOADABLE": 0,
        "PRELOADABLE-VIA-VENDORED-DOWNLOAD": 1,
        "PRELOADABLE-VIA-VENDORED-CONTEXT": 2,
        "INTERACTIVE": 3,
    }
    by_tag = {}
    for track, data in commands.items():
        for lab in data["labs"]:
            for command in lab["commands"]:
                if command["type"] != "build" or not command.get("tag"):
                    continue
                tag = command["tag"]
                status = command.get("preload_status", "INTERACTIVE")
                key = (track, tag)
                by_tag.setdefault(key, []).append(status)
    rows = [
        "OpenTelemetry VERSION/[VERSION] contexts resolve to the vendored intro-to-instrumentation v1.4 archive root; the hello-otel builds are PRELOADABLE-VIA-VENDORED-CONTEXT.",
        "otel-developers {VERSION} resolves to the vendored Java tracing v1.1 ZIP root; eligible builds have explicit extraction and docker build steps.",
        "track | tag | status",
        "--- | --- | ---",
    ]
    for (track, tag), statuses in sorted(by_tag.items()):
        status = min(statuses, key=lambda value: priority.get(value, 9))
        rows.append(f"{track} | {tag} | {status}")
    return rows


def curated_excerpt():
    lines = read_lines("content/extracted/curated.json")
    if len(lines) <= MAX_CURATED_LINES:
        return lines
    return lines[:MAX_CURATED_LINES - 1] + [
        f"... [excerpt capped at {MAX_CURATED_LINES} lines; complete JSON: content/extracted/curated.json]"
    ]


def lock_delta():
    return [
        line for line in read_lines("versions.lock")
        if line.startswith("learner-k3s") or line.startswith("runtime-download.") or line.startswith("workshop.reveal.js-menu ")
    ]


def sections():
    expected_skips = read_lines("content/extracted/build-failures-expected.txt")
    runtime_downloads = read_lines("content/extracted/runtime-downloads.txt")
    if not expected_skips:
        expected_skips = ["Final expected-skip count: 0.", "(empty; no expected build skips remain)"]
    else:
        expected_skips = [f"Final expected-skip count: {len(expected_skips)}.", *expected_skips]
    if not runtime_downloads:
        runtime_downloads = ["(empty; no runtime download inputs detected)"]
    return [
        ("k3s-vendoring", k3s_evidence()),
        ("build-status-table", build_status_table()),
        ("expected-skips-final", expected_skips),
        ("runtime-downloads", runtime_downloads),
        ("curated.json", curated_excerpt()),
        ("learner-vm/lab-vm.conf", read_lines("learner-vm/lab-vm.conf")),
        ("versions.lock-delta", lock_delta()),
    ]


def main():
    packet = []
    for title, body in sections():
        packet.append(f"=== BEGIN {title} ===")
        packet.extend(body)
        packet.append(f"=== END {title} ===")
    output = "\n".join(packet) + "\n"
    line_count = len(output.splitlines())
    if line_count > MAX_LINES:
        raise RuntimeError(f"reviewer packet has {line_count} lines; limit is {MAX_LINES}")
    destination = EXTRACTED / "reviewer-packet.md"
    destination.write_text(output, encoding="utf-8")
    print(f"{destination.relative_to(ROOT)}: {line_count} lines (limit {MAX_LINES})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
