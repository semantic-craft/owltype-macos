#!/usr/bin/env python3
"""Offline regressions for release license entries and SPDX package metadata."""

from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))


def load_script(name: str):
    path = SCRIPTS / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


FINALIZER = load_script("finalize-release-bundle")
BUNDLE = load_script("owl_bundle")
RETIRED_LICENSES = {
    "Contents/SharedSupport/librime-lua.LICENSE",
    "Contents/SharedSupport/librime.LICENSE",
    "Contents/SharedSupport/plum.LICENSE",
}
WUBI_LICENSE = "Contents/SharedSupport/wubi86-jidian.LICENSE"


class ReleaseLicenseEntriesTests(unittest.TestCase):
    def materialize_licenses(self, app: Path) -> None:
        for relative in FINALIZER.REQUIRED_LICENSES:
            path = app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture\n")
        (app / FINALIZER.CHINESE_IME_LM_CRATE_LICENSE).write_bytes(
            (ROOT / "rust/crates/chinese-ime-lm/LICENSE").read_bytes()
        )
        (app / FINALIZER.WUBI86_JIDIAN_LICENSE).write_bytes(
            (ROOT / "licenses/wubi86-jidian.LICENSE").read_bytes()
        )
        (app / FINALIZER.RIME_KAOMOJI_LICENSE).write_bytes(
            (ROOT / "licenses/rime-kaomoji.LICENSE").read_bytes()
        )
        (app / FINALIZER.PYTHON_PINYIN_LICENSE).write_bytes(
            (ROOT / "licenses/python-pinyin.LICENSE").read_bytes()
        )

    def test_current_seed_licenses_pass_without_retired_runtime_files(self) -> None:
        paths = set(FINALIZER.REQUIRED_LICENSES)
        self.assertFalse(paths & RETIRED_LICENSES)
        self.assertIn(WUBI_LICENSE, paths)
        self.assertIn(FINALIZER.PYTHON_PINYIN_LICENSE, paths)
        self.assertEqual(FINALIZER.missing_required_license_entries(paths), set())
        with tempfile.TemporaryDirectory(prefix="owltype-licenses-") as temporary:
            app = Path(temporary) / "Owltype.app"
            self.materialize_licenses(app)
            FINALIZER.verify_required_licenses(app)

    def test_missing_wubi_license_fails(self) -> None:
        paths = set(FINALIZER.REQUIRED_LICENSES)
        paths.remove(WUBI_LICENSE)
        self.assertEqual(
            FINALIZER.missing_required_license_entries(paths),
            {WUBI_LICENSE},
        )
        with tempfile.TemporaryDirectory(prefix="owltype-licenses-") as temporary:
            app = Path(temporary) / "Owltype.app"
            self.materialize_licenses(app)
            (app / WUBI_LICENSE).unlink()
            with self.assertRaisesRegex(SystemExit, "missing license bundle entries.*wubi86"):
                FINALIZER.verify_required_licenses(app)

    def test_missing_or_changed_kaomoji_license_fails(self) -> None:
        for missing in (True, False):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory(prefix="owl-kaomoji-license-") as temporary:
                app = Path(temporary) / "Owltype.app"
                self.materialize_licenses(app)
                license_path = app / FINALIZER.RIME_KAOMOJI_LICENSE
                if missing:
                    license_path.unlink()
                    message = "missing license bundle entries.*rime-kaomoji"
                else:
                    license_path.write_text("MIT but missing original attribution")
                    message = "license differs from the pinned upstream text.*rime-kaomoji"
                with self.assertRaisesRegex(SystemExit, message):
                    FINALIZER.verify_required_licenses(app)


