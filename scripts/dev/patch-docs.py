import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "content" / "docs"
REPORT = ROOT / "content" / "extracted" / "docs-patched.txt"
TRACKS = ("opentelemetry", "otel-developers", "prometheus", "fluentbit", "perses")
BANNER_TEXT = (
    "OFFLINE LAB VM — all images are preloaded. Skip docker pull steps (marked PRELOADED). "
    "Supported paths: docker and podman — both use the same image store on this VM. "
    "For Rancher Desktop labs, follow the docker commands and skip the Rancher install steps."
)
BANNER = f'<div class="offline-lab-banner">{BANNER_TEXT}</div>\n'
BODY_RE = re.compile(r"<body\b[^>]*>", re.IGNORECASE)
BLOCK_RE = re.compile(r"<pre\b[^>]*>.*?</pre\s*>|<code\b[^>]*>.*?</code\s*>", re.IGNORECASE | re.DOTALL)
PULL_RE = re.compile(r"(?im)^([ \t]*(?:\$\s*)?(?:sudo\s+)?(?:docker|podman)\s+pull\b[^\r\n<]*)([ \t]*)$")
MARKER = "# PRELOADED — skip offline"


def patch_block(match):
    block = match.group(0)

    def mark(line_match):
        line = line_match.group(1)
        if "PRELOADED" in line:
            return line_match.group(0)
        return f"{line} {MARKER}{line_match.group(2)}"

    return PULL_RE.sub(mark, block)


def patch_page(path):
    original = path.read_text(encoding="utf-8", errors="replace")
    updated = BLOCK_RE.sub(patch_block, original)
    if "offline-lab-banner" not in updated:
        match = BODY_RE.search(updated)
        if not match:
            raise ValueError("opening body tag not found")
        updated = updated[:match.end()] + "\n" + BANNER + updated[match.end():]
    if updated != original:
        path.write_text(updated, encoding="utf-8")
    return "offline-lab-banner" in updated


def main():
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    report = []
    failures = []
    for track in TRACKS:
        track_docs = DOCS / track
        pages = sorted(track_docs.rglob("*.html")) if track_docs.is_dir() else []
        patched = 0
        for page in pages:
            try:
                patched += patch_page(page)
            except (OSError, UnicodeError, ValueError) as error:
                failures.append(f"{track}/{page.relative_to(track_docs)}: {error}")
        report.append(f"{track}: patched={patched} html_pages={len(pages)}")
    REPORT.write_text("\n".join(report + failures) + "\n", encoding="utf-8")
    for line in report:
        print(line)
    for line in failures:
        print(f"warning: {line}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
