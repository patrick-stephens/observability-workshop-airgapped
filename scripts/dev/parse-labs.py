#!/usr/bin/env python3
import collections
import json
import re
import shlex
import sys
from html.parser import HTMLParser
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONTENT = ROOT / "content"
REPOS = CONTENT / "repos"
EXTRACTED = CONTENT / "extracted"
TRACKS = ("opentelemetry", "otel-developers", "prometheus", "fluentbit", "perses")
KNOWN_IMAGES = {
    "docker.io/library/busybox:1.36",
    "docker.io/opensearchproject/opensearch-dashboards:3.3.0",
    "docker.io/opensearchproject/opensearch:3.3.1",
    "ghcr.io/fluent/fluent-bit:5.1.1",
    "docker.io/jaegertracing/all-in-one:1.76.0",
    "docker.io/persesdev/perses:v0.54.0",
    "docker.io/prom/prometheus:v3.13.1",
    "quay.io/prometheus/node-exporter:v1.12.1",
}
SYNTAX_PATTERNS = (
    ("heredoc", re.compile(r"<<-?\s*(?:'EOF'|\"EOF\"|EOF)\b")),
    ("buildkit-syntax", re.compile(r"^\s*#\s*syntax\s*=", re.IGNORECASE | re.MULTILINE)),
    ("run-mount", re.compile(r"^\s*RUN\s+.*--mount\s*=", re.IGNORECASE | re.MULTILINE)),
)
COMMAND_START = re.compile(r"^(?:\$\s*)?(?:sudo\s+)?(?:docker|podman)(?:-compose)?\b|^(?:\$\s*)?podman-compose\b")
DOCKERFILE_FROM = re.compile(r"^\s*FROM\s+(.*)$", re.IGNORECASE | re.MULTILINE)


class PreBlockParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.depth = 0
        self.current = []
        self.blocks = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() == "pre":
            if self.depth == 0:
                self.current = []
            self.depth += 1

    def handle_endtag(self, tag):
        if tag.lower() == "pre" and self.depth:
            self.depth -= 1
            if self.depth == 0:
                self.blocks.append("".join(self.current))
                self.current = []

    def handle_data(self, data):
        if self.depth:
            self.current.append(data)


def natural_key(path):
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r"(\d+)", path.name)]


def path_type(path):
    name = path.stem.lower()
    if name.endswith("-podman"):
        return "podman"
    if name.endswith("-rancher"):
        return "rancher"
    return "docker"


def command_lines(block, working_dir):
    lines = block.splitlines()
    index = 0
    commands = []
    while index < len(lines):
        line = lines[index].strip()
        if re.match(r"^(?:\$\s*)?cd\s+", line):
            change = re.sub(r"^(?:\$\s*)?cd\s+", "", line, count=1).strip()
            try:
                target = Path(change).expanduser()
                if not target.is_absolute():
                    target = working_dir / target
                working_dir = target.resolve()
            except (OSError, RuntimeError):
                pass
            index += 1
            continue
        if not COMMAND_START.match(line):
            index += 1
            continue
        raw_lines = [lines[index].strip()]
        while raw_lines[-1].rstrip().endswith("\\") and index + 1 < len(lines):
            index += 1
            raw_lines.append(lines[index].strip())
        raw = "\n".join(raw_lines)
        parseable = " ".join(re.sub(r"\\\s*$", "", part).strip() for part in raw_lines)
        parseable = re.sub(r"^(?:\$\s*)", "", parseable, count=1)
        try:
            tokens = shlex.split(parseable, posix=True)
        except ValueError as error:
            commands.append({"raw": raw, "tokens": [], "warning": str(error), "working_dir": working_dir})
            index += 1
            continue
        commands.append({"raw": raw, "tokens": tokens, "working_dir": working_dir})
        index += 1
    return commands, working_dir


def parse_engine(tokens):
    index = 1 if tokens and tokens[0] == "sudo" else 0
    if index >= len(tokens):
        return None, None, index
    binary = tokens[index]
    if binary in ("docker", "docker-compose"):
        engine = "docker"
    elif binary in ("podman", "podman-compose"):
        engine = "podman"
    else:
        return None, None, index
    if binary.endswith("-compose"):
        return engine, "compose", index + 1
    if index + 1 >= len(tokens):
        return engine, "other", index + 1
    subcommand = tokens[index + 1]
    if subcommand == "compose" or binary == "podman-compose":
        return engine, "compose", index + (2 if subcommand == "compose" else 1)
    if subcommand in ("build", "pull", "run", "network", "volume"):
        return engine, subcommand, index + 2
    return engine, "other", index + 2


