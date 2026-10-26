#!/usr/bin/env python3
"""Compare the bundled seed SQLite resource with a generated full resource.

The report is intentionally based on the databases the Rust engine reads. It
does not infer behavior from the source YAML.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

DEFAULT_INPUTS = {
    "pinyin": [
        ("nihao", "ni hao"),
        ("zhongguo", "zhong guo"),
        ("shijie", "shi jie"),
        ("gongzuo", "gong zuo"),
    ],
    "wubi": [("wqiy", "wqiy"), ("wqvb", "wqvb"), ("aaaa", "aaaa"), ("ifcy", "ifcy")],
}


def pinyin_table(code: str) -> str | None:
    syllables = code.lower().split()
    if not syllables or not all(token.isascii() and token.isalpha() for token in syllables):
        return None
    initial = syllables[0][0]
    if initial not in "abcdefghjklmnopqrstwxyz":
        return None
    bucket = str(len(syllables)) if 1 <= len(syllables) <= 7 else "others"
    return f"tbl_{bucket}_{initial}"


def read_pinyin(db: Path) -> dict[tuple[str, str, str], int]:
    result: dict[tuple[str, str, str], int] = {}
    with sqlite3.connect(db) as conn:
        tables = [
            row[0]
            for row in conn.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name LIKE 'tbl_%' ORDER BY name"
            )
        ]
        for table in tables:
            for key, value, weight in conn.execute(
                f'SELECT "key", "value", "weight" FROM "{table}"'
            ):
                result[(table, key, value)] = int(weight or 0)
    return result


def wubi_database(db: Path) -> Path:
    split = db.with_name("msime-wubi.db")
    return split if db.name == "msime-pinyin.db" and split.is_file() else db


def read_wubi(db: Path) -> dict[str, list[tuple[str, int, int]]]:
    db = wubi_database(db)
    grouped: dict[str, list[tuple[str, int, int]]] = defaultdict(list)
    with sqlite3.connect(db) as conn:
        exists = conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='wubi86'"
        ).fetchone()
        if not exists:
            return grouped
        for key, value, weight, rowid in conn.execute(
            'SELECT "key", "value", "weight", rowid FROM "wubi86"'
        ):
            grouped[key].append((value, int(weight or 0), int(rowid)))
    for key in grouped:
        # The provider groups one key at a time, so its key ASC tie-break is a
        # no-op here; preserve the weight and rowid ordering users see.
        grouped[key].sort(key=lambda row: (-row[1], row[2]))
    return grouped


def query_pinyin(db: Path, code: str, page_size: int) -> list[dict[str, object]]:
    table = pinyin_table(code)
    if table is None:
        return []
    key = "'".join(code.lower().split())
    with sqlite3.connect(db) as conn:
        exists = conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
        ).fetchone()
        if not exists:
            return []
        rows = conn.execute(
            f'SELECT "value", "weight" FROM "{table}" '
            'WHERE "key"=? ORDER BY "weight" DESC, "value" LIMIT ?',
            (key, page_size),
        )
        return [{"text": value, "weight": int(weight or 0)} for value, weight in rows]


def query_wubi(db: Path, code: str, page_size: int) -> list[dict[str, object]]:
    db = wubi_database(db)
    with sqlite3.connect(db) as conn:
        exists = conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='wubi86'"
        ).fetchone()
        if not exists:
            return []
        key = code.lower()
        rows = conn.execute(
            'SELECT "value", "weight" FROM "wubi86" WHERE "key" LIKE ? '
            'ORDER BY ("key" = ?) DESC, "weight" DESC, "key" ASC, rowid ASC '
            "LIMIT ?",
            (key + "%", key, page_size),
        )
        return [{"text": value, "weight": int(weight or 0)} for value, weight in rows]


def write_tsv(path: Path, header: list[str], rows: list[list[object]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as output:
        output.write("\t".join(header) + "\n")
        for row in rows:
            output.write("\t".join(str(value) for value in row) + "\n")


def build_report(
    seed_db: Path,
    full_db: Path,
    output: Path,
    wubi_baseline_db: Path | None = None,
) -> dict[str, object]:
    output.mkdir(parents=True, exist_ok=True)
    seed_pinyin = read_pinyin(seed_db)
    full_pinyin = read_pinyin(full_db)
    wubi_baseline_db = wubi_baseline_db or seed_db
    wubi_baseline = read_wubi(wubi_baseline_db)
    full_wubi = read_wubi(full_db)
    if not wubi_baseline:
        raise ValueError(
            "Wubi baseline has no rows; pass --wubi-baseline-db with a core "
            "Wubi database so collision and four-code uniqueness results are meaningful"
        )

    missing = sorted(set(seed_pinyin) - set(full_pinyin))
    weight_changes = sorted(
        (
            table,
            key,
            value,
            seed_pinyin[(table, key, value)],
            weight,
        )
        for (table, key, value), weight in full_pinyin.items()
        if (table, key, value) in seed_pinyin
        and seed_pinyin[(table, key, value)] != weight
    )

    new_codes: list[tuple[str, int, int, str]] = []
    existing_code_collisions: list[tuple[str, int, int, str]] = []
    for key, full_rows in full_wubi.items():
        baseline_rows = wubi_baseline.get(key, [])
        if len(full_rows) > 1 and len(full_rows) > len(baseline_rows):
            destination = new_codes if not baseline_rows else existing_code_collisions
            destination.append(
                (
                    key,
                    len(baseline_rows),
                    len(full_rows),
                    " / ".join(row[0] for row in full_rows),
                )
            )
    new_codes.sort()
    existing_code_collisions.sort()
    new_collisions = [
        (key, baseline_count, full_count, candidates, "distinct-new-code")
        for key, baseline_count, full_count, candidates in new_codes
    ] + [
        (key, baseline_count, full_count, candidates, "existing-code-new-collision")
        for key, baseline_count, full_count, candidates in existing_code_collisions
    ]
    new_collisions.sort()

    lost_four_code_unique: list[tuple[str, str, int, str]] = []
    for key, baseline_rows in wubi_baseline.items():
        if len(key) != 4 or len(baseline_rows) != 1:
            continue
        full_rows = full_wubi.get(key, [])
        if len(full_rows) > 1:
            lost_four_code_unique.append(
                (
                    key,
                    baseline_rows[0][0],
                    len(full_rows),
                    " / ".join(row[0] for row in full_rows),
                )
            )
    lost_four_code_unique.sort()

    actual: dict[str, object] = {}
    for mode, cases in DEFAULT_INPUTS.items():
        entries = []
        for display, normalized in cases:
            seed_query = query_pinyin if mode == "pinyin" else query_wubi
            full_query = seed_query
            entries.append(
                {
                    "input": display,
                    "normalized": normalized,
                    "baseline": seed_query(
                        wubi_baseline_db if mode == "wubi" else seed_db,
                        normalized,
                        9,
                    ),
                    "full": full_query(full_db, normalized, 9),
                }
            )
        actual[mode] = entries

    write_tsv(
        output / "missing-seed-entries.tsv",
        ["table", "key", "value"],
        [list(row) for row in missing],
    )
    write_tsv(
        output / "weight-changes.tsv",
        ["table", "key", "value", "seed_weight", "full_weight"],
        [list(row) for row in weight_changes],
    )
    write_tsv(
        output / "wubi-new-collisions.tsv",
        ["code", "baseline_values", "full_values", "full_candidates", "classification"],
        [list(row) for row in new_collisions],
    )
    write_tsv(
        output / "wubi-new-codes.tsv",
        ["code", "baseline_values", "full_values", "full_candidates"],
        [list(row) for row in new_codes],
    )
    write_tsv(
        output / "wubi-existing-code-new-collisions.tsv",
        ["code", "baseline_values", "full_values", "full_candidates"],
        [list(row) for row in existing_code_collisions],
    )
    write_tsv(
        output / "wubi-lost-four-code-unique.tsv",
        ["code", "baseline_single_value", "full_values", "full_candidates"],
        [list(row) for row in lost_four_code_unique],
    )

    summary: dict[str, object] = {
        "schemaVersion": 2,
        "seedDatabase": str(seed_db),
        "fullDatabase": str(full_db),
        "wubiBaselineDatabase": str(wubi_baseline_db),
        "wubiBaselineMode": (
            "explicit" if wubi_baseline_db != seed_db else "seed"
        ),
        "counts": {
            "seedPinyinRows": len(seed_pinyin),
            "fullPinyinRows": len(full_pinyin),
            "missingSeedEntries": len(missing),
            "weightChanges": len(weight_changes),
            "wubiBaselineRows": sum(len(rows) for rows in wubi_baseline.values()),
            "fullWubiRows": sum(len(rows) for rows in full_wubi.values()),
            "wubiNewCollisions": len(new_collisions),
            "wubiDistinctNewCodes": len(new_codes),
            "wubiExistingCodeNewCollisions": len(existing_code_collisions),
            "wubiLostFourCodeUnique": len(lost_four_code_unique),
        },
        "samples": {
            "missingSeedEntries": [list(row) for row in missing[:100]],
            "weightChanges": [list(row) for row in weight_changes[:100]],
            "wubiNewCollisions": [list(row) for row in new_collisions[:100]],
            "wubiDistinctNewCodes": [list(row) for row in new_codes[:100]],
            "wubiExistingCodeNewCollisions": [
                list(row) for row in existing_code_collisions[:100]
            ],
            "wubiLostFourCodeUnique": [
                list(row) for row in lost_four_code_unique[:100]
            ],
        },
        "actualInputs": actual,
        "actualInputCoverage": (
            "Built-in acceptance inputs, not a private host history. "
            "The installed-host acceptance still needs to replay real typing."
        ),
    }
    (output / "report.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return summary


def selftest() -> int:
    with tempfile.TemporaryDirectory(prefix="owl-rust-resource-report-") as temporary:
        root = Path(temporary)
        seed = root / "seed.db"
        full = root / "full.db"
        baseline = root / "wubi-core.db"
        output = root / "report"

        with sqlite3.connect(baseline) as conn:
            conn.execute(
                'CREATE TABLE wubi86 ("key" TEXT, "value" TEXT, "weight" INTEGER)'
            )
            conn.execute(
                'INSERT INTO wubi86 VALUES ("bbbb", "baseline", 10)'
            )
        with sqlite3.connect(seed) as conn:
            conn.execute("CREATE TABLE tbl_2_a (\"key\" TEXT, \"value\" TEXT, \"weight\" INTEGER)")
        with sqlite3.connect(full) as conn:
            conn.execute(
                'CREATE TABLE wubi86 ("key" TEXT, "value" TEXT, "weight" INTEGER)'
            )
            conn.executemany(
                'INSERT INTO wubi86 VALUES (?, ?, ?)',
                [
                    ("aaaa", "new-b", 5),
                    ("aaaa", "new-a", 6),
                    ("bbbb", "baseline", 10),
                    ("bbbb", "collision", 9),
                ],
            )

        split_root = root / "split"
        split_root.mkdir()
        split_main = split_root / "msime-pinyin.db"
        split_wubi = split_root / "msime-wubi.db"
        with sqlite3.connect(split_main) as conn:
            conn.execute("CREATE TABLE pinyin (value TEXT)")
        with sqlite3.connect(split_wubi) as conn:
            conn.execute('CREATE TABLE wubi86 ("key" TEXT, "value" TEXT, "weight" INTEGER)')
            conn.execute("INSERT INTO wubi86 VALUES ('go', '来', 10)")
        assert query_wubi(split_main, "go", 5) == [{"text":"来", "weight":10}]
        assert read_wubi(split_main)["go"][0][0] == "来"

        summary = build_report(seed, full, output, baseline)
        counts = summary["counts"]
        assert counts["wubiDistinctNewCodes"] == 1
        assert counts["wubiExistingCodeNewCollisions"] == 1
        assert counts["wubiNewCollisions"] == 2
        assert (
            counts["wubiNewCollisions"]
            == counts["wubiDistinctNewCodes"]
            + counts["wubiExistingCodeNewCollisions"]
        )
        assert len((output / "wubi-new-codes.tsv").read_text().splitlines()) == 2
        assert len(
            (output / "wubi-existing-code-new-collisions.tsv").read_text().splitlines()
        ) == 2
        classifications = {
            line.split("\t")[-1]
            for line in (output / "wubi-new-collisions.tsv").read_text().splitlines()[1:]
        }
        assert classifications == {
            "distinct-new-code",
            "existing-code-new-collision",
        }

        # Historical tie: the real imported database has 西蓝花 before 横巷 at
        # the same weight, so the provider's rowid tie-break must be visible.
        tie_baseline = root / "tie-baseline.db"
        tie_full = root / "tie-full.db"
        tie_output = root / "tie-report"
        with sqlite3.connect(tie_baseline) as conn:
            conn.execute(
                'CREATE TABLE wubi86 ("key" TEXT, "value" TEXT, "weight" INTEGER)'
            )
            conn.execute(
                'INSERT INTO wubi86 VALUES ("saaw", "横巷", 10)'
            )
        with sqlite3.connect(tie_full) as conn:
            conn.execute(
                'CREATE TABLE wubi86 ("key" TEXT, "value" TEXT, "weight" INTEGER)'
            )
            conn.executemany(
                'INSERT INTO wubi86 VALUES (?, ?, ?)',
                [
                    ("saaw", "西蓝花", 10),
                    ("saaw", "横巷", 10),
                    ("saaws", "高权补全", 100),
                ],
            )
        build_report(tie_baseline, tie_full, tie_output, tie_baseline)
        tie_row = (
            tie_output / "wubi-lost-four-code-unique.tsv"
        ).read_text().splitlines()[1].split("\t")
        assert tie_row[3] == "西蓝花 / 横巷", tie_row
        assert query_wubi(tie_full, "saaw", 9) == [
            {"text": "西蓝花", "weight": 10},
            {"text": "横巷", "weight": 10},
            {"text": "高权补全", "weight": 100},
        ]
    print("owl-rust-resource-report selftest: ok")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--seed-db", type=Path)
    parser.add_argument("--full-db", type=Path)
    parser.add_argument(
        "--wubi-baseline-db",
        type=Path,
        help=(
            "SQLite database containing only the core Wubi dictionary; defaults "
            "to --seed-db only when that seed already has Wubi rows"
        ),
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    missing = [
        option
        for option, value in (
            ("--seed-db", args.seed_db),
            ("--full-db", args.full_db),
            ("--output", args.output),
        )
        if value is None
    ]
    if missing:
        parser.error("the following arguments are required: " + ", ".join(missing))
    try:
        summary = build_report(
            args.seed_db.resolve(),
            args.full_db.resolve(),
            args.output.resolve(),
            (
                args.wubi_baseline_db.resolve()
                if args.wubi_baseline_db is not None
                else None
            ),
        )
    except (OSError, sqlite3.Error, ValueError) as error:
        parser.error(str(error))
    print(json.dumps(summary["counts"], ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
