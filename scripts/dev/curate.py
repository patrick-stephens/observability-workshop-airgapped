import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EXTRACTED = ROOT / "content" / "extracted"
COMMANDS_PATH = EXTRACTED / "commands.json"
OUTPUT_PATH = EXTRACTED / "curated.json"
TRACKS = ("opentelemetry", "otel-developers", "prometheus", "fluentbit", "perses")


def docs_text(track):
    parts = []
    for path in sorted((ROOT / "content" / "docs" / track).rglob("*.html")):
        parts.append(path.read_text(encoding="utf-8", errors="replace"))
    return "\n".join(parts).lower()


def docker_path_runs(track, commands):
    for lab in commands[track]["labs"]:
        if lab["path_type"] != "docker":
            continue
        for command in lab["commands"]:
            if command["type"] == "run":
                yield lab, command


def make_entry(name, lab, command, check):
    env = {}
    for item in command.get("env", []):
        key, separator, value = item.partition("=")
        if separator:
            env[key] = value
    return {
        "name": name,
        "engine": "docker",
        "image": command.get("image"),
        "ports": command.get("ports", []),
        "env": env,
        "volumes": command.get("volumes", []),
        "cmd": command.get("cmd", []),
        "check": check,
        "source": {
            "file": lab["file"],
            "path_type": lab["path_type"],
            "engine": command["engine"],
            "raw": command["raw"],
        },
    }


def first_match(track, commands, predicate):
    for lab, command in docker_path_runs(track, commands):
        if predicate(command):
            return lab, command
    return None


def main():
    commands = json.loads(COMMANDS_PATH.read_text(encoding="utf-8"))
    curated = {}

    for track in TRACKS:
        docs = docs_text(track)
        runs = []
        unresolved = []
        notes = []

        if track == "opentelemetry":
            match = first_match(track, commands, lambda item: "jaegertracing/all-in-one" in (item.get("image") or ""))
            if match and "16686" in docs and "jaeger" in docs:
                runs.append(make_entry("jaeger", *match, {"url": "http://localhost:16686", "expect": "Jaeger"}))
                if match[1]["engine"] != "docker":
                    notes.append("The unsuffixed docker-path file invokes Podman; source.engine records the actual binary while engine follows the requested path label.")
            else:
                unresolved.append("The unsuffixed lab path contains no Jaeger container run command; no flags were inferred from another workshop.")

        elif track == "otel-developers":
            match = first_match(track, commands, lambda item: "jaegertracing/all-in-one" in (item.get("image") or ""))
            if match and "16686" in docs and "jaeger" in docs:
                runs.append(make_entry("jaeger", *match, {"url": "http://localhost:16686", "expect": "Jaeger"}))
                if match[1]["engine"] != "docker":
                    notes.append("The unsuffixed docker-path file invokes Podman; source.engine records the actual binary while engine follows the requested path label.")
            else:
                unresolved.append("No Jaeger run command with a docs-confirmed 16686 endpoint was found in the unsuffixed labs.")

        elif track == "prometheus":
            match = first_match(track, commands, lambda item: "prometheus" in (item.get("image") or "").lower() and any(port.endswith(":9090") for port in item.get("ports", [])))
            if match and "9090" in docs and "prometheus" in docs:
                runs.append(make_entry("prometheus", *match, {"url": "http://localhost:9090/-/ready", "expect": "Prometheus"}))
                if match[1]["engine"] != "docker":
                    notes.append("The unsuffixed docker-path file invokes Podman; source.engine records the actual binary while engine follows the requested path label.")
                if "/-/ready" not in docs:
                    notes.append("The docs confirm Prometheus on port 9090 but do not mention /-/ready; the requested readiness URL is retained.")
            else:
                unresolved.append("No unsuffixed Prometheus run command with a published host port 9090 was found.")

        elif track == "fluentbit":
            match = first_match(track, commands, lambda item: any(len(parts := port.rsplit(":", 2)) >= 2 and parts[-2] == "2020" for port in item.get("ports", [])))
            if match and "2020" in docs:
                runs.append(make_entry("fluentbit", *match, {"url": "http://localhost:2020/api/v1/metrics/prometheus", "expect": "fluentbit"}))
            else:
                unresolved.append("No unsuffixed Fluent Bit run command publishes host port 2020, and the mirrored docs do not establish that check; no port flag was invented.")

        elif track == "perses":
            match = first_match(track, commands, lambda item: "persesdev/perses" in (item.get("image") or ""))
            if match:
                unresolved.append("Perses is run only in lab02-podman.html, not an unsuffixed docker-path lab; the requested path filter excludes it.")
            else:
                alternate = any("persesdev/perses" in (command.get("image") or "") for lab in commands[track]["labs"] for command in lab["commands"])
                if alternate:
                    unresolved.append("Perses is run only in a suffixed path, not an unsuffixed docker-path lab; the requested path filter excludes it.")
                else:
                    unresolved.append("No Perses container run command was found in the current labs.")
            if "localhost:8080" in docs and "perses" in docs:
                notes.append("The mirrored docs use Perses on port 8080, not the expected port 3000; the docs take precedence.")
            if "9100" in docs and "node-exporter" in docs:
                notes.append("The mirrored docs place node-exporter on port 9100, but its run command is in lab05-podman.html and excluded by the requested path filter.")

        curated[track] = {"runs": runs, "unresolved": unresolved, "notes": notes}

    OUTPUT_PATH.write_text(json.dumps(curated, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    for track, value in curated.items():
        print(f"{track}: runs={len(value['runs'])}; unresolved={len(value['unresolved'])}; notes={len(value['notes'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