def option_values(tokens, start, names, short_prefixes=()):
    values = []
    index = start
    while index < len(tokens):
        token = tokens[index]
        matched = False
        for name in names:
            if token == name and index + 1 < len(tokens):
                values.append(tokens[index + 1])
                index += 2
                matched = True
                break
            if token.startswith(name + "="):
                values.append(token.split("=", 1)[1])
                index += 1
                matched = True
                break
        if matched:
            continue
        for prefix in short_prefixes:
            if token.startswith(prefix) and token != prefix:
                values.append(token[len(prefix):])
                matched = True
                break
        index += 1
    return values


def positional_args(tokens, start, kind):
    result = []
    value_options = {"-f", "--file", "-p", "--publish", "-v", "--volume", "-e", "--env", "--env-file", "--name", "--network", "--mount", "--platform", "--build-arg", "--label", "--entrypoint", "--user", "-w", "--workdir", "--hostname", "--add-host", "--memory", "-m", "--cpus", "--cpu-period", "--cpu-quota", "--shm-size", "--ulimit", "--security-opt", "--dns", "--pod"}
    if kind == "build":
        value_options.update(("-t", "--tag"))
    boolean_options = {"-d", "--detach", "--rm", "-i", "--interactive", "-t", "--tty", "-P", "--publish-all", "--privileged", "--pull", "--quiet", "--no-cache", "--load"}
    index = start
    while index < len(tokens):
        token = tokens[index]
        if token in value_options:
            index += 2
            continue
        if token in boolean_options or token.startswith("--"):
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        result.append(token)
        index += 1
    return result


def dockerfile_images(text):
    images = []
    for match in DOCKERFILE_FROM.finditer(text):
        if re.search(r"\s+import\s+", match.group(1), re.IGNORECASE):
            continue
        parts = shlex.split(match.group(1), comments=True)
        image = next((part for part in parts if not part.startswith("--")), "")
        if image:
            images.append(image)
    return images


def syntax_flags(text):
    return [name for name, pattern in SYNTAX_PATTERNS if pattern.search(text)]


def resolve_under_repo(repo, path):
    try:
        resolved = path.resolve()
        return resolved if resolved == repo.resolve() or repo.resolve() in resolved.parents else None
    except (OSError, RuntimeError):
        return None


def build_details(command, repo, embedded_candidates, warnings, track, lab_name):
    tokens = command["tokens"]
    engine, kind, start = parse_engine(tokens)
    item = {
        "type": kind,
        "engine": engine,
        "sudo": bool(tokens and tokens[0] == "sudo"),
        "raw": command["raw"],
    }
    ports = option_values(tokens, start, ("-p", "--publish"), ("-p",))
    if "-P" in tokens[start:] or "--publish-all" in tokens[start:]:
        ports.append("-P")
    names = option_values(tokens, start, ("--name",))
    pods = option_values(tokens, start, ("--pod",))
    item.update({
        "ports": ports,
        "name": names[-1] if names else None,
        "detached": "-d" in tokens[start:] or "--detach" in tokens[start:],
        "env": option_values(tokens, start, ("-e", "--env"), ("-e",)),
        "volumes": option_values(tokens, start, ("-v", "--volume", "--mount"), ("-v",)),
        "pod": pods[-1] if pods else None,
    })
    if kind not in ("build", "pull", "run"):
        return item

    if kind == "build":
        tags = option_values(tokens, start, ("-t", "--tag"), ("-t",))
        files = option_values(tokens, start, ("-f", "--file"), ("-f",))
        args = positional_args(tokens, start, kind)
        context_token = args[-1] if args else "."
        cwd = command["working_dir"]
        context_path = Path(context_token).expanduser()
        if not context_path.is_absolute():
            context_path = cwd / context_path
        resolved_context = resolve_under_repo(repo, context_path)
        context_exists = resolved_context is not None and resolved_context.is_dir()
        build_file = files[-1] if files else "Dockerfile"
        build_file_path = Path(build_file).expanduser()
        if not build_file_path.is_absolute():
            build_file_path = cwd / build_file_path
        resolved_file = resolve_under_repo(repo, build_file_path)
        dockerfile_text = ""
        if resolved_file is not None and resolved_file.is_file():
            try:
                dockerfile_text = resolved_file.read_text(encoding="utf-8", errors="replace")
            except OSError as error:
                warnings.append(f"{track}/{lab_name}: cannot read Dockerfile {resolved_file}: {error}")
        if not dockerfile_text and embedded_candidates:
            dockerfile_text = "\n".join(embedded_candidates)
            if len(embedded_candidates) > 1:
                warnings.append(f"{track}/{lab_name}: multiple embedded Dockerfiles; syntax/base-image scan is best-effort")
        item.update({
            "tag": tags[-1] if tags else None,
            "context": context_path.relative_to(repo).as_posix() if resolve_under_repo(repo, context_path) else context_token,
            "dockerfile": files[-1] if files else None,
            "syntax_flags": syntax_flags(dockerfile_text),
            "base_images": dockerfile_images(dockerfile_text),
            "interactive_context": not context_exists,
        })
        if not context_exists:
            warnings.append(f"{track}/{lab_name}: build context is missing or outside the repository: {item['context']}")
        if not dockerfile_text:
            warnings.append(f"{track}/{lab_name}: no readable or embedded Dockerfile for build context {item['context']}")
        return item

    args = positional_args(tokens, start, kind)
    if kind == "pull":
        item["image"] = args[0] if args else None
    else:
        item["image"] = args[0] if args else None
        if kind == "run" and args:
            image_index = tokens.index(args[0], start)
            item["cmd"] = tokens[image_index + 1:]
    return item


