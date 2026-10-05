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
        used_by = "script 45 (planned)" if filename.strip() == "install.sh" else "script 45 (planned)"
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
            "used_by": "script 60 (planned)",
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
        "used_by": "script 30 (planned)",
        "purpose": "Already present at the configured base-image path; no separate fetch is needed.",
    })
    return entries


def payload_entries():
    records = (
        ("learner-k3s-binary-amd64", "k3s", True, "/usr/local/bin/k3s"),
        ("learner-k3s-airgap-images-amd64.tar.zst", "k3s-airgap-images-amd64.tar.zst", False, "/var/lib/rancher/k3s/agent/images/k3s-airgap-images-amd64.tar.zst"),
    )
    result = []
    for key, filename, required, destination in records:
        line = lock_record(key)
        source = lock_field(line, "source", r"\bsource=([^\s]+)")
        digest = lock_field(line, "sha256", r"\bsha256:([0-9a-f]{64})")
        result.append({
            "name": f"k3s/{filename}",
            "category": "payload",
            "source": source,
            "sha256": digest,
            "staging": f"$MANUAL_FETCH_DIR/k3s/{filename}",
            "required": required,
            "used_by": "script 45 (planned)",
            "purpose": f"{'Required' if required else 'Optional fallback'} k3s release artifact; install or copy to {destination} as documented in Section B.",
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
            "staging": "$MANUAL_FETCH_DIR/images/",
            "required": False,
            "used_by": " and ".join(used_by),
            "purpose": f"FALLBACK image bundle; stores={','.join(stores)}; digest is resolved and recorded by make-image-bundles.sh when generated.",
            "stores": image["stores"],
            "expected_size": image["expected_size"],
        })
    return result


def build_entries():
    entries = repo_entries() + payload_entries() + image_entries()
    return sorted(entries, key=lambda item: (item["category"], item["name"]))


def table_row(entry):
    source = entry["source"]
    if source == "in-repo":
        source = "in repo"
    elif source == "base-image":
        source = "on base image"
    status = "REQUIRED" if entry["required"] else ("FALLBACK" if entry["category"] == "image" else "OPTIONAL")
    return "| " + " | ".join((
        entry["name"], source, entry["sha256"] or "n/a", entry["staging"], status,
        entry["used_by"], entry["purpose"],
    )) + " |"


