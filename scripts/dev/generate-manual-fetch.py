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
ARTIFACT_CATALOG = ROOT / "learner-vm/artifacts.tsv"


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
    seen = set()
    content_files = {
        path.relative_to(ROOT).as_posix(): path
        for path in (ROOT / "content").rglob("*")
        if path.is_file() and "payload-stage" not in path.parts
    }
    inventory = ROOT / "content/extracted/vendored-files.txt"
    for row in inventory.read_text(encoding="utf-8").splitlines():
        fields = [field.strip() for field in row.split("|", 3)]
        if len(fields) != 4:
            continue
        relative, source, digest, purpose = fields
        if not relative.startswith(("content/repos/", "content/docs/", "content/vendor/downloads/")):
            continue
        path = ROOT / relative
        if not path.is_file():
            raise FileNotFoundError(path)
        actual = sha256(path)
        if actual != digest:
            raise ValueError(f"SHA-256 mismatch for {relative}: expected {digest}, actual {actual}")
        if relative.endswith("/_vendored/app_pod.yaml"):
            purpose = "Vendored app_pod.yaml is already present in the repository; no fetch or staging action is needed."
        elif "/node_modules/reveal.js-menu/" in relative:
            purpose = "Vendored reveal.js-menu is already present in the repository; no fetch or staging action is needed."
        elif relative.startswith("content/vendor/downloads/"):
            purpose = "Pinned runtime build-context archive is already present in the repository; no fetch or staging action is needed."
        else:
            purpose = "Vendored workshop source or documentation mirror is already present in the repository; no fetch or staging action is needed."
        entries.append({
            "name": relative,
            "category": "repository",
            "source": "in-repository",
            "sha256": actual,
            "path": relative,
            "required": True,
            "used_by": "learner VM",
            "purpose": purpose,
            "recovery": "No action; this file is already in the repository.",
        })
        seen.add(relative)

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
            "category": "repository",
            "source": "in-repository",
            "sha256": actual,
            "path": relative,
            "required": True,
            "used_by": used_by,
            "purpose": purpose,
            "recovery": "No action; this file is already in the repository.",
        })

    for line in LOCK.read_text(encoding="utf-8").splitlines():
        if not line.startswith("runtime-download."):
            continue
        relative = lock_field(line, "path", r"\bpath=([^\s]+)")
        if relative in seen:
            continue
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
            "category": "repository",
            "source": "in-repository",
            "sha256": actual,
            "path": relative,
            "required": True,
            "used_by": "script 60",
            "purpose": "Pinned runtime build-context archive is already present in the repository; no fetch or staging action is needed.",
            "recovery": "No action; this file is already in the repository.",
        })
        seen.add(relative)

    config = (ROOT / "learner-vm/lab-vm.conf").read_text(encoding="utf-8")
    ca_match = re.search(r'^CA_CERT_SOURCE="([^"]+)"$', config, re.MULTILINE)
    if not ca_match:
        raise ValueError("CA_CERT_SOURCE is not set in learner-vm/lab-vm.conf")
    entries.append({
        "name": "Artifactory registry CA certificate",
        "category": "repository",
        "source": "base-image",
        "sha256": None,
        "path": ca_match.group(1),
        "required": True,
        "used_by": "script 30",
        "purpose": "Artifactory CA is already present in the base image at the configured trust path; no fetch or staging action is needed.",
        "recovery": "If the CA is absent, stop and ask the base-image administrator to restore the configured CA; do not use an untrusted fallback.",
    })
    return entries


