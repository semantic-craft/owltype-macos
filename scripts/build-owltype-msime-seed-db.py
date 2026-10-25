#!/usr/bin/env python3
"""Build or check msime-pinyin.db and msime-english.db from Owltype seed dictionaries."""

from __future__ import annotations

import argparse
import re
import sqlite3
import sys
from pathlib import Path

INITIALS = "abcdefghjklmnopqrstwxyz"
SYLLABLE_RE = re.compile(r"^[a-z]+$")

SEED_ENGLISH_WORDS: list[tuple[str, str, int, str]] = [
    ("hello", "hello", 1000, ""),
    ("world", "world", 900, ""),
    ("owltype", "Owltype", 800, ""),
    ("test", "test", 700, ""),
    ("computer", "computer", 600, ""),
    ("input", "input", 600, ""),
    ("system", "system", 550, ""),
    ("macos", "macOS", 550, ""),
    ("apple", "Apple", 500, ""),
    ("code", "code", 500, ""),
]

SEED_EN_ZH_GLOSSES: list[tuple[str, str, int]] = [
    ("hello", "你好", 0),
    ("world", "世界", 0),
    ("test", "测试", 0),
    ("computer", "计算机", 0),
    ("input", "输入", 0),
]

SEED_ZH_EN_GLOSSES: list[tuple[str, str, int]] = [
    ("你好", "hello", 0),
    ("世界", "world", 0),
    ("测试", "test", 0),
]


def all_pinyin_suffixes() -> list[str]:
    suffixes: list[str] = []
    for n in range(1, 8):
        for initial in INITIALS:
            suffixes.append(f"{n}_{initial}")
    for initial in INITIALS:
        suffixes.append(f"others_{initial}")
    return suffixes


def normalize_syllable(raw: str) -> str:
    return (
        raw.strip()
        .lower()
        .replace("ü", "v")
        .replace("u:", "v")
        .replace("v:", "v")
    )


def iter_rime_dict_entries(
    dict_path: Path, default_weight: int
) -> list[tuple[str, str, str, str, int]]:
    """Return (table_suffix, key, jp, value, weight) tuples from a Rime dict.yaml file."""
    results: list[tuple[str, str, str, str, int]] = []
    in_header = True
    with dict_path.open("r", encoding="utf-8") as fh:
        for raw_line in fh:
            line = raw_line.rstrip("\r\n")
            if in_header:
                if line.strip() == "...":
                    in_header = False
                continue
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            value = parts[0].strip()
            code_raw = parts[1].strip()
            if not value or not code_raw:
                continue
            weight = default_weight
            if len(parts) >= 3 and parts[2].strip():
                try:
                    weight = int(float(parts[2].strip()))
                except ValueError:
                    weight = default_weight

            syllables = [normalize_syllable(tok) for tok in code_raw.split() if tok.strip()]
            if not syllables:
                continue
            if not all(SYLLABLE_RE.match(s) for s in syllables):
                continue
            initial = syllables[0][0]
            if initial not in INITIALS:
                continue

            k = len(syllables)
            bucket = str(k) if 1 <= k <= 7 else "others"
            suffix = f"{bucket}_{initial}"
            key = "'".join(syllables)
            jp = "".join(s[0] for s in syllables)
            results.append((suffix, key, jp, value, weight))
    return results


def build_pinyin_db(seed_dir: Path, pinyin_db_path: Path) -> None:
    base_dict = seed_dir / "cn_dicts" / "owltype_base.dict.yaml"
    unicode_dict = seed_dir / "cn_dicts" / "owltype_unicode.dict.yaml"
    if not base_dict.is_file():
        raise FileNotFoundError(f"Missing required base dict: {base_dict}")
    if not unicode_dict.is_file():
        raise FileNotFoundError(f"Missing required unicode dict: {unicode_dict}")

    suffixes = all_pinyin_suffixes()
    assert len(suffixes) == 184

    # Deduplicate (key, value) per table suffix, keeping max weight and jp
    buckets: dict[str, dict[tuple[str, str], tuple[str, int]]] = {
        suffix: {} for suffix in suffixes
    }

    for dict_path, default_weight in ((base_dict, 1), (unicode_dict, 0)):
        for suffix, key, jp, value, weight in iter_rime_dict_entries(dict_path, default_weight):
            table_map = buckets[suffix]
            pair = (key, value)
            existing = table_map.get(pair)
            if existing is None or weight > existing[1]:
                table_map[pair] = (jp, weight)

    pinyin_db_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = pinyin_db_path.with_suffix(".db.tmp")
    if tmp_path.exists():
        tmp_path.unlink()

    conn = sqlite3.connect(str(tmp_path))
    try:
        conn.execute("PRAGMA journal_mode = OFF;")
        conn.execute("PRAGMA synchronous = OFF;")
        with conn:
            for suffix in suffixes:
                conn.execute(
                    f'CREATE TABLE tbl_{suffix} ("key" text, "jp" text, "value" text, "weight" integer default 0);'
                )
                rows = [
                    (key, jp, value, weight)
                    for (key, value), (jp, weight) in buckets[suffix].items()
                ]
                rows.sort(key=lambda r: (r[0], -r[3], r[2]))
                if rows:
                    conn.executemany(
                        f'INSERT INTO tbl_{suffix} ("key", "jp", "value", "weight") VALUES (?, ?, ?, ?);',
                        rows,
                    )
                conn.execute(f'CREATE INDEX idx_key_{suffix} ON tbl_{suffix} ("key");')
                conn.execute(f'CREATE INDEX idx_jp_{suffix} ON tbl_{suffix} ("jp");')

            conn.executescript(
                """
                CREATE TABLE wubi86 ("key" text, "value" text, "weight" integer default 0, UNIQUE("key", "value"));
                CREATE INDEX idx_wubi86_key_weight ON wubi86 ("key", "weight" DESC);
                CREATE INDEX idx_wubi86_value ON wubi86 ("value");
                CREATE TABLE wubi98 ("key" text, "value" text, "weight" integer default 0, UNIQUE("key", "value"));
                CREATE INDEX idx_wubi98_key_weight ON wubi98 ("key", "weight" DESC);
                CREATE INDEX idx_wubi98_value ON wubi98 ("value");
                CREATE TABLE quick_parases ("key" text, "value" text, "weight" integer default 0);
                CREATE INDEX idx_quick_parases_key_weight ON quick_parases ("key", "weight" DESC);
                """
            )
    finally:
        conn.close()

    tmp_path.replace(pinyin_db_path)


