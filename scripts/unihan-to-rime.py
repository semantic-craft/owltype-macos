#!/usr/bin/env python3

import sys
import unicodedata
import zipfile
from pathlib import Path


UMLAUTS = str.maketrans({"ü": "v", "ǖ": "v", "ǘ": "v", "ǚ": "v", "ǜ": "v"})


def without_tone(reading: str) -> str:
    decomposed = unicodedata.normalize("NFD", reading.translate(UMLAUTS))
    return "".join(character for character in decomposed if not unicodedata.combining(character))


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} Unihan.zip output.dict.yaml")

    archive = Path(sys.argv[1])
    output = Path(sys.argv[2])
    entries: list[tuple[str, str]] = []

    with zipfile.ZipFile(archive) as unihan:
        with unihan.open("Unihan_Readings.txt") as readings:
            for raw_line in readings:
                line = raw_line.decode("utf-8").rstrip("\n")
                if "\tkMandarin\t" not in line:
                    continue
                codepoint, _, raw_readings = line.split("\t", 2)
                character = chr(int(codepoint.removeprefix("U+"), 16))
                for raw_reading in raw_readings.split():
                    entries.append((character, without_tone(raw_reading)))

    required = {("你", "ni"), ("好", "hao")}
    if len(entries) < 40_000 or not required.issubset(entries):
        raise SystemExit("Unihan kMandarin input is incomplete")

    header = """# Rime dictionary
# encoding: utf-8
# Generated from Unicode 16.0.0 Unihan_Readings.txt kMandarin.

---
name: famotype_unicode
version: \"16.0.0\"
sort: by_weight
columns:
  - text
  - code
...
"""
    body = "".join(f"{character}\t{reading}\n" for character, reading in entries)
    output.write_text(header + body, encoding="utf-8")
    print(f"generated {len(entries)} Rime readings from Unicode Unihan")


if __name__ == "__main__":
    main()