def runtime_entries():
    result = []
    header = ("id", "kind", "required", "staging_relative_path", "url_variable", "sha256_lock_key", "consumer_script", "install_target")
    found_header = False
    seen = set()
    for number, raw_line in enumerate(ARTIFACT_CATALOG.read_text(encoding="utf-8").splitlines(), start=1):
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        columns = raw_line.split("\t")
        if tuple(columns) == header:
            found_header = True
            continue
        if not found_header or len(columns) != len(header):
            raise ValueError(f"invalid artifact catalog row {number}: expected the eight-column header followed by eight-column rows")
        artifact_id, kind, required_text, staging_relative_path, url_variable, lock_key, consumer_script, install_target = columns
        if artifact_id in seen:
            raise ValueError(f"duplicate artifact ID in learner-vm/artifacts.tsv: {artifact_id}")
        seen.add(artifact_id)
        if required_text not in ("yes", "no"):
            raise ValueError(f"invalid required value for artifact {artifact_id}: {required_text}")
        filesystem_image = kind == "image-archive"
        if filesystem_image:
            if url_variable != "-" or required_text != "no":
                raise ValueError(f"image archive {artifact_id} must be optional and filesystem-only")
            record = next((line for line in LOCK.read_text(encoding="utf-8").splitlines() if line.startswith(lock_key + " ")), None)
            upstream_reference = None
            digest = lock_field(record, "sha256", r"\bsha256:([0-9a-f]{64})") if record else None
        else:
            record = lock_record(lock_key)
            upstream_reference = lock_field(record, "source", r"\bsource=([^\s]+)")
            digest = lock_field(record, "sha256", r"\bsha256:([0-9a-f]{64})")
        required = required_text == "yes"
        result.append({
            "name": artifact_id,
            "id": artifact_id,
            "category": "image-archive" if filesystem_image else "runtime",
            "kind": kind,
            "source": "operator-provided filesystem archive" if filesystem_image else "operator-supplied Artifactory generic-file URL",
            "runtime_source": "filesystem-only" if filesystem_image else url_variable,
            "url_variable": None if filesystem_image else url_variable,
            "upstream_reference": upstream_reference,
            "sha256_lock_key": lock_key,
            "lock_key": lock_key,
            "expected_sha256": digest,
            "sha256": None,
            "staging_relative_path": staging_relative_path,
            "path": f"$MANUAL_FETCH_DIR/{staging_relative_path}",
            "consumer_script": consumer_script,
            "install_target": install_target,
            "required": required,
            "used_by": consumer_script,
            "purpose": "Load an operator-provided image archive before mirror pulls; verify an optional operator-recorded archive SHA and embedded manifest hashes when present." if filesystem_image else f"{consumer_script} resolves this {kind} from a checksum-verified local file first, otherwise from {url_variable}, and verifies versions.lock record {lock_key}.",
            "recovery": f"Provide $MANUAL_FETCH_DIR/{staging_relative_path} or content/vendor/{staging_relative_path}; see MANUAL-FETCH.md Section C. No URL is probed or fetched." if filesystem_image else f"Stage a verified file at $MANUAL_FETCH_DIR/{staging_relative_path}; {url_variable} is the Artifactory fallback. See MANUAL-FETCH.md Section B.",
        })
    if not found_header:
        raise ValueError("learner-vm/artifacts.tsv has no valid header")
    return result


def image_entries():
    result = []
    for image in discover_images():
        stores = image["stores"]
        is_local = image["source"] == "in-repo" or image["name"].startswith("localhost/")
        used_by = []
        if "podman" in stores:
            used_by.append("script 60 (Podman)")
        if "k3s" in stores:
            used_by.append("script 62 (k3s containerd)")
        result.append({
            "name": image["name"],
            "category": "image",
            "source": image["source"],
            "runtime_source": "repository build and local Podman store" if is_local else "DOCKER_REGISTRY (Artifactory mirror)",
            "sha256": None,
            "path": "runtime pull into the Podman or k3s containerd store",
            "required": True,
            "used_by": " and ".join(used_by),
            "purpose": f"{'Locally built' if is_local else 'External'} image used by stores={','.join(stores)}.",
            "recovery": "Rebuild from the recorded commands.json entry and vendored context; when k3s needs the image, use podman save and k3s ctr -n k8s.io images import." if is_local else "Record the original image reference, DOCKER_REGISTRY endpoint, k3s version if applicable, pull output, CA/DNS results, and relevant journal; escalate to the Artifactory administrator. Do not use a public-internet fallback.",
            "acquisition": "LOCAL BUILD/IMPORT" if is_local else "FETCH AT PROVISIONING",
            "stores": image["stores"],
            "expected_size": image["expected_size"],
        })
        if image["name"] in {"docker.io/jaegertracing/all-in-one:1.76.0", "docker.io/persesdev/perses:v0.54.0"}:
            result[-1]["approval_status"] = "not approved; escalate to the Artifactory administrator before provisioning the affected workshops"
            result[-1]["affected_workshops"] = ["OpenTelemetry", "OTel-for-Java"] if "jaegertracing" in image["name"] else ["Perses"]
    return result


