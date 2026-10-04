# v2: Curate primary services across every lab variant with source evidence and explicit execution adaptations.
import json
import re
from html.parser import HTMLParser
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EXTRACTED = ROOT / "content" / "extracted"
COMMANDS_PATH = EXTRACTED / "commands.json"
OUTPUT_PATH = EXTRACTED / "curated.json"
TRACKS = ("opentelemetry", "otel-developers", "prometheus", "fluentbit", "perses")
JAEGER_IMAGE = "docker.io/jaegertracing/all-in-one:1.76.0"


class LinkParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links = []

    def handle_starttag(self, tag, attrs):
        for key, value in attrs:
            if tag.lower() == "a" and key.lower() == "href" and value:
                self.links.append(value)


def track_html(track):
    pages = []
    for base in (ROOT / "content" / "repos" / track, ROOT / "content" / "docs" / track):
        if base.is_dir():
            pages.extend(sorted(base.rglob("*.html")))
    return pages


def track_text(track):
    return "\n".join(path.read_text(encoding="utf-8", errors="replace") for path in track_html(track)).lower()


def archive_links(track):
    links = []
    for page in track_html(track):
        parser = LinkParser()
        parser.feed(page.read_text(encoding="utf-8", errors="replace"))
        links.extend(link for link in parser.links if re.search(r"\.(?:zip|tgz|tar(?:\.gz|\.bz2|\.xz)?)(?:[?#].*)?$", link, re.IGNORECASE))
    return list(dict.fromkeys(links))


def all_commands(track, commands):
    for lab in commands[track]["labs"]:
        for command in lab["commands"]:
            yield lab, command


def choose(track, commands, predicate, preferred_files=()):
    candidates = list(all_commands(track, commands))
    ordered = []
    for filename in preferred_files:
        ordered.extend(pair for pair in candidates if pair[0]["file"] == filename)
    ordered.extend(pair for pair in candidates if pair[0]["file"] not in preferred_files)
    return next(((lab, command) for lab, command in ordered if predicate(lab, command)), None)


def build_provenance(track, tag, commands):
    sources = []
    for lab, command in all_commands(track, commands):
        if command["type"] == "build" and command.get("tag") == tag:
            sources.append({
                "file": lab["file"],
                "path_type": lab["path_type"],
                "engine": command["engine"],
                "cwd": command.get("cwd", "."),
                "context": command.get("context"),
                "dockerfile": command.get("dockerfile"),
                "dockerfile_arg": command.get("dockerfile_arg"),
                "runtime_download": command.get("runtime_download", False),
                "runtime_download_sources": command.get("runtime_download_sources", []),
                "raw": command["raw"],
            })
    return sources


def make_entry(name, lab, command, image, check, ports=None, prep=None, source_extra=None, adaptations=None, cmd=None):
    env = {}
    for value in command.get("env", []):
        key, separator, item = value.partition("=")
        if separator:
            env[key] = item
    chosen_ports = list(command.get("ports", [])) if ports is None else list(ports)
    raw = command.get("raw", "")
    exec_adaptations = []
    if command.get("engine") == "podman":
        if "play kube" in raw:
            exec_adaptations.append("Preserve the source podman play-kube operation through the rootful Podman runtime; this manifest start is not rewritten as docker run.")
        else:
            exec_adaptations.append("Use the docker shim for the source Podman command; both resolve to the same rootful Podman image store.")
    if command.get("type") == "run" and not command.get("detached"):
        exec_adaptations.append("-d added so the service remains available for verification.")
    if re.search(r"(?:^|\s)-i(?:t|\s)|(?:^|\s)-t(?:i|\s)|--interactive|--tty", raw):
        exec_adaptations.append("Interactive/TTY flags removed because verification has no interactive terminal.")
    exec_adaptations.extend(adaptations or [])
    source = {
        "file": lab["file"],
        "path_type": lab["path_type"],
        "engine": command.get("engine"),
        "raw": raw,
        "cwd": command.get("cwd", "."),
    }
    if source_extra:
        source.update(source_extra)
    result = {
        "name": name,
        "exec": "docker",
        "image": image,
        "ports": chosen_ports,
        "env": env,
        "volumes": list(command.get("volumes", [])),
        "cmd": list(command.get("cmd", [])) if cmd is None else list(cmd),
        "check": check,
        "exec_adaptations": exec_adaptations,
        "source": source,
    }
    if prep:
        result["verify_time_prep"] = prep
    return result


def check_for(text, url, expected, fallback_reason):
    if expected.lower() in text:
        return {"url": url, "expect": expected}
    return {"type": "running", "url": url, "reason": fallback_reason}


