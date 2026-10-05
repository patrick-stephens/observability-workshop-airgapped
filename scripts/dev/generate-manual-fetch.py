#!/usr/bin/env python3
import argparse
import hashlib
import json
import re
from pathlib import Path

from workshop_images import discover_images


ROOT = Path(__file__).resolve().parents[2]
VENDOR = ROOT / "content/vendor"
LOCK = ROOT / "versions.lock"
JSON_PATH = VENDOR / "manual-fetch.json"
MARKDOWN_PATH = VENDOR / "MANUAL-FETCH.md"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def lock_record(key):
    for line in LOCK.read_text(encoding="utf-8").splitlines():
        if line.startswith(key + " "):
            return line
    raise ValueError(f"missing versions.lock record: {key}")


def lock_field(line, name, pattern):
    match = re.search(pattern, line)
    if not match:
        raise ValueError(f"missing {name} in versions.lock record: {line}")
    return match.group(1)


def repo_entries():
    entries = []
    content_files = {
        path.relative_to(ROOT).as_posix(): path
        for path in (ROOT / "content").rglob("*")
        if path.is_file() and "payload-stage" not in path.parts
    }
    sums = VENDOR / "k3s/SHA256SUMS"
    for line in sums.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        digest, filename = line.split(None, 1)
        relative = f"content/vendor/k3s/{filename.strip()}"
        path = content_files.get(relative)
        if path is None:
            raise FileNotFoundError(ROOT / relative)
        actual = sha256(path)
        if actual != digest:
            raise ValueError(f"SHA-256 mismatch for {relative}: expected {digest}, actual {actual}")
        used_by = "script 45"
        purpose = {
            "install.sh": "Pinned small k3s installation input included in the repository ZIP; no separate fetch is needed.",
            "k3s-images.txt": "Pinned release system-image reference list included in the repository ZIP; no separate fetch is needed.",
            "k3s-selinux-1.6-1.el8.noarch.rpm": "Pinned RHEL SELinux policy package included in the repository ZIP; no separate fetch is needed.",
        }[filename.strip()]
        entries.append({
            "name": relative,
            "category": "repo",
            "source": "in-repo",
            "sha256": actual,
            "staging": relative,
            "required": True,
            "used_by": used_by,
            "purpose": purpose,
        })

    for line in LOCK.read_text(encoding="utf-8").splitlines():
        if not line.startswith("runtime-download."):
            continue
        relative = lock_field(line, "path", r"\bpath=([^\s]+)")
        digest = lock_field(line, "sha256", r"\bsha256:([0-9a-f]{64})")
        source = lock_field(line, "source", r"\bsource=([^\s]+)")
        path = content_files.get(relative)
        if path is None:
            raise FileNotFoundError(ROOT / relative)
        actual = sha256(path)
        if actual != digest:
            raise ValueError(f"SHA-256 mismatch for {relative}: expected {digest}, actual {actual}")
        entries.append({
            "name": relative,
            "category": "repo",
            "source": "in-repo",
            "sha256": actual,
            "staging": relative,
            "required": True,
            "used_by": "script 60",
            "purpose": f"Runtime build-context archive already included in the repository ZIP; original source URL: {source}.",
        })

    config = (ROOT / "learner-vm/lab-vm.conf").read_text(encoding="utf-8")
    ca_match = re.search(r'^CA_CERT_SOURCE="([^"]+)"$', config, re.MULTILINE)
    if not ca_match:
        raise ValueError("CA_CERT_SOURCE is not set in learner-vm/lab-vm.conf")
    entries.append({
        "name": "Artifactory registry CA certificate",
        "category": "repo",
        "source": "base-image",
        "sha256": None,
        "staging": ca_match.group(1),
        "required": True,
        "used_by": "script 30",
        "purpose": "Already present at the configured base-image path; no separate fetch is needed.",
    })
    return entries


def payload_entries():
    records = (
        ("learner-k3s-binary-amd64", "k3s", True, "/usr/local/bin/k3s"),
    )
    result = []
    for key, filename, required, destination in records:
        line = lock_record(key)
        source = lock_field(line, "source", r"\bsource=([^\s]+)")
        lock_field(line, "sha256", r"\bsha256:([0-9a-f]{64})")
        result.append({
            "name": f"k3s/{filename}",
            "category": "payload",
            "source": "K3S_BINARY_URL (operator-supplied Artifactory generic-file URL)",
            "upstream_reference": source,
            "runtime_source": "K3S_BINARY_URL",
            "lock_key": key,
            "sha256": None,
            "staging": f"$MANUAL_FETCH_DIR/k3s/{filename}",
            "required": required,
            "used_by": "script 45",
            "purpose": f"{'Required' if required else 'Optional, not used by normal provisioning'} k3s release artifact; script 45 downloads the required binary from K3S_BINARY_URL and verifies versions.lock; same-VM recovery staging path is $MANUAL_FETCH_DIR/k3s/{filename}; expected destination is {destination}.",
        })
    return result


