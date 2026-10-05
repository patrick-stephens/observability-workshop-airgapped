#!/usr/bin/env python3
# v2: Simulate lab working directories, resolve contexts, deduplicate commands, and scan every code block for base images.
import collections
import hashlib
import html
import json
import os
import re
import shlex
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[2]
CONTENT = ROOT / "content"
REPOS = CONTENT / "repos"
EXTRACTED = CONTENT / "extracted"
TRACKS = ("opentelemetry", "otel-developers", "prometheus", "fluentbit", "perses")
PREVIOUS_BUILD_OCCURRENCES = {"opentelemetry": 26, "otel-developers": 14, "prometheus": 28, "fluentbit": 22, "perses": 0}
PREVIOUS_RUN_OCCURRENCES = {"opentelemetry": 7, "otel-developers": 8, "prometheus": 26, "fluentbit": 29, "perses": 4}
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
DOWNLOADS_ROOT = CONTENT / "vendor" / "downloads"
BUILD_FLAGS = {"--load", "--push", "--builder", "--provenance", "--sbom"}
SYNTAX_PATTERNS = (
    ("heredoc", re.compile(r"<<-?\s*(?:'EOF'|\"EOF\"|EOF)\b")),
    ("buildkit-syntax", re.compile(r"^\s*#\s*syntax\s*=", re.IGNORECASE | re.MULTILINE)),
    ("run-mount", re.compile(r"^\s*RUN\s+.*--mount\s*=", re.IGNORECASE | re.MULTILINE)),
)
PLACEHOLDER_RE = re.compile(r"\[[A-Z][A-Z0-9_-]*\]|\{[A-Z][A-Z0-9_-]*\}|(?<=[_-])[A-Z][A-Z0-9]*(?=/|$)|(?:(?<=/)|^)[A-Z][A-Z0-9_-]*(?=/|$)")
COMMAND_START = re.compile(r"^(?:\$\s*)?(?:sudo\s+)?(?:docker|podman)(?:-compose)?\b|^(?:\$\s*)?podman-compose\b")
DOCKERFILE_FROM = re.compile(r"^\s*FROM\s+(.*)$", re.IGNORECASE | re.MULTILINE)
K8S_REFERENCE_RE = re.compile(
    r"\b(?:kubectl|k3s|minikube|helm)\b|"
    r"\bkind\s+(?:create|delete|get|load|export|version|build)\b|"
    r"\bkubectl\s+(?:apply|run|create)\b|"
    r"[\w./-]*(?:pod|deploy|manifest)[\w./-]*\.ya?ml\b",
    re.IGNORECASE,
)
CONTAINER_ALT_RE = re.compile(r"(?m)^\s*(?:\$\s*)?(?:sudo\s+)?(?:podman|docker)\s+(?:run|play|build)\b")


class CodeBlockParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.pre_depth = 0
        self.code_depth = 0
        self.current = []
        self.blocks = []

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        if tag == "pre":
            if self.pre_depth == 0 and self.code_depth == 0:
                self.current = []
            self.pre_depth += 1
        elif tag == "code" and self.pre_depth == 0:
            if self.code_depth == 0:
                self.current = []
            self.code_depth += 1
        elif tag == "br" and (self.pre_depth or self.code_depth):
            self.current.append("\n")

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag == "pre" and self.pre_depth:
            self.pre_depth -= 1
            if self.pre_depth == 0:
                self.blocks.append("".join(self.current))
                self.current = []
        elif tag == "code" and self.code_depth and self.pre_depth == 0:
            self.code_depth -= 1
            if self.code_depth == 0:
                self.blocks.append("".join(self.current))
                self.current = []

    def handle_data(self, data):
        if self.pre_depth or self.code_depth:
            self.current.append(data)


class LinkParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links = []

    def handle_starttag(self, tag, attrs):
        for key, value in attrs:
            if tag.lower() == "a" and key.lower() == "href" and value:
                self.links.append(value)


def natural_key(path):
    suffix = path.stem.lower()
    if suffix.endswith("-source"):
        priority = 0
    elif suffix.endswith("-podman"):
        priority = 2
    elif suffix.endswith("-rancher"):
        priority = 3
    else:
        priority = 1
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r"(\d+)", path.stem)] + [priority, path.name.lower()]


def version_key(path):
    versions = re.findall(r"\d+", str(path))
    return tuple(int(number) for number in versions) or (0,)


def path_type(path):
    name = path.stem.lower()
    if name.endswith("-podman"):
        return "podman"
    if name.endswith("-rancher"):
        return "rancher"
    return "docker"


def lab_variant_base(path):
    stem = path.stem
    for suffix in ("-podman", "-rancher"):
        if stem.endswith(suffix):
            return stem[:-len(suffix)]
    return stem


