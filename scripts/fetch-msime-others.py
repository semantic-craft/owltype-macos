#!/usr/bin/env python3
"""Build the deliverable emoji/kaomoji catalog from the pinned msime release artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
import stat
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "data/owl-rime/msime/msime-others.db"
SOURCE_URL = (
    "https://github.com/metasequoiaime/msime-dictionary/releases/download/"
    "dict-v2.0.24/msime-others.db"
)
SOURCE_SIZE = 1_314_816
SOURCE_SHA256 = "9f3cae5b407038e0e4536c40582a0bc0feb732657f0ae2d38196374cede52f94"
DATA_COMMIT = "71dc6f6cc7a451231ee29c0a39b39adbf2e04d32"
BUILDER_COMMIT = "128a332cabc5fa42b1cf5f827033ad5697ff528b"
EXPECTED_ROWS = {"emoji": 1_935, "emoji_pinyin": 21_541, "kaomoji": 1_675, "kaomoji_catalog": 1_400}
EXPECTED_ROW_HASHES = {
    "kaomoji": "31ecdb996b3d5dcd30d350d779651685fbc0d9d83578d846ac16c241b89b506f",
    "kaomoji_catalog": "149d3a2bea71d38cc5b4d853d5b889abac3c5deb1a098c518ffa42c63d36d15f",
    "emoji": "b3939c2005a8d46b18a5421eeee35698ba7b1ae01b3c24e6f470a524710905a7",
    "emoji_pinyin": "e761e06bb14331d27d48786fe6be4e998f289344e139e1252ce53f9090a4c306",
}
LICENSE_EXPRESSION = "GPL-3.0-only AND Unicode-3.0 AND MIT"
REQUIRED_NOTICE_HASHES = {
    "rime-kaomoji.LICENSE": "bc4f44c16c8a6ea28e30ac4e1e9a737e8711ba3140f241fea9c8404a86f3ffe1",
    "msime-others-NOTICE.txt": "b1ac4e7efbc3c97d44cd65ecfb43ef30042ce8c91bad57bbb1dc1b94ef4ba7a3",
}
TABLE_ORDER = {
    "kaomoji": ("pinyin", "jianpin", "kaomoji"),
    "kaomoji_catalog": ("kaomoji",),
    "emoji": ("emoji",),
    "emoji_pinyin": ("key", "emoji"),
}
TABLE_COLUMNS = {
    "kaomoji": ("pinyin", "jianpin", "kaomoji", "sort_order"),
    "kaomoji_catalog": ("kaomoji", "sort_order", "keywords"),
    "emoji": ("emoji", "category", "sort_order", "keywords", "pinyin"),
    "emoji_pinyin": ("key", "emoji", "sort_order"),
}
FORBIDDEN_TABLES = {"symbol_catalog"}
SCHEMA_SQL = (
    "CREATE TABLE kaomoji (pinyin TEXT NOT NULL, jianpin TEXT NOT NULL, kaomoji TEXT NOT NULL, sort_order INTEGER NOT NULL, PRIMARY KEY (pinyin, jianpin, kaomoji)) WITHOUT ROWID",
    "CREATE INDEX idx_kaomoji_jianpin ON kaomoji(jianpin)",
    "CREATE TABLE kaomoji_catalog (kaomoji TEXT PRIMARY KEY, sort_order INTEGER NOT NULL, keywords TEXT NOT NULL) WITHOUT ROWID",
    """
    CREATE TABLE emoji (
        emoji TEXT NOT NULL,
        category TEXT NOT NULL,
        sort_order INTEGER NOT NULL,
        keywords TEXT NOT NULL,
        pinyin TEXT NOT NULL,
        PRIMARY KEY (emoji)
    ) WITHOUT ROWID
    """,
    """
    CREATE TABLE emoji_pinyin (
        key TEXT NOT NULL,
        emoji TEXT NOT NULL,
        sort_order INTEGER NOT NULL,
        PRIMARY KEY (key, emoji)
    ) WITHOUT ROWID
    """,
    "CREATE INDEX idx_emoji_category_order ON emoji(category, sort_order)",
)
CHUNK_BYTES = 1 << 20


class Failure(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(CHUNK_BYTES), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_file(path: Path, expected_size: int, expected_sha: str) -> None:
    try:
        file_stat = path.lstat()
    except FileNotFoundError as error:
        raise Failure(f"missing resource: {path}") from error
    if not stat.S_ISREG(file_stat.st_mode) or path.is_symlink():
        raise Failure(f"resource is not a regular file: {path}")
    actual_sha = sha256(path)
    if file_stat.st_size != expected_size or actual_sha != expected_sha:
        raise Failure(
            f"resource mismatch: expected {expected_size} bytes at {expected_sha}, "
            f"got {file_stat.st_size} bytes at {actual_sha} ({path})"
        )


def table_row_hash(
    connection: sqlite3.Connection,
    table: str,
    columns: tuple[str, ...],
    order_by: tuple[str, ...],
) -> str:
    selected = ", ".join(f'"{column}"' for column in columns)
    ordering = ", ".join(f'"{column}"' for column in order_by)
    rows = connection.execute(
        f'SELECT {selected} FROM "{table}" ORDER BY {ordering}'
    )
    digest = hashlib.sha256()
    for row in rows:
        digest.update(
            json.dumps(row, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        )
        digest.update(b"\n")
    return digest.hexdigest()


def verify_database(
    path: Path,
    *,
    expected_rows: dict[str, int] = EXPECTED_ROWS,
    expected_hashes: dict[str, str] = EXPECTED_ROW_HASHES,
) -> None:
    if not path.is_file() or path.stat().st_size == 0:
        raise Failure(f"missing or empty SQLite resource: {path}")
    try:
        connection = sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True)
        try:
            check = connection.execute("PRAGMA quick_check").fetchone()
            if check != ("ok",):
                raise Failure(f"SQLite quick_check failed for {path}: {check!r}")
            tables = {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            }
            forbidden = sorted(tables & FORBIDDEN_TABLES)
            if forbidden:
                raise Failure(
                    f"{path.name} contains excluded tables: {', '.join(forbidden)}"
                )
            expected = set(expected_rows)
            if tables != expected:
                raise Failure(
                    f"{path.name} tables are {sorted(tables)}; expected {sorted(expected)}"
                )
            for table in expected:
                count = connection.execute(
                    f'SELECT COUNT(*) FROM "{table}"'
                ).fetchone()[0]
                if count != expected_rows[table]:
                    raise Failure(
                        f"{path.name} table {table} has {count} rows; "
                        f"expected {expected_rows[table]}"
                    )
                actual_hash = table_row_hash(
                    connection, table, TABLE_COLUMNS[table], TABLE_ORDER[table]
                )
                if actual_hash != expected_hashes[table]:
                    raise Failure(
                        f"{path.name} table {table} row hash is {actual_hash}; "
                        f"expected {expected_hashes[table]}"
                    )
        finally:
            connection.close()
    except sqlite3.Error as error:
        raise Failure(f"cannot read SQLite resource {path}: {error}") from error


def verify_distribution(shared_support: Path) -> None:
    """Use the same pinned four-table and notice contract at delivery time."""
    verify_database(shared_support / "msime/msime-others.db")
    for name, expected in REQUIRED_NOTICE_HASHES.items():
        path = shared_support / name
        if not path.is_file() or path.is_symlink() or sha256(path) != expected:
            raise Failure(f"missing or changed pinned others notice: {name}")


def read_source_tables(path: Path) -> dict[str, list[tuple[object, ...]]]:
    try:
        connection = sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True)
        try:
            tables = {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            }
            missing = sorted(set(EXPECTED_ROWS) - tables)
            if missing:
                raise Failure(
                    f"source artifact is missing tables: {', '.join(missing)}"
                )
            rows: dict[str, list[tuple[object, ...]]] = {}
            for table, columns in TABLE_COLUMNS.items():
                selected = ", ".join(f'"{column}"' for column in columns)
                ordering = ", ".join(f'"{column}"' for column in TABLE_ORDER[table])
                rows[table] = list(
                    connection.execute(
                        f'SELECT {selected} FROM "{table}" ORDER BY {ordering}'
                    )
                )
            return rows
        finally:
            connection.close()
    except sqlite3.Error as error:
        raise Failure(f"cannot read source artifact {path}: {error}") from error


def write_derived_database(
    source: Path,
    output: Path,
    *,
    expected_rows: dict[str, int] = EXPECTED_ROWS,
    expected_hashes: dict[str, str] = EXPECTED_ROW_HASHES,
) -> None:
    rows = read_source_tables(source)
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=output.parent, prefix=f".{output.name}.", suffix=".tmp"
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        connection = sqlite3.connect(temporary)
        try:
            for statement in SCHEMA_SQL:
                connection.execute(statement)
            for table, columns in TABLE_COLUMNS.items():
                placeholders = ", ".join("?" for _ in columns)
                connection.executemany(
                    f'INSERT INTO "{table}" VALUES ({placeholders})', rows[table]
                )
            connection.commit()
            connection.execute("VACUUM")
        finally:
            connection.close()
        verify_database(
            temporary,
            expected_rows=expected_rows,
            expected_hashes=expected_hashes,
        )
        os.chmod(temporary, 0o644)
        os.replace(temporary, output)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def download_source(directory: Path) -> Path:
    descriptor, temporary_name = tempfile.mkstemp(
        dir=directory, prefix=".msime-others-source.", suffix=".db"
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as staged:
            request = urllib.request.Request(
                SOURCE_URL, headers={"User-Agent": "owltype-msime-resource-fetch/1"}
            )
            with urllib.request.urlopen(request, timeout=60) as response:
                received = 0
                for chunk in iter(lambda: response.read(CHUNK_BYTES), b""):
                    received += len(chunk)
                    if received > SOURCE_SIZE:
                        raise Failure(
                            f"download exceeded pinned size {SOURCE_SIZE}: {SOURCE_URL}"
                        )
                    staged.write(chunk)
            staged.flush()
            os.fsync(staged.fileno())
        verify_file(temporary, SOURCE_SIZE, SOURCE_SHA256)
        return temporary
    except (OSError, urllib.error.URLError) as error:
        temporary.unlink(missing_ok=True)
        raise Failure(f"download failed from {SOURCE_URL}: {error}") from error
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def build_output(output: Path, force: bool) -> None:
    if not force:
        try:
            verify_database(output)
        except Failure:
            pass
        else:
            print(f"verified derived emoji/kaomoji catalog {output}")
            return

    output.parent.mkdir(parents=True, exist_ok=True)
    source = download_source(output.parent)
    try:
        write_derived_database(source, output)
    finally:
        source.unlink(missing_ok=True)
    print(f"installed derived emoji/kaomoji catalog {output}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Fetch the pinned msime artifact and retain only the emoji and "
            "emoji_pinyin, kaomoji and kaomoji_catalog tables in msime-others.db."
        )
    )
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--check", action="store_true", help="verify the existing output without downloading"
    )
    parser.add_argument(
        "--force", action="store_true", help="rebuild even when the output already matches"
    )
    arguments = parser.parse_args()
    try:
        if arguments.check:
            verify_database(arguments.output)
            print(f"verified derived emoji/kaomoji catalog {arguments.output}")
        else:
            build_output(arguments.output, arguments.force)
    except Failure as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    print(
        "source release dict-v2.0.24; "
        f"data commit {DATA_COMMIT}; builder commit {BUILDER_COMMIT}; "
        f"tables emoji, emoji_pinyin, kaomoji, kaomoji_catalog only; licensing {LICENSE_EXPRESSION}"
    )


if __name__ == "__main__":
    main()