def main():
    EXTRACTED.mkdir(parents=True, exist_ok=True)
    result = {}
    warnings = []
    all_images = set(KNOWN_IMAGES)
    expected_skips = []
    syntax_risks = []

    for track in TRACKS:
        repo = REPOS / track
        labs = []
        lab_files = sorted(repo.glob("lab*.html"), key=natural_key)
        for lab_path in lab_files:
            parser = PreBlockParser()
            try:
                parser.feed(lab_path.read_text(encoding="utf-8", errors="replace"))
            except OSError as error:
                warnings.append(f"{track}/{lab_path.name}: cannot read lab: {error}")
                continue
            blocks = parser.blocks
            embedded = [block for block in blocks if DOCKERFILE_FROM.search(block)]
            working_dir = repo.resolve()
            commands = []
            for block in blocks:
                parsed, working_dir = command_lines(block, working_dir)
                for command in parsed:
                    if command.get("warning"):
                        warnings.append(f"{track}/{lab_path.name}: ambiguous command {command['raw']!r}: {command['warning']}")
                        continue
                    tokens = command["tokens"]
                    if not tokens:
                        continue
                    engine, kind, _ = parse_engine(tokens)
                    if engine is None:
                        continue
                    item = build_details(command, repo, embedded, warnings, track, lab_path.name)
                    commands.append(item)
                    if item["type"] == "build":
                        all_images.update(item["base_images"])
                        if item["interactive_context"]:
                            expected_skips.append(f"{track}/{lab_path.name}: context={item['context']} command={item['raw']}")
                        if item["syntax_flags"]:
                            syntax_risks.append(f"{track}/{lab_path.name}: flags={','.join(item['syntax_flags'])} context={item['context']} command={item['raw']}")
            labs.append({"file": lab_path.name, "path_type": path_type(lab_path), "commands": commands})
        result[track] = {"labs": labs}

    (EXTRACTED / "commands.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (EXTRACTED / "external-images.txt").write_text("".join(f"{image}\n" for image in sorted(all_images)), encoding="utf-8")
    (EXTRACTED / "build-failures-expected.txt").write_text("".join(f"{line}\n" for line in expected_skips), encoding="utf-8")
    (EXTRACTED / "syntax-risk.txt").write_text("".join(f"{line}\n" for line in syntax_risks), encoding="utf-8")
    (EXTRACTED / "parse-warnings.txt").write_text("".join(f"{line}\n" for line in warnings), encoding="utf-8")

    for track, data in result.items():
        by_type = collections.Counter()
        by_engine = collections.Counter()
        by_path = collections.Counter(lab["path_type"] for lab in data["labs"])
        builds_by_path = collections.Counter()
        sudo_by_path = collections.defaultdict(collections.Counter)
        images = set()
        for lab in data["labs"]:
            for command in lab["commands"]:
                by_type[command["type"]] += 1
                by_engine[command["engine"]] += 1
                sudo_by_path[lab["path_type"]]["sudo" if command["sudo"] else "user"] += 1
                if command["type"] == "build":
                    builds_by_path[lab["path_type"]] += 1
                images.update(command.get("base_images", []))
        print(f"{track}: labs={len(data['labs'])}; types={dict(sorted(by_type.items()))}; builds_by_path_type={dict(sorted(builds_by_path.items()))}; engines={dict(sorted(by_engine.items()))}; path_type={dict(sorted(by_path.items()))}")
        print(f"  sudo_by_path_type={{{', '.join(f'{key}: {dict(sorted(value.items()))}' for key, value in sorted(sudo_by_path.items()))}}}; base_images={sorted(images)}")

    if not any(result.values()):
        print(f"No lab HTML files found under {REPOS}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
