#!/usr/bin/env python3
"""Verify that an Owltype App delivers the Rust engine, not legacy Rime runtime files."""

from __future__ import annotations

import argparse
import os
import sqlite3
import subprocess
import sys
from pathlib import Path


LEGACY_EXECUTABLES = {"rime-install", "rime_deployer", "rime_dict_manager"}
MACHO_MAGICS = {
    b"\xca\xfe\xba\xbe",
    b"\xca\xfe\xba\xbf",
    b"\xbe\xba\xfe\xca",
    b"\xbf\xba\xfe\xca",
    b"\xce\xfa\xed\xfe",
    b"\xcf\xfa\xed\xfe",
    b"\xfe\xed\xfa\xce",
    b"\xfe\xed\xfa\xcf",
}
REQUIRED_RUST_SYMBOLS = {
    "owl_msime_engine_finalize",
    "owl_msime_session_create_with_generation",
    "owl_msime_session_handle_action_json",
    "owl_msime_string_free",
}
REQUIRED_RESOURCES = {
    "msime-pinyin.db": {"tbl_1_n", "tbl_2_n", "wubi86", "quick_parases"},
    "msime-english.db": {"english_words"},
}


class DeliveryError(RuntimeError):
    pass


def display_path(path: Path, app: Path) -> str:
    try:
        return path.relative_to(app).as_posix()
    except ValueError:
        return str(path)


def is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(4) in MACHO_MAGICS
    except OSError:
        return False


def is_legacy_name(path: Path) -> bool:
    name = path.name
    return (
        "rime-plugins" in path.parts
        or name in LEGACY_EXECUTABLES
        or (name.startswith("librime") and name.endswith(".dylib"))
    )


def verify_no_legacy_files(app: Path) -> None:
    legacy: list[str] = []
    for root, directories, files in os.walk(app, followlinks=False):
        root_path = Path(root)
        for directory in directories:
            candidate = root_path / directory
            if is_legacy_name(candidate):
                legacy.append(display_path(candidate, app) + "/")
        for filename in files:
            candidate = root_path / filename
            if is_legacy_name(candidate):
                legacy.append(display_path(candidate, app))
    if legacy:
        raise DeliveryError(
            "legacy Rime runtime files remain: " + ", ".join(sorted(set(legacy)))
        )


def macho_files(app: Path) -> list[Path]:
    result: list[Path] = []
    for root, _, files in os.walk(app, followlinks=False):
        for filename in files:
            path = Path(root) / filename
            if path.is_file() and is_macho(path):
                result.append(path)
    return sorted(result)


def verify_no_legacy_dependencies(app: Path, binaries: list[Path]) -> None:
    failures: list[str] = []
    for binary in binaries:
        result = subprocess.run(
            ["otool", "-L", str(binary)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise DeliveryError(
                f"cannot inspect Mach-O dependencies for {display_path(binary, app)}: "
                f"{result.stderr.strip()}"
            )
        for line in result.stdout.splitlines()[1:]:
            dependency = line.strip().split(" (compatibility", 1)[0]
            if not dependency:
                continue
            name = Path(dependency).name
            if (
                "/rime-plugins/" in dependency
                or name in LEGACY_EXECUTABLES
                or (name.startswith("librime") and name.endswith(".dylib"))
            ):
                failures.append(
                    f"{display_path(binary, app)} -> {dependency}"
                )
    if failures:
        raise DeliveryError(
            "legacy Rime dynamic dependencies remain: " + ", ".join(sorted(failures))
        )


def defined_symbols(binary: Path) -> set[str]:
    result = subprocess.run(
        ["nm", "-gU", str(binary)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise DeliveryError(f"cannot inspect symbols in {binary}: {result.stderr.strip()}")
    symbols: set[str] = set()
    for line in result.stdout.splitlines():
        fields = line.split()
        if fields:
            symbols.add(fields[-1].removeprefix("_"))
    return symbols


def verify_rust_symbols(binaries: list[Path]) -> None:
    found: set[str] = set()
    for binary in binaries:
        found.update(defined_symbols(binary))
    missing = sorted(REQUIRED_RUST_SYMBOLS - found)
    if missing:
        raise DeliveryError(
            "Rust FFI symbols are missing from the App: " + ", ".join(missing)
        )


def verify_database(path: Path, tables: set[str]) -> None:
    if not path.is_file() or path.stat().st_size == 0:
        raise DeliveryError(f"Rust resource is missing or empty: {path}")
    try:
        connection = sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True)
        try:
            check = connection.execute("PRAGMA quick_check").fetchone()
            if check != ("ok",):
                raise DeliveryError(f"SQLite quick_check failed for {path}: {check!r}")
            present = {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            }
            missing = sorted(tables - present)
            if missing:
                raise DeliveryError(
                    f"{path.name} is missing required tables: {', '.join(missing)}"
                )
            for table in sorted(tables):
                if connection.execute(f'SELECT 1 FROM "{table}" LIMIT 1').fetchone() is None:
                    raise DeliveryError(f"{path.name} has an empty required table: {table}")
        finally:
            connection.close()
    except sqlite3.Error as error:
        raise DeliveryError(f"cannot read SQLite resource {path}: {error}") from error


def verify_resources(app: Path) -> None:
    resource_root = app / "Contents/SharedSupport/msime"
    for filename, tables in REQUIRED_RESOURCES.items():
        verify_database(resource_root / filename, tables)


def validate_app(app: Path) -> tuple[int, int]:
    app = app.resolve()
    if not (app / "Contents/Info.plist").is_file():
        raise DeliveryError(f"not an Owltype App bundle: {app}")
    verify_no_legacy_files(app)
    binaries = macho_files(app)
    if not binaries:
        raise DeliveryError("App contains no Mach-O files")
    verify_no_legacy_dependencies(app, binaries)
    verify_rust_symbols(binaries)
    verify_resources(app)
    return len(binaries), len(REQUIRED_RESOURCES)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Verify Rust delivery and the absence of legacy Rime runtime files."
    )
    parser.add_argument("app", type=Path, help="path to Owltype.app")
    arguments = parser.parse_args()
    try:
        binary_count, resource_count = validate_app(arguments.app)
    except DeliveryError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    print("PASS: no legacy Rime runtime files or dynamic dependencies")
    print("PASS: required Rust FFI symbols are linked into the App")
    print(f"PASS: {resource_count} Rust SQLite resources are complete")
    print(f"PASS: Rust delivery verified across {binary_count} Mach-O files")


if __name__ == "__main__":
    main()
