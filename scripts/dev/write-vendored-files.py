# v1: Inventory content files added, vendored, or transformed beyond the five upstream repo/docs sources.
import hashlib
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONTENT = ROOT / "content"
OUTPUT = CONTENT / "extracted" / "vendored-files.txt"
TRACKS = ("opentelemetry", "otel-developers", "prometheus", "fluentbit", "perses")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def gitlab_sha(track):
    path = CONTENT / "repos" / track / ".source-sha"
    return path.read_text(encoding="utf-8").strip() if path.is_file() else "unknown"


def classify(path):
    relative = path.relative_to(ROOT).as_posix()
    parts = path.relative_to(CONTENT).parts
    if relative == OUTPUT.relative_to(ROOT).as_posix():
        return None
    if relative.endswith("content/bin/docker-compose-v2"):
        return "https://github.com/docker/compose/releases/download/v2.40.3/docker-compose-linux-x86_64", "Official Docker Compose v2.40.3 offline backend for podman.socket."
    if relative.endswith("content/bin/docker-compose-v2.sha256"):
        return "n/a (generated checksum)", "Integrity record for the vendored official Compose binary."
    if relative.endswith("content/repos/opentelemetry/_vendored/app_pod.yaml"):
        return "https://gitlab.com/o11y-workshops/intro-to-instrumentation/-/archive/v1.4/intro-to-instrumentation-v1.4.zip", "Podman-native Pod manifest referenced by the OpenTelemetry lab."
    if relative.startswith("content/repos/opentelemetry/_vendored/intro-to-instrumentation-v1.4/"):
        return "https://gitlab.com/o11y-workshops/intro-to-instrumentation/-/archive/v1.4/intro-to-instrumentation-v1.4.zip", "Vendored project build context required for the Podman-only hello-otel:prog run."
    if relative.endswith("node_modules/reveal.js-menu/menu.js"):
        return "https://registry.npmjs.org/reveal.js-menu/-/reveal.js-menu-2.1.0.tgz", "Repairs the missing reveal.js-menu v2.1.0 script referenced by otel-developers pages."
    if len(parts) >= 3 and parts[0] == "extracted":
        return "n/a (generated)", "Generated online-side extraction, review, or integrity report."
    if path.name == ".source-sha" and len(parts) >= 3 and parts[0] == "repos":
        return f"GitLab workshop repo HEAD {gitlab_sha(parts[1])}", "Records the source repository revision for the copied working tree."
    text = ""
    if path.suffix.lower() in (".html", ".htm"):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            pass
    if "offline-lab-banner" in text or "--load removed: buildx-only flag" in text or "# PRELOADED — skip offline" in text:
        if parts[0] == "docs":
            return "upstream GitLab Pages mirror + offline patch", "Offline banner, preload pull markers, or Buildx flag note."
        if parts[0] == "repos":
            return f"GitLab workshop repo HEAD {gitlab_sha(parts[1])} + offline patch", "Offline banner, preload pull markers, or Buildx flag note."
    return None


def main():
    entries = []
    for path in sorted(item for item in CONTENT.rglob("*") if item.is_file()):
        classification = classify(path)
        if classification is None:
            continue
        source, reason = classification
        relative = path.relative_to(ROOT).as_posix()
        entries.append(f"{relative} | {source} | {sha256(path)} | {reason}")
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(entries) + "\n", encoding="utf-8")
    print(f"{OUTPUT.relative_to(ROOT)}: {len(entries)} files inventoried (self-hash omitted to avoid recursion)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
