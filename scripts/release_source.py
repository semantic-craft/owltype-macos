#!/usr/bin/env python3
"""Deterministic corresponding-source and generated-seed snapshots."""

from __future__ import annotations

import hashlib
import gzip
import io
import os
import stat
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


@dataclass(frozen=True)
class FileEntry:
    mode: int
    sha256: str
    data: bytes | None = None


class SourceSnapshotError(RuntimeError):
    pass


ARCHIVE_UID = 0
ARCHIVE_GID = 0
ARCHIVE_OWNER = "root"
ARCHIVE_GROUP = "root"
ARCHIVE_MTIME = 0
ARCHIVE_GZIP_HEADER = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff"


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


def _archive_path_key(path: Path, root: Path) -> bytes:
    if path == root:
        return root.name.encode("utf-8")
    return f"{root.name}/{path.relative_to(root).as_posix()}".encode("utf-8")


def _canonical_archive_mode(path_stat: os.stat_result) -> int:
    if stat.S_ISDIR(path_stat.st_mode):
        return 0o755
    if stat.S_IMODE(path_stat.st_mode) & 0o111:
        return 0o755
    return 0o644


def _archive_info(name: str, path_stat: os.stat_result) -> tarfile.TarInfo:
    member = tarfile.TarInfo(name)
    member.uid = ARCHIVE_UID
    member.gid = ARCHIVE_GID
    member.uname = ARCHIVE_OWNER
    member.gname = ARCHIVE_GROUP
    member.mtime = ARCHIVE_MTIME
    member.mode = _canonical_archive_mode(path_stat)
    if stat.S_ISDIR(path_stat.st_mode):
        member.type = tarfile.DIRTYPE
        member.size = 0
    else:
        member.type = tarfile.REGTYPE
        member.size = path_stat.st_size
    return member


def write_deterministic_archive(source_root: Path, output: Path) -> None:
    source_root = source_root.absolute()
    try:
        root_stat = source_root.lstat()
    except OSError as error:
        raise SourceSnapshotError(f"cannot read source archive root: {error}") from error
    if not stat.S_ISDIR(root_stat.st_mode):
        raise SourceSnapshotError(f"source archive root is not a directory: {source_root}")
    if source_root.name in {"", ".", "..", ".git"}:
        raise SourceSnapshotError(f"unsafe source archive root: {source_root.name!r}")

    paths = [source_root, *source_root.rglob("*")]
    paths.sort(key=lambda path: _archive_path_key(path, source_root))
    inspected: list[tuple[Path, os.stat_result]] = []
    for path in paths:
        try:
            path_stat = path.lstat()
        except OSError as error:
            raise SourceSnapshotError(f"cannot inspect source archive path: {path}") from error
        relative_parts = path.relative_to(source_root).parts
        if ".git" in relative_parts:
            raise SourceSnapshotError("source archive contains forbidden .git metadata")
        if not (stat.S_ISDIR(path_stat.st_mode) or stat.S_ISREG(path_stat.st_mode)):
            raise SourceSnapshotError(
                f"source archive contains unsupported entry: {path.relative_to(source_root)}"
            )
        inspected.append((path, path_stat))

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            dir=output.parent, prefix=f".{output.name}.", delete=False
        ) as raw:
            temporary_name = raw.name
            with gzip.GzipFile(
                filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=ARCHIVE_MTIME
            ) as compressed:
                with tarfile.open(
                    fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT
                ) as archive:
                    for path, path_stat in inspected:
                        name = _archive_path_key(path, source_root).decode("utf-8")
                        member = _archive_info(name, path_stat)
                        if member.isfile():
                            with path.open("rb") as source:
                                archive.addfile(member, source)
                        else:
                            archive.addfile(member)
        os.replace(temporary_name, output)
        temporary_name = None
    except (OSError, tarfile.TarError, ValueError) as error:
        raise SourceSnapshotError(f"cannot write source archive: {error}") from error
    finally:
        if temporary_name is not None:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def validate_deterministic_archive_metadata(
    archive_path: Path, expected_root: str
) -> None:
    try:
        with archive_path.open("rb") as archive_file:
            header = archive_file.read(10)
    except OSError as error:
        raise SourceSnapshotError(f"cannot read source archive: {error}") from error
    if header != ARCHIVE_GZIP_HEADER:
        raise SourceSnapshotError("source archive has noncanonical gzip metadata")

    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            members = archive.getmembers()
    except (OSError, tarfile.TarError) as error:
        raise SourceSnapshotError(f"cannot inspect source archive: {error}") from error

    names = [member.name for member in members]
    if not names or names != sorted(names, key=lambda name: name.encode("utf-8")):
        raise SourceSnapshotError("source archive member ordering is not canonical")
    if len(names) != len(set(names)):
        raise SourceSnapshotError("source archive contains duplicate members")
    for index, member in enumerate(members):
        path = PurePosixPath(member.name)
        if (
            path.is_absolute()
            or not path.parts
            or path.parts[0] != expected_root
            or ".." in path.parts
        ):
            raise SourceSnapshotError("source archive contains an unsafe member path")
        if ".git" in path.parts:
            raise SourceSnapshotError("source archive contains forbidden .git metadata")
        if index == 0 and (member.name != expected_root or not member.isdir()):
            raise SourceSnapshotError("source archive root is not a directory")
        if not (member.isdir() or member.isfile()):
            raise SourceSnapshotError("source archive contains unsupported member type")
        if member.pax_headers:
            raise SourceSnapshotError("source archive has noncanonical extended metadata")
        if (
            member.uid != ARCHIVE_UID
            or member.gid != ARCHIVE_GID
            or member.uname != ARCHIVE_OWNER
            or member.gname != ARCHIVE_GROUP
        ):
            raise SourceSnapshotError("source archive has noncanonical ownership metadata")
        if member.mtime != ARCHIVE_MTIME:
            raise SourceSnapshotError("source archive has noncanonical timestamps")
        expected_mode = 0o755 if member.isdir() or member.mode & 0o111 else 0o644
        if member.mode != expected_mode:
            raise SourceSnapshotError("source archive has noncanonical file modes")


def main() -> None:
    try:
        if len(sys.argv) == 5 and sys.argv[1] == "stage":
            stage_git_source(Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4]))
        elif len(sys.argv) == 4 and sys.argv[1] == "archive":
            write_deterministic_archive(Path(sys.argv[2]), Path(sys.argv[3]))
        elif len(sys.argv) == 4 and sys.argv[1] == "check-archive-metadata":
            validate_deterministic_archive_metadata(Path(sys.argv[2]), sys.argv[3])
        else:
            raise SourceSnapshotError(
                "usage: release_source.py "
                "stage REPOSITORY REVISION DESTINATION | "
                "archive SOURCE_ROOT OUTPUT | "
                "check-archive-metadata ARCHIVE EXPECTED_ROOT"
            )
    except SourceSnapshotError as error:
        raise SystemExit(f"FAIL: {error}") from error


if __name__ == "__main__":
    main()
