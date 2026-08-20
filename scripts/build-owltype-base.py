#!/usr/bin/env python3

import sys
import unicodedata
import zipfile
from pathlib import Path


# Kept in sync with scripts/unihan-to-rime.py.
UMLAUTS = str.maketrans({"ü": "v", "ǖ": "v", "ǘ": "v", "ǚ": "v", "ǜ": "v"})

SECONDARY_READING_DIVISOR = 20
MAX_SYLLABLE_DROPS = 500


def without_tone(reading: str) -> str:
    decomposed = unicodedata.normalize("NFD", reading.translate(UMLAUTS))
    return "".join(character for character in decomposed if not unicodedata.combining(character))


def load_unihan(archive: Path) -> tuple[set[str], dict, dict, dict]:
    tgh_chars: set[str] = set()
    tghz_readings: dict[str, list[str]] = {}
    mandarin_readings: dict[str, list[str]] = {}
    pinlu_counts: dict[str, dict[str, int]] = {}

    with zipfile.ZipFile(archive) as unihan:
        with unihan.open("Unihan_OtherMappings.txt") as mappings:
            for raw_line in mappings:
                line = raw_line.decode("utf-8")
                if "\tkTGH\t" not in line:
                    continue
                codepoint = line.split("\t", 1)[0]
                tgh_chars.add(chr(int(codepoint.removeprefix("U+"), 16)))
        with unihan.open("Unihan_Readings.txt") as readings:
            for raw_line in readings:
                line = raw_line.decode("utf-8").rstrip("\n")
                if line.startswith("#") or "\t" not in line:
                    continue
                codepoint, field, value = line.split("\t", 2)
                character = chr(int(codepoint.removeprefix("U+"), 16))
                if field == "kTGHZ2013":
                    # Groups look like "223.010,223.020:liǎo"; keep dictionary order.
                    ordered: list[str] = []
                    for group in value.split():
                        reading = without_tone(group.split(":", 1)[1])
                        if reading not in ordered:
                            ordered.append(reading)
                    tghz_readings[character] = ordered
                elif field == "kMandarin":
                    mandarin_readings[character] = [without_tone(item) for item in value.split()]
                elif field == "kHanyuPinlu":
                    # Groups look like "liǎo(654)"; tones collapse, counts sum.
                    counts: dict[str, int] = {}
                    for group in value.split():
                        reading, _, count = group.partition("(")
                        toneless = without_tone(reading)
                        counts[toneless] = counts.get(toneless, 0) + int(count.rstrip(")"))
                    pinlu_counts[character] = counts
    return tgh_chars, tghz_readings, mandarin_readings, pinlu_counts


def load_jieba(path: Path) -> dict[str, int]:
    frequencies: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        try:
            frequency = int(fields[1])
        except ValueError:
            continue
        word = fields[0]
        frequencies[word] = max(frequency, frequencies.get(word, 0))
    return frequencies