def system_entries():
    return [{
        "name": "RHEL 8 packages and repository metadata",
        "category": "system",
        "source": "configured Artifactory DNF repositories",
        "runtime_source": "ART_HOST",
        "sha256": None,
        "path": "RHEL BaseOS, AppStream, and configured module repositories",
        "required": True,
        "used_by": "script 20",
        "purpose": "Operating-system packages and repository metadata are fetched from the configured Artifactory repositories during provisioning.",
        "recovery": "Capture dnf -v repolist and dnf -v makecache output, repository configuration, ART_HOST DNS results, and CA/TLS diagnostics; contact the Artifactory administrator. Do not use a public-internet fallback.",
    }]


def build_entries():
    entries = repo_entries() + runtime_entries() + image_entries() + system_entries()
    return sorted(entries, key=lambda item: (item["category"], item["name"]))


def table_row(entry):
    source = entry["source"]
    if source == "in-repository":
        source = "in repository"
    elif source == "base-image":
        source = "on base image"
    status = "PRESENT" if entry["category"] == "repository" else "FETCH AT PROVISIONING"
    return "| " + " | ".join((
        entry["name"], source, entry["sha256"] or "see versions.lock" if entry["category"] == "runtime" else (entry["sha256"] or "n/a"), entry["path"], status,
        entry["used_by"], entry["purpose"], entry["recovery"],
    )) + " |"