def human_document(entries):
    repo = [entry for entry in entries if entry["category"] == "repo"]
    payload = sorted((entry for entry in entries if entry["category"] == "payload"), key=lambda entry: not entry["required"])
    image_count = sum(entry["category"] == "image" for entry in entries)
    lines = [
        "# Manual Fetch and Recovery",
        "",
        "Use this guide when an online or Artifactory fetch cannot be completed automatically.",
        "The repository ZIP already contains the repository entries below; the CA certificate is supplied by the configured base image.",
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
        "## Section B — Payload Artifacts",
        "",
        "Fetch these files on an internet-connected machine, verify the pinned digest, then transfer them to the VM staging path shown in the table.",
        "",
        "| name | source URL | SHA-256 | staging path | status | used by | purpose |",
        "|---|---|---|---|---|---|---|",
        *[table_row(entry) for entry in payload],
        "",
    ]
    binary, airgap = payload
    lines.extend([
        "### Required k3s Binary",
        "",
        f'On an internet-connected machine: `curl -fL -o k3s {binary["source"]}`.',
        f'Check the actual checksum with `sha256sum k3s` and verify it against `{binary["sha256"]}` from this table or `versions.lock`.',
        f'Transfer the verified file to `{binary["staging"]}` on the VM.',
        f'The planned script 45 also accepts the file at `{binary["staging"]}`; to install it manually, run `sudo install -m 755 "$MANUAL_FETCH_DIR/k3s/k3s" /usr/local/bin/k3s`.',
        "",
        "### Optional Airgap Image Tarball",
        "",
        f'On an internet-connected machine: `curl -fL -o k3s-airgap-images-amd64.tar.zst {airgap["source"]}`.',
        f'Check the actual checksum with `sha256sum k3s-airgap-images-amd64.tar.zst` and verify it against `{airgap["sha256"]}` from this table or `versions.lock`.',
        f'Transfer the verified file to `{airgap["staging"]}` on the VM.',
        "Copy it before the first k3s start; the planned script 45 copies a correctly staged file automatically.",
        "To copy manually: `sudo mkdir -p /var/lib/rancher/k3s/agent/images/` followed by `sudo cp \"$MANUAL_FETCH_DIR/k3s/k3s-airgap-images-amd64.tar.zst\" /var/lib/rancher/k3s/agent/images/`.",
        "This fallback avoids pulling k3s system images during bootstrap and is only needed if Artifactory-based provisioning is unreliable.",
        "",
        "## Section C — Container Images (Fallback Only)",
        "",
        f"If Artifactory is unreachable from the VM, script 60 cannot complete the Podman image store and script 62 cannot complete the separate k3s containerd store. Generate the optional fallback bundle on an internet-connected machine with `scripts/dev/make-image-bundles.sh`; the current dynamic image set contains {image_count} unique references and is derived from `content/extracted/external-images.txt` plus images in the curated Kubernetes manifests.",
        "Regenerate and print that set with `scripts/dev/make-image-bundles.sh --list`.",
        "Transfer fallback archives to `$MANUAL_FETCH_DIR/images/`; the tool writes per-image digest sidecars and archive checksums.",
        "",
        "## How to Use This File",
        "",
        "1. Look for the requested file at its staging path.",
        "2. If present, verify its SHA-256 and use it.",
        "3. If absent, try the documented network source while that source is reachable.",
        "4. If the network fetch fails, stop with FATAL; the fix hint names this MANUAL-FETCH section and the exact staging path.",
        "",
        "Worked example:",
        "",
        "```text",
        "Script 45: FATAL — pinned k3s binary is missing. FIX: See MANUAL-FETCH.md Section B; place the verified file at $MANUAL_FETCH_DIR/k3s/k3s.",
        f'Operator on connected machine: curl -fL -o k3s {binary["source"]}',
        f'Operator: printf \'%s  k3s\\n\' \'{binary["sha256"]}\' | sha256sum -c -',
        "Operator transfers the verified file to $MANUAL_FETCH_DIR/k3s/k3s, then reruns script 45.",
        "```",
        "",
    ])
    return "\n".join(lines)


def payload_instructions(entries):
    lines = [
        "Manual fetch instructions — payload artifacts only",
        "Generated from content/vendor/manual-fetch.json.",
        "",
    ]
    for entry in entries:
        if entry["category"] != "payload":
            continue
        filename = Path(entry["name"]).name
        lines.extend([
            f'{"REQUIRED" if entry["required"] else "OPTIONAL"}: {entry["name"]}',
            f'Source: {entry["source"]}',
            f'SHA-256: {entry["sha256"]}',
            f'Staging path: {entry["staging"]}',
            f'VM action: {entry["purpose"]}',
            f'Fetch: curl -fL -o {filename} {entry["source"]}',
            f'Inspect: sha256sum {filename}',
            f'Expected: {entry["sha256"]}',
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
        print("name | category | source | SHA-256 | staging | status | used by")
        for entry in entries:
            status = "REQUIRED" if entry["required"] else ("FALLBACK" if entry["category"] == "image" else "OPTIONAL")
            print(f'{entry["name"]} | {entry["category"]} | {entry["source"]} | {entry["sha256"] or "n/a"} | {entry["staging"]} | {status} | {entry["used_by"]}')
        return 0
    if options.instructions:
        entries = json.loads(JSON_PATH.read_text(encoding="utf-8"))
        destination = Path(options.instructions)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(payload_instructions(entries), encoding="utf-8")
        print(f"{destination}: payload-only instructions written")
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