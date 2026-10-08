"""Offline regression checks for dependency bundles, profiles and derived recipes."""

import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile


ROOT = Path(__file__).resolve().parents[2]


def load_module(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BUNDLE = load_module("bundle", "learner-vm/dependency_bundle.py")
RECIPES = load_module("recipes", "scripts/dev/prepare-learner-build.py")


class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def make_source(self):
        source = self.root / "payload"
        source.mkdir()
        for name in BUNDLE.PACKAGE_DIRS:
            directory = source / name
            directory.mkdir(parents=True)
            fixture = directory / "fixture"
            fixture.write_text("verified cache content", encoding="utf-8")
            os.utime(fixture, (1, 1))
        (source / "images").mkdir()
        (source / "images/lab-images.tar").write_bytes(b"mock image archive")
        manifest = {"schema": 1, "architecture": "amd64", "source_commit": "a" * 40,
                    "images": [{"reference": "fixture:1", "id": "sha256:" + "b" * 64}],
                    "coverage": {"required": ["fixture"], "verified": ["fixture"]},
                    "offline_verified": True}
        (source / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        return source

    def test_old_verified_cache_is_accepted(self):
        source = self.make_source()
        archive = self.root / "bundle.tar.gz"
        BUNDLE.seal(source, archive)
        BUNDLE.verify(archive, BUNDLE.digest_file(archive), self.root / "installed")
        self.assertEqual((self.root / "installed/cache/pypi/wheels/fixture").read_text(), "verified cache content")

    def test_checksum_mismatch_rejected(self):
        source = self.make_source()
        archive = self.root / "bundle.tar.gz"
        BUNDLE.seal(source, archive)
        with self.assertRaises(ValueError):
            BUNDLE.verify(archive, "0" * 64, self.root / "installed")
        self.assertFalse((self.root / "installed").exists())

    def test_incomplete_coverage_not_published(self):
        source = self.make_source()
        path = source / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["coverage"]["required"].append("missing-lab")
        path.write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            BUNDLE.seal(source, self.root / "bundle.tar.gz")

    def test_unsafe_paths_rejected(self):
        for name in ("../escape", "/absolute", "payload/../escape", "payload\\escape"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                BUNDLE.safe_path(name)

    def test_profiles_disable_freshness_not_integrity(self):
        urls = ("https://art.example/pypi", "https://art.example/maven", "https://art.example/npm", "https://art.example/go")
        for mode in ("offline", "artifactory"):
            with self.subTest(mode=mode):
                output = self.root / mode
                BUNDLE.profile(output, self.root, mode, urls, "")
                pip = (output / "pip.conf").read_text()
                npm = (output / "npmrc").read_text()
                self.assertIn("disable-pip-version-check = true", pip)
                for value in ("prefer-offline=true", "audit=false", "fund=false", "update-notifier=false", "strict-ssl=true"):
                    self.assertIn(value, npm)
                settings = ET.parse(output / "settings.xml")
                namespace = {"m": "http://maven.apache.org/SETTINGS/1.0.0"}
                self.assertEqual(settings.find(".//m:mirror/m:id", namespace).text, "workshop-artifactory")
                policies = settings.findall(".//m:updatePolicy", namespace)
                self.assertEqual(len(policies), 4)
                self.assertTrue(all(item.text == "never" for item in policies))
                self.assertTrue(all(item.text == "fail" for item in settings.findall(".//m:checksumPolicy", namespace)))
                if mode == "offline":
                    self.assertIn("no-index = true", pip)
                    self.assertIn("offline=true", npm)
                    self.assertEqual(settings.find("m:offline", namespace).text, "true")

    def test_endpoint_credentials_and_injection_rejected(self):
        for value in ("http://art.example/repo", "https://user:fixture@art.example/repo", "https://art.example/a'bad", "https://art.example/repo?token=fixture"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                BUNDLE.endpoint_url(value, "react")
        self.assertEqual(BUNDLE.endpoint_url("https://art.example/go", "module/@v/v1.mod"), "https://art.example/go/module/@v/v1.mod")

    def test_generated_python_recipe_has_no_index(self):
        base = "docker.io/library/python:3.13-bullseye@sha256:" + "a" * 64
        text = RECIPES.render("python", "FROM python:3.13-bullseye\nRUN pip install -r requirements.txt\n", base, "prog")
        self.assertIn("PIP_NO_INDEX=1", text)
        self.assertIn("PIP_DISABLE_PIP_VERSION_CHECK=1", text)
        self.assertIn("opentelemetry-sdk==1.44.0", text)

    def test_java17_pom_transformation(self):
        path = self.root / "pom.xml"
        path.write_text('<project xmlns="http://maven.apache.org/POM/4.0.0"><properties><maven.compiler.source>21</maven.compiler.source></properties></project>')
        RECIPES.java17(self.root)
        properties = ET.parse(path).find("{*}properties")
        self.assertEqual(properties.find("{*}maven.compiler.source").text, "17")
        self.assertEqual(properties.find("{*}maven.compiler.target").text, "17")

    def test_java_bytecode_rejection(self):
        path = self.root / "application.jar"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("App.class", b"\xca\xfe\xba\xbe" + struct.pack(">HH", 0, 65))
        with self.assertRaises(ValueError):
            RECIPES.verify_java17(self.root)
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("App.class", b"\xca\xfe\xba\xbe" + struct.pack(">HH", 0, 61))
        RECIPES.verify_java17(self.root)

    def test_safe_helper_zip_extraction(self):
        archive_path = self.root / "helper.zip"
        with zipfile.ZipFile(archive_path, "w") as archive:
            archive.writestr("helper/configs/Buildfile", "FROM fluent-bit\n")
        destination = self.root / "helper"
        RECIPES.extract_zip(archive_path, destination)
        self.assertEqual((destination / "helper/configs/Buildfile").read_text(), "FROM fluent-bit\n")
        RECIPES.extract_zip(archive_path, destination)
        unsafe = self.root / "unsafe.zip"
        with zipfile.ZipFile(unsafe, "w") as archive:
            archive.writestr("../escape", "no")
        with self.assertRaises(ValueError):
            RECIPES.extract_zip(unsafe, self.root / "unsafe")

    def test_fluentbit_recipe_uses_pinned_base_and_local_config(self):
        base = "ghcr.io/fluent/fluent-bit:5.1.1@sha256:" + "a" * 64
        text = RECIPES.render("fluentbit", "", base, "routing-fb.yaml")
        self.assertIn("FROM " + base, text)
        self.assertIn("COPY routing-fb.yaml /fluent-bit/etc/routing-fb.yaml", text)
        self.assertNotIn("https://", text)

    def test_fluentbit_memory_limit_transforms_only_expected_stage(self):
        path = self.root / "workshop-fb.yaml"
        path.write_text("pipeline:\n  inputs:\n    - name: dummy\n      #mem_buf_limit: 2MB\n", encoding="utf-8")
        RECIPES.enable_fluentbit_memory_limit(path)
        self.assertIn("      mem_buf_limit: 2MB\n", path.read_text())
        with self.assertRaises(ValueError):
            RECIPES.enable_fluentbit_memory_limit(path)

    def test_java_metrics_transform_enables_lab6_reference_blocks(self):
        archive_path = ROOT / "content/vendor/downloads/otel-developers/opentelemetry-java-tracing-demo-v1.1.zip"
        with zipfile.ZipFile(archive_path) as archive:
            member = "opentelemetry-java-tracing-demo-v1.1/src/main/java/io/chronosphere/App.java"
            source = self.root / "App.java"
            source.write_bytes(archive.read(member))
        RECIPES.enable_java_metrics(source)
        transformed = source.read_text(encoding="utf-8")
        for expected in (
            "import io.opentelemetry.api.metrics.LongCounter;",
            "private static final LongCounter hitsCounter = meter",
            "private static OpenTelemetry initOpenTelemetry()",
            "ServiceAttributes.SERVICE_NAME, \"java-demo\")));",
            "hitsCounter.add(1, Attributes.of(",
            "requestDuration.record(duration, Attributes.of(",
        ):
            self.assertIn(expected, transformed)
        self.assertNotIn("// private static final LongCounter hitsCounter", transformed)
        self.assertNotRegex(transformed, r"(?m)^\s*//\s*ServiceAttributes\.SERVICE_NAME")
        self.assertNotIn("ResourceAttributes", transformed)


if __name__ == "__main__":
    unittest.main()