class ConsoleUserAccessTests(unittest.TestCase):
    def make_entry(self, path: Path, mode: int, content: bytes | None = None) -> None:
        if content is None:
            path.mkdir(parents=True, exist_ok=True)
        else:
            path.write_bytes(content)
        path.chmod(mode)

    def test_entries_other_users_cannot_read_fail_the_finalizer(self) -> None:
        with tempfile.TemporaryDirectory(prefix="owltype-modes-") as temporary:
            app = Path(temporary) / "Owltype.app"
            version = app / "Contents/Frameworks/Sparkle.framework/Versions/B"
            for directory in (app, app / "Contents", app / "Contents/Frameworks",
                              version.parent.parent, version.parent, version):
                self.make_entry(directory, 0o755)
            self.make_entry(app / "Contents/Info.plist", 0o644, b"plist\n")
            sparkle = version / "Sparkle"
            self.make_entry(sparkle, 0o755, b"\xcf\xfa\xed\xfe")
            link = version.parent.parent / "Sparkle"
            link.symlink_to("Versions/B/Sparkle")
            os.lchmod(link, 0o700)
            self.assertEqual(BUNDLE.unreadable_by_others(app), [])
            FINALIZER.verify_console_user_access(app)

            # 2.1.1's first PKG shipped these as 0700 after a umask 077 bootstrap.
            sparkle.chmod(0o700)
            self.make_entry(version / "Autoupdate", 0o744, b"\xcf\xfa\xed\xfe")
            self.make_entry(version / "Resources", 0o750)
            self.make_entry(app / "Contents/PkgInfo", 0o640, b"APPL????")
            self.assertEqual(
                BUNDLE.unreadable_by_others(app),
                [
                    "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate (0744)",
                    "Contents/Frameworks/Sparkle.framework/Versions/B/Resources (0750)",
                    "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle (0700)",
                    "Contents/PkgInfo (0640)",
                ],
            )
            with self.assertRaisesRegex(SystemExit, r"cannot read once installed root-owned: .*Sparkle \(0700\)"):
                FINALIZER.verify_console_user_access(app)


class ReleaseSBOMTests(unittest.TestCase):
    def test_sbom_names_only_current_components_and_contains_them(self) -> None:
        with tempfile.TemporaryDirectory(prefix="owltype-sbom-") as temporary:
            app = Path(temporary) / "Owltype.app"
            app.mkdir()
            sbom = BUNDLE.make_sbom(
                app,
                version="2.1.0",
                revision="0" * 40,
                created="2026-10-26T00:00:00Z",
            )

        packages = {package["SPDXID"]: package for package in sbom["packages"]}
        names = {package["name"] for package in packages.values()}
        self.assertTrue(
            {
                "OpenCC data",
                "rime-wubi86-jidian",
                "Owltype emoji and kaomoji catalog (msime-others.db)",
                "rime-ice emoji data",
                "Unicode Emoji, CLDR annotations, and Emoji 1.0 names",
                "python-pinyin emoji reading overrides",
                "rime_kaomoji_dict",
                "chinese-ime-lm model weights",
            }
            <= names
        )
        self.assertFalse({"librime", "librime-lua", "plum"} & names)
        by_name = {package["name"]: package for package in packages.values()}
        self.assertEqual(
            by_name["rime-wubi86-jidian"]["versionInfo"],
            "a194fb8b3ec41ef9dcf079d3a67876fa75f79135",
        )
        self.assertEqual(by_name["Metasequoia IME (msime)"]["versionInfo"],
                         "208c10e848bbed99373ca8b609fd2142b6b0b4e2")
        self.assertEqual(
            by_name["chinese-ime-lm model weights"]["versionInfo"],
            "model-v1",
        )
        self.assertEqual(
            by_name["Owltype emoji and kaomoji catalog (msime-others.db)"]["licenseConcluded"],
            "GPL-3.0-only AND Unicode-3.0 AND MIT",
        )
        self.assertEqual(
            by_name["rime-ice emoji data"]["versionInfo"],
            "9e66b0729083b37d217312294f6d516c8d7234be",
        )
        self.assertEqual(
            by_name["python-pinyin emoji reading overrides"]["versionInfo"],
            "v0.55.0",
        )
        self.assertNotIn("PiliApp symbol catalog", names)
        self.assertEqual(by_name["rime_kaomoji_dict"]["licenseConcluded"], "MIT")
        self.assertEqual(by_name["rime_kaomoji_dict"]["versionInfo"], "dict-v2.0.24-derived")
        self.assertIn("1675 rows", by_name["rime_kaomoji_dict"]["sourceInfo"])

        owltype_id = next(
            package_id
            for package_id, package in packages.items()
            if package["name"] == "Owltype"
        )
        non_owltype_ids = set(packages) - {owltype_id}
        contained_ids = {
            relationship["relatedSpdxElement"]
            for relationship in sbom["relationships"]
            if relationship["spdxElementId"] == owltype_id
            and relationship["relationshipType"] == "CONTAINS"
        }
        self.assertEqual(contained_ids, non_owltype_ids)
        self.assertFalse(
            any(
                relationship["relationshipType"] == "DEPENDS_ON"
                for relationship in sbom["relationships"]
            )
        )


if __name__ == "__main__":
    unittest.main()
