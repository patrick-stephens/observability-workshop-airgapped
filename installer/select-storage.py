#!/usr/bin/env python3
"""Select the only eligible target disk after a short operator grace period."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    yaml = None

WAIT_SECONDS = 5


def flattened(nodes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    result = []
    for node in nodes:
        result.append(node)
        result.extend(flattened(node.get("children") or []))
    return result


def device_path(value: str) -> str:
    value = value.split("[", 1)[0]
    return os.path.realpath(value) if value.startswith("/dev/") else value


def eligible_disks(blockdevices: list[dict[str, Any]], installer_source: str = "") -> list[str]:
    installer_device = device_path(installer_source) if installer_source else ""
    eligible = []
    for disk in blockdevices:
        if disk.get("type") != "disk" or disk.get("rm") or disk.get("ro"):
            continue
        if int(disk.get("size") or 0) <= 0:
            continue
        nodes = flattened([disk])
        if installer_device and any(device_path(str(node.get("name", ""))) == installer_device for node in nodes):
            continue
        eligible.append(str(disk["name"]))
    return sorted(eligible)


def configure_autoinstall(config: dict[str, Any], disk: str) -> dict[str, Any]:
    wrapped = isinstance(config.get("autoinstall"), dict)
    autoinstall = config["autoinstall"] if wrapped else config
    if not isinstance(autoinstall, dict) or "version" not in autoinstall:
        raise ValueError("autoinstall.yaml must contain a versioned autoinstall mapping")
    autoinstall["storage"] = {
        "layout": {
            "name": "lvm",
            "sizing-policy": "all",
            "match": {"path": disk},
        }
    }
    interactive_sections = autoinstall.get("interactive-sections") or []
    autoinstall["interactive-sections"] = [section for section in interactive_sections if section != "storage"]
    return config


def self_test() -> None:
    fixtures = [
        {"name": "/dev/vda", "type": "disk", "rm": False, "ro": False, "size": 128849018880},
        {"name": "/dev/sr0", "type": "rom", "rm": True, "ro": True, "size": 4096},
        {"name": "/dev/sdb", "type": "disk", "rm": True, "ro": False, "size": 64000000},
    ]
    assert eligible_disks(fixtures) == ["/dev/vda"]
    assert eligible_disks(fixtures, "/dev/vda") == []
    assert eligible_disks(fixtures + [{"name": "/dev/vdb", "type": "disk", "rm": False, "ro": False, "size": 64000000}]) == ["/dev/vda", "/dev/vdb"]
    config = configure_autoinstall({"autoinstall": {"version": 1, "interactive-sections": ["storage"]}}, "/dev/vda")
    assert config["autoinstall"]["storage"]["layout"]["match"]["path"] == "/dev/vda"
    assert config["autoinstall"]["interactive-sections"] == []
    config = configure_autoinstall({"version": 1, "interactive-sections": ["storage"]}, "/dev/vda")
    assert config["storage"]["layout"]["match"]["path"] == "/dev/vda"
    assert config["interactive-sections"] == []
    print("storage selector self-test passed")


def configure_storage(config_path: Path) -> int:
    print(f"[installer-storage] Waiting {WAIT_SECONDS} seconds before checking disks.", flush=True)
    time.sleep(WAIT_SECONDS)
    try:
        block_output = subprocess.run(
            ["lsblk", "--json", "--paths", "--bytes", "--output", "NAME,TYPE,RM,RO,SIZE"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        blockdevices = json.loads(block_output)["blockdevices"]
    except (OSError, subprocess.CalledProcessError, KeyError, json.JSONDecodeError) as error:
        print(f"[installer-storage] Could not inspect disks ({error}); leaving disk selection interactive.", flush=True)
        return 0
    installer_source = subprocess.run(
        ["findmnt", "--noheadings", "--evaluate", "--output", "SOURCE", "--target", "/cdrom"],
        check=False,
        capture_output=True,
        text=True,
    ).stdout.strip()
    disks = eligible_disks(blockdevices, installer_source)
    if len(disks) != 1:
        print(f"[installer-storage] Found {len(disks)} eligible non-removable disks; leaving disk selection interactive.", flush=True)
        return 0
    if yaml is None:
        print("[installer-storage] PyYAML is unavailable; leaving disk selection interactive.", flush=True)
        return 0

    temporary_path = None
    try:
        config = yaml.safe_load(config_path.read_text(encoding="utf-8"))
        config = configure_autoinstall(config, disks[0])

        original_mode = stat.S_IMODE(config_path.stat().st_mode)
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=config_path.parent, delete=False) as temporary:
            temporary_path = Path(temporary.name)
            yaml.safe_dump(config, temporary, sort_keys=False)
        os.chmod(temporary_path, original_mode)
        os.replace(temporary_path, config_path)
    except (OSError, ValueError, yaml.YAMLError) as error:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
        print(f"[installer-storage] Could not configure the sole disk ({error}); leaving disk selection interactive.", flush=True)
        return 0
    print(f"[installer-storage] Selecting the only eligible disk {disks[0]} and continuing with LVM.", flush=True)
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        raise SystemExit(0)
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {sys.argv[0]} AUTOINSTALL_YAML | --self-test")
    raise SystemExit(configure_storage(Path(sys.argv[1])))
