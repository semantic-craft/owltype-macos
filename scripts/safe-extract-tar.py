#!/usr/bin/env python3
"""Extract a regular-file tar archive without links or path traversal."""

from __future__ import annotations

import os
import shutil
import stat
import sys
import tarfile
from pathlib import Path, PurePosixPath


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def main() -> None:
    if len(sys.argv) != 3:
        fail(f"usage: {Path(sys.argv[0]).name} ARCHIVE DESTINATION")
    archive_path = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    destination.mkdir(parents=True, exist_ok=False)
    seen: set[str] = set()
    try:
        with tarfile.open(archive_path, "r:*") as archive:
            for member in archive.getmembers():
                relative = PurePosixPath(member.name)
                if relative.is_absolute() or not relative.parts or ".." in relative.parts:
                    fail("archive contains an unsafe path")
                normalized = relative.as_posix()
                if normalized in seen:
                    fail("archive contains a duplicate path")
                seen.add(normalized)
                target = destination.joinpath(*relative.parts)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    os.chmod(target, stat.S_IMODE(member.mode))
                    continue
                if not member.isfile():
                    fail("archive contains a link or unsupported member type")
                target.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    fail("archive member cannot be read")
                with target.open("wb") as output:
                    shutil.copyfileobj(source, output)
                os.chmod(target, stat.S_IMODE(member.mode))
    except (OSError, tarfile.TarError) as error:
        fail(f"cannot safely extract archive: {error}")


if __name__ == "__main__":
    main()
