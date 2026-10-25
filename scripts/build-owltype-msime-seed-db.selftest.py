#!/usr/bin/env python3
"""Focused regressions for the production Wubi86 seed source and parser."""

from __future__ import annotations

import hashlib
import importlib.util
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).with_name("build-owltype-msime-seed-db.py")


def load_builder():
    spec = importlib.util.spec_from_file_location("owltype_msime_seed_builder", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class WubiSourceTests(unittest.TestCase):
    def setUp(self):
        self.builder = load_builder()

    def test_production_pin_is_the_reviewed_commit_and_content_hashes(self):
        self.assertEqual(
            self.builder.WUBI86_SOURCE_REPO, "KyleBing/rime-wubi86-jidian"
        )
        self.assertEqual(
            self.builder.WUBI86_SOURCE_COMMIT,
            "a194fb8b3ec41ef9dcf079d3a67876fa75f79135",
        )
        self.assertEqual(
            self.builder.WUBI86_SOURCE_SHA256,
            "8ccf1358b91028ed234bbe82647a0bcd0f554a8d5994042de28b146e517633e6",
        )
        self.assertEqual(
            self.builder.WUBI86_LICENSE_SHA256,
            "43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1",
        )
        self.assertEqual(self.builder.WUBI86_SOURCE_TOTAL_ROWS, 89_273)
        self.assertEqual(self.builder.WUBI86_ACCEPTED_ROWS, 89_272)
        self.assertEqual(self.builder.WUBI86_UNIQUE_ROWS, 89_269)
        self.assertEqual(self.builder.WUBI86_DUPLICATE_ROWS, 3)
        self.assertEqual(self.builder.WUBI86_REJECTED_ROWS, 1)
        self.assertEqual(
            self.builder.WUBI86_REJECTIONS,
            [
                {
                    "sourceLine": 7911,
                    "reason": "empty text column",
                    "row": "\tcokg\t10\t全角空格",
                }
            ],
        )
        self.assertEqual(
            self.builder.WUBI86_REQUIRED_PAIRS,
            {
                ("a", "工"),
                ("aaaa", "工"),
                ("ifcy", "法"),
                ("wq", "你"),
                ("wqiy", "你"),
                ("edui", "膫"),
                ("jixu", "曳光弹"),
                ("hang", "歫"),
                ("hang", "虛"),
            },
        )
        self.assertEqual(
            self.builder.WUBI86_FORBIDDEN_PAIRS,
            {("bian", "便"), ("qigu", "乐平")},
        )

    def test_parser_keeps_max_weight_and_reports_duplicate_and_rejected_rows(self):
        source = "\n".join(
            [
                "---",
                "name: fixture",
                "...",
                "工\ta\t20",
                "工\ta\t30",
                "法\tifcy\t40",
                "好\tvbg",
                "\tbad\t10",
                "malformed",
                "",
            ]
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fixture.dict.yaml"
            path.write_text(source, encoding="utf-8")
            with (
                mock.patch.object(self.builder, "WUBI86_SOURCE_TOTAL_ROWS", 6),
                mock.patch.object(self.builder, "WUBI86_ACCEPTED_ROWS", 4),
                mock.patch.object(self.builder, "WUBI86_UNIQUE_ROWS", 3),
                mock.patch.object(self.builder, "WUBI86_DUPLICATE_ROWS", 1),
                mock.patch.object(self.builder, "WUBI86_REJECTED_ROWS", 2),
                mock.patch.object(
                    self.builder,
                    "WUBI86_REQUIRED_PAIRS",
                    {("a", "工"), ("ifcy", "法"), ("vbg", "好")},
                ),
            ):
                rows, stats = self.builder.import_wubi86_entries(path)
        self.assertEqual(
            stats,
            self.builder.WubiImportStats(
                source_total_rows=6,
                accepted_rows=4,
                unique_rows=3,
                duplicate_rows=1,
                rejected_rows=2,
            ),
        )
        self.assertEqual(
            rows,
            [("a", "工", 30), ("ifcy", "法", 40), ("vbg", "好", 1)],
        )

    def test_missing_header_terminator_has_stable_error_mapping(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "broken.dict.yaml"
            path.write_text("---\nname: broken\n工\ta\t20\n", encoding="utf-8")
            with self.assertRaises(self.builder.SeedSourceError) as raised:
                self.builder.import_wubi86_entries(path)
        self.assertEqual(raised.exception.code, "MSIME_SOURCE_FORMAT_INVALID")

    def test_bad_cache_hash_is_reported_before_import(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "source.dict.yaml"
            path.write_bytes(b"tampered")
            with self.assertRaises(self.builder.SeedSourceError) as raised:
                self.builder.read_pinned_source(path, "00", "fixture")
        self.assertEqual(raised.exception.code, "MSIME_SOURCE_HASH_MISMATCH")

    def test_download_failure_does_not_fall_back_to_fixture_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "missing.dict.yaml"
            with mock.patch.object(
                self.builder.urllib.request,
                "urlopen",
                side_effect=urllib.error.URLError("offline"),
            ):
                with self.assertRaises(self.builder.SeedSourceError) as raised:
                    self.builder.fetch_pinned_source(
                        "https://invalid.example/source", "00", path, "fixture"
                    )
        self.assertEqual(raised.exception.code, "MSIME_SOURCE_DOWNLOAD_FAILED")
        self.assertFalse(path.exists())

    def test_known_synthetic_mapping_is_rejected(self):
        source = "\n".join(["---", "name: fixture", "...", "便\tbian\t20", ""])
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fixture.dict.yaml"
            path.write_text(source, encoding="utf-8")
            with (
                mock.patch.object(self.builder, "WUBI86_SOURCE_TOTAL_ROWS", 1),
                mock.patch.object(self.builder, "WUBI86_ACCEPTED_ROWS", 1),
                mock.patch.object(self.builder, "WUBI86_UNIQUE_ROWS", 1),
                mock.patch.object(self.builder, "WUBI86_DUPLICATE_ROWS", 0),
                mock.patch.object(self.builder, "WUBI86_REJECTED_ROWS", 0),
                mock.patch.object(self.builder, "WUBI86_REQUIRED_PAIRS", set()),
            ):
                with self.assertRaises(self.builder.SeedSourceError) as raised:
                    self.builder.import_wubi86_entries(path)
        self.assertEqual(raised.exception.code, "MSIME_SOURCE_CONTENT_MISMATCH")
        self.assertIn("synthetic", str(raised.exception))

    def test_bad_source_hash_leaves_existing_seed_untouched(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            seed = self.minimal_seed(root / "seed")
            source = self.source_dir(root / "source", b"tampered")
            db_path = seed / "msime" / "msime-pinyin.db"
            before = db_path.read_bytes()
            with self.assertRaises(self.builder.SeedSourceError) as raised:
                self.builder.main(["--wubi-source-dir", str(source), str(seed)])
            self.assertEqual(raised.exception.code, "MSIME_SOURCE_HASH_MISMATCH")
            self.assertEqual(db_path.read_bytes(), before)

    def test_source_content_failure_leaves_existing_seed_untouched(self):
        source_bytes = b"---\nname: fixture\n...\n\xe5\xb7\xa5\ta\t20\n"
        license_bytes = b"fixture license\n"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            seed = self.minimal_seed(root / "seed")
            source = self.source_dir(root / "source", source_bytes, license_bytes)
            db_path = seed / "msime" / "msime-pinyin.db"
            before = db_path.read_bytes()
            with (
                mock.patch.object(
                    self.builder,
                    "WUBI86_SOURCE_SHA256",
                    hashlib.sha256(source_bytes).hexdigest(),
                ),
                mock.patch.object(
                    self.builder,
                    "WUBI86_LICENSE_SHA256",
                    hashlib.sha256(license_bytes).hexdigest(),
                ),
                mock.patch.object(self.builder, "WUBI86_SOURCE_TOTAL_ROWS", 2),
                mock.patch.object(self.builder, "WUBI86_ACCEPTED_ROWS", 1),
                mock.patch.object(self.builder, "WUBI86_UNIQUE_ROWS", 1),
                mock.patch.object(self.builder, "WUBI86_DUPLICATE_ROWS", 0),
                mock.patch.object(self.builder, "WUBI86_REJECTED_ROWS", 0),
                mock.patch.object(self.builder, "WUBI86_REQUIRED_PAIRS", {("a", "工")}),
            ):
                with self.assertRaises(self.builder.SeedSourceError) as raised:
                    self.builder.main(["--wubi-source-dir", str(source), str(seed)])
            self.assertEqual(raised.exception.code, "MSIME_SOURCE_COUNT_MISMATCH")
            self.assertEqual(db_path.read_bytes(), before)

    def test_publish_failure_restores_existing_wubi_artifacts(self):
        source_bytes = b"---\nname: fixture\n...\n\xe5\xb7\xa5\ta\t20\n"
        license_bytes = b"fixture license\n"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            seed = self.minimal_seed(root / "seed")
            source = self.source_dir(root / "source", source_bytes, license_bytes)
            db_path = seed / "msime" / "msime-pinyin.db"
            license_path = seed / self.builder.WUBI86_LICENSE_OUTPUT
            metadata_path = (
                seed / "msime" / self.builder.WUBI86_SOURCE_METADATA_OUTPUT
            )
            license_path.write_bytes(b"old license\n")
            metadata_path.write_bytes(b"old metadata\n")
            before = {
                path: path.read_bytes()
                for path in (db_path, license_path, metadata_path)
            }

            original_replace = Path.replace
            failed = False

            def fail_metadata_install(source_path, target_path):
                nonlocal failed
                if (
                    not failed
                    and source_path.name.startswith(f".{metadata_path.name}.")
                    and target_path == metadata_path
                ):
                    failed = True
                    raise OSError("simulated metadata publish failure")
                return original_replace(source_path, target_path)

            with (
                mock.patch.object(
                    self.builder,
                    "WUBI86_SOURCE_SHA256",
                    hashlib.sha256(source_bytes).hexdigest(),
                ),
                mock.patch.object(
                    self.builder,
                    "WUBI86_LICENSE_SHA256",
                    hashlib.sha256(license_bytes).hexdigest(),
                ),
                mock.patch.object(self.builder, "WUBI86_SOURCE_TOTAL_ROWS", 1),
                mock.patch.object(self.builder, "WUBI86_ACCEPTED_ROWS", 1),
                mock.patch.object(self.builder, "WUBI86_UNIQUE_ROWS", 1),
                mock.patch.object(self.builder, "WUBI86_DUPLICATE_ROWS", 0),
                mock.patch.object(self.builder, "WUBI86_REJECTED_ROWS", 0),
                mock.patch.object(self.builder, "WUBI86_REQUIRED_PAIRS", {("a", "工")}),
                mock.patch.object(Path, "replace", new=fail_metadata_install),
            ):
                with self.assertRaises(OSError):
                    self.builder.build_pinyin_db(
                        seed,
                        db_path,
                        source / self.builder.WUBI86_SOURCE_PATH,
                        source / self.builder.WUBI86_LICENSE_PATH,
                    )

            self.assertTrue(failed)
            for path, expected in before.items():
                self.assertEqual(path.read_bytes(), expected)
            leftovers = [
                path
                for path in seed.rglob("*")
                if path.name.endswith((".tmp", ".bak"))
            ]
            self.assertEqual(leftovers, [])

    @staticmethod
    def minimal_seed(seed: Path) -> Path:
        dicts = seed / "cn_dicts"
        dicts.mkdir(parents=True)
        for name in ("owltype_base.dict.yaml", "owltype_unicode.dict.yaml"):
            (dicts / name).write_text(
                "---\nname: fixture\n...\n你\tni\t1\n",
                encoding="utf-8",
            )
        msime = seed / "msime"
        msime.mkdir()
        (msime / "msime-pinyin.db").write_bytes(b"existing seed")
        return seed

    @staticmethod
    def source_dir(
        source: Path, dictionary: bytes, license_text: bytes = b"license\n"
    ) -> Path:
        source.mkdir()
        (source / "wubi86_jidian.dict.yaml").write_bytes(dictionary)
        (source / "LICENSE").write_bytes(license_text)
        return source


if __name__ == "__main__":
    unittest.main()
