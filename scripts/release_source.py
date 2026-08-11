#!/usr/bin/env python3
"""Deterministic corresponding-source and generated-seed snapshots."""

from __future__ import annotations

import hashlib
import io
import os
import stat
import subprocess
import sys
import tarfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


@dataclass(frozen=True)
class FileEntry:
    mode: int
    sha256: str
    data: bytes | None = None


class SourceSnapshotError(RuntimeError):
    pass


def _git(repo: Path, *arguments: str) -> bytes:
    try:
        return subprocess.check_output(["git", *arguments], cwd=repo)
    except (OSError, subprocess.CalledProcessError) as error:
        raise SourceSnapshotError(
            f"cannot read pinned Git source at {repo}: {' '.join(arguments)}"
        ) from error


def _safe_relative(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise SourceSnapshotError(f"unsafe Git archive path: {value!r}")
    return path


def _repo_snapshot(
    repo: Path,
    revision: str,
    prefix: PurePosixPath,
    entries: dict[str, FileEntry],
    submodules: dict[str, str],
) -> None:
    canonical_modes: dict[str, int] = {}
    gitlinks: list[tuple[PurePosixPath, str]] = []
    for record in _git(
        repo, "ls-tree", "-rz", "--full-tree", "-r", revision
    ).split(b"\0"):
        if not record:
            continue
        metadata, separator, raw_path = record.partition(b"\t")
        if not separator:
            raise SourceSnapshotError("Git tree entry has no path separator")
        fields = metadata.split()
        if len(fields) != 3:
            raise SourceSnapshotError("Git tree entry has invalid metadata")
        git_mode, entry_type, object_id = fields
        relative = _safe_relative(raw_path.decode("utf-8"))
        if entry_type == b"blob":
            if git_mode == b"100644":
                mode = 0o644
            elif git_mode == b"100755":
                mode = 0o755
            else:
                raise SourceSnapshotError(
                    f"unsupported tracked Git mode {git_mode.decode()}: {relative}"
                )
            canonical_modes[relative.as_posix()] = mode
        elif entry_type == b"commit" and git_mode == b"160000":
            gitlinks.append((relative, object_id.decode("ascii")))
        else:
            raise SourceSnapshotError(
                f"unsupported Git tree entry {entry_type.decode()}: {relative}"
            )

    archive_bytes = _git(repo, "archive", "--format=tar", revision)
    archived_paths: set[str] = set()
    try:
        with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:") as archive:
            for member in archive.getmembers():
                if member.isdir():
                    continue
                if not member.isfile():
                    raise SourceSnapshotError(
                        f"unsupported tracked source entry type: {member.name}"
                    )
                relative = _safe_relative(member.name)
                extracted = archive.extractfile(member)
                if extracted is None:
                    raise SourceSnapshotError(f"cannot read tracked source: {member.name}")
                data = extracted.read()
                local_path = relative.as_posix()
                try:
                    canonical_mode = canonical_modes[local_path]
                except KeyError as error:
                    raise SourceSnapshotError(
                        f"Git archive contains an unbound source path: {local_path}"
                    ) from error
                archived_paths.add(local_path)
                source_path = (prefix / relative).as_posix()
                if source_path in entries:
                    raise SourceSnapshotError(f"duplicate tracked source path: {source_path}")
                entries[source_path] = FileEntry(
                    mode=canonical_mode,
                    sha256=hashlib.sha256(data).hexdigest(),
                    data=data,
                )
    except tarfile.TarError as error:
        raise SourceSnapshotError(f"cannot inspect Git archive for {repo}") from error

    if archived_paths != set(canonical_modes):
        missing = sorted(set(canonical_modes) - archived_paths)
        raise SourceSnapshotError(
            f"Git archive omits tracked source paths: {', '.join(missing[:3])}"
        )

    for relative, submodule_revision in gitlinks:
        source_path = (prefix / relative).as_posix()
        child_repo = repo.joinpath(*relative.parts)
        if not child_repo.is_dir():
            raise SourceSnapshotError(f"pinned submodule is not initialized: {source_path}")
        _git(child_repo, "cat-file", "-e", f"{submodule_revision}^{{commit}}")
        if source_path in submodules:
            raise SourceSnapshotError(f"duplicate submodule path: {source_path}")
        submodules[source_path] = submodule_revision
        _repo_snapshot(
            child_repo,
            submodule_revision,
            prefix / relative,
            entries,
            submodules,
        )


def git_source_snapshot(
    repo: Path, revision: str
) -> tuple[dict[str, FileEntry], dict[str, str]]:
    entries: dict[str, FileEntry] = {}
    submodules: dict[str, str] = {}
    _repo_snapshot(repo.resolve(), revision, PurePosixPath(), entries, submodules)
    return entries, submodules


def file_tree_snapshot(root: Path) -> dict[str, FileEntry]:
    root = root.resolve()
    if not root.is_dir():
        raise SourceSnapshotError(f"source tree is missing: {root}")
    entries: dict[str, FileEntry] = {}
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        path_stat = path.lstat()
        if stat.S_ISDIR(path_stat.st_mode):
            continue
        relative = path.relative_to(root).as_posix()
        if not stat.S_ISREG(path_stat.st_mode):
            raise SourceSnapshotError(f"source tree contains unsupported entry: {relative}")
        data = path.read_bytes()
        entries[relative] = FileEntry(
            mode=stat.S_IMODE(path_stat.st_mode),
            sha256=hashlib.sha256(data).hexdigest(),
            data=data,
        )
    if not entries:
        raise SourceSnapshotError(f"source tree has no files: {root}")
    return entries


def tree_fingerprint(entries: dict[str, FileEntry]) -> str:
    digest = hashlib.sha256()
    for relative, entry in sorted(entries.items()):
        digest.update(b"F\0")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(f"{entry.mode:04o}".encode("ascii"))
        digest.update(b"\0")
        digest.update(entry.sha256.encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def stage_git_source(repo: Path, revision: str, destination: Path) -> None:
    if destination.exists():
        raise SourceSnapshotError(f"source staging destination already exists: {destination}")
    entries, _ = git_source_snapshot(repo, revision)
    destination.mkdir(parents=True)
    for relative, entry in sorted(entries.items()):
        if entry.data is None:
            raise AssertionError("Git snapshot unexpectedly omitted source data")
        target = destination.joinpath(*PurePosixPath(relative).parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(entry.data)
        os.chmod(target, entry.mode)


def main() -> None:
    if len(sys.argv) != 5 or sys.argv[1] != "stage":
        raise SystemExit(
            f"usage: {Path(sys.argv[0]).name} stage REPOSITORY REVISION DESTINATION"
        )
    try:
        stage_git_source(Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4]))
    except SourceSnapshotError as error:
        raise SystemExit(f"FAIL: {error}") from error


if __name__ == "__main__":
    main()
