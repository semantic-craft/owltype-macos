#!/usr/bin/env python3
"""Normalize secret-scanner findings and apply the shared release-gate policy.

Scanner adapters stop at translating scanner-specific JSON into ``Finding``.
All exemptions, rejection decisions, and redacted reporting live here so the
history and artifact gates cannot drift apart.
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import hashlib
import json
import pathlib
import re
import sqlite3
import sys
from collections.abc import Callable, Iterable
from contextlib import closing
from typing import Any, Literal


Source = Literal["history", "artifact"]
Scanner = Literal["gitleaks", "trufflehog"]


@dataclasses.dataclass(frozen=True)
class Finding:
    source: Source
    scanner: Scanner
    detector: str
    path: str
    raw: str = ""
    location: Literal["file", "commit_message"] = "file"
    commit: str = ""
    line: int | None = None
    verified: bool | None = None


@dataclasses.dataclass(frozen=True)
class Decision:
    finding: Finding
    waiver: str | None

    @property
    def rejected(self) -> bool:
        return self.waiver is None


class PolicyInputError(Exception):
    """The scanner report could not be safely normalized."""


HASH_MANIFESTS = {"OWLTYPE-FILE-MANIFEST.sha256", "OWLTYPE-SOURCE-MANIFEST.sha256"}
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MANIFEST_LINE = re.compile(r"^[0-9a-f]{64} {2}\S")
SWIFT_MANGLED = re.compile(r"^s\d+Owltype")

# Lob recognizes a five-character environment prefix followed by exactly 35
# token characters.  The exemption accepts only the test environment, requires
# an identifier separator, and is limited to files below a test directory.
LOB_TEST_IDENTIFIER = re.compile(
    r"^test_(?=[A-Za-z0-9_]{35}$)(?=[A-Za-z0-9_]*_)[A-Za-z0-9_]{35}$"
)
TEST_PATH_COMPONENTS = {"test", "tests"}
SOURCE_SUFFIXES = {
    ".swift",
    ".py",
    ".cpp",
    ".cc",
    ".c",
    ".h",
    ".hpp",
    ".m",
    ".mm",
    ".go",
    ".rs",
    ".java",
    ".js",
    ".ts",
    ".rb",
    ".lua",
}


def _text(value: Any, default: str = "") -> str:
    return value if isinstance(value, str) and value else default


def _line_number(value: Any) -> int | None:
    if isinstance(value, int) and value > 0:
        return value
    if isinstance(value, str) and value.isdigit() and int(value) > 0:
        return int(value)
    return None


def normalize_gitleaks(record: dict[str, Any], source: Source) -> Finding:
    """Translate one Gitleaks report entry without making a policy decision."""
    return Finding(
        source=source,
        scanner="gitleaks",
        detector=_text(record.get("RuleID"), "unknown"),
        path=_text(record.get("File"), "unknown"),
        commit=_text(record.get("Commit"))[:12],
    )


def normalize_history_trufflehog(record: dict[str, Any]) -> Finding | None:
    """Translate one TruffleHog Git record; JSON log records are not findings."""
    detector = _text(record.get("DetectorName"))
    if not detector:
        return None
    metadata = record.get("SourceMetadata")
    metadata = metadata if isinstance(metadata, dict) else {}
    data = metadata.get("Data")
    data = data if isinstance(data, dict) else {}
    git_data = data.get("Git")
    if not isinstance(git_data, dict):
        git_data = {}
    path = _text(git_data.get("file"))
    return Finding(
        source="history",
        scanner="trufflehog",
        detector=detector,
        path=path or "(commit message)",
        raw=_text(record.get("Raw")),
        location="file" if path else "commit_message",
        commit=_text(git_data.get("commit"), "unknown")[:12],
    )


def normalize_artifact_trufflehog(record: dict[str, Any]) -> Finding | None:
    """Translate one TruffleHog filesystem record without applying policy."""
    detector = _text(record.get("DetectorName"))
    if not detector:
        return None
    metadata = record.get("SourceMetadata")
    metadata = metadata if isinstance(metadata, dict) else {}
    data = metadata.get("Data")
    data = data if isinstance(data, dict) else {}
    filesystem = data.get("Filesystem")
    if not isinstance(filesystem, dict):
        filesystem = {}
    return Finding(
        source="artifact",
        scanner="trufflehog",
        detector=detector,
        path=_text(filesystem.get("file"), "unknown"),
        raw=_text(record.get("Raw")),
        line=_line_number(filesystem.get("line")),
        verified=record.get("Verified") if isinstance(record.get("Verified"), bool) else None,
    )


def manifest_hash_column(finding: Finding) -> bool:
    """Allow only the leading digest column of a generated SHA-256 manifest."""
    if finding.source != "artifact" or finding.scanner != "trufflehog":
        return False
    if finding.detector != "PhraseAccessToken" or not SHA256.fullmatch(finding.raw):
        return False
    path = pathlib.Path(finding.path)
    if path.name not in HASH_MANIFESTS or finding.line is None:
        return False
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            for index, line in enumerate(handle, start=1):
                if index == finding.line:
                    return bool(MANIFEST_LINE.match(line)) and line[:64] == finding.raw
    except OSError:
        return False
    return False


def swift_symbol(finding: Finding) -> bool:
    """Allow Owltype Swift symbol names only inside executable bundle locations."""
    if finding.source != "artifact" or finding.scanner != "trufflehog":
        return False
    if not SWIFT_MANGLED.match(finding.raw):
        return False
    path = pathlib.Path(finding.path)
    return path.is_file() and path.parent.name in {"MacOS", "Frameworks", "PlugIns"}


def lob_test_identifier(finding: Finding) -> bool:
    """Allow an exact Lob-shaped test identifier only in a source file."""
    if finding.scanner != "trufflehog" or finding.detector != "Lob":
        return False
    if finding.location != "file" or not LOB_TEST_IDENTIFIER.fullmatch(finding.raw):
        return False
    path = pathlib.PurePosixPath(finding.path.replace("\\", "/"))
    if path.suffix not in SOURCE_SUFFIXES:
        return False
    in_test_directory = any(
        part.casefold() in TEST_PATH_COMPONENTS for part in path.parts[:-1]
    )
    is_selftest_source = ".selftest." in path.name.casefold()
    return in_test_directory or is_selftest_source


# Public dict-v2.0.24 msime-english.db is shipped byte-for-byte from the
# SHA-pinned official manifest. Eraser matches one serialized word/display
# pair rather than a credential. Pin this single raw match as well as the
# complete public file; do not exempt a path, table, detector or generic shape.
PUBLIC_ENGLISH_DB_SHA256 = "d216f66cab7edb9072ba7a07f3fe35623e76870438b76d360a89cc2a4795d3cd"
PUBLIC_ENGLISH_PAIR_SHA256 = "0765860a9a46aa632108905db5870971f1e74c377435cf6df910651abd976298"


def public_english_row_pair(finding: Finding) -> bool:
    """Allow only the proven unverified Eraser match in the unchanged public DB."""
    if (finding.source != "artifact" or finding.scanner != "trufflehog"
            or finding.detector != "Eraser" or finding.verified is not False):
        return False
    raw = finding.raw
    if (len(raw) != 20 or not raw.isascii() or not raw.isalpha() or not raw.islower()
            or hashlib.sha256(raw.encode()).hexdigest() != PUBLIC_ENGLISH_PAIR_SHA256):
        return False
    path = pathlib.Path(finding.path)
    if (path.parts[-4:] != ("Contents", "SharedSupport", "msime", "msime-english.db")
            or not path.parents[3].name.endswith(".app") or path.is_symlink()):
        return False
    try:
        if hashlib.sha256(path.read_bytes()).hexdigest() != PUBLIC_ENGLISH_DB_SHA256:
            return False
        # Read exactly the hashed DB; do not incorporate an ambient WAL/journal.
        with closing(sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro&immutable=1", uri=True)) as db:
            row = db.execute(
                "SELECT COUNT(*) FROM english_words WHERE word = display AND word || display = ?",
                (raw,),
            ).fetchone()
            return row == (1,)
    except (OSError, sqlite3.Error):
        return False


Predicate = tuple[str, Callable[[Finding], bool]]
ALLOWED: tuple[Predicate, ...] = (
    ("SHA-256 清单的哈希列", manifest_hash_column),
    ("Swift 符号修饰", swift_symbol),
    ("Lob 撞测试函数名", lob_test_identifier),
    ("固定公开英文词库的词条列拼接", public_english_row_pair),
)


def decide(finding: Finding) -> Decision:
    for reason, predicate in ALLOWED:
        if predicate(finding):
            return Decision(finding=finding, waiver=reason)
    return Decision(finding=finding, waiver=None)


def _load_gitleaks(path: pathlib.Path, source: Source) -> list[Finding]:
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            records = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise PolicyInputError("Gitleaks report is missing or invalid") from error
    if not isinstance(records, list):
        raise PolicyInputError("Gitleaks report is not a JSON array")
    if any(not isinstance(record, dict) for record in records):
        raise PolicyInputError("Gitleaks report contains a non-object finding")
    return [normalize_gitleaks(record, source) for record in records]


def _load_trufflehog(path: pathlib.Path, source: Source) -> list[Finding]:
    normalizer = (
        normalize_history_trufflehog if source == "history" else normalize_artifact_trufflehog
    )
    findings: list[Finding] = []
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            for line_number, line in enumerate(handle, start=1):
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError as error:
                    raise PolicyInputError(
                        f"TruffleHog report has invalid JSON on line {line_number}"
                    ) from error
                if not isinstance(record, dict):
                    raise PolicyInputError(
                        f"TruffleHog report has a non-object record on line {line_number}"
                    )
                finding = normalizer(record)
                if finding is not None:
                    findings.append(finding)
    except OSError as error:
        raise PolicyInputError("TruffleHog report is missing or unreadable") from error
    return findings


def load_findings(path: pathlib.Path, source: Source, scanner: Scanner) -> list[Finding]:
    if scanner == "gitleaks":
        return _load_gitleaks(path, source)
    return _load_trufflehog(path, source)


def _safe_field(value: str) -> str:
    sanitized = "".join(character if character.isprintable() else "?" for character in value)
    return sanitized[:240] or "unknown"


def report_rejected(finding: Finding, label: str | None) -> None:
    path = _safe_field(finding.path)
    detector = _safe_field(finding.detector)
    detector_field = "rule" if finding.scanner == "gitleaks" else "detector"
    if finding.source == "artifact":
        artifact = _safe_field(label or "unknown")
        print(
            f"potential secret found in artifact: scanner={finding.scanner} "
            f"artifact={artifact} {detector_field}={detector} file={path}",
            file=sys.stderr,
        )
        return

    location = f" commit={_safe_field(finding.commit)}" if finding.commit else ""
    print(
        f"potential secret found: scanner={finding.scanner} "
        f"{detector_field}={detector} file={path}{location}",
        file=sys.stderr,
    )


def report_pass(source: Source, scanner: Scanner, label: str | None, waivers: Iterable[str]) -> None:
    if scanner != "trufflehog":
        return
    counts = collections.Counter(waivers)
    suffix = ""
    if counts:
        summary = "，".join(f"{reason} {count} 条" for reason, count in counts.items())
        suffix = f"（已按既有误报判据豁免：{summary}）"
    if source == "artifact":
        print(f"PASS: no secrets in artifact {_safe_field(label or 'unknown')}{suffix}")
    else:
        print(f"PASS: TruffleHog found no secrets in reachable history{suffix}")


def run_policy(source: Source, scanner: Scanner, report: pathlib.Path, label: str | None) -> int:
    try:
        findings = load_findings(report, source, scanner)
    except PolicyInputError as error:
        print(f"ERROR: {error}; scanner output was suppressed", file=sys.stderr)
        return 2

    decisions = [decide(finding) for finding in findings]
    rejected = [decision.finding for decision in decisions if decision.rejected]
    if rejected:
        for finding in rejected:
            report_rejected(finding, label)
        return 1

    report_pass(
        source,
        scanner,
        label,
        (decision.waiver for decision in decisions if decision.waiver is not None),
    )
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", choices=("history", "artifact"))
    parser.add_argument("scanner", choices=("gitleaks", "trufflehog"))
    parser.add_argument("report", type=pathlib.Path)
    parser.add_argument("--label")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.source == "artifact" and not args.label:
        print("ERROR: artifact policy requires --label", file=sys.stderr)
        return 2
    return run_policy(args.source, args.scanner, args.report, args.label)


if __name__ == "__main__":
    raise SystemExit(main())
