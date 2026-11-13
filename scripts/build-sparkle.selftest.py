#!/usr/bin/env python3
"""Verify the real pinned patch also applies without repository metadata."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("build_sparkle", ROOT / "scripts/build-sparkle.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class SourceArchiveTests(unittest.TestCase):
    def test_gitless_source_and_modified_source(self):
        with tempfile.TemporaryDirectory(prefix="owl-sparkle-source-") as directory:
            work = Path(directory)
            upstream = work / "Sparkle"
            upstream.mkdir()
            archive = subprocess.check_output(["git", "-C", str(ROOT / "Sparkle"), "archive", builder.REVISION])
            subprocess.run(["tar", "-xf", "-", "-C", str(upstream)], input=archive, check=True)
            self.assertFalse((upstream / ".git").exists())
            source = work / "prepared"
            source.mkdir()
            builder.prepare_source(upstream, source)
            controller = "Sparkle/InstallerProgress/InstallerProgressAppController.m"
            self.assertIn("openApplicationAtURL", (source / controller).read_text())
            self.assertNotIn("openApplicationAtURL", (upstream / controller).read_text())
            with (upstream / controller).open("a") as handle:
                handle.write("\n// unrecorded modification\n")
            with self.assertRaisesRegex(ValueError, "differs from the pinned"):
                builder.prepare_source(upstream, work / "modified")


class BuildPermissionTests(unittest.TestCase):
    def test_build_other_users_cannot_read_is_not_current(self):
        with tempfile.TemporaryDirectory(prefix="owl-sparkle-modes-") as directory:
            framework = Path(directory) / "Sparkle.framework"
            binary = framework / "Versions/B/Sparkle"
            updater = framework / builder.UPDATER
            updater.parent.mkdir(parents=True)
            (framework / builder.RECEIPT).parent.mkdir(parents=True)
            binary.write_bytes(b"\xcf\xfa\xed\xfe")
            updater.write_bytes(b"openApplicationAtURL:configuration:completionHandler:")
            updater_uuids = {"arm64": "UUID-ARM64"}
            (framework / builder.RECEIPT).write_text(json.dumps({**builder.identity(), "updaterUUIDs": updater_uuids}))
            for path in [framework, *framework.rglob("*")]:
                path.chmod(0o755 if path.is_dir() or path in (binary, updater) else 0o644)
            with mock.patch.object(builder, "uuids", return_value=updater_uuids):
                builder.verify(framework)
                # A umask 077 bootstrap built this; build() catches the ValueError and rebuilds.
                binary.chmod(0o700)
                with self.assertRaisesRegex(ValueError, r"other users cannot read.*Versions/B/Sparkle \(0700\)"):
                    builder.verify(framework)


if __name__ == "__main__":
    unittest.main()
