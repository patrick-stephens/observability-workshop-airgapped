"""Generate derived offline image recipes without changing vendored sources."""

import argparse
import ast
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
import xml.etree.ElementTree as ET
import zipfile


def patch_runtime(root):
    root = Path(root)
    for path in root.rglob("*.java"):
        text = path.read_text(encoding="utf-8")
        if '"https://dog.ceo/api' not in text:
            continue
        text = re.sub(r'"https://dog\.ceo/api([^"\n]*)"', lambda match: 'System.getProperty("o11y.dog.api", System.getenv().getOrDefault("O11Y_DOG_API_URL", "http://127.0.0.1:18187/api")) + "' + match.group(1) + '"', text)
        text = re.sub(r'Pattern\.compile\("[^"\n]*dog[^"\n]*"\)', 'Pattern.compile("/breeds/([^/]+)/")', text)
        path.write_text(text, encoding="utf-8")
    for path in root.rglob("*.py"):
        text = path.read_text(encoding="utf-8")
        if "requests.get(" not in text or "https://dog.ceo/api" not in text:
            continue
        text = "import os\nO11Y_API = os.environ.get('O11Y_DOG_API_URL', 'http://127.0.0.1:18187/api').rstrip('/')\n" + text
        text = re.sub(r"requests\.get\(f?'https://dog\.ceo/api([^']*)'", lambda match: "requests.get(f'{O11Y_API}" + match.group(1) + "'", text)
        ast.parse(text)
        path.write_text(text, encoding="utf-8")


def java17(root):
    namespace = "http://maven.apache.org/POM/4.0.0"
    ET.register_namespace("", namespace)
    qualified = lambda name: "{" + namespace + "}" + name
    for path in Path(root).rglob("pom*.xml"):
        tree = ET.parse(path)
        project = tree.getroot()
        properties = project.find(qualified("properties"))
        if properties is None:
            properties = ET.SubElement(project, qualified("properties"))
        for name in ("maven.compiler.source", "maven.compiler.target", "maven.compiler.release"):
            element = properties.find(qualified(name))
            if element is None:
                element = ET.SubElement(properties, qualified(name))
            element.text = "17"
        for plugin in project.findall(".//" + qualified("plugin")):
            if plugin.findtext(qualified("artifactId")) != "maven-compiler-plugin":
                continue
            configuration = plugin.find(qualified("configuration"))
            if configuration is not None:
                for name in ("source", "target", "release"):
                    element = configuration.find(qualified(name))
                    if element is not None:
                        element.text = "17"
        tree.write(path, encoding="utf-8", xml_declaration=True)


def verify_java17(root):
    jars = list(Path(root).glob("*.jar"))
    if not jars:
        raise ValueError("no Java application JARs were built")
    checked = 0
    for path in jars:
        with zipfile.ZipFile(path) as archive:
            for name in archive.namelist():
                if not name.endswith(".class") or name.startswith("META-INF/versions/"):
                    continue
                header = archive.read(name)[:8]
                if len(header) != 8 or header[:4] != b"\xca\xfe\xba\xbe" or int.from_bytes(header[6:8], "big") > 61:
                    raise ValueError("JAR contains bytecode newer than Java 17: " + path.name + " :: " + name)
                checked += 1
    if not checked:
        raise ValueError("no Java bytecode found in built JARs")
    print("Verified Java 17 base bytecode in " + str(len(jars)) + " JARs; versioned entries require runtime tests.")


def extract_source(source, destination):
    destination = Path(destination)
    with tarfile.open(source, "r:gz") as archive:
        members = archive.getmembers()
        for member in members:
            path = Path(member.name)
            if path.is_absolute() or ".." in path.parts or "\\" in member.name or not (member.isfile() or member.isdir()):
                raise ValueError("unsafe source archive entry")
        if destination.exists():
            for member in members:
                if member.isfile():
                    target = destination / member.name
                    if target.is_symlink() or not target.is_file():
                        raise ValueError("existing source context is incomplete")
                    with archive.extractfile(member) as expected:
                        if hashlib.sha256(expected.read()).digest() != hashlib.sha256(target.read_bytes()).digest():
                            raise ValueError("existing source context differs from the captured archive: " + member.name)
            return
        destination.mkdir(parents=True)
        for member in members:
            path = destination / member.name
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as input_file, path.open("xb") as output_file:
                    shutil.copyfileobj(input_file, output_file)
                path.chmod(0o755 if member.mode & 0o111 else 0o644)


