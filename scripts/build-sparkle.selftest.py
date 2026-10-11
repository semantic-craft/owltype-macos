#!/usr/bin/env python3
"""Verify the real pinned patch also applies without repository metadata."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

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


if __name__ == "__main__":
    unittest.main()