def k8s_audit(track, repo, lab_files):
    references = []
    classifications = []
    contents = {}
    for lab_path in lab_files:
        try:
            contents[lab_path] = lab_path.read_text(encoding="utf-8", errors="replace")
        except OSError as error:
            references.append(f"{track} | {lab_path.name} | {path_type(lab_path)} | unable to read file: {error}")
            contents[lab_path] = ""
    for lab_path in lab_files:
        text = contents[lab_path]
        snippets = []
        for line in text.splitlines():
            if K8S_REFERENCE_RE.search(line):
                snippet = re.sub(r"<[^>]+>", " ", html.unescape(line))
                snippet = re.sub(r"\s+", " ", snippet).strip()
                if snippet and snippet not in snippets:
                    snippets.append(snippet[:260])
        for snippet in snippets:
            references.append(f"{track} | {lab_path.name} | {path_type(lab_path)} | {snippet}")

        has_k8s = bool(K8S_REFERENCE_RE.search(text))
        has_alt = bool(CONTAINER_ALT_RE.search(text))
        if path_type(lab_path) == "rancher" and not has_alt:
            siblings = [
                candidate for candidate in lab_files
                if lab_variant_base(candidate) == lab_variant_base(lab_path)
                and candidate != lab_path
                and path_type(candidate) != "rancher"
                and CONTAINER_ALT_RE.search(contents[candidate])
            ]
            has_alt = bool(siblings)
        if has_k8s and not has_alt:
            classification = "K8s-only (no Podman/Docker alternative in this file or its lab variants)"
        elif has_alt:
            classification = "Has Podman/Docker alternative"
        else:
            classification = "Neither"
        classifications.append((lab_path.name, path_type(lab_path), classification))
    return references, classifications


def classify_otelo_lab(lab_path, text, siblings):
    has_k8s = bool(K8S_REFERENCE_RE.search(text))
    has_alternative = bool(CONTAINER_ALT_RE.search(text))
    if not has_alternative and path_type(lab_path) == "rancher":
        has_alternative = any(
            candidate != lab_path
            and lab_variant_base(candidate) == lab_variant_base(lab_path)
            and path_type(candidate) != "rancher"
            and CONTAINER_ALT_RE.search(siblings.get(candidate, ""))
            for candidate in siblings
        )
    if has_k8s and not has_alternative:
        return "K8s-only (no Podman/Docker alternative documented)"
    if has_alternative:
        return "Has Podman/Docker alternative"
    return "Neither"


def relative_path(repo, path):
    try:
        return path.relative_to(repo).as_posix() or "."
    except ValueError:
        return path.as_posix()


def normalise_path(repo, cwd, target):
    target_path = Path(os.path.expanduser(target))
    if not target_path.is_absolute():
        target_path = cwd / target_path
    return Path(os.path.normpath(str(target_path)))


def simulate_cd(repo, cwd, line):
    match = re.match(r"^(?:\$\s*)?cd\s+(.+?)\s*(?:&&|;)?\s*$", line)
    if not match:
        return cwd
    try:
        tokens = shlex.split(match.group(1))
    except ValueError:
        return cwd
    if not tokens or tokens[0] == "-":
        return cwd
    return normalise_path(repo, cwd, tokens[0])


def command_lines(block, repo, working_dir, earlier_creators):
    lines = block.splitlines()
    index = 0
    commands = []
    creators = []
    last_archive = None
    while index < len(lines):
        line = lines[index].strip()
        extracted = re.match(r"^(?:creating|inflating|extracting):\s+(.+)$", line, re.IGNORECASE)
        if extracted and last_archive is not None:
            last_archive.setdefault("members", []).append(extracted.group(1).strip().rstrip("/"))
            index += 1
            continue
        if re.match(r"^(?:\$\s*)?cd\s+", line):
            working_dir = simulate_cd(repo, working_dir, line)
            index += 1
            continue
        if not COMMAND_START.match(line):
            creator = creator_details(line, repo, working_dir)
            if creator:
                creators.append(creator)
                last_archive = creator if creator.get("kind") == "unzip" else None
            elif line and not line.lower().startswith("archive:"):
                last_archive = None
            index += 1
            continue
        command_cwd = working_dir
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
            commands.append({"raw": raw, "tokens": [], "warning": str(error), "cwd_path": command_cwd})
            index += 1
            continue
        commands.append({
            "raw": raw,
            "tokens": tokens,
            "cwd_path": command_cwd,
            "prior_creators": earlier_creators + creators,
        })
        index += 1
    return commands, working_dir, creators


def urls_in(tokens):
    return [token.rstrip(")],;\"'") for token in tokens if token.startswith(("http://", "https://"))]