def image_entries():
    result = []
    for image in discover_images():
        stores = image["stores"]
        used_by = []
        if "podman" in stores:
            used_by.append("script 60 (Podman)")
        if "k3s" in stores:
            used_by.append("script 62 (k3s containerd)")
        result.append({
            "name": image["name"],
            "category": "image",
            "source": image["source"],
            "sha256": None,
            "staging": "runtime pull through configured Artifactory mirror",
            "required": False,
            "used_by": " and ".join(used_by),
            "purpose": f"External image acquired during provisioning through Artifactory for stores={','.join(stores)}; no image bundle transfer is required.",
            "stores": image["stores"],
            "expected_size": image["expected_size"],
        })
    return result


def build_entries():
    entries = repo_entries() + payload_entries() + image_entries()
    return sorted(entries, key=lambda item: (item["category"], item["name"]))


def table_row(entry):
    source = entry.get("upstream_reference", entry["source"])
    if source == "in-repo":
        source = "in repo"
    elif source == "base-image":
        source = "on base image"
    staging = entry["staging"]
    if entry["category"] == "payload":
        staging = f'K3S_BINARY_URL at provisioning; manual fallback: {staging}'
    status = "REQUIRED" if entry["required"] else ("PROVISIONING" if entry["category"] == "image" else "OPTIONAL")
    return "| " + " | ".join((
        entry["name"], source, entry["sha256"] or "n/a", staging, status,
        entry["used_by"], entry["purpose"],
    )) + " |"


def human_document(entries):
    repo = [entry for entry in entries if entry["category"] == "repo"]
    payload = sorted((entry for entry in entries if entry["category"] == "payload"), key=lambda entry: not entry["required"])
    lines = [
        "# Manual Fetch and Recovery",
        "",
        "Use this guide when the configured Artifactory fetch fails or a same-VM manual recovery is needed.",
        "The normal transfer is one source-only repository ZIP generated by `scripts/dev/package-vm-transfer.sh`; it contains no k3s binary or image tarball.",
        "The ZIP SHA-256 sidecar is for online record-keeping; transfer only the ZIP.",
        "The k3s binary is downloaded during provisioning from the operator-supplied `K3S_BINARY_URL` Artifactory generic-file endpoint and verified against `versions.lock`.",
        "The upstream URL recorded in `versions.lock` is provenance only and must not be fetched from the learner VM.",
        "The CA certificate is supplied by the configured base image.",
        "",
        "## Section A — Repository Files (No Fetch Needed)",
        "",
        "These files travel inside the repository ZIP and require no separate download or transfer.",
        "The base-image CA certificate is already at its configured path and also requires no separate transfer.",
        "",
        "| name | source | SHA-256 | staging path | status | used by | purpose |",
        "|---|---|---|---|---|---|---|",
        *[table_row(entry) for entry in repo],
        "",
        "## Section B — k3s Binary Configuration and Recovery",
        "",
        "Set `K3S_BINARY_URL` in `learner-vm/lab-vm.conf` to the exact HTTPS Artifactory generic-file URL supplied by the Artifactory administrator.",
        "The URL setting is intentionally empty in the packaged configuration until the administrator provides the endpoint; do not invent a URL or use the public release URL on the learner VM.",
        "Script 45 first accepts a same-VM staged binary, otherwise downloads from `K3S_BINARY_URL` with TLS validation and a bounded timeout, then verifies the binary against the SHA-256 in `versions.lock` before installing it.",
        "Do not run scripts 10–80 until the complete diagnostic report has been transcribed and reviewed.",
        "",
        "| artifact | pinned upstream reference (connected provenance only) | lock record | runtime source | manual same-VM fallback | status |",
        "|---|---|---|---|---|---|---|",
        *[
            "| " + " | ".join((entry["name"], entry["upstream_reference"], entry["lock_key"], "K3S_BINARY_URL", entry["staging"], "REQUIRED" if entry["required"] else "OPTIONAL")) + " |"
            for entry in payload
        ],
        "",
    ]
    lines.extend([
        "### Required k3s Binary",
        "",
        "The default value in `learner-vm/lab-vm.conf` is deliberately blank:",
        "",
        "```bash",
        'K3S_BINARY_URL=""',
        "```",
        "",
        "Ask the Artifactory administrator for the exact generic-file URL and place it in this setting before provisioning.",
        "Do not copy the GitHub provenance URL into `K3S_BINARY_URL`.",
        "The pinned binary SHA-256 is recorded only in `versions.lock` under `learner-k3s-binary-amd64`; scripts 00, 10, and 45 read that record as the checksum authority.",
        "",
        "#### Same-VM Manual Fallback",
        "",
        "If the automatic download fails, run these commands on the learner VM after `K3S_BINARY_URL` has been configured.",
        "They place the file on the same VM; no binary or payload archive is transferred separately.",
        "",
        "```bash",
        "set -a",
        "source learner-vm/lab-vm.conf",
        "set +a",
        'sudo install -d -o "$WORKSHOP_USER" -g "$WORKSHOP_USER" -m 0750 "$MANUAL_FETCH_DIR/k3s"',
        'curl --fail --silent --show-error --connect-timeout 15 --max-time 900 --output "$MANUAL_FETCH_DIR/k3s/k3s" "$K3S_BINARY_URL"',
        'expected_sha="$(awk \'$1 == "learner-k3s-binary-amd64" {for (i=1;i<=NF;i++) if ($i ~ /^sha256:/) {sub(/^sha256:/,"",$i); print $i; exit}}\' versions.lock)"',
        'actual_sha="$(sha256sum "$MANUAL_FETCH_DIR/k3s/k3s" | awk \'{print $1}\')"',
        '[[ "$actual_sha" == "$expected_sha" ]]',
        "```",
        "",
        "Then rerun script 45; it verifies the staged binary against the same `versions.lock` pin before installation.",
        "If the checksum differs, stop and report both hashes; do not install the file.",
        "",
        "There is no airgap image tarball in the normal transfer or install path.",
        "K3s obtains its system images from Artifactory through the mirror configuration when provisioning runs; this has not been verified on the learner network.",
        "",
        "## Section C — Container Images During Provisioning",
        "",
        "The Podman and k3s containerd image stores are separate and must each be populated during provisioning.",
        "Script 60 uses `podman pull <original-reference>` for external Podman images through `registries.conf`.",
        "Script 62 uses `k3s crictl pull <original-reference>` for external Kubernetes images through the k3s CRI mirror; do not use `k3s ctr images pull` for mirror access.",
        "For a locally built image needed by k3s, use `podman save` followed by `k3s ctr -n k8s.io images import` and verify the original manifest reference.",
        "If a mirror pull fails, check the configured Artifactory endpoint, image availability, and CA trust; no separately transferred image bundle is part of the recovery procedure.",
        "Do not claim Artifactory pulls work until the operator provides learner-network report evidence.",
        "",
        "## How to Use This File",
        "",
        "1. Transfer and extract the single source-only repository ZIP.",
        "2. Configure `K3S_BINARY_URL` using the exact Artifactory URL supplied by the administrator.",
        "3. Run only `sudo bash scripts/00-diagnose.sh` from the extracted `learner-vm/` directory.",
        "4. Transcribe the complete REPORT block and wait for review before running scripts 10–80.",
        "",
    ])
    return "\n".join(lines)