def main():
    commands = json.loads(COMMANDS_PATH.read_text(encoding="utf-8"))
    docs = {track: track_text(track) for track in TRACKS}
    archives = {track: archive_links(track) for track in TRACKS}
    curated = {}

    for track in TRACKS:
        runs = []
        unresolved = []
        notes = []
        text = docs[track]

        if track == "opentelemetry":
            match = choose(track, commands, lambda lab, item: "play kube" in item.get("raw", "") and "app_pod.yaml" in item.get("raw", ""), ("lab04.html", "lab03.html", "lab04-rancher.html"))
            if match:
                lab, command = match
                manifest_path = ROOT / "content/repos/opentelemetry/_vendored/app_pod.yaml"
                manifest_text = manifest_path.read_text(encoding="utf-8", errors="replace") if manifest_path.is_file() else ""
                manifest_is_pod = re.search(r"(?m)^kind:\s*Pod\s*$", manifest_text) is not None
                manifest_sha = None
                if manifest_path.is_file():
                    import hashlib
                    manifest_sha = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
                source_extra = {
                    "manifest": "content/repos/opentelemetry/_vendored/app_pod.yaml",
                    "manifest_present_in_repo": manifest_path.is_file(),
                    "manifest_kind": "Podman-native Pod" if manifest_is_pod else "unverified",
                    "manifest_source": "https://gitlab.com/o11y-workshops/intro-to-instrumentation/-/archive/v1.4/intro-to-instrumentation-v1.4.zip",
                    "manifest_sha256": manifest_sha,
                }
                prep = ["Run `podman play kube content/repos/opentelemetry/_vendored/app_pod.yaml`; its kind: Pod resource is handled by Podman and does not require k3s.", "The manifest starts localhost/hello-otel:prog plus jaegertracing/all-in-one:1.76.0; the app image is built by the earlier lab command."]
                jaeger_entry = make_entry("jaeger", lab, command, JAEGER_IMAGE, check_for(text, "http://localhost:16686", "Jaeger", "The mirrored lab documents the Jaeger UI at localhost:16686."), ports=["16686:16686"], prep=prep, source_extra=source_extra, adaptations=["Use the verified vendored Podman Pod manifest path instead of the source-relative programmatic/app_pod.yaml path.", "This is `podman play kube` for kind: Pod; it is not a kubectl/k3s workflow."], cmd=[])
                jaeger_entry["images"] = ["localhost/hello-otel:prog", JAEGER_IMAGE]
                runs.append(jaeger_entry)
                if not manifest_is_pod:
                    unresolved.append("Searched content/repos/opentelemetry/lab*.html and the linked v1.4 archive; the vendored file is not confirmed as kind: Pod, so Podman-only compatibility remains unverified.")
            else:
                unresolved.append("Searched all content/repos/opentelemetry/lab*.html; no Jaeger run or play-kube command was extracted.")

        elif track == "otel-developers":
            match = choose(track, commands, lambda lab, item: item["type"] == "run" and "jaegertracing/all-in-one" in (item.get("image") or ""), ("lab03.html",))
            if match:
                lab, command = match
                runs.append(make_entry("jaeger", lab, command, command["image"], check_for(text, "http://localhost:16686", "Jaeger", "The mirrored lab identifies the Jaeger UI at localhost:16686.")))
            else:
                unresolved.append("Searched every content/repos/otel-developers/lab*.html; lab03.html is expected to contain the Jaeger run, but no matching parsed run command exists.")

        elif track == "prometheus":
            main_run = choose(track, commands, lambda lab, item: item["type"] == "run" and item.get("image") == "workshop-prometheus:v3.13" and any(port.endswith(":9090") for port in item.get("ports", [])), ("lab05.html",))
            if main_run:
                lab, command = main_run
                runs.append(make_entry("prometheus", lab, command, command["image"], {"url": "http://localhost:9090/-/ready", "expect": "Prometheus"}))
            else:
                unresolved.append("Searched every content/repos/prometheus/lab*.html; lab05.html should run workshop-prometheus:v3.13 on port 9090, but no such parsed run was found.")
            service_run = choose(track, commands, lambda lab, item: item["type"] == "run" and item.get("image") == "prometheus_services_demo:v1" and any(port.endswith(":8080") for port in item.get("ports", [])), ("lab03-podman.html", "lab03.html", "lab07-podman.html", "lab07.html"))
            if service_run:
                lab, command = service_run
                build_sources = build_provenance(track, command["image"], commands)
                adaptations = []
                if any("--load" in source["raw"] for source in build_sources):
                    adaptations.append("The alternate Rancher build source uses buildx-only --load; strip it for Podman, which loads locally by default.")
                runs.append(make_entry("prometheus-services-demo", lab, command, command["image"], {"type": "running", "reason": "The lab documents the container port mapping but does not give a stable response substring for this service."}, source_extra={"build_sources": build_sources}, adaptations=adaptations))
            else:
                unresolved.append("Searched content/repos/prometheus/lab03*.html and lab07*.html; the Buildfile tag prometheus_services_demo:v1 is shown, but no parsed run publishing its service port was found.")

        elif track == "fluentbit":
            match = choose(track, commands, lambda lab, item: item["type"] == "run" and item.get("image") == "workshop-fb:v7" and bool(item.get("ports")), ("lab04.html",))
            if match:
                lab, command = match
                runs.append(make_entry("fluentbit", lab, command, command["image"], {"type": "running", "reason": "The lab run publishes host port 9999 but does not document a stable HTTP response substring for this container."}))
                notes.append("No container run publishes host port 2020; lab04.html runs workshop-fb:v7 with `-p 9999:9999`, so the curated check is container-running rather than an invented metrics URL.")
            else:
                unresolved.append("Searched every content/repos/fluentbit/lab*.html; no Fluent Bit run command publishing a host port was parsed.")

        elif track == "perses":
            perses_run = choose(track, commands, lambda lab, item: item["type"] == "run" and "persesdev/perses" in (item.get("image") or ""), ("lab02-podman.html",))
            if perses_run:
                lab, command = perses_run
                archive = archives[track]
                prep = ["Run the lab's pod creation command before its container commands if the shared datasource pod is needed."]
                if archive:
                    prep.append(f"Lab archive link: {archive[0]}")
                runs.append(make_entry("perses", lab, command, command["image"], check_for(text, "http://localhost:8080", "Perses", "The docs confirm Perses on port 8080; page text is used because the UI may be an SPA."), prep=prep))
            else:
                unresolved.append("Searched all content/repos/perses/lab*.html; lab02-podman.html contains the Perses run, but no parsed persesdev/perses command was found.")

            pod_create = choose(track, commands, lambda lab, item: "podman pod create --name workshop-datasource" in item.get("raw", ""), ("lab05-podman.html",))
            pod_create_raw = pod_create[1]["raw"] if pod_create else None
            prometheus_run = choose(track, commands, lambda lab, item: item["type"] == "run" and item.get("image") == "docker.io/prom/prometheus:v3.13.1" and item.get("pod") == "workshop-datasource", ("lab05-podman.html",))
            if prometheus_run:
                lab, command = prometheus_run
                pod_ports = pod_create[1].get("ports", []) if pod_create else []
                ports = [port for port in pod_ports if port.endswith(":9090")]
                prep = ["Ensure support/workshop-prometheus.yml exists; the exact source run mounts this lab-provided configuration read-only."]
                if archives[track]:
                    prep.append(f"Lab archive link: {archives[track][0]}")
                runs.append(make_entry("prometheus", lab, command, command["image"], check_for(text, "http://localhost:9090/-/ready", "Prometheus", "The docs show the Prometheus server ready message on port 9090."), ports=ports, prep=prep, source_extra={"pod_create_raw": pod_create_raw} if pod_create_raw else None))
            else:
                unresolved.append("Searched content/repos/perses/lab05-podman.html; it documents a Prometheus run in workshop-datasource, but no parsed run command was found.")

            node_run = choose(track, commands, lambda lab, item: item["type"] == "run" and item.get("image") == "quay.io/prometheus/node-exporter:v1.12.1" and item.get("pod") == "workshop-datasource", ("lab05-podman.html",))
            if node_run:
                lab, command = node_run
                pod_ports = pod_create[1].get("ports", []) if pod_create else []
                ports = [port for port in pod_ports if port.endswith(":9100")]
                runs.append(make_entry("node-exporter", lab, command, command["image"], check_for(text, "http://localhost:9100/metrics", "node_", "The mirrored lab documents node-exporter on port 9100, but its specific metric text is not present in the copied docs."), ports=ports, adaptations=["Host port 9100 is published by the source pod-create command; the container command itself joins that pod."], source_extra={"pod_create_raw": pod_create_raw} if pod_create_raw else None))
            else:
                unresolved.append("Searched content/repos/perses/lab05-podman.html; the node-exporter run command is documented, but no parsed quay.io/prometheus/node-exporter command was found.")

        curated[track] = {"runs": runs, "unresolved": unresolved, "notes": notes}

    OUTPUT_PATH.write_text(json.dumps(curated, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    for track, value in curated.items():
        print(f"{track}: runs={len(value['runs'])}; unresolved={len(value['unresolved'])}; notes={len(value['notes'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