def extract_zip(source, destination):
    destination = Path(destination)
    with zipfile.ZipFile(source) as archive:
        members = archive.infolist()
        seen = set()
        for member in members:
            name = member.filename.rstrip("/")
            path = PurePosixPath(name)
            mode = member.external_attr >> 16
            file_type = mode & 0o170000
            if not name or name in seen or path.is_absolute() or ".." in path.parts or "\\" in name or "\0" in name:
                raise ValueError("unsafe or duplicate source archive entry")
            if file_type == 0o120000 or (file_type and file_type not in (0o100000, 0o040000)):
                raise ValueError("source archive links and special files are rejected")
            if member.is_dir() != (file_type == 0o040000) and file_type:
                raise ValueError("source archive entry type is inconsistent")
            seen.add(name)
        if destination.exists():
            actual_files = set()
            for path in destination.rglob("*"):
                if path.is_symlink():
                    raise ValueError("existing source context contains a symbolic link")
                if path.is_file():
                    actual_files.add(path.relative_to(destination).as_posix())
            expected_files = {member.filename.rstrip("/") for member in members if not member.is_dir()}
            if actual_files != expected_files:
                raise ValueError("existing source context differs from the captured archive inventory")
            for member in members:
                if member.is_dir():
                    continue
                target = destination / member.filename
                if target.is_symlink() or not target.is_file() or hashlib.sha256(target.read_bytes()).digest() != hashlib.sha256(archive.read(member)).digest():
                    raise ValueError("existing source context differs from the captured archive: " + member.filename)
            return
        destination.mkdir(parents=True)
        for member in members:
            path = destination / member.filename
            if member.is_dir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(member) as source_file, path.open("xb") as output_file:
                    shutil.copyfileobj(source_file, output_file)
                path.chmod(0o755 if (member.external_attr >> 16) & 0o111 else 0o644)


def enable_fluentbit_memory_limit(source):
    path = Path(source)
    text = path.read_text(encoding="utf-8")
    updated, count = re.subn(r"(?m)^([ \t]*)#mem_buf_limit:[ \t]*2MB[ \t]*$", r"\1mem_buf_limit: 2MB", text)
    if count != 1:
        raise ValueError("expected exactly one commented Fluent Bit memory limit")
    path.write_text(updated, encoding="utf-8")


def enable_java_metrics(source):
    path = Path(source)
    text = path.read_text(encoding="utf-8")
    markers = (
        ("Uncommenting adds imports for OpenTelemetry metrics API:", 1),
        ("Uncomment the following to initialize OpenTelemetry and get a Tracer and Meter:", 1),
        ("Uncomment the following to use counter and histogram metrics for pages and requests:", 1),
        ("Uncomment the following to initialize OpenTelemetry SDK with Prometheus metrics:", 1),
        ("Uncomment the following to increment the counter with attributes:", 1),
        ("Uncomment the following to track request duration with histogram:", 2),
        ("Uncomment the following (with startTime above) to record request duration:", 2),
    )
    code_prefixes = ("import ", "private ", "@SuppressWarnings", "Resource ", "ResourceAttributes.", "Attributes.", "Sdk", "return ", "long ", "double ", "hitsCounter.", "requestDuration.", "AttributeKey.", ".", "try {", "finally {")
    for marker, expected_count in markers:
        if text.count(marker) != expected_count:
            raise ValueError("expected " + str(expected_count) + " Java metrics source markers: " + marker)
        search_from = 0
        for _ in range(expected_count):
            start = text.index(marker, search_from) + len(marker)
            divider = re.search(r"(?m)^\s*// ={5,}\s*$", text[start:])
            if divider is None:
                raise ValueError("Java metrics source block has no closing divider: " + marker)
            end = start + divider.start()
            lines = text[start:end].splitlines(keepends=True)
            code_started = False
            transformed = []
            for line in lines:
                match = re.match(r"^(\s*)//(?: ?)(.*?)(\r?\n)?$", line)
                if not match:
                    transformed.append(line)
                    continue
                indent, content, ending = match.groups()
                ending = ending or ""
                stripped = content.lstrip()
                if not stripped:
                    transformed.append(ending if code_started else line)
                elif stripped.startswith(code_prefixes) or stripped.startswith(("/**", "*", "*/")) or re.match(r"^[ \t]*[})]+[;]?$", content):
                    code_started = True
                    transformed.append(indent + content + ending)
                elif code_started and stripped.startswith("//"):
                    transformed.append(indent + content[1:] + ending)
                else:
                    transformed.append(line)
            replacement = "".join(transformed)
            text = text[:start] + replacement + text[end:]
            search_from = start + len(replacement)
    # The lesson's ResourceAttributes symbol was split into ServiceAttributes in the pinned semconv API.
    text = re.sub(r"(?m)^([ \t]*)//[ \t]*(ResourceAttributes\.SERVICE_NAME,)", r"\1\2", text)
    text = text.replace("import io.opentelemetry.semconv.ResourceAttributes;", "import io.opentelemetry.semconv.ServiceAttributes;")
    text = text.replace("ResourceAttributes.SERVICE_NAME", "ServiceAttributes.SERVICE_NAME")
    path.write_text(text, encoding="utf-8")


def copy_context(source, destination):
    source = Path(source)
    destination = Path(destination)
    if destination.exists():
        raise ValueError("derived build context already exists; use a versioned output directory")
    for path in source.rglob("*"):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError("source context contains a link or special file")
    shutil.copytree(source, destination, symlinks=False)