def creator_details(line, repo, cwd):
    clean = re.sub(r"^(?:\$\s*)", "", line.strip(), count=1)
    try:
        tokens = shlex.split(clean, posix=True)
    except ValueError:
        return None
    if not tokens:
        return None
    command = Path(tokens[0]).name
    urls = urls_in(tokens)
    created = None

    def option(name):
        if name in tokens:
            at = tokens.index(name)
            return tokens[at + 1] if at + 1 < len(tokens) else None
        return None

    if command in ("wget", "curl"):
        output_name = option("-O") or option("--output-document") or option("-o")
        directory = option("-P") or option("--directory-prefix")
        if output_name:
            created = normalise_path(repo, cwd, output_name)
        elif directory and urls:
            created = normalise_path(repo, cwd, directory) / Path(urlparse(urls[-1]).path).name
        elif urls:
            created = cwd / Path(urlparse(urls[-1]).path).name
    elif command == "git" and len(tokens) > 1 and tokens[1] == "clone":
        non_options = [token for token in tokens[2:] if not token.startswith("-") and not token.startswith(("http://", "https://", "git@"))]
        source = next((token for token in tokens[2:] if token.startswith(("http://", "https://", "git@"))), None)
        if non_options:
            created = normalise_path(repo, cwd, non_options[-1])
        elif source:
            created = cwd / Path(source.rstrip("/").split(":")[-1].removesuffix(".git")).name
            urls = [source]
    elif command == "unzip":
        destination = option("-d")
        archive = next((token for token in tokens[1:] if not token.startswith("-")), None)
        if destination:
            created = normalise_path(repo, cwd, destination)
        elif archive:
            created = cwd / Path(archive).name.removesuffix(".zip")
    elif command == "tar":
        destination = option("-C")
        archive = next((token for token in tokens[1:] if not token.startswith("-") and token not in ("xf", "xzf", "xvf", "xJf", "x")), None)
        if destination:
            created = normalise_path(repo, cwd, destination)
        elif archive:
            created = cwd / strip_archive(Path(archive).name)
    elif command == "cp":
        operands = [token for token in tokens[1:] if not token.startswith("-")]
        if len(operands) >= 2:
            created = normalise_path(repo, cwd, operands[-1])
    if created is None and not urls:
        return None
    return {
        "cwd": relative_path(repo, cwd),
        "created_path": relative_path(repo, created) if created else None,
        "urls": urls,
        "raw": line.strip(),
        "kind": command,
        "input_path": next((token for token in tokens[1:] if not token.startswith("-")), None) if command in ("unzip", "tar", "cp") else None,
        "members": [],
    }


def strip_archive(name):
    for suffix in (".tar.gz", ".tgz", ".tar.bz2", ".tar.xz", ".tar"):
        if name.endswith(suffix):
            return name[:-len(suffix)]
    return name


def parse_engine(tokens):
    index = 1 if tokens and tokens[0] == "sudo" else 0
    while index < len(tokens) and tokens[index] in ("-E", "--preserve-env", "-n", "--non-interactive"):
        index += 1
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
    value_options = {"-f", "--file", "-p", "--publish", "-v", "--volume", "-e", "--env", "--env-file", "--name", "--network", "--mount", "--platform", "--build-arg", "--label", "--entrypoint", "--user", "-w", "--workdir", "--hostname", "--add-host", "--memory", "-m", "--cpus", "--cpu-period", "--cpu-quota", "--shm-size", "--ulimit", "--security-opt", "--dns", "--pod", "--builder", "--provenance", "--sbom"}
    if kind == "build":
        value_options.update(("-t", "--tag"))
    boolean_options = {"-d", "--detach", "--rm", "-i", "--interactive", "-t", "--tty", "-P", "--publish-all", "--privileged", "--pull", "--quiet", "--no-cache", "--load", "--push"}
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
        argument = match.group(1).strip()
        if re.search(r"\s+import\s+", argument, re.IGNORECASE):
            continue
        try:
            parts = shlex.split(argument, comments=True)
        except ValueError:
            parts = argument.split()
        image = next((part for part in parts if not part.startswith("--")), "")
        if image and image.lower() not in ("pathlib", "os", "sys", "collections", "typing"):
            images.append(image)
    return images


def dockerfile_syntax_flags(text):
    return [name for name, pattern in SYNTAX_PATTERNS if pattern.search(text)]


def buildx_flags(tokens, start):
    found = []
    for token in tokens[start:]:
        flag = token.split("=", 1)[0]
        if flag in BUILD_FLAGS and flag not in found:
            found.append(flag)
    return found


def placeholder_glob(context):
    matches = list(PLACEHOLDER_RE.finditer(context))
    if not matches:
        return None
    pattern = PLACEHOLDER_RE.sub("*", context)
    return pattern, [match.group(0) for match in matches]