def load_phrase_pinyin(path: Path) -> dict[str, list[str]]:
    codes: dict[str, list[str]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        word, separator, readings = line.partition(":")
        word = word.strip()
        syllables = readings.split()
        if not separator or not word or len(syllables) != len(word):
            continue
        code = " ".join(without_tone(syllable) for syllable in syllables)
        word_codes = codes.setdefault(word, [])
        if code not in word_codes:
            word_codes.append(code)
    return codes


def readings_for(character: str, tghz: dict, mandarin: dict) -> list[str]:
    readings = tghz.get(character)
    if not readings:
        readings = mandarin.get(character, [])[:1]
    return readings


def primary_reading(character: str, tghz: dict, mandarin: dict) -> str:
    readings = readings_for(character, tghz, mandarin)
    mandarin_values = mandarin.get(character)
    if mandarin_values and mandarin_values[0] in readings:
        return mandarin_values[0]
    return readings[0]


def build_char_entries(tgh_chars, tghz, mandarin, pinlu, jieba) -> list[tuple[str, str, int]]:
    unreadable = sorted(character for character in tgh_chars if not readings_for(character, tghz, mandarin))
    if unreadable:
        raise SystemExit(f"kTGH characters without readings: {unreadable[:10]}")

    entries: list[tuple[str, str, int]] = []
    for character in sorted(tgh_chars):
        readings = readings_for(character, tghz, mandarin)
        frequency = jieba.get(character, 1)
        counts = pinlu.get(character, {})
        weighted = {reading: counts[reading] for reading in readings if reading in counts}
        if weighted:
            total = sum(weighted.values())
            for reading in readings:
                if reading in weighted:
                    weight = max(1, round(frequency * weighted[reading] / total))
                else:
                    weight = max(1, frequency // SECONDARY_READING_DIVISOR)
                entries.append((character, reading, weight))
        else:
            primary = primary_reading(character, tghz, mandarin)
            for reading in readings:
                weight = frequency if reading == primary else max(1, frequency // SECONDARY_READING_DIVISOR)
                entries.append((character, reading, weight))
    return entries


def build_word_entries(jieba, tgh_chars, phrase_codes, tghz, mandarin) -> list[tuple[str, str, int]]:
    deduplicated: dict[tuple[str, str], int] = {}
    for word, frequency in jieba.items():
        if len(word) < 2 or not set(word) <= tgh_chars:
            continue
        codes = phrase_codes.get(word)
        if not codes:
            codes = [" ".join(primary_reading(character, tghz, mandarin) for character in word)]
        for code in codes:
            key = (word, code)
            deduplicated[key] = max(frequency, deduplicated.get(key, 0))
    return [(word, code, weight) for (word, code), weight in deduplicated.items()]


def validate(char_entries, word_entries, tgh_chars) -> list[tuple[str, str, int]]:
    if len(tgh_chars) != 8105:
        raise SystemExit(f"kTGH character count is {len(tgh_chars)}, expected 8105")
    if not 8105 <= len(char_entries) <= 14_000:
        raise SystemExit(f"char entry count {len(char_entries)} outside expected range")

    syllables = {entry[1] for entry in char_entries}
    for syllable in syllables:
        if not syllable.isascii() or not syllable.isalpha() or not syllable.islower():
            raise SystemExit(f"char reading is not plain lowercase pinyin: {syllable!r}")

    kept: list[tuple[str, str, int]] = []
    dropped: list[tuple[str, str, int]] = []
    for entry in word_entries:
        if all(syllable in syllables for syllable in entry[1].split()):
            kept.append(entry)
        else:
            dropped.append(entry)
    if len(dropped) > MAX_SYLLABLE_DROPS:
        raise SystemExit(f"{len(dropped)} word entries fall outside the char syllabary: {dropped[:10]}")
    if dropped:
        print(f"dropped {len(dropped)} word entries outside the char syllabary")

    if len(kept) < 200_000:
        raise SystemExit(f"word entry count {len(kept)} is suspiciously low")

    entry_keys = {(entry[0], entry[1]) for entry in char_entries + kept}
    required = {
        ("编程", "bian cheng"),
        ("你好", "ni hao"),
        ("繁体字", "fan ti zi"),
        ("银行", "yin hang"),
        ("重庆", "chong qing"),
        ("了", "le"),
        ("了", "liao"),
    }
    missing = required - entry_keys
    if missing:
        raise SystemExit(f"required probe entries missing: {sorted(missing)}")

    forbidden = {"們", "國", "說", "體"}
    for entry in char_entries + kept:
        if not set(entry[0]) <= tgh_chars:
            raise SystemExit(f"entry text outside 通用规范汉字表: {entry!r}")
        if set(entry[0]) & forbidden:
            raise SystemExit(f"traditional-form probe leaked into output: {entry!r}")
    return kept


def main() -> None:
    if len(sys.argv) != 6:
        raise SystemExit(
            f"usage: {Path(sys.argv[0]).name} Unihan.zip jieba-dict.txt ppd-pinyin.txt output.dict.yaml version"
        )

    archive = Path(sys.argv[1])
    jieba_path = Path(sys.argv[2])
    phrase_path = Path(sys.argv[3])
    output = Path(sys.argv[4])
    version = sys.argv[5]

    tgh_chars, tghz, mandarin, pinlu = load_unihan(archive)
    jieba = load_jieba(jieba_path)
    phrase_codes = load_phrase_pinyin(phrase_path)

    char_entries = build_char_entries(tgh_chars, tghz, mandarin, pinlu, jieba)
    word_entries = build_word_entries(jieba, tgh_chars, phrase_codes, tghz, mandarin)
    word_entries = validate(char_entries, word_entries, tgh_chars)

    header = f"""# Rime dictionary
# encoding: utf-8
# Generated from jieba dict.txt (MIT), phrase-pinyin-data pinyin.txt (MIT), and
# Unicode Unihan kTGH/kTGHZ2013/kMandarin/kHanyuPinlu (Unicode-3.0).
# Every entry is restricted to 通用规范汉字表 (kTGH 2013) characters.

---
name: owltype_base
version: "{version}"
sort: by_weight
columns:
  - text
  - code
  - weight
...
"""
    entries = sorted(char_entries + word_entries)
    body = "".join(f"{text}\t{code}\t{weight}\n" for text, code, weight in entries)
    output.write_text(header + body, encoding="utf-8")
    print(
        f"generated {len(char_entries)} char readings and {len(word_entries)} words "
        f"for {len(tgh_chars)} 通用规范 characters"
    )


if __name__ == "__main__":
    main()
