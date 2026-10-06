#!/usr/bin/env python3
"""Reject common private network identifiers in committed learner feedback."""

import ipaddress
import re
import sys
from pathlib import Path


IPV4_PATTERN = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?(?![\w.])")
IPV6_PATTERN = re.compile(r"(?<![A-Fa-f0-9:])(?:[A-Fa-f0-9]{0,4}:){2,7}[A-Fa-f0-9]{0,4}(?:/\d{1,3})?(?![A-Fa-f0-9:])")
INTERNAL_HOST_PATTERN = re.compile(
    r"(?<![A-Za-z0-9_-])(?:[A-Za-z0-9-]+\.)+(?:internal|corp|intranet|lan|local|home|lab)"
    r"(?![A-Za-z0-9_-])",
    re.IGNORECASE,
)
HOST_LINE_PATTERN = re.compile(r"^\s*HOST:\s*(\S+)", re.IGNORECASE | re.MULTILINE)
PRIVATE_NETWORKS = tuple(
    ipaddress.ip_network(cidr)
    for cidr in (
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",
        "100.64.0.0/10",
        "fc00::/7",
        "fe80::/10",
    )
)


def is_private_address(value: str) -> bool:
    try:
        address = ipaddress.ip_address(value.split("/", 1)[0].split("%", 1)[0])
    except ValueError:
        try:
            network = ipaddress.ip_network(value, strict=False)
        except ValueError:
            return False
        return any(network.version == private.version and network.overlaps(private) for private in PRIVATE_NETWORKS)
    if address.version == 6 and address.ipv4_mapped is not None:
        address = address.ipv4_mapped
    return any(address.version == private.version and address in private for private in PRIVATE_NETWORKS)


def check_text(text: str, filename: str) -> list[str]:
    problems = []
    for match in HOST_LINE_PATTERN.finditer(text):
        if match.group(1).casefold() != "[redacted]":
            line = text.count("\n", 0, match.start()) + 1
            problems.append(f"{filename}:{line}: redact the HOST value as [REDACTED]")

    for pattern, description in (
        (IPV4_PATTERN, "private IPv4 address or network"),
        (IPV6_PATTERN, "private IPv6 address or network"),
        (INTERNAL_HOST_PATTERN, "internal DNS name"),
    ):
        for match in pattern.finditer(text):
            if pattern in (IPV4_PATTERN, IPV6_PATTERN) and not is_private_address(match.group()):
                continue
            line = text.count("\n", 0, match.start()) + 1
            problems.append(f"{filename}:{line}: redact {description}")
    return problems


def main() -> int:
    if len(sys.argv) == 1:
        inputs = [("<stdin>", sys.stdin.read())]
    else:
        inputs = []
        for name in sys.argv[1:]:
            path = Path(name)
            try:
                inputs.append((name, path.read_text(encoding="utf-8")))
            except (OSError, UnicodeError) as error:
                print(f"{name}: could not read feedback record: {error}", file=sys.stderr)
                return 1

    problems = [problem for name, text in inputs for problem in check_text(text, name)]
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
