#!/usr/bin/env python3
"""Focused regression test for deterministic corresponding-source archives."""

from __future__ import annotations

import gzip
import io
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SOURCE_TOOL = ROOT / "scripts/release_source.py"


class ReleaseSourceArchiveTests(unittest.TestCase):
    def run_tool(self, *arguments: str, umask: int = 0o022) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SOURCE_TOOL), *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            preexec_fn=lambda: os.umask(umask),
        )

    def test_archive_is_reproducible_and_metadata_gate_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="owl-source-archive-") as temporary:
            work = Path(temporary)
            source = work / "Owltype-macOS-9.9.9-source"
            (source / "bin").mkdir(parents=True)
            (source / "docs").mkdir()
            (source / "bin/tool").write_text("#!/bin/sh\nexit 0\n")
            (source / "docs/说明.txt").write_text("public source\n")
            os.chmod(source / "bin/tool", 0o700)
            os.chmod(source / "docs/说明.txt", 0o600)

            first = work / "first.tar.gz"
            second = work / "second.tar.gz"
            result = self.run_tool("archive", str(source), str(first), umask=0o077)
            self.assertEqual(result.returncode, 0, result.stderr)

            for path in [source, *source.rglob("*")]:
                os.utime(path, (1_900_000_000, 1_900_000_000))
            result = self.run_tool("archive", str(source), str(second), umask=0o002)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(first.read_bytes(), second.read_bytes())

            compressed = first.read_bytes()
            self.assertEqual(compressed[:10], b"\x1f\x8b\x08\0\0\0\0\0\x02\xff")
            with tarfile.open(first, "r:gz") as archive:
                members = archive.getmembers()
            names = [member.name for member in members]
            self.assertEqual(names, sorted(names, key=lambda name: name.encode("utf-8")))
            self.assertEqual(
                {member.name: member.mode for member in members},
                {
                    source.name: 0o755,
                    f"{source.name}/bin": 0o755,
                    f"{source.name}/bin/tool": 0o755,
                    f"{source.name}/docs": 0o755,
                    f"{source.name}/docs/说明.txt": 0o644,
                },
            )
            for member in members:
                self.assertEqual((member.uid, member.gid), (0, 0))
                self.assertEqual((member.uname, member.gname), ("root", "root"))
                self.assertEqual(member.mtime, 0)
                self.assertFalse(member.pax_headers)

            malformed = work / "malformed.tar.gz"
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as archive:
                member = tarfile.TarInfo(source.name)
                member.type = tarfile.DIRTYPE
                member.mode = 0o755
                member.uid = 501
                member.gid = 20
                member.uname = "local-user"
                member.gname = "staff"
                member.mtime = 0
                archive.addfile(member)
            with malformed.open("wb") as raw:
                with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped:
                    zipped.write(buffer.getvalue())
            result = self.run_tool(
                "check-archive-metadata", str(malformed), source.name
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("ownership metadata", result.stderr)


if __name__ == "__main__":
    unittest.main()
