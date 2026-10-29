#!/usr/bin/env python3
"""Offline regression for the Rust delivery gate."""

from __future__ import annotations

import importlib.util
import plistlib
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
CHECKER_PATH = ROOT / "scripts/check-rust-delivery.py"
SPEC = importlib.util.spec_from_file_location("check_rust_delivery", CHECKER_PATH)
CHECKER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(CHECKER)


VALID_SOURCE = """
#include <stddef.h>
#include <stdbool.h>
bool owl_msime_engine_finalize(void) { return true; }
void *owl_msime_session_create_with_generation(void) { return NULL; }
char *owl_msime_session_handle_action_json(void) { return NULL; }
void owl_msime_string_free(char *value) { (void)value; }
int main(void) { return 0; }
"""


class RustDeliveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="owl-rust-delivery-")
        self.root = Path(self.temporary.name)
        # Synthetic rows have literal independent hashes. Production never uses
        # these fixture overrides and verifies the pinned 1,935/21,541/1,675/1,400.
        self.rows_patch = patch.dict(CHECKER.OTHERS.EXPECTED_ROWS,
            {name: 1 for name in ("emoji", "emoji_pinyin", "kaomoji", "kaomoji_catalog")}, clear=True)
        self.hashes_patch = patch.dict(CHECKER.OTHERS.EXPECTED_ROW_HASHES, {
            "emoji": "95faaea3549f7c04ee182359916f77b52a5c9265f4af041bd699a0edb98a6679",
            "emoji_pinyin": "08e9d4c3cf7df90657adf5554a071f9ccd13360811c8707343df16478e6e2f30",
            "kaomoji": "9129a4113ceda0b06e681a15264a29eec49b440e278b3757d4f69171d262d0c9",
            "kaomoji_catalog": "19f71b9703e9454451454f7e3755f0cc46e561260a41d19d61a5a4f97fb4496b",
        }, clear=True)
        self.rows_patch.start(); self.hashes_patch.start()
        self.addCleanup(self.rows_patch.stop); self.addCleanup(self.hashes_patch.stop)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_app(self, name: str = "Owltype.app") -> Path:
        app = self.root / name
        (app / "Contents/MacOS").mkdir(parents=True)
        with (app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "fixture"}, handle)
        self.write_resources(app)
        self.write_helper(app)
        return app

    def write_helper(self, app: Path, version: str = "owltype-mcp 0.1.0 (bridge protocol 1)",
                     archs: tuple[str, ...] = ("arm64", "x86_64")) -> None:
        helper = app / CHECKER.MCP_HELPER
        helper.parent.mkdir(parents=True, exist_ok=True)
        # A file, not stdin: clang reads stdin once, for the first architecture only.
        source = self.root / "helper.c"
        source.write_text(f'#include <stdio.h>\nint main(void) {{ puts("{version}"); return 0; }}\n')
        subprocess.run(
            ["clang", *(flag for arch in archs for flag in ("-arch", arch)), str(source), "-o", str(helper)],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def write_resources(self, app: Path) -> None:
        resource_root = app / "Contents/SharedSupport/msime"
        resource_root.mkdir(parents=True)
        pinyin = resource_root / "msime-pinyin.db"
        with closing(sqlite3.connect(pinyin)) as connection, connection:
            connection.execute("CREATE TABLE tbl_1_n (key TEXT, value TEXT, weight INTEGER)")
            connection.execute("CREATE TABLE tbl_2_n (key TEXT, value TEXT, weight INTEGER)")
            connection.execute("CREATE TABLE quick_parases (key TEXT, value TEXT, weight INTEGER)")
            connection.execute("INSERT INTO tbl_1_n VALUES ('ni', '你', 1)")
            connection.execute("INSERT INTO tbl_2_n VALUES ('ni hao', '你好', 1)")
            connection.execute("INSERT INTO quick_parases VALUES ('ni', '你', 1)")
        with closing(sqlite3.connect(resource_root / "msime-wubi.db")) as connection, connection:
            for table in ("wubi86", "wubi98"):
                connection.execute(f"CREATE TABLE {table} (key TEXT, value TEXT, weight INTEGER)")
                connection.execute(f"INSERT INTO {table} VALUES ('a', '工', 20)")
        english = resource_root / "msime-english.db"
        with closing(sqlite3.connect(english)) as connection, connection:
            connection.execute("CREATE TABLE english_words (key TEXT, value TEXT, weight INTEGER)")
            connection.execute("INSERT INTO english_words VALUES ('hello', 'hello', 1)")
        others = resource_root / "msime-others.db"
        with closing(sqlite3.connect(others)) as connection, connection:
            for statement in CHECKER.OTHERS.SCHEMA_SQL:
                connection.execute(statement)
            connection.execute("INSERT INTO emoji VALUES ('🍎', 'Food', 0, '苹果', 'pingguo')")
            connection.execute("INSERT INTO emoji_pinyin VALUES ('ping', '🍎', 0)")
            connection.execute("INSERT INTO kaomoji VALUES ('haixiu', 'hx', '(^_^)', 0)")
            connection.execute("INSERT INTO kaomoji_catalog VALUES ('(^_^)', 0, '害羞')")
        shared = resource_root.parent
        shutil.copyfile(ROOT / 'licenses/rime-kaomoji.LICENSE', shared / 'rime-kaomoji.LICENSE')
        shutil.copyfile(ROOT / 'data/msime-others-NOTICE.txt', shared / 'msime-others-NOTICE.txt')

    def compile_fixture(self, app: Path, source: str, *linker_inputs: Path) -> None:
        subprocess.run(
            [
                "clang",
                "-x",
                "c",
                "-",
                "-x",
                "none",
                *map(str, linker_inputs),
                "-o",
                str(app / "Contents/MacOS/Owltype"),
            ],
            input=source,
            text=True,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_rejects_legacy_runtime_files(self) -> None:
        legacy_paths = (
            ("Contents/Frameworks/librime.1.dylib", "librime.1.dylib"),
            ("Contents/Frameworks/rime-plugins/librime-lua.dylib", "rime-plugins"),
            ("Contents/MacOS/rime-install", "rime-install"),
            ("Contents/MacOS/rime_deployer", "rime_deployer"),
            ("Contents/MacOS/rime_dict_manager", "rime_dict_manager"),
        )
        for index, (relative, rejected_name) in enumerate(legacy_paths):
            with self.subTest(relative=relative):
                app = self.make_app(f"Legacy{index}.app")
                legacy = app / relative
                legacy.parent.mkdir(parents=True, exist_ok=True)
                legacy.write_bytes(b"legacy")
                self.compile_fixture(app, VALID_SOURCE)
                with self.assertRaisesRegex(CHECKER.DeliveryError, rejected_name):
                    CHECKER.validate_app(app)

    def test_rejects_a_macho_that_depends_on_librime(self) -> None:
        app = self.make_app("Dependent.app")
        fake_rime = self.root / "librime.1.dylib"
        subprocess.run(
            [
                "clang",
                "-dynamiclib",
                "-x",
                "c",
                "-",
                "-install_name",
                "@rpath/librime.1.dylib",
                "-o",
                str(fake_rime),
            ],
            input="int fake_rime(void) { return 0; }\n",
            text=True,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.compile_fixture(
            app,
            "int fake_rime(void); int main(void) { return fake_rime(); }\n",
            fake_rime,
        )
        with self.assertRaisesRegex(CHECKER.DeliveryError, "librime.1.dylib"):
            CHECKER.validate_app(app)

    def test_rejects_a_missing_or_wrong_mcp_helper(self) -> None:
        app = self.make_app("NoHelper.app")
        self.compile_fixture(app, VALID_SOURCE)
        (app / CHECKER.MCP_HELPER).unlink()
        with self.assertRaisesRegex(CHECKER.DeliveryError, "MCP helper is missing"):
            CHECKER.validate_app(app)
        self.write_helper(app, archs=("arm64",))
        with self.assertRaisesRegex(CHECKER.DeliveryError, "x86_64"):
            CHECKER.validate_app(app)
        self.write_helper(app, version="something else")
        with self.assertRaisesRegex(CHECKER.DeliveryError, "not owltype-mcp"):
            CHECKER.validate_app(app)
        (app / CHECKER.MCP_HELPER).chmod(0o644)
        with self.assertRaisesRegex(CHECKER.DeliveryError, "not executable"):
            CHECKER.validate_app(app)

    def test_rejects_missing_rust_symbols(self) -> None:
        app = self.make_app("MissingSymbols.app")
        self.compile_fixture(app, "int main(void) { return 0; }\n")
        with self.assertRaisesRegex(CHECKER.DeliveryError, "Rust FFI symbols"):
            CHECKER.validate_app(app)

    def test_rejects_bad_resources(self) -> None:
        app = self.make_app("BadResources.app")
        self.compile_fixture(app, VALID_SOURCE)
        shutil.rmtree(app / "Contents/SharedSupport")
        (app / "Contents/SharedSupport/msime").mkdir(parents=True)
        (app / "Contents/SharedSupport/msime/msime-pinyin.db").write_text("not sqlite")
        (app / "Contents/SharedSupport/msime/msime-english.db").write_text("not sqlite")
        with self.assertRaisesRegex(CHECKER.DeliveryError, "SQLite"):
            CHECKER.validate_app(app)

    def test_rejects_missing_and_empty_resource_tables(self) -> None:
        app = self.make_app("IncompleteResources.app")
        self.compile_fixture(app, VALID_SOURCE)
        pinyin = app / "Contents/SharedSupport/msime/msime-pinyin.db"
        pinyin.unlink()
        with closing(sqlite3.connect(pinyin)) as connection, connection:
            connection.execute("CREATE TABLE tbl_1_n (key TEXT)")
            connection.execute("CREATE TABLE tbl_2_n (key TEXT)")
            connection.execute("CREATE TABLE wubi86 (key TEXT)")
            connection.execute("CREATE TABLE quick_parases (key TEXT)")
            connection.execute("INSERT INTO tbl_1_n VALUES ('ni')")
            connection.execute("INSERT INTO tbl_2_n VALUES ('ni hao')")
            connection.execute("INSERT INTO wubi86 VALUES ('wq')")
        with self.assertRaisesRegex(CHECKER.DeliveryError, "empty required table: quick_parases"):
            CHECKER.validate_app(app)
        with closing(sqlite3.connect(pinyin)) as connection, connection:
            connection.execute("INSERT INTO quick_parases VALUES ('ni')")
            connection.execute("DROP TABLE tbl_2_n")
        with self.assertRaisesRegex(CHECKER.DeliveryError, "missing required tables: tbl_2_n"):
            CHECKER.validate_app(app)

    def test_accepts_rust_symbols_and_complete_resources(self) -> None:
        app = self.make_app("Valid.app")
        self.compile_fixture(app, VALID_SOURCE)
        result = CHECKER.validate_app(app)
        self.assertEqual(result, (2, 4))  # the App binary and the MCP helper

    def test_rejects_forbidden_msime_others_catalogs(self) -> None:
        app = self.make_app("ForbiddenOthers.app")
        self.compile_fixture(app, VALID_SOURCE)
        others = app / "Contents/SharedSupport/msime/msime-others.db"
        with closing(sqlite3.connect(others)) as connection, connection:
            connection.execute("CREATE TABLE symbol_catalog (symbol TEXT PRIMARY KEY)")
        with self.assertRaisesRegex(CHECKER.DeliveryError, "forbidden tables: symbol_catalog"):
            CHECKER.validate_app(app)

    def test_rejects_changed_kaomoji_rows_even_with_same_count(self) -> None:
        for table, column in [('kaomoji', 'kaomoji'), ('kaomoji_catalog', 'keywords')]:
            with self.subTest(table=table):
                app = self.make_app(f"Changed{table}.app")
                with closing(sqlite3.connect(app / "Contents/SharedSupport/msime/msime-others.db")) as db, db:
                    db.execute(f"UPDATE {table} SET {column} = 'tampered'")
                with self.assertRaisesRegex(CHECKER.DeliveryError, "row hash"):
                    CHECKER.verify_resources(app)

    def test_rejects_missing_empty_or_extra_kaomoji_rows(self) -> None:
        for operation, expected in [
            ("DROP TABLE kaomoji_catalog", "missing required tables"),
            ("DELETE FROM kaomoji", "empty required table"),
            ("INSERT INTO kaomoji VALUES ('a', 'a', 'x', 1)", "has 2 rows")]:
            with self.subTest(operation=operation):
                app = self.make_app(f"BadRows{len(list(self.root.iterdir()))}.app")
                with closing(sqlite3.connect(app / "Contents/SharedSupport/msime/msime-others.db")) as db, db:
                    db.execute(operation)
                with self.assertRaisesRegex(CHECKER.DeliveryError, expected):
                    CHECKER.verify_resources(app)

    def test_rejects_missing_or_changed_kaomoji_license_and_source_notice(self) -> None:
        for name in ('rime-kaomoji.LICENSE', 'msime-others-NOTICE.txt'):
            for missing in (True, False):
                with self.subTest(name=name, missing=missing):
                    app = self.make_app(f"Notice{len(list(self.root.iterdir()))}.app")
                    path = app / 'Contents/SharedSupport' / name
                    if missing:
                        path.unlink()
                    else:
                        path.write_text('changed')
                    with self.assertRaisesRegex(CHECKER.DeliveryError, 'pinned others notice'):
                        CHECKER.verify_resources(app)

    def test_rejects_unknown_msime_others_tables(self) -> None:
        app = self.make_app("UnknownOthers.app")
        self.compile_fixture(app, VALID_SOURCE)
        others = app / "Contents/SharedSupport/msime/msime-others.db"
        with closing(sqlite3.connect(others)) as connection, connection:
            connection.execute("CREATE TABLE unexpected_catalog (symbol TEXT PRIMARY KEY)")
        with self.assertRaisesRegex(
            CHECKER.DeliveryError,
            "unexpected tables: unexpected_catalog",
        ):
            CHECKER.validate_app(app)

    def test_rejects_missing_msime_others_emoji_table(self) -> None:
        app = self.make_app("IncompleteOthers.app")
        self.compile_fixture(app, VALID_SOURCE)
        others = app / "Contents/SharedSupport/msime/msime-others.db"
        with closing(sqlite3.connect(others)) as connection, connection:
            connection.execute("DROP TABLE emoji_pinyin")
        with self.assertRaisesRegex(CHECKER.DeliveryError, "emoji_pinyin"):
            CHECKER.validate_app(app)


if __name__ == "__main__":
    unittest.main()
