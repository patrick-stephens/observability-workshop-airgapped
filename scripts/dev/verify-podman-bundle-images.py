#!/usr/bin/env python3
"""Verify and canonicalise image references loaded from the learner bundle."""

import json
import subprocess
import sys


def inspect(reference):
    value = subprocess.check_output(
        ["podman", "image", "inspect", "--format", "{{.Id}}", reference],
        universal_newlines=True,
        stderr=subprocess.DEVNULL,
    ).strip()
    return value if value.startswith("sha256:") else "sha256:" + value


def main(manifest_path):
    with open(manifest_path, encoding="utf-8") as source:
        images = json.load(source)["images"]
    for image in images:
        reference = image["reference"]
        expected = image["id"]
        try:
            actual = inspect(reference)
        except subprocess.CalledProcessError:
            actual = ""
        if actual != expected:
            try:
                by_id = inspect(expected)
            except subprocess.CalledProcessError:
                by_id = ""
            if by_id == expected:
                subprocess.check_call(["podman", "image", "tag", expected.split(":", 1)[1], reference])
                actual = inspect(reference)
        if actual != expected:
            raise SystemExit("image ID mismatch for {}: {} != {}".format(reference, actual, expected))
    print("Podman image inventory PASS: {} references".format(len(images)))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify-podman-bundle-images.py MANIFEST.json")
    main(sys.argv[1])