# v1: Assemble the requested 10r/10s2 review evidence in one bounded, reproducible packet.
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EXTRACTED = ROOT / "content" / "extracted"
MAX_LINES = 400


def run_output(arguments, cwd=ROOT):
    completed = subprocess.run(arguments, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    return completed.stdout.rstrip("\n")


def selftest_report():
    output = run_output(["bash", str(ROOT / "learner-vm/scripts/00-diagnose.sh"), "--selftest"])
    match = re.search(r"(?m)^==================== REPORT BEGIN ====================\n.*?^==================== REPORT END ======================\s*$", output, re.DOTALL)
    if not match:
        raise RuntimeError("00-diagnose --selftest did not emit a complete report block")
    return match.group(0)


def grep_audits():
    audits = (
        ("docker-ce", ["grep", "-rn", "docker-ce", "learner-vm/scripts", "learner-vm/lab-vm.conf"]),
        ("/etc/docker", ["grep", "-rn", "/etc/docker", "learner-vm/scripts"]),
        ("daemon.json", ["grep", "-rn", "daemon.json", "learner-vm/scripts"]),
        ("registry-mirrors", ["grep", "-rn", "registry-mirrors", "learner-vm/scripts"]),
    )
    results = []
    for name, command in audits:
        output = run_output(command)
        results.append(f"$ {' '.join(command)}\n{output if output else '(no matches)'}")
    return "\n".join(results)


def read_artifact(relative_path, empty_text=None):
    path = ROOT / relative_path
    if not path.is_file():
        raise FileNotFoundError(path)
    content = path.read_text(encoding="utf-8", errors="replace").rstrip("\n")
    if not content and empty_text is not None:
        return empty_text
    return content


def sections():
    return [
        ("selftest-report", "scripts/00-diagnose.sh --selftest", selftest_report()),
        ("grep-audits", "the four required grep audits", grep_audits()),
        ("lab-vm.conf", "learner-vm/lab-vm.conf", read_artifact("learner-vm/lab-vm.conf")),
        ("README-FIRST.md", "learner-vm/README-FIRST.md", read_artifact("learner-vm/README-FIRST.md")),
        ("curated.json", "content/extracted/curated.json", read_artifact("content/extracted/curated.json")),
        ("build-failures-expected.txt", "content/extracted/build-failures-expected.txt", read_artifact("content/extracted/build-failures-expected.txt", "(empty)")),
        ("runtime-downloads.txt", "content/extracted/runtime-downloads.txt", read_artifact("content/extracted/runtime-downloads.txt", "(empty - no runtime downloads detected)")),
        ("docs-patched.txt", "content/extracted/docs-patched.txt", read_artifact("content/extracted/docs-patched.txt", "(empty)")),
        ("docs-gaps.txt", "content/extracted/docs-gaps.txt", read_artifact("content/extracted/docs-gaps.txt", "(empty)")),
    ]


def bounded_packet(items):
    bodies = [body.splitlines() or [""] for _, _, body in items]
    def count_lines():
        return sum(len(body) + 2 for body in bodies)

    overflow = count_lines() - MAX_LINES
    if overflow > 0:
        for index in sorted(range(len(items)), key=lambda current: len(bodies[current]), reverse=True):
            if overflow <= 0:
                break
            name, source_path, _ = items[index]
            body = bodies[index]
            marker = f"... [truncated, full file at {source_path}] ..."
            reducible = max(0, len(body) - 1)
            reduction = min(overflow, reducible)
            kept = len(body) - reduction
            if kept <= 1:
                bodies[index] = [marker]
            else:
                prefix = max(1, (kept - 1) // 2)
                suffix = max(0, kept - 1 - prefix)
                bodies[index] = body[:prefix] + [marker] + (body[-suffix:] if suffix else [])
            overflow = count_lines() - MAX_LINES
    if count_lines() > MAX_LINES:
        raise RuntimeError(f"reviewer packet exceeds {MAX_LINES} lines after truncation")

    packet = []
    for (name, _, _), body in zip(items, bodies):
        packet.append(f"=== BEGIN {name} ===")
        packet.extend(body)
        packet.append(f"=== END {name} ===")
    return "\n".join(packet) + "\n"


def main():
    EXTRACTED.mkdir(parents=True, exist_ok=True)
    packet = bounded_packet(sections())
    destination = EXTRACTED / "reviewer-packet.md"
    destination.write_text(packet, encoding="utf-8")
    line_count = len(packet.splitlines())
    print(f"{destination.relative_to(ROOT)}: {line_count} lines (limit {MAX_LINES})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