def payload_instructions(entries):
    lines = [
        "Manual fetch instructions — k3s binary runtime recovery",
        "Generated from content/vendor/manual-fetch.json.",
        "",
    ]
    for entry in entries:
        if entry["category"] != "payload":
            continue
        filename = Path(entry["name"]).name
        lines.extend([
            f'{"REQUIRED" if entry["required"] else "OPTIONAL"}: {entry["name"]}',
            f'Runtime source: {entry.get("runtime_source", "see learner-vm/lab-vm.conf")}',
            f'Pinned upstream provenance (connected machine only): {entry.get("upstream_reference", "n/a")}',
            f'SHA-256 pin: read {entry["lock_key"]} from versions.lock',
            f'Manual recovery staging path: {entry["staging"]}',
            f'VM action: {entry["purpose"]}',
            f'Manual same-VM fetch: curl --fail --silent --show-error --connect-timeout 15 --max-time 900 --output "$MANUAL_FETCH_DIR/k3s/{filename}" "$K3S_BINARY_URL"',
            f'Expected SHA-256 source: versions.lock record {entry["lock_key"]}',
            "",
        ])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Generate manual-fetch metadata and guide")
    parser.add_argument("--list", action="store_true", help="print current entries without regenerating files")
    parser.add_argument("--instructions", metavar="PATH", help="write payload-only fetch instructions to PATH")
    options = parser.parse_args()
    if options.list:
        entries = json.loads(JSON_PATH.read_text(encoding="utf-8"))
        print("name | category | runtime source | upstream reference | SHA-256 | manual fallback | status | used by")
        for entry in entries:
            status = "REQUIRED" if entry["required"] else ("PROVISIONING" if entry["category"] == "image" else "OPTIONAL")
            print(f'{entry["name"]} | {entry["category"]} | {entry.get("runtime_source", entry["source"])} | {entry.get("upstream_reference", "n/a")} | {entry["sha256"] or "n/a"} | {entry["staging"]} | {status} | {entry["used_by"]}')
        return 0
    if options.instructions:
        entries = json.loads(JSON_PATH.read_text(encoding="utf-8"))
        destination = Path(options.instructions)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(payload_instructions(entries), encoding="utf-8")
        print(f"{destination}: runtime binary recovery instructions written")
        return 0

    entries = build_entries()
    if entries:
        entries[0] = {
            "_generated": "generated; see MANUAL-FETCH.md for the human-readable version",
            **entries[0],
        }
    VENDOR.mkdir(parents=True, exist_ok=True)
    JSON_PATH.write_text(json.dumps(entries, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    MARKDOWN_PATH.write_text(human_document(entries), encoding="utf-8")
    print(f"{JSON_PATH.relative_to(ROOT)}: {len(entries)} entries")
    print(f"{MARKDOWN_PATH.relative_to(ROOT)}: generated from the same entry set")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
