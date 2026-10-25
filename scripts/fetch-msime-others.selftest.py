#!/usr/bin/env python3
"""Offline self-test for fetch-msime-others.py."""

from __future__ import annotations

import hashlib
import importlib.util
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FETCHER = ROOT / "scripts/fetch-msime-others.py"
SPEC = importlib.util.spec_from_file_location("fetch_msime_others", FETCHER)
assert SPEC is not None and SPEC.loader is not None
FETCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FETCH)


class FetchMsimeOthersTests(unittest.TestCase):
    def test_license_expression_covers_every_retained_source(self) -> None:
        self.assertEqual(
            FETCH.LICENSE_EXPRESSION,
            "GPL-3.0-only AND Unicode-3.0 AND MIT",
        )

    def test_verify_file_pins_length_and_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "artifact.db"
            path.write_bytes(b"pinned")
            digest = hashlib.sha256(b"pinned").hexdigest()
            FETCH.verify_file(path, len(b"pinned"), digest)
            with self.assertRaisesRegex(FETCH.Failure, "resource mismatch"):
                FETCH.verify_file(path, len(b"pinned") + 1, digest)
            with self.assertRaisesRegex(FETCH.Failure, "resource mismatch"):
                FETCH.verify_file(path, len(b"pinned"), "0" * 64)

    def make_source(self, directory: Path) -> Path:
        source = directory / "source.db"
        with closing(sqlite3.connect(source)) as connection, connection:
            for statement in FETCH.SCHEMA_SQL:
                connection.execute(statement)
            connection.execute(
                "CREATE TABLE kaomoji (pinyin TEXT, kaomoji TEXT)"
            )
            connection.execute(
                "CREATE TABLE kaomoji_catalog (kaomoji TEXT PRIMARY KEY)"
            )
            connection.execute(
                "CREATE TABLE symbol_catalog (symbol TEXT PRIMARY KEY)"
            )
            connection.executemany(
                "INSERT INTO emoji VALUES (?, ?, ?, ?, ?)",
                [
                    ("🍎", "Food", 0, "苹果", "pingguo"),
                    ("🙂", "Smileys", 1, "微笑", "weixiao"),
                ],
            )
            connection.executemany(
                "INSERT INTO emoji_pinyin VALUES (?, ?, ?)",
                [
                    ("ping", "🍎", 0),
                    ("pingguo", "🍎", 0),
                    ("wei", "🙂", 1),
                ],
            )
            connection.execute("INSERT INTO kaomoji VALUES ('hx', '(^_^)')")
            connection.execute("INSERT INTO kaomoji_catalog VALUES ('(^_^)')")
            connection.execute("INSERT INTO symbol_catalog VALUES ('→')")
        return source

    def expected_rows_and_hashes(
        self, source: Path
    ) -> tuple[dict[str, int], dict[str, str]]:
        with closing(sqlite3.connect(source)) as connection:
            counts = {
                table: connection.execute(
                    f'SELECT COUNT(*) FROM "{table}"'
                ).fetchone()[0]
                for table in FETCH.EXPECTED_ROWS
            }
            hashes = {
                table: FETCH.table_row_hash(
                    connection,
                    table,
                    FETCH.TABLE_COLUMNS[table],
                    FETCH.TABLE_ORDER[table],
                )
                for table in FETCH.EXPECTED_ROWS
            }
        return counts, hashes

    def test_derivation_drops_every_excluded_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(root)
            output = root / "msime-others.db"
            counts, hashes = self.expected_rows_and_hashes(source)
            FETCH.write_derived_database(
                source, output, expected_rows=counts, expected_hashes=hashes
            )
            FETCH.verify_database(
                output, expected_rows=counts, expected_hashes=hashes
            )
            with closing(sqlite3.connect(output)) as connection:
                tables = {
                    row[0]
                    for row in connection.execute(
                        "SELECT name FROM sqlite_master WHERE type='table'"
                    )
                }
            self.assertEqual(tables, {"emoji", "emoji_pinyin"})

    def test_verification_rejects_forbidden_or_missing_tables(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(root)
            counts, hashes = self.expected_rows_and_hashes(source)
            output = root / "msime-others.db"
            FETCH.write_derived_database(
                source, output, expected_rows=counts, expected_hashes=hashes
            )
            with closing(sqlite3.connect(output)) as connection, connection:
                connection.execute(
                    "CREATE TABLE symbol_catalog (symbol TEXT PRIMARY KEY)"
                )
            with self.assertRaisesRegex(FETCH.Failure, "excluded tables"):
                FETCH.verify_database(
                    output, expected_rows=counts, expected_hashes=hashes
                )
            with closing(sqlite3.connect(output)) as connection, connection:
                connection.execute("DROP TABLE symbol_catalog")
                connection.execute("DROP TABLE emoji_pinyin")
            with self.assertRaisesRegex(FETCH.Failure, "tables are"):
                FETCH.verify_database(
                    output, expected_rows=counts, expected_hashes=hashes
                )

    def test_verification_rejects_changed_rows(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(root)
            counts, hashes = self.expected_rows_and_hashes(source)
            output = root / "msime-others.db"
            FETCH.write_derived_database(
                source, output, expected_rows=counts, expected_hashes=hashes
            )
            with closing(sqlite3.connect(output)) as connection, connection:
                connection.execute(
                    "UPDATE emoji SET keywords = 'changed' WHERE emoji = '🍎'"
                )
            with self.assertRaisesRegex(FETCH.Failure, "row hash"):
                FETCH.verify_database(
                    output, expected_rows=counts, expected_hashes=hashes
                )


if __name__ == "__main__":
    unittest.main()
