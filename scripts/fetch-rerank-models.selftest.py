#!/usr/bin/env python3
"""Offline self-test for fetch-rerank-models.py."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FETCHER = ROOT / "scripts/fetch-rerank-models.py"
TRACKED_LOCK = ROOT / "resources/rerank-models.lock.json"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class FakeResponse:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.offset = 0
        self.headers = {"Content-Length": str(len(data))}

    def __enter__(self) -> FakeResponse:
        return self

    def __exit__(self, *_arguments: object) -> None:
        return None

    def read(self, size: int = -1) -> bytes:
        if self.offset >= len(self.data):
            return b""
        end = len(self.data) if size < 0 else min(self.offset + size, len(self.data))
        chunk = self.data[self.offset : end]
        self.offset = end
        return chunk


class FetcherSelfTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.resources = self.root / "resources"
        self.licenses = self.resources / "licenses"
        self.licenses.mkdir(parents=True)
        self.sources = self.root / "sources"
        self.sources.mkdir()
        self.output = self.root / "seed/msime/models"
        self.lock = self.resources / "rerank-models.lock.json"
        self.payloads = {
            "keyboard": b"keyboard model fixture\n",
            "settled": b"settled model fixture with a pause\n",
        }
        self.write_manifest()

    def write_manifest(self) -> None:
        license_bytes = b"Apache License 2.0 fixture\n"
        notice_bytes = b"chinese-ime-lm attribution fixture\n"
        (self.licenses / "LICENSE.txt").write_bytes(license_bytes)
        (self.licenses / "NOTICE.txt").write_bytes(notice_bytes)
        lock = {
            "schema_version": 1,
            "upstream": {
                "release": "model-v1",
                "license": "Apache-2.0",
                "msime_pin": "09e3d53c16eb11420bef708c35d425c31eff41e2",
                "license_file": "licenses/LICENSE.txt",
                "license_size": len(license_bytes),
                "license_sha256": digest(license_bytes),
                "notice_file": "licenses/NOTICE.txt",
                "notice_size": len(notice_bytes),
                "notice_sha256": digest(notice_bytes),
            },
            "deployment": {
                "directory": "data/owl-rime/msime/models",
                "license_name": "LICENSE-Apache-2.0.txt",
                "notice_name": "NOTICE.txt",
            },
            "models": [
                {
                    "role": "keyboard",
                    "upstream_preset": "keyboard",
                    "upstream_name": "sentence-model.safetensors",
                    "output_name": "keyboard-model.bin",
                    "format": "safetensors",
                    "url": "https://example.invalid/sentence-model.safetensors",
                    "size": len(self.payloads["keyboard"]),
                    "sha256": digest(self.payloads["keyboard"]),
                },
                {
                    "role": "settled",
                    "upstream_preset": "desktop",
                    "upstream_name": "sentence-model-desktop.safetensors",
                    "output_name": "settled-model.bin",
                    "format": "safetensors",
                    "url": "https://example.invalid/sentence-model-desktop.safetensors",
                    "size": len(self.payloads["settled"]),
                    "sha256": digest(self.payloads["settled"]),
                },
            ],
        }
        self.lock.write_text(json.dumps(lock, indent=2) + "\n")

    def write_sources(self, *, corrupt_settled: bool = False) -> None:
        (self.sources / "sentence-model.safetensors").write_bytes(
            self.payloads["keyboard"]
        )
        settled = self.payloads["settled"]
        if corrupt_settled:
            settled = b"X" * len(settled)
        (self.sources / "sentence-model-desktop.safetensors").write_bytes(settled)

    def run_fetcher(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return self.run_fetcher_for(self.output, *arguments)

    def run_fetcher_for(
        self, output: Path, *arguments: str
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(FETCHER),
                "--lock",
                str(self.lock),
                "--out",
                str(output),
                *arguments,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def assert_output_materialized(self) -> None:
        self.assertEqual(
            (self.output / "keyboard-model.bin").read_bytes(),
            self.payloads["keyboard"],
        )
        self.assertEqual(
            (self.output / "settled-model.bin").read_bytes(),
            self.payloads["settled"],
        )
        self.assertEqual(
            (self.output / "LICENSE-Apache-2.0.txt").read_bytes(),
            (self.licenses / "LICENSE.txt").read_bytes(),
        )
        self.assertEqual(
            (self.output / "NOTICE.txt").read_bytes(),
            (self.licenses / "NOTICE.txt").read_bytes(),
        )

    def test_tracked_lock_pins_the_reviewed_upstream_artifacts(self) -> None:
        lock = json.loads(TRACKED_LOCK.read_text())
        self.assertEqual(lock["upstream"]["release"], "model-v1")
        self.assertEqual(lock["upstream"]["license"], "Apache-2.0")
        by_role = {model["role"]: model for model in lock["models"]}
        self.assertEqual(
            by_role["keyboard"]["upstream_name"], "sentence-model.safetensors"
        )
        self.assertEqual(by_role["keyboard"]["output_name"], "keyboard-model.bin")
        self.assertEqual(by_role["keyboard"]["size"], 4_486_280)
        self.assertEqual(
            by_role["keyboard"]["sha256"],
            "86ac529510cb3b4968a5e6ade83ec8080f5b34a0a681e75c362accbbd387d1c1",
        )
        self.assertEqual(
            by_role["settled"]["upstream_name"],
            "sentence-model-desktop.safetensors",
        )
        self.assertEqual(by_role["settled"]["output_name"], "settled-model.bin")
        self.assertEqual(by_role["settled"]["size"], 25_480_184)
        self.assertEqual(
            by_role["settled"]["sha256"],
            "0a6ecba69bf1d39c7eb49549c716477dd6c03fdf05757773e1f50435262fb469",
        )
        notice = (TRACKED_LOCK.parent / lock["upstream"]["notice_file"]).read_text(
            encoding="utf-8"
        )
        self.assertIn("Apache License 2.0", notice)
        self.assertIn("C4 中文部分（ODC-BY）", notice)
        self.assertIn("LCCC（MIT）", notice)

    def test_materializes_then_repeats_without_touching_files(self) -> None:
        self.write_sources()
        first = self.run_fetcher("--source-dir", str(self.sources))
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assert_output_materialized()
        before = {
            path.name: (path.read_bytes(), path.stat().st_mtime_ns)
            for path in self.output.iterdir()
        }

        second = self.run_fetcher()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("already at the locked digest", second.stdout)
        after = {
            path.name: (path.read_bytes(), path.stat().st_mtime_ns)
            for path in self.output.iterdir()
        }
        self.assertEqual(before, after)

    def test_https_download_fallback_writes_the_locked_bytes(self) -> None:
        spec = importlib.util.spec_from_file_location("fetch_rerank_models", FETCHER)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        fetcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fetcher)
        lock = json.loads(self.lock.read_text())
        model = lock["models"][0]
        destination = self.root / "download-stage" / model["output_name"]
        destination.parent.mkdir()
        original_urlopen = fetcher.urllib.request.urlopen

        def fake_urlopen(request: object, timeout: int) -> FakeResponse:
            self.assertEqual(request.full_url, model["url"])
            self.assertEqual(timeout, 300)
            return FakeResponse(self.payloads["keyboard"])

        fetcher.urllib.request.urlopen = fake_urlopen
        try:
            fetcher.download(model, destination)
        finally:
            fetcher.urllib.request.urlopen = original_urlopen
        self.assertEqual(destination.read_bytes(), self.payloads["keyboard"])

    def test_missing_source_leaves_no_output_files(self) -> None:
        (self.sources / "sentence-model.safetensors").write_bytes(
            self.payloads["keyboard"]
        )
        result = self.run_fetcher("--source-dir", str(self.sources))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.output.parent.glob(".*.staging-*")), [])

    def test_bad_source_digest_leaves_no_output_files(self) -> None:
        self.write_sources(corrupt_settled=True)
        result = self.run_fetcher("--source-dir", str(self.sources))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("settled", result.stderr)
        self.assertFalse(self.output.exists())

    def test_check_detects_damage_and_fetch_repairs_it(self) -> None:
        self.write_sources()
        first = self.run_fetcher("--source-dir", str(self.sources))
        self.assertEqual(first.returncode, 0, first.stderr)
        damaged = self.output / "settled-model.bin"
        damaged.write_bytes(b"X" * len(self.payloads["settled"]))

        checked = self.run_fetcher("--check")
        self.assertNotEqual(checked.returncode, 0)
        self.assertIn("settled", checked.stderr)

        repaired = self.run_fetcher("--source-dir", str(self.sources))
        self.assertEqual(repaired.returncode, 0, repaired.stderr)
        passed = self.run_fetcher("--check")
        self.assertEqual(passed.returncode, 0, passed.stderr)
        self.assert_output_materialized()

    def test_check_targets_the_app_not_a_valid_source_cache(self) -> None:
        self.write_sources()
        source_cache = self.root / "data/owl-rime/msime/models"
        materialized = self.run_fetcher_for(
            source_cache, "--source-dir", str(self.sources)
        )
        self.assertEqual(materialized.returncode, 0, materialized.stderr)
        source_check = self.run_fetcher_for(source_cache, "--check")
        self.assertEqual(source_check.returncode, 0, source_check.stderr)

        app_models = (
            self.root / "Owltype.app/Contents/SharedSupport/msime/models"
        )
        shutil.copytree(source_cache, app_models)
        keyboard = app_models / "keyboard-model.bin"
        keyboard.unlink()
        missing = self.run_fetcher_for(app_models, "--check")
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("keyboard-model.bin", missing.stderr)

        shutil.copy2(source_cache / keyboard.name, keyboard)
        copied = self.run_fetcher_for(app_models, "--check")
        self.assertEqual(copied.returncode, 0, copied.stderr)
        (app_models / "settled-model.bin").write_bytes(
            b"X" * len(self.payloads["settled"])
        )
        damaged = self.run_fetcher_for(app_models, "--check")
        self.assertNotEqual(damaged.returncode, 0)
        self.assertIn("settled", damaged.stderr)

    def test_release_gates_check_bundle_model_directories(self) -> None:
        expected = {
            ROOT / "scripts/finalize-release-bundle.py": (
                '"--out"',
                'str(app / "Contents/SharedSupport/msime/models")',
            ),
            ROOT / "scripts/check-release.sh": (
                '--out "$APP/Contents/SharedSupport/msime/models"',
                '--out "$pkg_app/Contents/SharedSupport/msime/models"',
            ),
            ROOT / "scripts/check-installed.sh": (
                '--out "$APP/Contents/SharedSupport/msime/models"',
            ),
        }
        for path, fragments in expected.items():
            text = path.read_text(encoding="utf-8")
            self.assertIn("fetch-rerank-models.py", text, path.name)
            for fragment in fragments:
                self.assertIn(fragment, text, path.name)

    def test_symlink_output_is_not_accepted_as_materialized(self) -> None:
        self.write_sources()
        self.output.mkdir(parents=True)
        outside = self.root / "outside-model"
        outside.write_bytes(self.payloads["keyboard"])
        (self.output / "keyboard-model.bin").symlink_to(outside)
        result = self.run_fetcher("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a regular file", result.stderr)
        self.assertTrue((self.output / "keyboard-model.bin").is_symlink())


if __name__ == "__main__":
    unittest.main()