def build_english_db(english_db_path: Path) -> None:
    english_db_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = english_db_path.with_suffix(".db.tmp")
    if tmp_path.exists():
        tmp_path.unlink()

    conn = sqlite3.connect(str(tmp_path))
    try:
        with conn:
            conn.executescript(
                """
                PRAGMA user_version = 3;
                CREATE TABLE english_words (
                    word TEXT NOT NULL,
                    display TEXT NOT NULL,
                    weight INTEGER NOT NULL DEFAULT 0,
                    phonetic TEXT NOT NULL DEFAULT '',
                    PRIMARY KEY (word, display)
                );
                CREATE INDEX idx_english_words_word_weight ON english_words (word, weight DESC);
                CREATE TABLE en_zh_glosses (
                    word TEXT NOT NULL,
                    translation TEXT NOT NULL,
                    rank INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (word, rank)
                );
                CREATE TABLE zh_en_glosses (
                    word TEXT NOT NULL,
                    translation TEXT NOT NULL,
                    rank INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (word, rank)
                );
                """
            )
            conn.executemany(
                "INSERT INTO english_words (word, display, weight, phonetic) VALUES (?, ?, ?, ?);",
                SEED_ENGLISH_WORDS,
            )
            conn.executemany(
                "INSERT INTO en_zh_glosses (word, translation, rank) VALUES (?, ?, ?);",
                SEED_EN_ZH_GLOSSES,
            )
            conn.executemany(
                "INSERT INTO zh_en_glosses (word, translation, rank) VALUES (?, ?, ?);",
                SEED_ZH_EN_GLOSSES,
            )
    finally:
        conn.close()

    tmp_path.replace(english_db_path)


def check_seed_dbs(pinyin_db_path: Path, english_db_path: Path) -> None:
    if not pinyin_db_path.is_file():
        raise RuntimeError(f"Missing msime-pinyin.db at {pinyin_db_path}")
    if not english_db_path.is_file():
        raise RuntimeError(f"Missing msime-english.db at {english_db_path}")

    suffixes = all_pinyin_suffixes()
    expected_pinyin_tables = {f"tbl_{s}" for s in suffixes} | {
        "wubi86",
        "wubi98",
        "quick_parases",
    }

    conn = sqlite3.connect(str(pinyin_db_path))
    try:
        rows = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table';"
        ).fetchall()
        actual_tables = {r[0] for r in rows}
        missing = expected_pinyin_tables - actual_tables
        if missing:
            raise RuntimeError(
                f"msime-pinyin.db missing tables ({len(missing)}): {sorted(missing)[:5]}"
            )

        count_1_n = conn.execute("SELECT count(*) FROM tbl_1_n;").fetchone()[0]
        count_2_n = conn.execute("SELECT count(*) FROM tbl_2_n;").fetchone()[0]
        if count_1_n <= 0 or count_2_n <= 0:
            raise RuntimeError(
                f"Expected non-zero rows in tbl_1_n ({count_1_n}) and tbl_2_n ({count_2_n})"
            )

        nihao_count = conn.execute(
            "SELECT count(*) FROM tbl_2_n WHERE \"key\" = 'ni''hao' AND \"value\" = '你好';"
        ).fetchone()[0]
        if nihao_count < 1:
            raise RuntimeError("Expected '你好' for key \"ni'hao\" in tbl_2_n")
    finally:
        conn.close()

    conn = sqlite3.connect(str(english_db_path))
    try:
        user_version = conn.execute("PRAGMA user_version;").fetchone()[0]
        if user_version != 3:
            raise RuntimeError(
                f"Expected msime-english.db PRAGMA user_version=3, got {user_version}"
            )
        rows = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table';"
        ).fetchall()
        actual_tables = {r[0] for r in rows}
        for req in ("english_words", "en_zh_glosses", "zh_en_glosses"):
            if req not in actual_tables:
                raise RuntimeError(f"msime-english.db missing table {req}")
        eng_count = conn.execute("SELECT count(*) FROM english_words;").fetchone()[0]
        if eng_count <= 0:
            raise RuntimeError("Expected non-zero rows in english_words")
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> int:
    repo_root = Path(__file__).resolve().parent.parent
    default_seed_dir = repo_root / "data" / "owl-rime"

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Verify existing msime-pinyin.db and msime-english.db without rebuilding.",
    )
    parser.add_argument(
        "seed_dir",
        nargs="?",
        default=str(default_seed_dir),
        help="Path to owl-rime seed directory (default: data/owl-rime).",
    )
    args = parser.parse_args(argv)

    seed_dir = Path(args.seed_dir).resolve()
    msime_dir = seed_dir / "msime"
    pinyin_db_path = msime_dir / "msime-pinyin.db"
    english_db_path = msime_dir / "msime-english.db"

    if args.check:
        check_seed_dbs(pinyin_db_path, english_db_path)
        return 0

    build_pinyin_db(seed_dir, pinyin_db_path)
    build_english_db(english_db_path)
    check_seed_dbs(pinyin_db_path, english_db_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
