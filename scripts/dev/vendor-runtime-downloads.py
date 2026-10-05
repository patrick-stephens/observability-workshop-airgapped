# v1: Fetch unique lab-linked archives into content/vendor/downloads and lock URL/hash provenance.
import hashlib
import re
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[2]
EXTRACTED = ROOT / "content" / "extracted"
VENDOR = ROOT / "content" / "vendor" / "downloads"
LOCK = ROOT / "versions.lock"
RECORD_RE = re.compile(r"^(?P<track>[^/]+)/[^:]+:.*?urls=(?P<urls>.+)$")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".partial")
    request = urllib.request.Request(url, headers={"User-Agent": "workshop-content-capture/1"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
        temporary.replace(destination)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def main():
    records = []
    for line in (EXTRACTED / "runtime-downloads.txt").read_text(encoding="utf-8").splitlines():
        match = RECORD_RE.match(line)
        if not match:
            continue
        track = match.group("track")
        for url in match.group("urls").split(","):
            filename = Path(urlsplit(url).path).name
            if not filename:
                continue
            destination = VENDOR / track / filename
            if not destination.is_file():
                print(f"fetching {url}")
                download(url, destination)
            digest = sha256(destination)
            relative = destination.relative_to(ROOT).as_posix()
            lock_key = f"runtime-download.{track}.{filename}"
            records.append((lock_key, f"{lock_key} sha256:{digest} - source={url} path={relative}"))

    unique_records = dict(records)
    existing_lines = LOCK.read_text(encoding="utf-8").splitlines()
    keys = set(unique_records)
    retained = [line for line in existing_lines if not any(line.startswith(f"{key} ") for key in keys)]
    retained.extend(value for _, value in sorted(unique_records.items()))
    LOCK.write_text("\n".join(retained) + "\n", encoding="utf-8")
    for key, line in sorted(unique_records.items()):
        print(line)
    print(f"runtime archives vendored: {len(unique_records)} unique track/archive entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
