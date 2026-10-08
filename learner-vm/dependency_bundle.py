"""Standard-library helper for verified learner dependency bundles."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
import tempfile
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET


SCHEMA = 1
PACKAGE_DIRS = ("cache/pypi/wheels", "cache/maven/repository", "cache/npm", "cache/go/pkg/mod")


def endpoint_url(base, suffix):
    parsed = urlsplit(base)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("endpoint must be a credential-free HTTPS URL")
    if any(character.isspace() for character in base) or any(character in base for character in "'\"\\"):
        raise ValueError("unsafe endpoint characters")
    if parsed.path and not re.fullmatch(r"/[A-Za-z0-9._~/-]*", parsed.path):
        raise ValueError("unsafe endpoint path")
    if not re.fullmatch(r"[A-Za-z0-9._~/@-]+", suffix) or ".." in suffix.split("/"):
        raise ValueError("unsafe package probe path")
    return base.rstrip("/") + "/" + suffix.lstrip("/")


def digest_stream(source):
    checksum = hashlib.sha256()
    for block in iter(lambda: source.read(1024 * 1024), b""):
        checksum.update(block)
    return checksum.hexdigest()


def digest_file(path):
    with Path(path).open("rb") as source:
        return digest_stream(source)


def safe_path(value):
    path = PurePosixPath(value)
    if not value or "\\" in value or path.is_absolute() or any(part in ("", ".", "..") for part in value.split("/")):
        raise ValueError("unsafe bundle path")
    return path


def validate_manifest(manifest):
    if manifest.get("schema") != SCHEMA or manifest.get("architecture") != "amd64":
        raise ValueError("unsupported bundle schema or architecture")
    if not re.fullmatch(r"[0-9a-f]{40,64}", manifest.get("source_commit", "")):
        raise ValueError("bundle source commit is missing or invalid")
    images = manifest.get("images", [])
    if not images or len({image["reference"] for image in images}) != len(images):
        raise ValueError("bundle requires unique image references")
    for image in images:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]*", image["reference"]) or not re.fullmatch(r"sha256:[0-9a-f]{64}", image.get("id", "")):
            raise ValueError("invalid image reference or config ID")
    coverage = manifest.get("coverage", {})
    required = set(coverage.get("required", []))
    verified = set(coverage.get("verified", []))
    if not required or required != verified or coverage.get("excluded"):
        raise ValueError("bundle coverage is incomplete; publication/import refused")
    if manifest.get("offline_verified") is not True:
        raise ValueError("bundle has not passed offline validation")


def seal(source, destination):
    source = Path(source).resolve()
    destination = Path(destination).resolve()
    if source == destination or source in destination.parents:
        raise ValueError("output archive must be outside the source directory")
    manifest_path = source / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    validate_manifest(manifest)
    for directory in PACKAGE_DIRS:
        if not any((source / directory).rglob("*")):
            raise ValueError("required package cache is empty: " + directory)
    if not (source / "images/lab-images.tar").is_file():
        raise ValueError("multi-image archive is missing")
    checksums = {}
    for path in sorted(source.rglob("*")):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError("links and special files are not allowed in a bundle")
        if path.is_file() and path.name != "SHA256SUMS":
            relative = path.relative_to(source).as_posix()
            safe_path(relative)
            checksums[relative] = digest_file(path)
    (source / "SHA256SUMS").write_text("".join(f"{checksum}  {name}\n" for name, checksum in checksums.items()), encoding="utf-8")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".partial")
    if temporary.exists() or destination.exists():
        raise ValueError("refusing to replace an existing archive")
    try:
        with tarfile.open(temporary, "w:gz") as archive:
            for path in [source] + sorted(source.rglob("*")):
                archive.add(path, arcname="learner-dependencies" + ("/" + path.relative_to(source).as_posix() if path != source else ""), recursive=False)
        checksum = digest_file(temporary)
        os.replace(temporary, destination)
        destination.with_name(destination.name + ".sha256").write_text(f"{checksum}  {destination.name}\n", encoding="utf-8")
    finally:
        if temporary.exists():
            temporary.unlink()
    print(checksum)


def verify_directory(directory):
    directory = Path(directory)
    marker = directory / ".bundle-sha256"
    if directory.is_symlink() or not directory.is_dir() or not marker.is_file():
        raise ValueError("installed bundle directory is unverified")
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    validate_manifest(manifest)
    lines = (directory / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
    expected_files = {}
    for line in lines:
        checksum, separator, name = line.partition("  ")
        safe_path(name)
        if not separator or not re.fullmatch(r"[0-9a-f]{64}", checksum) or name in expected_files:
            raise ValueError("invalid or duplicate installed checksum record")
        expected_files[name] = checksum
    actual_files = {}
    for path in directory.rglob("*"):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError("installed bundle contains a link or special file")
        if path.is_file() and path.name != "SHA256SUMS" and path.name != ".bundle-sha256":
            name = path.relative_to(directory).as_posix()
            actual_files[name] = digest_file(path)
    if actual_files != expected_files:
        raise ValueError("installed bundle contents do not match SHA256SUMS")
    return manifest


def verify(archive_path, expected, destination=None):
    if not re.fullmatch(r"[0-9a-f]{64}", expected) or digest_file(archive_path) != expected:
        raise ValueError("outer bundle checksum mismatch")
    target = Path(destination) if destination else None
    if target and (target.exists() or target.is_symlink()):
        if target.is_symlink() or (target / ".bundle-sha256").read_text(encoding="ascii").strip() != expected:
            raise ValueError("destination exists with a different bundle identity")
        verify_directory(target)
        print(json.dumps({"schema": SCHEMA, "verified": True, "reused": True}))
        return
    with tarfile.open(archive_path, "r:gz") as archive:
        members = {}
        for member in archive.getmembers():
            name = member.name.rstrip("/")
            safe_path(name)
            if name.split("/")[0] != "learner-dependencies" or name in members:
                raise ValueError("unexpected top-level entry or duplicate archive member")
            if not (member.isfile() or member.isdir()):
                raise ValueError("archive links and special files are rejected")
            members[name] = member
        manifest_member = members.get("learner-dependencies/manifest.json")
        checksums_member = members.get("learner-dependencies/SHA256SUMS")
        if not manifest_member or not manifest_member.isfile() or not checksums_member or not checksums_member.isfile():
            raise ValueError("bundle manifest or checksums are missing")
        with archive.extractfile(manifest_member) as source:
            manifest = json.load(source)
        validate_manifest(manifest)
        with archive.extractfile(checksums_member) as source:
            lines = source.read().decode("utf-8").splitlines()
        checksums = {}
        for line in lines:
            checksum, separator, name = line.partition("  ")
            safe_path(name)
            if not separator or not re.fullmatch(r"[0-9a-f]{64}", checksum) or name in checksums:
                raise ValueError("invalid or duplicate checksum record")
            checksums[name] = checksum
        actual = {name[len("learner-dependencies/"):] for name, member in members.items() if member.isfile() and name != "learner-dependencies/SHA256SUMS"}
        if actual != set(checksums):
            raise ValueError("checksum inventory does not match archive contents")
        for name, expected_file in checksums.items():
            with archive.extractfile(members["learner-dependencies/" + name]) as source:
                if digest_stream(source) != expected_file:
                    raise ValueError("inner checksum mismatch: " + name)
        if target:
            target.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix=".learner-bundle-", dir=target.parent) as staging:
                stage = Path(staging) / "payload"
                stage.mkdir(mode=0o755)
                for name, member in members.items():
                    if name == "learner-dependencies":
                        continue
                    path = stage / name[len("learner-dependencies/"):]
                    if member.isdir():
                        path.mkdir(parents=True, exist_ok=True)
                    else:
                        path.parent.mkdir(parents=True, exist_ok=True)
                        with archive.extractfile(member) as source, path.open("xb") as output:
                            shutil.copyfileobj(source, output)
                        path.chmod(0o755 if member.mode & 0o111 else 0o644)
                    (stage / ".bundle-sha256").write_text(expected + "\n", encoding="ascii")
                os.replace(stage, target)
    print(json.dumps({"schema": SCHEMA, "architecture": manifest["architecture"], "images": len(manifest["images"]), "verified": True}))


def profile(output, root, mode, endpoints, ca, working_cache_root=None):
    output = Path(output)
    root = str(Path(root).resolve())
    working_cache_root = str(Path(working_cache_root or (Path.home() / ".cache/o11y-lab")).resolve())
    if any(character in root + str(output) + working_cache_root for character in "\n\r'\""):
        raise ValueError("unsafe cache root")
    if mode == "artifactory":
        for endpoint in endpoints:
            parsed = urlsplit(endpoint)
            if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or (parsed.path and not re.fullmatch(r"/[A-Za-z0-9._~/-]*", parsed.path)):
                raise ValueError("package endpoints must be credential-free HTTPS URLs")
        if ca and ("\n" in ca or not Path(ca).is_file()):
            raise ValueError("CA certificate must be an existing local file")
    output.mkdir(parents=True, exist_ok=True)
    pip = "[global]\ndisable-pip-version-check = true\n"
    if mode == "offline":
        pip += f"no-index = true\nfind-links = {root}/cache/pypi/wheels\n"
    else:
        pip += "index-url = " + endpoints[0] + "\n"
        if ca:
            pip += "cert = " + ca + "\n"
    (output / "pip.conf").write_text(pip, encoding="utf-8")
    settings = ET.Element("settings", xmlns="http://maven.apache.org/SETTINGS/1.0.0")
    ET.SubElement(settings, "localRepository").text = working_cache_root + "/maven"
    mirror_url = "file://" + root + "/cache/maven/repository" if mode == "offline" else endpoints[1]
    mirror = ET.SubElement(ET.SubElement(settings, "mirrors"), "mirror")
    for name, value in (("id", "workshop-artifactory"), ("mirrorOf", "*"), ("url", mirror_url)):
        ET.SubElement(mirror, name).text = value
    if mode == "offline":
        ET.SubElement(settings, "offline").text = "true"
    policy_profile = ET.SubElement(ET.SubElement(settings, "profiles"), "profile")
    ET.SubElement(policy_profile, "id").text = "workshop-cache-policy"
    ET.SubElement(ET.SubElement(policy_profile, "activation"), "activeByDefault").text = "true"
    for collection, item_name in (("repositories", "repository"), ("pluginRepositories", "pluginRepository")):
        repository = ET.SubElement(ET.SubElement(policy_profile, collection), item_name)
        ET.SubElement(repository, "id").text = "central"
        ET.SubElement(repository, "url").text = mirror_url
        for channel in ("releases", "snapshots"):
            policy = ET.SubElement(repository, channel)
            ET.SubElement(policy, "enabled").text = "true"
            ET.SubElement(policy, "updatePolicy").text = "never"
            ET.SubElement(policy, "checksumPolicy").text = "fail"
    ET.ElementTree(settings).write(output / "settings.xml", encoding="utf-8", xml_declaration=True)
    npm = "strict-ssl=true\ncache=" + working_cache_root + "/npm\nprefer-offline=true\naudit=false\nfund=false\nupdate-notifier=false\n"
    npm += "offline=true\n" if mode == "offline" else "registry=" + endpoints[2] + "\n"
    if ca and mode == "artifactory":
        npm += "cafile=" + ca + "\n"
    (output / "npmrc").write_text(npm, encoding="utf-8")
    proxy = "file://" + root + "/cache/go/pkg/mod/cache/download" if mode == "offline" else endpoints[3]
    environment = f"export PIP_CONFIG_FILE='{output}/pip.conf'\nexport PIP_DISABLE_PIP_VERSION_CHECK=1\nexport NPM_CONFIG_USERCONFIG='{output}/npmrc'\nexport NPM_CONFIG_PREFER_OFFLINE=true\nexport NPM_CONFIG_AUDIT=false\nexport NPM_CONFIG_FUND=false\nexport NPM_CONFIG_UPDATE_NOTIFIER=false\nexport GOPROXY='{proxy}'\nexport GOMODCACHE='{working_cache_root}/go/pkg/mod'\nexport GOTOOLCHAIN=local\n"
    environment += f"export MAVEN_ARGS='--settings {output}/settings.xml -Dmaven.repo.local={working_cache_root}/maven'\n"
    if mode == "offline":
        environment += f"export PIP_NO_INDEX=1\nexport PIP_FIND_LINKS='{root}/cache/pypi/wheels'\nexport MAVEN_ARGS=\"$MAVEN_ARGS --offline --no-snapshot-updates\"\n"
    else:
        environment += "unset PIP_NO_INDEX PIP_FIND_LINKS\n"
    (output / "profile.sh").write_text(environment, encoding="utf-8")
    print("Generated " + mode + " profiles; Maven settings and writable cache seeding must be selected explicitly.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command")
    endpoint = commands.add_parser("endpoint")
    endpoint.add_argument("--base", required=True)
    endpoint.add_argument("--suffix", required=True)
    pack = commands.add_parser("pack")
    pack.add_argument("--source", required=True)
    pack.add_argument("--output", required=True)
    check = commands.add_parser("verify")
    check.add_argument("--archive", required=True)
    check.add_argument("--sha256", required=True)
    check.add_argument("--destination")
    profiles = commands.add_parser("profiles")
    profiles.add_argument("--output", required=True)
    profiles.add_argument("--root", required=True)
    profiles.add_argument("--working-cache-root", default="")
    profiles.add_argument("--mode", choices=("offline", "artifactory"), default="offline")
    for manager in ("pypi", "maven", "npm", "go"):
        profiles.add_argument("--" + manager + "-url", default="")
    profiles.add_argument("--ca", default="")
    arguments = parser.parse_args()
    if not arguments.command:
        parser.error("a command is required")
    try:
        if arguments.command == "endpoint":
            print(endpoint_url(arguments.base, arguments.suffix))
        elif arguments.command == "pack":
            seal(arguments.source, arguments.output)
        elif arguments.command == "verify":
            verify(arguments.archive, arguments.sha256, arguments.destination)
        else:
            working_root = arguments.working_cache_root or str(Path.home() / ".cache/o11y-lab")
            profile(arguments.output, arguments.root, arguments.mode, (arguments.pypi_url, arguments.maven_url, arguments.npm_url, arguments.go_url), arguments.ca, working_root)
    except (ValueError, OSError, KeyError, tarfile.TarError) as error:
        parser.exit(1, "[dependency-bundle] ERROR: " + str(error) + "\n")


if __name__ == "__main__":
    main()