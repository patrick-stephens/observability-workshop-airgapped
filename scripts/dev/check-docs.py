# v1: Validate local doc links and assets, with one targeted retry for the otel-developers mirror.
import html
import subprocess
from collections import defaultdict
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit


ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "content" / "docs"
REPOS = ROOT / "content" / "repos"
EXTRACTED = ROOT / "content" / "extracted"
GAPS_FILE = EXTRACTED / "docs-gaps.txt"
TRACKS = ("opentelemetry", "otel-developers", "prometheus", "fluentbit", "perses")
DOCS_HOST = "o11y-workshops.gitlab.io"


class ReferenceParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.references = []

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name.lower() in ("href", "src") and value:
                self.references.append((name.lower(), html.unescape(value.strip())))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)


def site_root_for(track_root, track):
    expected = f"workshop-{track}"
    for path in track_root.rglob(expected):
        if path.is_dir() and path.parent.name == DOCS_HOST:
            return path
    return track_root


def html_pages(track):
    docs_root = DOCS / track
    repo_root = REPOS / track
    docs_pages = sorted(path for path in docs_root.rglob("*.html") if path.is_file()) if docs_root.is_dir() else []
    repo_pages = sorted(path for path in repo_root.rglob("lab*.html") if path.is_file()) if repo_root.is_dir() else []
    return docs_pages, repo_pages


def target_for(page, reference, docs_root, site_root, track):
    parsed = urlsplit(reference)
    if parsed.scheme.lower() in ("mailto", "javascript", "data", "tel"):
        return None
    if parsed.scheme and parsed.scheme.lower() not in ("http", "https", "file"):
        return None
    if parsed.netloc:
        if parsed.netloc.lower() != DOCS_HOST:
            return None
        prefix = f"/workshop-{track}/"
        path = unquote(parsed.path)
        if path.startswith(prefix):
            return site_root / path[len(prefix):]
        return None
    path = unquote(parsed.path)
    if not path:
        return None
    if path.startswith("/"):
        return site_root / path.lstrip("/")
    return (page.parent / path).resolve()


def exists_with_html_fallback(target):
    if target.exists():
        if target.is_dir():
            return (target / "index.html").is_file() or (target / "index.htm").is_file()
        return target.is_file()
    if not target.suffix:
        return Path(f"{target}.html").is_file() or Path(f"{target}.htm").is_file()
    return False


def inspect_track(track):
    docs_pages, repo_pages = html_pages(track)
    docs_root = DOCS / track
    site_root = site_root_for(docs_root, track)
    missing = []
    refs_checked = 0
    external_skipped = 0
    for page in docs_pages + repo_pages:
        parser = ReferenceParser()
        try:
            parser.feed(page.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
        for kind, reference in parser.references:
            target = target_for(page, reference, docs_root, site_root, track)
            if target is None:
                external_skipped += 1
                continue
            refs_checked += 1
            if not exists_with_html_fallback(target):
                missing.append({"page": page, "kind": kind, "reference": reference, "target": target, "docs_page": page.is_relative_to(docs_root)})
    return {
        "pages": len(docs_pages) + len(repo_pages),
        "docs_pages": len(docs_pages),
        "repo_pages": len(repo_pages),
        "refs_checked": refs_checked,
        "external_skipped": external_skipped,
        "missing": missing,
        "site_root": site_root,
    }


def retry_otel_assets(track_result):
    retry_count = 0
    docs_root = DOCS / "otel-developers"
    site_root = track_result["site_root"]
    remote_base = f"https://{DOCS_HOST}/workshop-otel-developers/"
    attempted = set()
    for entry in track_result["missing"]:
        if not entry["docs_page"] or entry["target"] in attempted:
            continue
        try:
            relative = entry["target"].relative_to(site_root).as_posix()
        except ValueError:
            continue
        if relative.startswith("../"):
            continue
        attempted.add(entry["target"])
        retry_count += 1
        entry["target"].parent.mkdir(parents=True, exist_ok=True)
        url = remote_base + quote(relative, safe="/!$&'()*+,;=:@-._~")
        completed = subprocess.run(
            ["wget", "--quiet", "--timeout=10", "--tries=1", "-O", str(entry["target"]), url],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if completed.returncode != 0:
            try:
                entry["target"].unlink()
            except OSError:
                pass
    return retry_count


def main():
    EXTRACTED.mkdir(parents=True, exist_ok=True)
    results = {}
    for track in TRACKS:
        results[track] = inspect_track(track)
    retry_count = retry_otel_assets(results["otel-developers"])
    if retry_count:
        results["otel-developers"] = inspect_track("otel-developers")

    gaps = []
    for track, result in results.items():
        result["missing"].sort(key=lambda entry: (str(entry["page"]), entry["reference"]))
        print(
            f"{track}: pages_checked={result['pages']} (docs={result['docs_pages']} repo_labs={result['repo_pages']}); "
            f"references_checked={result['refs_checked']}; external_skipped={result['external_skipped']}; "
            f"missing={len(result['missing'])}" + (f"; targeted_retries={retry_count}" if track == "otel-developers" else "")
        )
        for entry in result["missing"]:
            page = entry["page"].relative_to(ROOT).as_posix()
            target = entry["target"].relative_to(ROOT).as_posix() if entry["target"].is_relative_to(ROOT) else str(entry["target"])
            line = f"{track}: {page}: {entry['kind']}={entry['reference']} -> missing {target}"
            gaps.append(line)
            print(f"  MISSING: {line}")
    GAPS_FILE.write_text("\n".join(gaps) + ("\n" if gaps else ""), encoding="utf-8")
    if not gaps:
        print("docs-gaps.txt: empty; all checked local references resolve")
    else:
        print(f"docs-gaps.txt: {len(gaps)} missing local reference(s) recorded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())