#!/usr/bin/env python3
"""Build or check msime-pinyin.db and msime-english.db from Owltype seed dictionaries."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path

from resource_publish import publish_artifacts, temporary_path

INITIALS = "abcdefghjklmnopqrstwxyz"
SYLLABLE_RE = re.compile(r"^[a-z]+$")
WUBI86_SOURCE_REPO = "KyleBing/rime-wubi86-jidian"
WUBI86_SOURCE_COMMIT = "a194fb8b3ec41ef9dcf079d3a67876fa75f79135"
WUBI86_SOURCE_PATH = "wubi86_jidian.dict.yaml"
WUBI86_LICENSE_PATH = "LICENSE"
WUBI86_SOURCE_SHA256 = "8ccf1358b91028ed234bbe82647a0bcd0f554a8d5994042de28b146e517633e6"
WUBI86_LICENSE_SHA256 = "43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1"
WUBI86_SOURCE_TOTAL_ROWS = 89_273
WUBI86_ACCEPTED_ROWS = 89_272
WUBI86_UNIQUE_ROWS = 89_269
WUBI86_DUPLICATE_ROWS = 3
WUBI86_REJECTED_ROWS = 1
WUBI86_REJECTIONS = [
    {
        "sourceLine": 7911,
        "reason": "empty text column",
        "row": "\tcokg\t10\t全角空格",
    }
]
WUBI86_REQUIRED_PAIRS = {
    ("a", "工"),
    ("aaaa", "工"),
    ("ifcy", "法"),
    ("wq", "你"),
    ("wqiy", "你"),
    ("edui", "膫"),
    ("jixu", "曳光弹"),
    ("hang", "歫"),
    ("hang", "虛"),
}
WUBI86_FORBIDDEN_PAIRS = {
    # Mappings from the old 50-row production fixture that do not exist in the real table.
    ("bian", "便"),
    ("qigu", "乐平"),
}
WUBI86_LICENSE_OUTPUT = "wubi86-jidian.LICENSE"
WUBI86_SOURCE_METADATA_OUTPUT = "msime-wubi86-source.json"


class SeedSourceError(RuntimeError):
    """A source failure with a stable category for build logs and regressions."""

    def __init__(self, code: str, detail: str):
        super().__init__(f"{code}: {detail}")
        self.code = code


@dataclass(frozen=True)
class WubiImportStats:
    source_total_rows: int
    accepted_rows: int
    unique_rows: int
    duplicate_rows: int
    rejected_rows: int

SEED_ENGLISH_WORDS: list[tuple[str, str, int, str]] = [
    ("hello", "hello", 1000, ""),
    ("held", "held", 850, ""),
    ("help", "help", 900, ""),
    ("dir", "dir", 800, ""),
    ("github", "GitHub", 950, ""),
    ("git", "git", 850, ""),
    ("you", "you", 950, ""),
    ("did", "did", 700, ""),
    ("ship", "ship", 700, ""),
    ("shin", "shin", 600, ""),
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

SEED_PINYIN_EXTRA: list[tuple[str, str, str, str, int]] = [
    ("2_e", "e'du", "ed", "额度", 5000),
    ("2_j", "ji'xu", "jx", "继续", 5000),
    ("2_z", "zhong'guo", "zg", "中国", 8000),
    ("1_z", "zhao", "z", "找", 5000),
    ("1_z", "zhao", "z", "着", 4500),
    ("1_h", "hao", "h", "好", 8000),
    ("2_h", "han'guo", "hg", "韩国", 5000),
    ("2_x", "xu'qiu", "xq", "需求", 5000),
    ("2_b", "bian'yi", "by", "编译", 5000),
    ("2_q", "qi'guai", "qg", "奇怪", 5000),
    ("2_s", "shi'jie", "sj", "世界", 6000),
    ("2_n", "ni'hao", "nh", "你好", 8000),
    ("2_x", "x'guang", "xg", "X光", 3000),
    ("2_t", "t'xu", "tx", "T恤", 3000),
    ("2_a", "a'gu", "ag", "A股", 3000),
    ("2_q", "qq'qun", "qq", "QQ群", 3000),
    ("2_q", "q'qun", "qq", "QQ群", 3000),
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


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_pinned_source(path: Path, expected_sha256: str, label: str) -> bytes:
    try:
        data = path.read_bytes()
    except OSError as error:
        raise SeedSourceError(
            "MSIME_SOURCE_READ_FAILED", f"{label} at {path}: {error}"
        ) from error
    actual = sha256_bytes(data)
    if actual != expected_sha256:
        raise SeedSourceError(
            "MSIME_SOURCE_HASH_MISMATCH",
            f"{label} expected sha256 {expected_sha256}, got {actual}",
        )
    return data


def fetch_pinned_source(url: str, expected_sha256: str, target: Path, label: str) -> bytes:
    if target.is_file():
        try:
            return read_pinned_source(target, expected_sha256, label)
        except SeedSourceError as error:
            if error.code != "MSIME_SOURCE_HASH_MISMATCH":
                raise
            target.unlink(missing_ok=True)

    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            data = response.read()
    except (OSError, urllib.error.URLError) as error:
        raise SeedSourceError(
            "MSIME_SOURCE_DOWNLOAD_FAILED", f"{label} from {url}: {error}"
        ) from error

    actual = sha256_bytes(data)
    if actual != expected_sha256:
        raise SeedSourceError(
            "MSIME_SOURCE_HASH_MISMATCH",
            f"{label} expected sha256 {expected_sha256}, got {actual}",
        )
    target.write_bytes(data)
    return data


def import_wubi86_entries(dict_path: Path) -> tuple[list[tuple[str, str, int]], WubiImportStats]:
    rows: dict[tuple[str, str], int] = {}
    source_total_rows = 0
    accepted_rows = 0
    duplicate_rows = 0
    rejected_rows = 0
    in_header = True

    try:
        lines = dict_path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise SeedSourceError(
            "MSIME_SOURCE_READ_FAILED", f"Wubi86 dictionary at {dict_path}: {error}"
        ) from error

    for line in lines:
        if in_header:
            if line.strip() == "...":
                in_header = False
            continue
        if not line.strip() or line.startswith("#"):
            continue
        source_total_rows += 1

        parts = line.split("\t")
        if len(parts) < 2:
            rejected_rows += 1
            continue
        value = parts[0].strip()
        code = parts[1].strip().lower()
        if not value or not code or not code.isascii() or not code.isalpha():
            rejected_rows += 1
            continue
        try:
            weight = (
                int(float(parts[2].strip()))
                if len(parts) >= 3 and parts[2].strip()
                else 1
            )
        except ValueError:
            rejected_rows += 1
            continue

        accepted_rows += 1
        pair = (code, value)
        if pair in rows:
            duplicate_rows += 1
            rows[pair] = max(rows[pair], weight)
        else:
            rows[pair] = weight

    if in_header:
        raise SeedSourceError(
            "MSIME_SOURCE_FORMAT_INVALID",
            "Wubi86 dictionary ended before the YAML header terminator",
        )

    stats = WubiImportStats(
        source_total_rows=source_total_rows,
        accepted_rows=accepted_rows,
        unique_rows=len(rows),
        duplicate_rows=duplicate_rows,
        rejected_rows=rejected_rows,
    )
    expected = WubiImportStats(
        source_total_rows=WUBI86_SOURCE_TOTAL_ROWS,
        accepted_rows=WUBI86_ACCEPTED_ROWS,
        unique_rows=WUBI86_UNIQUE_ROWS,
        duplicate_rows=WUBI86_DUPLICATE_ROWS,
        rejected_rows=WUBI86_REJECTED_ROWS,
    )
    if stats != expected:
        raise SeedSourceError(
            "MSIME_SOURCE_COUNT_MISMATCH",
            f"Wubi86 expected {asdict(expected)}, got {asdict(stats)}",
        )
    missing_pairs = sorted(WUBI86_REQUIRED_PAIRS - rows.keys())
    if missing_pairs:
        raise SeedSourceError(
            "MSIME_SOURCE_CONTENT_MISMATCH",
            f"Wubi86 missing required code/text pairs: {missing_pairs[:5]}",
        )
    forbidden_pairs = sorted(WUBI86_FORBIDDEN_PAIRS & rows.keys())
    if forbidden_pairs:
        raise SeedSourceError(
            "MSIME_SOURCE_CONTENT_MISMATCH",
            f"Wubi86 contains known synthetic code/text pairs: {forbidden_pairs[:5]}",
        )

    entries = [(code, value, weight) for (code, value), weight in rows.items()]
    entries.sort(key=lambda row: (row[0], -row[2], row[1]))
    return entries, stats


def stage_bytes(path: Path, data: bytes) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = temporary_path(path, "tmp")
    try:
        with tmp_path.open("xb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
    except Exception:
        tmp_path.unlink(missing_ok=True)
        raise
    return tmp_path


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


def build_pinyin_db(
    seed_dir: Path,
    pinyin_db_path: Path,
    wubi_dict_path: Path,
    wubi_license_path: Path,
) -> WubiImportStats:
    base_dict = seed_dir / "cn_dicts" / "owltype_base.dict.yaml"
    unicode_dict = seed_dir / "cn_dicts" / "owltype_unicode.dict.yaml"
    if not base_dict.is_file():
        raise FileNotFoundError(f"Missing required base dict: {base_dict}")
    if not unicode_dict.is_file():
        raise FileNotFoundError(f"Missing required unicode dict: {unicode_dict}")

    wubi_entries, wubi_stats = import_wubi86_entries(wubi_dict_path)
    license_bytes = read_pinned_source(
        wubi_license_path, WUBI86_LICENSE_SHA256, "Wubi86 Apache-2.0 license"
    )
    source_metadata = {
        "repo": WUBI86_SOURCE_REPO,
        "revision": WUBI86_SOURCE_COMMIT,
        "sourcePath": WUBI86_SOURCE_PATH,
        "sourceSha256": WUBI86_SOURCE_SHA256,
        "licensePath": WUBI86_LICENSE_PATH,
        "licenseSha256": WUBI86_LICENSE_SHA256,
        "counts": asdict(wubi_stats),
        "rejections": WUBI86_REJECTIONS,
    }

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

    for suffix, key, jp, value, weight in SEED_PINYIN_EXTRA:
        table_map = buckets[suffix]
        pair = (key, value)
        existing = table_map.get(pair)
        if existing is None or weight > existing[1]:
            table_map[pair] = (jp, weight)

    pinyin_db_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = temporary_path(pinyin_db_path, "tmp")

    try:
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
                    conn.execute(
                        f'CREATE INDEX idx_key_{suffix} ON tbl_{suffix} ("key");'
                    )
                    conn.execute(
                        f'CREATE INDEX idx_jp_{suffix} ON tbl_{suffix} ("jp");'
                    )

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
                conn.executemany(
                    'INSERT INTO quick_parases ("key", "value", "weight") VALUES (?, ?, ?);',
                    [
                        ("xguang", "X光", 3000),
                        ("txu", "T恤", 3000),
                        ("agu", "A股", 3000),
                        ("upan", "U盘", 3000),
                        ("qqqun", "QQ群", 3000),
                    ],
                )
                conn.executemany(
                    'INSERT INTO wubi86 ("key", "value", "weight") VALUES (?, ?, ?);',
                    wubi_entries,
                )
                conn.execute(
                    """
                    CREATE TABLE owl_seed_wubi86_source (
                        repo TEXT NOT NULL,
                        revision TEXT NOT NULL,
                        source_path TEXT NOT NULL,
                        source_sha256 TEXT NOT NULL,
                        license_path TEXT NOT NULL,
                        license_sha256 TEXT NOT NULL,
                        source_total_rows INTEGER NOT NULL,
                        accepted_rows INTEGER NOT NULL,
                        unique_rows INTEGER NOT NULL,
                        duplicate_rows INTEGER NOT NULL,
                        rejected_rows INTEGER NOT NULL
                    );
                    """
                )
                conn.execute(
                    """
                    INSERT INTO owl_seed_wubi86_source VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    (
                        WUBI86_SOURCE_REPO,
                        WUBI86_SOURCE_COMMIT,
                        WUBI86_SOURCE_PATH,
                        WUBI86_SOURCE_SHA256,
                        WUBI86_LICENSE_PATH,
                        WUBI86_LICENSE_SHA256,
                        wubi_stats.source_total_rows,
                        wubi_stats.accepted_rows,
                        wubi_stats.unique_rows,
                        wubi_stats.duplicate_rows,
                        wubi_stats.rejected_rows,
                    ),
                )
        finally:
            conn.close()
    except Exception:
        tmp_path.unlink(missing_ok=True)
        raise
    license_output = seed_dir / WUBI86_LICENSE_OUTPUT
    metadata_output = seed_dir / "msime" / WUBI86_SOURCE_METADATA_OUTPUT
    staged_sidecars: list[tuple[Path, Path]] = []
    try:
        staged_sidecars.append((license_output, stage_bytes(license_output, license_bytes)))
        staged_sidecars.append(
            (
                metadata_output,
                stage_bytes(
                    metadata_output,
                    (
                        json.dumps(source_metadata, ensure_ascii=False, indent=2) + "\n"
                    ).encode("utf-8"),
                ),
            )
        )
        publish_artifacts(
            [(pinyin_db_path, tmp_path), *staged_sidecars],
        )
    except Exception:
        tmp_path.unlink(missing_ok=True)
        for _, staged in staged_sidecars:
            staged.unlink(missing_ok=True)
        raise
    return wubi_stats


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


