"""Rollback-capable publication shared by seed builders and official resource acquisition."""
import os
from pathlib import Path
import uuid


def temporary_path(path: Path, suffix: str) -> Path:
    return path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.{suffix}")



def publish_artifacts(artifacts: list[tuple[Path, Path]]) -> None:
    """Replace a set of files together, restoring every old file on failure."""
    backups: list[tuple[Path, Path]] = []
    installed: list[Path] = []
    try:
        for target, staged in artifacts:
            if target.exists():
                backup = temporary_path(target, "bak")
                target.replace(backup)
                backups.append((target, backup))
            staged.replace(target)
            installed.append(target)
    except Exception:
        for target in reversed(installed):
            target.unlink(missing_ok=True)
        for target, backup in reversed(backups):
            if backup.exists():
                backup.replace(target)
        for _, staged in artifacts:
            staged.unlink(missing_ok=True)
        raise
    else:
        for _, backup in backups:
            backup.unlink(missing_ok=True)

