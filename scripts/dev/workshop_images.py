#!/usr/bin/env python3
import json
import shlex
import subprocess
from pathlib import Path

try:
    import yaml
except ImportError as error:
    raise SystemExit("PyYAML is required; install the pinned version recorded in versions.lock") from error


ROOT = Path(__file__).resolve().parents[2]


def read_external_images():
    path = ROOT / "content/extracted/external-images.txt"
    if not path.is_file():
        raise FileNotFoundError(path)
    return {line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip() and not line.lstrip().startswith("#")}


def read_local_build_tags():
    path = ROOT / "content/extracted/commands.json"
    if not path.is_file():
        raise FileNotFoundError(path)
    commands = json.loads(path.read_text(encoding="utf-8"))
    tags = set()
    for track_data in commands.values():
        for lab in track_data.get("labs", []):
            for command in lab.get("commands", []):
                if command.get("type") == "build" and command.get("tag"):
                    tags.add(command["tag"])
    return tags


def manifest_images(path):
    manifest_path = ROOT / path
    if not manifest_path.is_file():
        raise FileNotFoundError(manifest_path)
    documents = list(yaml.safe_load_all(manifest_path.read_text(encoding="utf-8")))
    found = set()

    def visit(value):
        if isinstance(value, dict):
            for key in ("containers", "initContainers", "ephemeralContainers"):
                containers = value.get(key)
                if isinstance(containers, list):
                    found.update(container["image"] for container in containers if isinstance(container, dict) and container.get("image"))
            if value.get("kind") == "List":
                for item in value.get("items", []):
                    visit(item)
            else:
                for child in value.values():
                    if isinstance(child, (dict, list)):
                        visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    for document in documents:
        visit(document)
    return found


def canonical_reference(reference, local_build_tags):
    if reference.startswith("localhost/"):
        return reference
    if reference in local_build_tags:
        return reference
    first, separator, remainder = reference.partition("/")
    if separator and ("." in first or ":" in first):
        return reference
    if separator:
        return f"docker.io/{reference}"
    return f"docker.io/library/{reference}"


def _curated_sources():
    curated_path = ROOT / "content/extracted/curated.json"
    if not curated_path.is_file():
        raise FileNotFoundError(curated_path)
    return json.loads(curated_path.read_text(encoding="utf-8"))


def _manifest_store_references(curated, k3s_only=False):
    references = {"podman": set(), "k3s": set()}
    manifest_paths = set()
    for track_data in curated.values():
        for run in track_data.get("runs", []):
            store = "k3s" if run.get("requires_k3s") else "podman"
            if k3s_only and store != "k3s":
                continue
            manifest = run.get("source", {}).get("manifest")
            if manifest:
                manifest_paths.add((manifest, store))
    for path, store in sorted(manifest_paths):
        references[store].update(manifest_images(path))
    return references


def _make_entries(podman_references, k3s_references, local_tags):
    all_references = podman_references | k3s_references
    stores = {}
    for reference in all_references:
        canonical = canonical_reference(reference, local_tags)
        stores.setdefault(canonical, set())
        if reference in podman_references:
            stores[canonical].add("podman")
        if reference in k3s_references:
            stores[canonical].add("k3s")
    entries = []
    for reference in sorted(stores):
        local_reference = reference.removeprefix("localhost/")
        local = reference.startswith("localhost/") or local_reference in local_tags or reference in local_tags
        entries.append({
            "name": reference,
            "source": "in-repo" if local else f"docker://{reference}",
            "stores": sorted(stores[reference]),
            "expected_size": None,
        })
    return entries


def discover_images():
    external = read_external_images()
    local_tags = read_local_build_tags()
    curated = _curated_sources()
    manifest_references = _manifest_store_references(curated)
    podman_references = set(external) | manifest_references["podman"]
    k3s_references = manifest_references["k3s"]
    return _make_entries(podman_references, k3s_references, local_tags)


def discover_store_images():
    external = read_external_images()
    local_tags = read_local_build_tags()
    curated = _curated_sources()
    manifest_references = _manifest_store_references(curated)
    podman_references = set(external) | manifest_references["podman"]
    return {
        "podman": sorted({canonical_reference(ref, local_tags) for ref in podman_references}),
        "k3s": sorted({canonical_reference(ref, local_tags) for ref in manifest_references["k3s"]}),
    }


def store_entries(store):
    local_tags = read_local_build_tags()
    entries = []
    for reference in discover_store_images()[store]:
        local_reference = reference.removeprefix("localhost/")
        local = reference.startswith("localhost/") or local_reference in local_tags or reference in local_tags
        entries.append({
            "name": reference,
            "source": "in-repo" if local else f"docker://{reference}",
            "build_context_available": local_build_command(reference) is not None if local else False,
        })
    return entries


def local_build_command(reference):
    target = reference.removeprefix("localhost/")
    commands = json.loads((ROOT / "content/extracted/commands.json").read_text(encoding="utf-8"))
    for track, track_data in commands.items():
        for lab in track_data.get("labs", []):
            for command in lab.get("commands", []):
                if command.get("type") != "build" or command.get("tag") != target:
                    continue
                build_step = next((step for step in command.get("preload_steps", []) if step.startswith("docker build ")), None)
                if build_step:
                    return track, shlex.split(build_step)
    return None


def build_local_image(reference):
    result = local_build_command(reference)
    if result is None:
        raise SystemExit(f"no captured preloadable build command exists for in-repository image {reference}")
    track, arguments = result
    print(f"building {reference} from the vendored {track} context", flush=True)
    subprocess.run(arguments, cwd=ROOT / "content/repos" / track, check=True)


def print_image_list(entries):
    print("image | expected size | stores | source")
    for entry in entries:
        size = "unknown" if entry["expected_size"] is None else f'{entry["expected_size"]} bytes'
        print(f'{entry["name"]} | {size} | {",".join(entry["stores"])} | {entry["source"]}')


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--store", choices=("podman", "k3s"))
    parser.add_argument("--build-local")
    options = parser.parse_args()
    if options.build_local:
        build_local_image(options.build_local)
    elif options.list:
        print_image_list(discover_images())
    elif options.store:
        for entry in store_entries(options.store):
            print(json.dumps(entry, sort_keys=True))
    else:
        for entry in discover_images():
            print(json.dumps(entry, sort_keys=True))