def check_seed_dbs(
    pinyin_db_path: Path,
    english_db_path: Path,
    wubi_license_path: Path | None = None,
    wubi_metadata_path: Path | None = None,
) -> None:
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

        wubi_count = conn.execute("SELECT count(*) FROM wubi86;").fetchone()[0]
        if wubi_count != WUBI86_UNIQUE_ROWS:
            raise RuntimeError(
                f"Expected {WUBI86_UNIQUE_ROWS} unique Wubi86 rows, got {wubi_count}"
            )
        try:
            provenance = conn.execute(
                """
                SELECT repo, revision, source_sha256, license_sha256,
                       source_total_rows, accepted_rows, unique_rows,
                       duplicate_rows, rejected_rows
                FROM owl_seed_wubi86_source;
                """
            ).fetchone()
        except sqlite3.Error as error:
            raise RuntimeError(f"Missing Wubi86 seed provenance: {error}") from error
        expected_provenance = (
            WUBI86_SOURCE_REPO,
            WUBI86_SOURCE_COMMIT,
            WUBI86_SOURCE_SHA256,
            WUBI86_LICENSE_SHA256,
            WUBI86_SOURCE_TOTAL_ROWS,
            WUBI86_ACCEPTED_ROWS,
            WUBI86_UNIQUE_ROWS,
            WUBI86_DUPLICATE_ROWS,
            WUBI86_REJECTED_ROWS,
        )
        if provenance != expected_provenance:
            raise RuntimeError(
                f"Unexpected Wubi86 seed provenance: expected {expected_provenance}, got {provenance}"
            )
        missing_pairs = [
            pair
            for pair in sorted(WUBI86_REQUIRED_PAIRS)
            if conn.execute(
                'SELECT 1 FROM wubi86 WHERE "key" = ? AND "value" = ? LIMIT 1;',
                pair,
            ).fetchone()
            is None
        ]
        if missing_pairs:
            raise RuntimeError(
                f"Wubi86 seed missing required code/text pairs: {missing_pairs[:5]}"
            )
        forbidden_pairs = [
            pair
            for pair in sorted(WUBI86_FORBIDDEN_PAIRS)
            if conn.execute(
                'SELECT 1 FROM wubi86 WHERE "key" = ? AND "value" = ? LIMIT 1;',
                pair,
            ).fetchone()
            is not None
        ]
        if forbidden_pairs:
            raise RuntimeError(
                f"Wubi86 seed contains known synthetic code/text pairs: {forbidden_pairs[:5]}"
            )
    finally:
        conn.close()

    if wubi_license_path is not None:
        read_pinned_source(
            wubi_license_path, WUBI86_LICENSE_SHA256, "Wubi86 Apache-2.0 license"
        )
    if wubi_metadata_path is not None:
        try:
            metadata = json.loads(wubi_metadata_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise RuntimeError(f"Invalid Wubi86 seed metadata: {error}") from error
        expected_metadata = {
            "repo": WUBI86_SOURCE_REPO,
            "revision": WUBI86_SOURCE_COMMIT,
            "sourcePath": WUBI86_SOURCE_PATH,
            "sourceSha256": WUBI86_SOURCE_SHA256,
            "licensePath": WUBI86_LICENSE_PATH,
            "licenseSha256": WUBI86_LICENSE_SHA256,
            "counts": asdict(
                WubiImportStats(
                    source_total_rows=WUBI86_SOURCE_TOTAL_ROWS,
                    accepted_rows=WUBI86_ACCEPTED_ROWS,
                    unique_rows=WUBI86_UNIQUE_ROWS,
                    duplicate_rows=WUBI86_DUPLICATE_ROWS,
                    rejected_rows=WUBI86_REJECTED_ROWS,
                )
            ),
            "rejections": WUBI86_REJECTIONS,
        }
        if metadata != expected_metadata:
            raise RuntimeError("Wubi86 seed metadata does not match the pinned source")

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
        "--wubi-source-dir",
        help="Use already-downloaded pinned Wubi86 source files from this directory.",
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
    wubi_license_output = seed_dir / WUBI86_LICENSE_OUTPUT
    wubi_metadata_path = msime_dir / WUBI86_SOURCE_METADATA_OUTPUT

    if args.check:
        check_seed_dbs(
            pinyin_db_path,
            english_db_path,
            wubi_license_output,
            wubi_metadata_path,
        )
        return 0

    if args.wubi_source_dir:
        source_dir = Path(args.wubi_source_dir).resolve()
        wubi_dict_path = source_dir / WUBI86_SOURCE_PATH
        wubi_license_path = source_dir / WUBI86_LICENSE_PATH
        read_pinned_source(wubi_dict_path, WUBI86_SOURCE_SHA256, "Wubi86 dictionary")
        read_pinned_source(
            wubi_license_path, WUBI86_LICENSE_SHA256, "Wubi86 Apache-2.0 license"
        )
    else:
        cache_root = Path(
            os.environ.get("OWLTYPE_MSIME_SOURCE_CACHE", "/tmp/owltype-msime-source")
        ).expanduser()
        cache_dir = cache_root / WUBI86_SOURCE_COMMIT
        dict_url = (
            f"https://raw.githubusercontent.com/{WUBI86_SOURCE_REPO}/"
            f"{WUBI86_SOURCE_COMMIT}/{WUBI86_SOURCE_PATH}"
        )
        wubi_dict_path = cache_dir / WUBI86_SOURCE_PATH
        wubi_license_path = repo_root / "licenses" / WUBI86_LICENSE_OUTPUT
        fetch_pinned_source(
            dict_url, WUBI86_SOURCE_SHA256, wubi_dict_path, "Wubi86 dictionary"
        )
        read_pinned_source(
            wubi_license_path,
            WUBI86_LICENSE_SHA256,
            "Wubi86 Apache-2.0 license",
        )

    wubi_stats = build_pinyin_db(
        seed_dir, pinyin_db_path, wubi_dict_path, wubi_license_path
    )
    build_english_db(english_db_path)
    check_seed_dbs(
        pinyin_db_path,
        english_db_path,
        wubi_license_output,
        wubi_metadata_path,
    )
    print(
        "[msime-seed] "
        f"wubi86={WUBI86_SOURCE_COMMIT[:12]} "
        f"source_total_rows={wubi_stats.source_total_rows} "
        f"accepted_rows={wubi_stats.accepted_rows} "
        f"unique_rows={wubi_stats.unique_rows} "
        f"duplicate_rows={wubi_stats.duplicate_rows} "
        f"rejected_rows={wubi_stats.rejected_rows} "
        f"dict_sha256={WUBI86_SOURCE_SHA256} "
        f"license_sha256={WUBI86_LICENSE_SHA256}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