def human_document(entries):
    repo = [entry for entry in entries if entry["category"] == "repository"]
    runtime = [entry for entry in entries if entry["category"] == "runtime"]
    images = [entry for entry in entries if entry["category"] == "image"]
    systems = [entry for entry in entries if entry["category"] == "system"]
    image_archives = [entry for entry in entries if entry["category"] == "image-archive"]
    runtime_rows = [
        "| " + " | ".join((
            entry["id"], entry["kind"], "REQUIRED" if entry["required"] else "OPTIONAL",
            entry["url_variable"], entry["sha256_lock_key"],
            entry["upstream_reference"], entry["expected_sha256"],
            f'$MANUAL_FETCH_DIR/{entry["staging_relative_path"]}', entry["consumer_script"], entry["install_target"],
        )) + " |"
        for entry in runtime
    ]
    repo_groups = [
        ("Workshop repositories, including app_pod.yaml and reveal.js-menu", "content/repos/", "Tracked source trees and vendored lab inputs; no action needed."),
        ("Documentation mirrors", "content/docs/", "Tracked documentation mirrors; no action needed."),
        ("Runtime build-context downloads", "content/vendor/downloads/", "Pinned build-context files already present; no action needed."),
        ("k3s installer, image list, and SELinux RPM", "content/vendor/k3s/", "Already present and checksummed by content/vendor/k3s/SHA256SUMS; no action needed."),
        ("Artifactory CA certificate", "base-image", "Already supplied by the base image at CA_CERT_SOURCE; no action needed."),
    ]
    repo_rows = []
    for title, selector, purpose in repo_groups:
        if selector == "base-image":
            matched = [entry for entry in repo if entry["source"] == selector]
            path = matched[0]["path"] if matched else "CA_CERT_SOURCE"
            source = "base image"
        else:
            matched = [entry for entry in repo if entry["name"].startswith(selector)]
            path = selector + "…"
            source = "in repository"
        if matched:
            repo_rows.append("| " + " | ".join((title, source, f"{len(matched)} inventoried file(s)", path, "PRESENT", purpose)) + " |")
    lines = [
        "# Runtime Fetch and Recovery",
        "",
        "This is a runtime recovery reference for the learner VM.",
        "The repository already contains its workshop sources, documentation mirrors, runtime build-context archives, k3s support files, `app_pod.yaml`, and `reveal.js-menu`; no action is needed for those entries.",
        "Standalone runtime files are resolved from checksum-verified local files before any Artifactory URL is probed or fetched.",
        "Runtime image pulls use the configured Artifactory mirror. If it is unavailable, stop and contact the Artifactory administrator; there is no public-internet fallback.",
        "",
        "## Section A — In Repository (Already Present)",
        "",
        "All listed files are already in the repository or base image. Nothing in this section needs fetching, staging, or operator action.",
        "",
        "The machine-readable catalog lists the exact repository paths and per-file hashes for all inventoried files.",
        "",
        "| vendored group | source | inventory | repository/base-image path | status | purpose |",
        "|---|---|---|---|---|---|",
        *repo_rows,
        "",
        "## Section B — Fetched at Provisioning Time on the VM",
        "",
        "Every standalone runtime artifact is catalogued in `learner-vm/artifacts.tsv` with its kind, required status, local staging path, URL variable, checksum lock key, consumer, and install target.",
        "The pinned upstream URL and SHA-256 below identify the version in `versions.lock`; the learner VM fetches only from the configured Artifactory URL variable, never from that upstream URL.",
        "For each entry, the resolver checks `$MANUAL_FETCH_DIR/<staging_relative_path>` first and verifies it against the checksum key in `versions.lock` before use.",
        "A bad local checksum is a hard failure; the file is never overwritten and its URL is never fetched as a fallback.",
        "Only when no local file exists does the resolver use the configured HTTPS Artifactory generic-file URL, download to a temporary file, verify its SHA-256, and stage it locally.",
        "The Artifactory URL is supplied by the operator and is not stored in the catalog or committed configuration.",
        "",
        "| id | kind | required | URL variable | SHA-256 lock key | pinned upstream reference | SHA-256 | local staging path | consumer | install target |",
        "|---|---|---|---|---|---|---|---|---|---|",
        *runtime_rows,
        "",
        "### Required k3s Binary Recovery",
        "",
        "If script 45 cannot obtain the required binary, ask the Artifactory administrator for the exact generic-file URL and set `K3S_BINARY_URL` on the VM.",
        "Run the following from the repository root to download to a temporary file, verify the lock key, and stage the file for retry.",
        "The commands refuse to overwrite an existing staged file; investigate a checksum failure before replacing that file manually.",
        "",
        "```bash",
        "set -euo pipefail",
        "set -a",
        "source learner-vm/lab-vm.conf",
        "set +a",
        '[[ -n "$K3S_BINARY_URL" ]] || { printf "%s\\n" "Set K3S_BINARY_URL from the Artifactory administrator." >&2; exit 1; }',
        'sudo install -d -o "$WORKSHOP_USER" -g "$WORKSHOP_USER" -m 0750 "$MANUAL_FETCH_DIR/k3s"',
        '[[ ! -e "$MANUAL_FETCH_DIR/k3s/k3s" && ! -L "$MANUAL_FETCH_DIR/k3s/k3s" ]] || { printf "%s\\n" "Staged file already exists; verify it before taking any action." >&2; exit 1; }',
        'temporary_binary="$(mktemp)"',
        'trap \'rm -f -- "$temporary_binary"\' EXIT',
        'curl --fail --silent --show-error --connect-timeout 10 --max-time 900 --output "$temporary_binary" "$K3S_BINARY_URL"',
        'expected_sha="$(awk \'$1 == "learner-k3s-binary-amd64" {for (i=1;i<=NF;i++) if ($i ~ /^sha256:/) {sub(/^sha256:/,"",$i); print $i; exit}}\' versions.lock)"',
        'actual_sha="$(sha256sum "$temporary_binary" | awk \'{print $1}\')"',
        '[[ -n "$expected_sha" && "$actual_sha" == "$expected_sha" ]] || { printf "SHA-256 mismatch: expected %s, actual %s\\n" "$expected_sha" "$actual_sha" >&2; exit 1; }',
        'sudo install -o root -g root -m 0755 "$temporary_binary" "$MANUAL_FETCH_DIR/k3s/k3s"',
        "sudo bash learner-vm/scripts/45-k3s-install.sh",
        "```",
        "",
        "If the download fails or the checksum differs, do not install the file. Preserve the report and escalate with the redacted URL, HTTP/error details, expected and actual SHA-256, DNS/TLS diagnostics, and script 45 report.",
        "The `k3s-airgap-images` archive is optional and uses `K3S_AIRGAP_IMAGES_URL`, an operator-supplied Artifactory generic-file URL separate from the container-image registry endpoint.",
        "If that URL is unset or the optional fetch fails, k3s obtains `registry.k8s.io` system images through the configured Artifactory registry mirrors.",
        "The archive is not present in Git and is not transferred separately; if intentionally staged locally, place it at `$MANUAL_FETCH_DIR/k3s/k3s-airgap-images-amd64.tar.zst`, verify lock key `learner-k3s-airgap-images-amd64.tar.zst`, and rerun script 45 so it stages the file under `/var/lib/rancher/k3s/agent/images/` before startup.",
        "",
        "## Section C — Container Images, Fetched at Provisioning Time",
        "",
        "Preferred: pull external images during provisioning through the Artifactory mirror using `podman pull <original-reference>` or `k3s crictl pull <original-reference>`.",
        "Set `ART_REPO_DOMAIN` to the base domain and leave `DOCKER_REGISTRY` empty to derive `docker-registry.${ART_REPO_DOMAIN}` (preferred); the explicit `${ART_REPO_DOMAIN}/artifactory/docker-registry` path form remains accepted.",
        "A manifest HTTP 404 is informational: the image may not be cached and may warm on first pull; only an actual pull establishes availability.",
        "",
        "### Operator-Provided Image Archives",
        "",
        "Fallback: place an approved image archive at `$MANUAL_FETCH_DIR/images/<filename>.tar` using the corresponding `image-archive` row in `learner-vm/artifacts.tsv`.",
        "On a connected machine that is authorised to obtain the original image, run:",
        "",
        "```bash",
        "podman pull <original-reference>",
        "podman save --format oci-archive \\",
        "  -o <filename>.tar <original-reference>",
        "```",
        "",
        "`--format oci-archive` is interoperable with `podman load -i <path>` on the learner VM.",
        "The archive resolver is filesystem-only: it never probes or fetches a URL; an operator-recorded SHA-256 in `versions.lock` is verified, a mismatch is fatal, and an absent pin produces an explicit verification-skipped line.",
        "The loader validates embedded manifest/blob hashes and checks the loaded image references/config IDs when present, then checks each required image before deciding whether to pull it.",
        "",
        "| archive ID | local staging path | optional checksum lock key | store target |",
        "|---|---|---|---|",
        *["| " + " | ".join((entry["id"], entry["path"], entry["sha256_lock_key"], entry["install_target"])) + " |" for entry in image_archives],
        "",
        "No archive is supplied by the repository by default; the three slots above are optional operator choices, not approval workarounds.",
        "For a supplied archive also needed by k3s, set its catalog install target to `both` (or `k3s-containerd`) so script 62 conditionally imports it into namespace `k8s.io` before CRI pulls.",
        "",
        "### Small-Image Vendoring",
        "",
        "Alternatively commit an approved small archive under `content/vendor/images/`, using the same catalogued filename; local `$MANUAL_FETCH_DIR` files always take precedence over the repository copy.",
        "Below 30 MB per image is reasonable; above 100 MB is strongly discouraged, and large images must not be committed.",
        "Do not bypass the repository's large-file or secret checks; obtain review before adding an archive.",
        "",
        "### Image Approval Escalation",
        "",
        "The following images are not approved for this environment yet and require escalation to the Artifactory administrator before provisioning can complete for their affected workshops:",
        "",
        "- `docker.io/jaegertracing/all-in-one:1.76.0`: affects the OpenTelemetry and OTel-for-Java workshops.",
        "- `docker.io/persesdev/perses:v0.54.0`: affects the Perses workshop.",
        "",
        "If an approval is not expected, discuss with the workshop organisers whether those workshops can be supported with an alternative image that is already approved.",
        "Image archives and vendoring do not grant approval; no substitute or workaround is implemented.",
        "",
        "Script 20 fetches RHEL packages and repository metadata from the configured Artifactory DNF repositories.",
        "If package or metadata fetches fail, capture `dnf -v repolist`, `dnf -v makecache`, repository configuration, ART_HOST DNS results, and CA/TLS diagnostics, then contact the Artifactory administrator.",
        "",
        "| runtime package source | endpoint | status | used by | recovery |",
        "|---|---|---|---|---|",
        *["| " + " | ".join((entry["name"], entry["runtime_source"], "FETCH AT PROVISIONING", entry["used_by"], entry["recovery"])) + " |" for entry in systems],
        "",
        "Scripts 60 and 62 pull external images through `$DOCKER_REGISTRY`, configured in `registries.conf` and `/etc/rancher/k3s/registries.yaml` before k3s starts.",
        "The Podman and k3s containerd stores are separate: script 60 uses `podman pull <original-reference>`; script 62 uses `k3s crictl pull <original-reference>` for external images.",
        "For locally built Podman images required by k3s, use `podman save` followed by `k3s ctr -n k8s.io images import`.",
        "",
        "| image | runtime source | status | used by | recovery |",
        "|---|---|---|---|---|",
        *["| " + " | ".join((entry["name"], entry["runtime_source"], entry["acquisition"], entry["used_by"], entry["recovery"])) + " |" for entry in images],
        "",
        "If Artifactory is unreachable or an image is absent from the mirror, do not attempt a public-internet fallback. Contact the Artifactory administrator.",
        "Before escalating, capture the original image reference, configured `$DOCKER_REGISTRY` endpoint, pull command output, DNS lookup, CA/TLS diagnostics, `podman info` or `k3s crictl images`, k3s version, and relevant k3s/containerd journal excerpts.",
        "Learner-network Artifactory access and image pulls remain unverified until operator reports are reviewed.",
        "",
    ]
    return "\n".join(lines)