def resolve_placeholders(repo, context):
    globbed = placeholder_glob(context)
    if not globbed:
        return context, [], [], []
    pattern, placeholders = globbed
    try:
        matches = sorted({path for path in repo.glob(pattern) if path.is_dir()}, key=lambda path: (version_key(path), str(path)))
    except (OSError, ValueError):
        matches = []
    if not matches:
        return context, [], [], placeholders
    selected = matches[-1]
    resolved = relative_path(repo, selected)
    assumption = {"type": "placeholder-resolution", "placeholder": ",".join(placeholders), "resolved": resolved}
    alternatives = [relative_path(repo, path) for path in matches if path != selected]
    if alternatives:
        assumption["alternatives"] = alternatives
        warning = f"placeholder {','.join(placeholders)} in {context}: selected {resolved}; alternatives: {', '.join(alternatives)}"
        return resolved, [assumption], [warning], placeholders
    return resolved, [assumption], [], placeholders


def path_matches_context(context, created):
    for member in created.get("members", []):
        member = member.removeprefix("./").rstrip("/")
        if member == context or member.endswith("/" + context.strip("./")):
            return True
    created_path = created.get("created_path")
    if created_path:
        if context == created_path or context.startswith(created_path.rstrip("/") + "/"):
            return True
        if created_path.endswith("/" + context.lstrip("./")) or context.endswith("/" + created_path.lstrip("./")):
            return True
        context_base = context.rstrip("/").split("/")[-1]
        created_base = created_path.rstrip("/").split("/")[-1]
        context_pattern = PLACEHOLDER_RE.sub("*", context_base)
        if re.fullmatch(context_pattern.replace("*", ".*"), created_base):
            return True
    target_base = context.rstrip("/").split("/")[-1]
    for url in created.get("urls", []):
        source_base = Path(urlparse(url).path).name
        source_base = strip_archive(source_base)
        target_pattern = PLACEHOLDER_RE.sub(".*", target_base)
        if source_base and re.fullmatch(target_pattern, source_base):
            return True
    return False


def find_runtime_sources(context, creators):
    matches = [creator for creator in creators if path_matches_context(context, creator)]
    urls = sorted({url for creator in matches for url in creator.get("urls", [])})
    return matches, urls


def connect_archive_urls(creators, archive_urls):
    by_name = collections.defaultdict(list)
    for url in archive_urls:
        by_name[Path(urlparse(url).path).name].append(url)
    for creator in creators:
        if creator.get("kind") != "unzip" or creator.get("urls"):
            continue
        input_path = creator.get("input_path") or ""
        archive_name = Path(input_path).name
        creator["urls"] = by_name.get(archive_name, [])
    return creators


def resolve_dockerfile(repo, cwd_path, file_value):
    file_path = normalise_path(repo, cwd_path, file_value)
    if repo.resolve() not in (file_path.resolve(), *file_path.resolve().parents):
        return None
    return file_path


