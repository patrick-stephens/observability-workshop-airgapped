# v2: Patch mirrored docs and repo lab copies, and document removal of docker build --load.
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "content" / "docs"
REPOS = ROOT / "content" / "repos"
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
PULL_RE = re.compile(r"(?im)^([ \t]*(?:\$\s*)?(?:sudo\s+)?(?:docker|podman)\s+pull\b[^\r\n<]*)([ \t]*)(\r?\n?)$")
LOAD_LINE_RE = re.compile(r"(?i)(?<!\S)--load(?:=\S+)?(?!\S)")
LOAD_NOTE = "# --load removed: buildx-only flag; podman loads by default"
MARKER = "# PRELOADED — skip offline"


def patch_code_block(block):
    pull_count = 0

    def mark_pull(match):
        nonlocal pull_count
        line = match.group(1)
        if "PRELOADED" in line:
            return match.group(0)
        pull_count += 1
        return f"{line} {MARKER}{match.group(2)}{match.group(3)}"

    block = PULL_RE.sub(mark_pull, block)
    lines = block.splitlines(keepends=True)
    output = []
    load_count = 0
    index = 0
    while index < len(lines):
        line = lines[index]
        if not re.match(r"^[ \t]*(?:\$\s*)?(?:sudo\s+)?docker\s+build\b", line, re.IGNORECASE):
            output.append(line)
            index += 1
            continue
        command_lines = [line]
        index += 1
        while command_lines[-1].rstrip("\r\n").rstrip().endswith("\\") and index < len(lines):
            command_lines.append(lines[index])
            index += 1
        command_text = "".join(command_lines)
        if LOAD_LINE_RE.search(command_text):
            clean_lines = [LOAD_LINE_RE.sub("", current) for current in command_lines]
            output.extend(clean_lines)
            output.append(LOAD_NOTE + "\n")
            load_count += 1
        else:
            output.extend(command_lines)
    return "".join(output), pull_count, load_count


def patch_page(path):
    original = path.read_text(encoding="utf-8", errors="replace")
    counts = {"banner": 0, "pulls": 0, "loads": 0}

    def replace_block(match):
        updated, pulls, loads = patch_code_block(match.group(0))
        counts["pulls"] += pulls
        counts["loads"] += loads
        return updated

    updated = BLOCK_RE.sub(replace_block, original)
    if "offline-lab-banner" not in updated:
        match = BODY_RE.search(updated)
        if not match:
            raise ValueError("opening body tag not found")
        updated = updated[:match.end()] + "\n" + BANNER + updated[match.end():]
        counts["banner"] = 1
    if updated != original:
        path.write_text(updated, encoding="utf-8")
    return counts


def html_pages(root, track, include_labs=False):
    pages = set(root.rglob("index.html"))
    pages.update(root.rglob("index.htm"))
    if include_labs:
        pages.update(root.rglob("lab*.html"))
    else:
        pages.update(root.rglob("*.html"))
    return sorted(page for page in pages if page.is_file())


def patch_tree(root, track, include_labs):
    pages = html_pages(root, track, include_labs) if root.is_dir() else []
    totals = {"pages": len(pages), "banner": 0, "pulls": 0, "loads": 0}
    failures = []
    for page in pages:
        try:
            counts = patch_page(page)
            for key in ("banner", "pulls", "loads"):
                totals[key] += counts[key]
        except (OSError, UnicodeError, ValueError) as error:
            failures.append(f"{track}/{page.relative_to(root)}: {error}")
    return totals, failures


def count_present(root, pages):
    counts = {"banners": 0, "pulls": 0, "load_notes": 0}
    for page in pages:
        try:
            text = page.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        counts["banners"] += int("offline-lab-banner" in text)
        counts["pulls"] += text.count(MARKER)
        counts["load_notes"] += text.count(LOAD_NOTE)
    return counts


def main():
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    report = []
    failures = []
    for track in TRACKS:
        docs_root = DOCS / track
        repo_root = REPOS / track
        docs_counts, docs_failures = patch_tree(docs_root, track, include_labs=False)
        repo_counts, repo_failures = patch_tree(repo_root, track, include_labs=True)
        failures.extend(docs_failures + repo_failures)
        docs_present = count_present(docs_root, html_pages(docs_root, track, include_labs=False))
        repo_present = count_present(repo_root, html_pages(repo_root, track, include_labs=True))
        report.append(
            f"{track}: docs_pages={docs_counts['pages']} repo_pages={repo_counts['pages']} "
            f"banners_present={docs_present['banners'] + repo_present['banners']} "
            f"pull_markers_present={docs_present['pulls'] + repo_present['pulls']} "
            f"docker_build_load_notes={docs_present['load_notes']} docs+{repo_present['load_notes']} repo "
            f"load_rewrites_this_run={docs_counts['loads'] + repo_counts['loads']}"
        )
    REPORT.write_text("\n".join(report + failures) + "\n", encoding="utf-8")
    for line in report:
        print(line)
    for line in failures:
        print(f"warning: {line}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