def capture_plugins(source, destination):
    import yaml
    source = Path(source)
    destination = Path(destination)
    plugins = yaml.safe_load((source / "scripts/plugin/plugin.yaml").read_text(encoding="utf-8"))
    records = []
    for plugin in plugins:
        name = plugin["name"] + "-" + plugin["version"] + ".tar.gz"
        if not re.fullmatch(r"[A-Za-z0-9._-]+", name):
            raise ValueError("invalid plugin archive name")
        archive_path = source / "plugins-archive" / name
        if not archive_path.is_file() or not tarfile.is_tarfile(archive_path):
            raise ValueError("missing or invalid Perses plugin: " + name)
        records.append({"name": name, "sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest()})
    destination.mkdir(parents=True, exist_ok=True)
    for record in records:
        shutil.copyfile(source / "plugins-archive" / record["name"], destination / record["name"])
    (destination / "manifest.json").write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")


def render(kind, text, base, variant):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}", base):
        raise ValueError("base image must include an immutable digest")
    if kind == "python":
        text = re.sub(r"^FROM .*", "FROM " + base, text, count=1, flags=re.MULTILINE)
        text = text.replace("FROM " + base, "FROM " + base + "\nCOPY wheelhouse /opt/wheelhouse\nENV PIP_NO_INDEX=1 PIP_FIND_LINKS=/opt/wheelhouse PIP_DISABLE_PIP_VERSION_CHECK=1", 1)
        if variant == "prog":
            text = text.replace("RUN pip install -r requirements.txt", "RUN pip install -r requirements.txt\nRUN pip install opentelemetry-api==1.44.0 opentelemetry-sdk==1.44.0 opentelemetry-exporter-otlp==1.44.0 opentelemetry-instrumentation-flask==0.65b0 opentelemetry-instrumentation-jinja2==0.65b0 opentelemetry-instrumentation-requests==0.65b0", 1)
    elif kind == "java":
        text = re.sub(r"^FROM .*", "FROM " + base, text, count=1, flags=re.MULTILINE)
        text = re.sub(r"ADD https://github\.com/open-telemetry/opentelemetry-java-instrumentation/\\\s*\nreleases/download/v2\.30\.0/opentelemetry-javaagent\.jar (\S+)", r"COPY opentelemetry-javaagent-2.30.0.jar \1", text)
        if re.search(r"^(ADD|RUN).*https?://", text, re.MULTILINE):
            raise ValueError("unhandled remote download in derived Java recipe")
    elif kind == "config":
        text = re.sub(r"^FROM .*", "FROM " + base, text, count=1, flags=re.MULTILINE)
        if re.search(r"^(ADD|COPY).*https?://", text, re.MULTILINE):
            raise ValueError("configuration image recipe contains a remote file input")
    elif kind == "fluentbit":
        config = variant
        if not re.fullmatch(r"[A-Za-z0-9._-]+\.yaml", config):
            raise ValueError("Fluent Bit config must be a simple YAML filename")
        text = "FROM " + base + "\nCOPY " + config + " /fluent-bit/etc/" + config + "\nCMD [ \"fluent-bit\", \"-c\", \"/fluent-bit/etc/" + config + "\"]\n"
    else:
        text = "FROM " + base + "\nCOPY prometheus_demo_service /bin/prometheus_demo_service\nEXPOSE 8080\nENTRYPOINT [\"/bin/prometheus_demo_service\"]\n"
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("python", "java", "java-metrics", "go", "config", "fluentbit", "fluentbit-memory-limit", "patch-runtime", "java17", "verify-java17", "extract-source", "extract-zip", "copy-context", "capture-plugins"))
    parser.add_argument("--source", required=True)
    parser.add_argument("--output")
    parser.add_argument("--base", default="")
    parser.add_argument("--programmatic", default="")
    arguments = parser.parse_args()
    try:
        if arguments.kind == "patch-runtime":
            patch_runtime(arguments.source)
            return
        if arguments.kind == "java17":
            java17(arguments.source)
            return
        if arguments.kind == "verify-java17":
            verify_java17(arguments.source)
            return
        if arguments.kind == "fluentbit-memory-limit":
            enable_fluentbit_memory_limit(arguments.source)
            return
        if arguments.kind == "java-metrics":
            enable_java_metrics(arguments.source)
            return
        if not arguments.output:
            parser.error("--output is required for an image recipe")
        if arguments.kind == "extract-source":
            extract_source(arguments.source, arguments.output)
            return
        if arguments.kind == "extract-zip":
            extract_zip(arguments.source, arguments.output)
            return
        if arguments.kind == "copy-context":
            copy_context(arguments.source, arguments.output)
            return
        if arguments.kind == "capture-plugins":
            capture_plugins(arguments.source, arguments.output)
            return
        result = render(arguments.kind, Path(arguments.source).read_text(encoding="utf-8"), arguments.base, arguments.programmatic)
        Path(arguments.output).write_text(result, encoding="utf-8")
    except (ValueError, OSError) as error:
        parser.exit(1, "[prepare-learner-build] ERROR: " + str(error) + "\n")


if __name__ == "__main__":
    main()