def runtime_instructions(entries):
    lines = [
        "Runtime recovery instructions — k3s binary and container images",
        "Generated from content/vendor/manual-fetch.json.",
        "",
    ]
    for entry in entries:
        if entry["category"] != "runtime":
            continue
        lines.extend([
            f'{"REQUIRED" if entry["required"] else "OPTIONAL"}: {entry["name"]}',
            f'Runtime source: {entry["runtime_source"]}',
            f'SHA-256 authority: versions.lock record {entry["lock_key"]}',
            f'Recovery: {entry["recovery"]}',
            "",
        ])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Generate manual-fetch metadata and guide")
    parser.add_argument("--list", action="store_true", help="print current entries without regenerating files")
    parser.add_argument("--instructions", metavar="PATH", help="write runtime recovery instructions to PATH")
    options = parser.parse_args()
    if options.list:
        entries = json.loads(JSON_PATH.read_text(encoding="utf-8"))
        print("name | category | source | SHA-256 authority | path | status | used by | recovery")
        for entry in entries:
            status = "PRESENT" if entry["category"] == "repository" else "FETCH AT PROVISIONING"
            sha_source = entry.get("lock_key", "recorded hash" if entry["sha256"] else "n/a")
            print(f'{entry["name"]} | {entry["category"]} | {entry.get("runtime_source", entry["source"])} | {sha_source} | {entry["path"]} | {status} | {entry["used_by"]} | {entry["recovery"]}')
        return 0
    if options.instructions:
        entries = json.loads(JSON_PATH.read_text(encoding="utf-8"))
        destination = Path(options.instructions)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(runtime_instructions(entries), encoding="utf-8")
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