def archive_root_from_url(url):
    filename = Path(urlparse(url).path).name
    for suffix in (".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".zip", ".tar"):
        if filename.endswith(suffix):
            return filename[:-len(suffix)]
    return Path(filename).stem


def downloaded_asset(track, url):
    filename = Path(urlparse(url).path).name
    path = DOWNLOADS_ROOT / track / filename
    if not path.is_file():
        return path, None
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return path, digest


def preload_build_steps(track, tag, dockerfile_arg, context, status, runtime_url=None):
    repo_prefix = f"content/repos/{track}"
    context_path = context or "."
    if status == "PRELOADABLE-VIA-VENDORED-DOWNLOAD" and runtime_url:
        archive_root = archive_root_from_url(runtime_url)
        archive_name = Path(urlparse(runtime_url).path).name
        vendored_path = f"content/vendor/downloads/{track}/{archive_name}"
        if context_path.startswith(archive_root + "/"):
            build_context = context_path
        elif context_path == archive_root or context_path in (".", "", Path(context_path).name) or "[VERSION]" in context_path or "{VERSION}" in context_path:
            build_context = archive_root
        else:
            build_context = f"{archive_root}/{context_path.lstrip('./')}"
        dockerfile_path = f"{archive_root}/{dockerfile_arg}" if dockerfile_arg else f"{build_context}/Dockerfile"
        return [
            f"extract {vendored_path} to {repo_prefix} (archive root {archive_root})",
            f"docker build -t {tag} -f {repo_prefix}/{dockerfile_path} {repo_prefix}/{build_context}",
        ]
    if status in ("PRELOADABLE-VIA-VENDORED-CONTEXT", "BUILT-PRELOADABLE"):
        dockerfile_path = dockerfile_arg or "Dockerfile"
        return [f"docker build -t {tag} -f {dockerfile_path} {context_path}"]
    return []


def build_preload_status(repo, item, dockerfile_path, vendored_archive_context):
    if item.get("runtime_download"):
        urls = item.get("runtime_download_sources", [])
        if urls and all(downloaded_asset(repo.name, url)[1] for url in urls):
            return "PRELOADABLE-VIA-VENDORED-DOWNLOAD"
        return "INTERACTIVE"
    if vendored_archive_context and dockerfile_path and dockerfile_path.is_file():
        return "PRELOADABLE-VIA-VENDORED-CONTEXT"
    if item.get("context_exists") and dockerfile_path and dockerfile_path.is_file():
        return "BUILT-PRELOADABLE"
    return "INTERACTIVE"


def command_fields(command, repo, embedded_blocks, creators, warnings, track, lab_name, archive_urls):
    tokens = command["tokens"]
    engine, kind, start = parse_engine(tokens)
    cwd_path = command["cwd_path"]
    cwd_value = relative_path(repo, cwd_path)
    item = {
        "type": kind,
        "engine": engine,
        "sudo": bool(tokens and tokens[0] == "sudo"),
        "raw": command["raw"],
        "cwd": cwd_value,
        "occurrences": 1,
        "assumptions": [],
        "syntax_flags": [],
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
    if kind in ("build", "run"):
        item["syntax_flags"] = buildx_flags(tokens, start)
        if item["syntax_flags"]:
            item["flag_transformations"] = [
                {"flag": flag, "action": "strip at preload", "reason": "Buildx-only flag; Buildah/Podman does not use it"}
                for flag in item["syntax_flags"] if flag in BUILD_FLAGS
            ]
    if kind not in ("build", "pull", "run"):
        return item

    args = positional_args(tokens, start, kind)
    if kind == "pull":
        item["image"] = args[0] if args else None
        return item
    if kind == "run":
        item["image"] = args[0] if args else None
        if args:
            image_index = tokens.index(args[0], start)
            item["cmd"] = tokens[image_index + 1:]
        return item

    tags = option_values(tokens, start, ("-t", "--tag"), ("-t",))
    files = option_values(tokens, start, ("-f", "--file"), ("-f",))
    context_token = args[-1] if args else "."
    context_path = normalise_path(repo, cwd_path, context_token)
    context_value = relative_path(repo, context_path)
    resolved_context, assumptions, placeholder_warnings, placeholders = resolve_placeholders(repo, context_value)
    item["assumptions"].extend(assumptions)
    warnings.extend(f"{track}/{lab_name}: {warning}" for warning in placeholder_warnings)
    resolved_path = normalise_path(repo, repo.resolve(), resolved_context)
    file_value = files[-1] if files else "Dockerfile"
    dockerfile_path = resolve_dockerfile(repo, cwd_path, file_value)
    vendored_archive_context = False
    if placeholders and (dockerfile_path is None or not dockerfile_path.is_file()):
        for archive_url in archive_urls:
            archive_root = archive_root_from_url(archive_url)
            candidate_root = repo / "_vendored" / archive_root
            candidate_dockerfile = candidate_root / file_value
            if candidate_root.is_dir() and candidate_dockerfile.is_file():
                resolved_context = relative_path(repo, candidate_root)
                resolved_path = candidate_root
                dockerfile_path = candidate_dockerfile
                vendored_archive_context = True
                assumptions.append({
                    "type": "vendored-archive-placeholder",
                    "placeholder": ",".join(placeholders),
                    "resolved": resolved_context,
                    "source_url": archive_url,
                })
                break
    if (dockerfile_path is None or not dockerfile_path.is_file()) and (repo / "_vendored").is_dir():
        expected_suffix = Path(file_value).as_posix().lstrip("./")
        vendored_candidates = [
            candidate for candidate in (repo / "_vendored").rglob(Path(file_value).name)
            if candidate.relative_to(repo / "_vendored").as_posix().endswith(expected_suffix)
        ]
        if len(vendored_candidates) == 1:
            dockerfile_path = vendored_candidates[0]
            archive_root = dockerfile_path
            for _ in Path(expected_suffix).parts:
                archive_root = archive_root.parent
            resolved_context = relative_path(repo, archive_root)
            resolved_path = archive_root
            assumptions.append({
                "type": "vendored-archive-context",
                "source_path": relative_path(repo, dockerfile_path),
                "context": resolved_context,
            })
            vendored_archive_context = True
    dockerfile_text = ""
    if dockerfile_path and dockerfile_path.is_file():
        try:
            dockerfile_text = dockerfile_path.read_text(encoding="utf-8", errors="replace")
        except OSError as error:
            warnings.append(f"{track}/{lab_name}: cannot read Dockerfile {relative_path(repo, dockerfile_path)}: {error}")
    if not dockerfile_text and embedded_blocks:
        dockerfile_text = "\n".join(embedded_blocks)
    item.update({
        "tag": tags[-1] if tags else None,
        "context": resolved_context,
        "dockerfile": relative_path(repo, dockerfile_path) if files and dockerfile_path else (file_value if files else None),
        "dockerfile_arg": file_value if files else None,
        "cwd": cwd_value,
        "interactive_context": not resolved_path.is_dir(),
        "runtime_download": False,
        "base_images": dockerfile_images(dockerfile_text),
        "context_exists": resolved_path.is_dir(),
    })
    for flag in dockerfile_syntax_flags(dockerfile_text):
        if flag not in item["syntax_flags"]:
            item["syntax_flags"].append(flag)
    if not resolved_path.is_dir():
        prior_creators, urls = find_runtime_sources(resolved_context, creators)
        if prior_creators and urls:
            item["runtime_download"] = True
            item["runtime_download_sources"] = urls
            item["interactive_context"] = False
            if placeholders:
                resolved_from_archive = next((creator.get("created_path") for creator in prior_creators if creator.get("created_path")), None)
                item["assumptions"].append({
                    "type": "placeholder-runtime-download",
                    "placeholder": ",".join(placeholders),
                    "resolved": resolved_from_archive or resolved_context,
                    "source_urls": urls,
                })
        elif prior_creators:
            item["runtime_download"] = True
            item["runtime_download_sources"] = []
            item["interactive_context"] = False
        elif placeholders:
            warnings.append(f"{track}/{lab_name}: unresolved placeholder context {context_value}; no earlier creator command matched")
        else:
            warnings.append(f"{track}/{lab_name}: missing context {resolved_context}; no earlier creator command matched")
    if not dockerfile_text:
        warnings.append(f"{track}/{lab_name}: no readable Dockerfile or embedded FROM block for context {resolved_context}")
    runtime_url = next(iter(item.get("runtime_download_sources", [])), None)
    item["preload_status"] = build_preload_status(repo, item, dockerfile_path, vendored_archive_context)
    item["preloadable"] = item["preload_status"] != "INTERACTIVE"
    item["preload_steps"] = preload_build_steps(track, item.get("tag") or "<untagged>", item.get("dockerfile_arg" if item["preload_status"] == "PRELOADABLE-VIA-VENDORED-DOWNLOAD" else "dockerfile"), item["context"], item["preload_status"], runtime_url)
    return item


def deduplicate_commands(commands):
    unique = []
    by_raw = {}
    for command in commands:
        raw = command["raw"]
        if raw not in by_raw:
            by_raw[raw] = command
            unique.append(command)
            continue
        existing = by_raw[raw]
        existing["occurrences"] += 1
        cwd_values = existing.setdefault("cwd_occurrences", [existing["cwd"]])
        cwd_values.append(command["cwd"])
        if "context" in command:
            context_values = existing.setdefault("context_occurrences", [existing["context"]])
            context_values.append(command["context"])
        for assumption in command.get("assumptions", []):
            if assumption not in existing["assumptions"]:
                existing["assumptions"].append(assumption)
    return unique


def creator_urls_for_lab(blocks, repo, cwd):
    records = []
    for block in blocks:
        for line in block.splitlines():
            details = creator_details(line, repo, cwd)
            if details:
                records.append(details)
    return records


def main():
    EXTRACTED.mkdir(parents=True, exist_ok=True)
    result = {}
    warnings = [
        "compose-vendor correction: invalid prior version v5.6.0 replaced with official Docker Compose v2.40.3 from https://github.com/docker/compose/releases/download/v2.40.3/docker-compose-linux-x86_64; SHA-256 dba9d98e1ba5bfe11d88c99b9bd32fc4a0624a30fafe68eea34d61a3e42fd372."
    ]
    all_images = set(KNOWN_IMAGES)
    initial_images = set(KNOWN_IMAGES)
    expected_skips = []
    syntax_risks = []
    runtime_downloads = []
    k8s_references = []
    opentelemetry_classifications = []
    pulls_by_track = collections.Counter()
    summary = {}

    for track in TRACKS:
        repo = REPOS / track
        labs = []
        creators_so_far = []
        tag_sources = collections.defaultdict(list)
        lab_files = sorted(repo.glob("lab*.html"), key=natural_key)
        track_references, track_classifications = k8s_audit(track, repo, lab_files)
        k8s_references.extend(track_references)
        if track == "opentelemetry":
            otel_contents = {}
            for page in lab_files:
                try:
                    otel_contents[page] = page.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    otel_contents[page] = ""
            opentelemetry_classifications = [
                (page.name, path_type(page), classify_otelo_lab(page, otel_contents[page], otel_contents))
                for page in lab_files
            ]
        track_archive_urls = []
        for source_page in lab_files:
            link_parser = LinkParser()
            try:
                link_parser.feed(source_page.read_text(encoding="utf-8", errors="replace"))
            except OSError:
                continue
            track_archive_urls.extend(link for link in link_parser.links if re.search(r"\.(?:zip|tar(?:\.gz|\.bz2|\.xz)?|tgz)(?:[?#].*)?$", urlparse(link).path, re.IGNORECASE))
        track_archive_urls = list(dict.fromkeys(track_archive_urls))
        for lab_path in lab_files:
            parser = CodeBlockParser()
            try:
                lab_html = lab_path.read_text(encoding="utf-8", errors="replace")
                parser.feed(lab_html)
            except OSError as error:
                warnings.append(f"{track}/{lab_path.name}: cannot read lab: {error}")
                continue
            blocks = parser.blocks
            link_parser = LinkParser()
            link_parser.feed(lab_html)
            archive_urls = [link for link in link_parser.links if re.search(r"\.(?:zip|tar(?:\.gz|\.bz2|\.xz)?|tgz)(?:[?#].*)?$", urlparse(link).path, re.IGNORECASE)]
            if not archive_urls:
                archive_urls = track_archive_urls
            embedded_blocks = [block for block in blocks if DOCKERFILE_FROM.search(block)]
            for block in blocks:
                all_images.update(dockerfile_images(block))
            cwd = repo.resolve()
            commands = []
            lab_creators = []
            for block in blocks:
                parsed, cwd, creators = command_lines(block, repo, cwd, creators_so_far + lab_creators)
                creators = connect_archive_urls(creators, archive_urls)
                lab_creators.extend(creators)
                for command in parsed:
                    if command.get("warning"):
                        warnings.append(f"{track}/{lab_path.name}: ambiguous command {command['raw']!r}: {command['warning']}")
                        continue
                    tokens = command["tokens"]
                    if not tokens:
                        continue
                    engine, kind, _ = parse_engine(tokens)
                    if engine is None:
                        creator = creator_details(command["raw"], repo, command["cwd_path"])
                        if creator:
                            lab_creators.append(creator)
                        continue
                    item = command_fields(command, repo, embedded_blocks, command.get("prior_creators", []), warnings, track, lab_path.name, archive_urls)
                    commands.append(item)
                    if item["type"] == "pull":
                        pulls_by_track[track] += 1
                    if item["type"] == "build":
                        all_images.update(item.get("base_images", []))
                        if item.get("interactive_context"):
                            expected_skips.append(f"{track}/{lab_path.name}: context={item['context']} cwd={item['cwd']} command={item['raw']}")
                        if item.get("runtime_download"):
                            urls = item.get("runtime_download_sources", [])
                            for url in urls:
                                asset_path, digest = downloaded_asset(track, url)
                                runtime_downloads.append(
                                    f"url={url} | sha256={digest or 'NOT_VENDORED'} | "
                                    f"vendored path={relative_path(ROOT, asset_path)} | "
                                    f"build={item.get('tag') or '<untagged>'} | {track}/{lab_path.name} | "
                                    f"context={item['context']} | dockerfile={item.get('dockerfile_arg') or 'Dockerfile'}"
                                )
                        if item.get("syntax_flags"):
                            syntax_risks.append(f"{track}/{lab_path.name}: flags={','.join(item['syntax_flags'])} context={item['context']} command={item['raw']}")
            unique_commands = deduplicate_commands(commands)
            for item in unique_commands:
                if item["type"] == "build" and item.get("tag"):
                    tag_sources[item["tag"]].append((lab_path.name, item["raw"]))
            labs.append({"file": lab_path.name, "path_type": path_type(lab_path), "commands": unique_commands})
            creators_so_far.extend(lab_creators)
        for tag, sources in sorted(tag_sources.items()):
            unique_raws = sorted({raw for _, raw in sources})
            if len(unique_raws) > 1:
                locations = ", ".join(f"{lab}: {raw}" for lab, raw in sources)
                warnings.append(f"{track}: duplicate build tag {tag} from different commands: {locations}")
        result[track] = {"labs": labs}
        unique_tags = {command["tag"] for lab in labs for command in lab["commands"] if command["type"] == "build" and command.get("tag")}
        unique_runs = {(lab["file"], command["raw"]) for lab in labs for command in lab["commands"] if command["type"] == "run"}
        summary[track] = {"build_tags": sorted(unique_tags), "run_count": len(unique_runs), "pull_count": pulls_by_track[track]}

    (EXTRACTED / "commands.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (EXTRACTED / "external-images.txt").write_text("".join(f"{image}\n" for image in sorted(all_images)), encoding="utf-8")
    expected_skips = list(dict.fromkeys(expected_skips))
    syntax_risks = list(dict.fromkeys(syntax_risks))
    runtime_downloads = list(dict.fromkeys(runtime_downloads))
    warnings = list(dict.fromkeys(warnings))
    (EXTRACTED / "build-failures-expected.txt").write_text("".join(f"{line}\n" for line in expected_skips), encoding="utf-8")
    (EXTRACTED / "syntax-risk.txt").write_text("".join(f"{line}\n" for line in syntax_risks), encoding="utf-8")
    (EXTRACTED / "runtime-downloads.txt").write_text("".join(f"{line}\n" for line in runtime_downloads), encoding="utf-8")
    (EXTRACTED / "parse-warnings.txt").write_text("".join(f"{line}\n" for line in warnings), encoding="utf-8")
    (EXTRACTED / "k8s-references.txt").write_text("".join(f"{line}\n" for line in k8s_references), encoding="utf-8")

    added_images = sorted(all_images - initial_images)
    print("track | unique build tags | unique run commands | pulls")
    for track, data in summary.items():
        previous_builds = PREVIOUS_BUILD_OCCURRENCES.get(track, 0)
        previous_runs = PREVIOUS_RUN_OCCURRENCES.get(track, 0)
        print(f"{track} | unique build tags={len(data['build_tags'])} vs prior build occurrences={previous_builds}; tags={data['build_tags']} | unique run commands={data['run_count']} vs prior run occurrences={previous_runs} | pulls={data['pull_count']}")
    print(f"pulls found: {sum(pulls_by_track.values())}")
    print(f"externals added this pass: {added_images}")
    print("placeholder resolutions:")
    resolutions = []
    for track, data in result.items():
        for lab in data["labs"]:
            for command in lab["commands"]:
                for assumption in command.get("assumptions", []):
                    if assumption.get("type") in ("placeholder-resolution", "placeholder-runtime-download", "vendored-archive-placeholder"):
                        resolutions.append((track, assumption["placeholder"], assumption["resolved"], assumption.get("alternatives", [])))
    seen_resolutions = set()
    for track, placeholder, resolved, alternatives in resolutions:
        resolution_key = (track, placeholder, resolved, tuple(alternatives))
        if resolution_key in seen_resolutions:
            continue
        seen_resolutions.add(resolution_key)
        print(f"{track}: {placeholder} -> {resolved}" + (f" (alternatives: {alternatives})" if alternatives else ""))
    unresolved_placeholders = set()
    for track, data in result.items():
        for lab in data["labs"]:
            for command in lab["commands"]:
                if command["type"] != "build":
                    continue
                for placeholder in placeholder_glob(command["context"])[1] if placeholder_glob(command["context"]) else []:
                    key = (track, f"{placeholder} in {command['context']}")
                    if not any(item.get("placeholder") == placeholder for item in command.get("assumptions", [])):
                        unresolved_placeholders.add(key)
    for track, placeholder in sorted(unresolved_placeholders):
        print(f"{track}: {placeholder} -> unresolved (no matching captured directory or earlier creator command)")
    print(f"expected-skip count delta: {len(expected_skips) - 36:+d} ({len(expected_skips)} now; was 36)")
    print("OpenTelemetry lab classification:")
    for filename, file_path_type, classification in opentelemetry_classifications:
        print(f"{filename} | {file_path_type} | {classification}")
    print(f"K8s/tooling references recorded: {len(k8s_references)} -> {EXTRACTED / 'k8s-references.txt'}")
    print("BUILD STATUS TABLE (unique tags):")
    status_priority = {
        "BUILT-PRELOADABLE": 0,
        "PRELOADABLE-VIA-VENDORED-DOWNLOAD": 1,
        "PRELOADABLE-VIA-VENDORED-CONTEXT": 2,
        "INTERACTIVE": 3,
    }
    status_counts = collections.Counter()
    for track, data in result.items():
        by_tag = collections.defaultdict(list)
        for lab in data["labs"]:
            for command in lab["commands"]:
                if command["type"] == "build" and command.get("tag"):
                    by_tag[command["tag"]].append(command.get("preload_status", "INTERACTIVE"))
        for tag, statuses in sorted(by_tag.items()):
            status = min(statuses, key=lambda value: status_priority.get(value, 9))
            status_counts[status] += 1
            print(f"{track} | {tag} | {status}")
    print(f"build status counts: {dict(sorted(status_counts.items()))}")
    if sum(pulls_by_track.values()) == 0:
        print("Pull check: no docker/podman pull commands exist in any lab HTML; podman auto-pulls on run, and preload makes those pulls a no-op.")
    else:
        print(f"Pull check: {sum(pulls_by_track.values())} docker/podman pull commands found; repo lab HTML must receive PRELOADED markers.")
    return 0 if any(result.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
