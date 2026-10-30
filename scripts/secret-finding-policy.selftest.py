#!/usr/bin/env python3
"""Table-driven tests for the shared secret finding policy and shell adapters.

Every finding and scanner executable is synthetic and lives in a temporary
directory. Container tests use unsigned system packaging tools, but never real
credentials, signing identities, notarization, or Keychain state.
"""

from __future__ import annotations

import importlib.util
import hashlib
import contextlib
import io
import sqlite3
import dataclasses
import json
import os
import pathlib
import secrets
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest
from typing import Any
from unittest.mock import patch


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
POLICY_PATH = SCRIPT_DIR / "secret-finding-policy.py"

SPEC = importlib.util.spec_from_file_location("secret_finding_policy", POLICY_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {POLICY_PATH}")
POLICY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = POLICY
SPEC.loader.exec_module(POLICY)

LOB_IDENTIFIER_BODY = "unit_case_" + "x" * 25
assert len(LOB_IDENTIFIER_BODY) == 35
SYNTHETIC_LOB_IDENTIFIER = "test_" + LOB_IDENTIFIER_BODY
SYNTHETIC_CREDENTIAL_SHAPE = "test_" + "A" * 35
SYNTHETIC_LIVE_CREDENTIAL_SHAPE = "live_" + LOB_IDENTIFIER_BODY


def synthetic_generic_api_key() -> str:
    """Return a deterministic high-entropy fixture without storing a secret-shaped literal."""
    return "0123456789abcdef" * 4


def history_record(
    raw: str,
    *,
    detector: str = "Lob",
    path: str | None = "tests/SyntheticTests.swift",
) -> dict[str, Any]:
    git: dict[str, Any] = {"commit": "0123456789abcdef"}
    if path is not None:
        git["file"] = path
    return {
        "DetectorName": detector,
        "Raw": raw,
        "SourceMetadata": {"Data": {"Git": git}},
    }


def artifact_record(
    raw: str,
    *,
    detector: str = "Lob",
    path: str = "tests/SyntheticTests.swift",
    line: int | None = None,
) -> dict[str, Any]:
    filesystem: dict[str, Any] = {"file": path}
    if line is not None:
        filesystem["line"] = line
    return {
        "DetectorName": detector,
        "Raw": raw,
        "SourceMetadata": {"Data": {"Filesystem": filesystem}},
    }


class PolicyTableTests(unittest.TestCase):
    def test_lob_predicate_is_shared_and_minimal(self) -> None:
        cases = (
            (
                "history source identifier",
                POLICY.normalize_history_trufflehog(
                    history_record(SYNTHETIC_LOB_IDENTIFIER)
                ),
                "Lob 撞测试函数名",
            ),
            (
                "artifact source identifier",
                POLICY.normalize_artifact_trufflehog(
                    artifact_record(SYNTHETIC_LOB_IDENTIFIER)
                ),
                "Lob 撞测试函数名",
            ),
            (
                "history selftest source identifier",
                POLICY.normalize_history_trufflehog(
                    history_record(
                        SYNTHETIC_LOB_IDENTIFIER,
                        path="scripts/secret-finding-policy.selftest.py",
                    )
                ),
                "Lob 撞测试函数名",
            ),
            (
                "artifact selftest source identifier",
                POLICY.normalize_artifact_trufflehog(
                    artifact_record(
                        SYNTHETIC_LOB_IDENTIFIER,
                        path="scripts/secret-finding-policy.selftest.py",
                    )
                ),
                "Lob 撞测试函数名",
            ),
            (
                "credential-shaped body has no identifier separator",
                POLICY.normalize_history_trufflehog(
                    history_record(SYNTHETIC_CREDENTIAL_SHAPE)
                ),
                None,
            ),
            (
                "live credential shape is never a test identifier",
                POLICY.normalize_history_trufflehog(
                    history_record(SYNTHETIC_LIVE_CREDENTIAL_SHAPE)
                ),
                None,
            ),
            (
                "commit message is never source",
                POLICY.normalize_history_trufflehog(
                    history_record(SYNTHETIC_LOB_IDENTIFIER, path=None)
                ),
                None,
            ),
            (
                "non-source artifact location",
                POLICY.normalize_artifact_trufflehog(
                    artifact_record(SYNTHETIC_LOB_IDENTIFIER, path="config/runtime.env")
                ),
                None,
            ),
            (
                "ordinary source directory",
                POLICY.normalize_history_trufflehog(
                    history_record(SYNTHETIC_LOB_IDENTIFIER, path="Sources/Feature.swift")
                ),
                None,
            ),
            (
                "non-source history location",
                POLICY.normalize_history_trufflehog(
                    history_record(SYNTHETIC_LOB_IDENTIFIER, path="docs/example.md")
                ),
                None,
            ),
            (
                "wrong detector",
                POLICY.normalize_history_trufflehog(
                    history_record(SYNTHETIC_LOB_IDENTIFIER, detector="Other")
                ),
                None,
            ),
            (
                "short body",
                POLICY.normalize_history_trufflehog(
                    history_record("test_" + "unit_case_" + "x" * 24)
                ),
                None,
            ),
            (
                "long body",
                POLICY.normalize_artifact_trufflehog(
                    artifact_record("test_" + "unit_case_" + "x" * 26)
                ),
                None,
            ),
        )

        for name, finding, expected_waiver in cases:
            with self.subTest(name=name):
                self.assertIsNotNone(finding)
                self.assertEqual(POLICY.decide(finding).waiver, expected_waiver)

    def test_artifact_only_predicates_remain_narrow(self) -> None:
        digest = "a" * 64
        different_digest = "b" * 64
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            manifest = root / "OWLTYPE-FILE-MANIFEST.sha256"
            manifest.write_text(f"{digest}  ./Owltype\n", encoding="utf-8")
            executable = root / "MacOS" / "Owltype"
            executable.parent.mkdir()
            executable.write_text("synthetic", encoding="utf-8")

            cases = (
                (
                    "manifest leading digest",
                    artifact_record(
                        digest,
                        detector="PhraseAccessToken",
                        path=str(manifest),
                        line=1,
                    ),
                    "SHA-256 清单的哈希列",
                ),
                (
                    "different token elsewhere on a manifest line",
                    artifact_record(
                        different_digest,
                        detector="PhraseAccessToken",
                        path=str(manifest),
                        line=1,
                    ),
                    None,
                ),
                (
                    "swift symbol in executable location",
                    artifact_record(
                        "s7Owltype" + "SyntheticWitness",
                        detector="Box",
                        path=str(executable),
                    ),
                    "Swift 符号修饰",
                ),
            )

            for name, record, expected_waiver in cases:
                with self.subTest(name=name):
                    finding = POLICY.normalize_artifact_trufflehog(record)
                    self.assertIsNotNone(finding)
                    self.assertEqual(POLICY.decide(finding).waiver, expected_waiver)

    def test_adapter_ignores_only_json_log_records(self) -> None:
        self.assertIsNone(POLICY.normalize_history_trufflehog({"level": "info"}))
        self.assertIsNone(POLICY.normalize_artifact_trufflehog({"msg": "scanning"}))
        malformed_metadata = {"DetectorName": "Lob", "SourceMetadata": None}
        history = POLICY.normalize_history_trufflehog(malformed_metadata)
        artifact = POLICY.normalize_artifact_trufflehog(malformed_metadata)
        self.assertEqual(history.location, "commit_message")
        self.assertEqual(artifact.path, "unknown")

    def test_rejection_report_never_prints_raw_finding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            report = pathlib.Path(temporary_directory) / "findings.jsonl"
            report.write_text(
                json.dumps(history_record(SYNTHETIC_CREDENTIAL_SHAPE)) + "\n",
                encoding="utf-8",
            )
            completed = subprocess.run(
                [sys.executable, str(POLICY_PATH), "history", "trufflehog", str(report)],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertEqual(completed.returncode, 1)
        self.assertIn("potential secret found", completed.stderr)
        self.assertNotIn(SYNTHETIC_CREDENTIAL_SHAPE, completed.stdout + completed.stderr)

    def test_malformed_scanner_output_is_an_error_not_a_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            report = pathlib.Path(temporary_directory) / "findings.jsonl"
            report.write_text("synthetic malformed scanner output\n", encoding="utf-8")
            completed = subprocess.run(
                [sys.executable, str(POLICY_PATH), "history", "trufflehog", str(report)],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("invalid JSON", completed.stderr)
        self.assertNotIn("synthetic malformed scanner output", completed.stderr)


class PublicEnglishDictionaryTests(unittest.TestCase):
    def test_waives_only_exact_unverified_public_row_pair(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / 'Owltype.app/Contents/SharedSupport/msime/msime-english.db'
            path.parent.mkdir(parents=True)
            with sqlite3.connect(path) as db:
                db.execute('CREATE TABLE english_words(word TEXT, display TEXT, weight INTEGER)')
                db.execute('INSERT INTO english_words VALUES (?, ?, 1)', ('dictionary', 'dictionary'))
            raw = 'dictionary' * 2
            record = artifact_record(raw, detector='Eraser', path=str(path))
            record['Verified'] = False
            finding = POLICY.normalize_artifact_trufflehog(record)
            trusted = hashlib.sha256(path.read_bytes()).hexdigest()
            with patch.object(POLICY, 'PUBLIC_ENGLISH_DB_SHA256', trusted), \
                 patch.object(POLICY, 'PUBLIC_ENGLISH_PAIR_SHA256', hashlib.sha256(raw.encode()).hexdigest()):
                self.assertEqual(POLICY.decide(finding).waiver, '固定公开英文词库的词条列拼接')
                cases = [
                    {'source': 'history'},
                    {'scanner': 'gitleaks', 'detector': 'generic-api-key'},
                    {'detector': 'Other'},
                    {'detector': 'generic-api-key'},
                    {'verified': True},
                    {'verified': None},
                    {'raw': 'dictionary' + 'otherwords'},
                    {'path': str(path.with_name('other.db'))},
                    {'path': str(pathlib.Path(temporary) / 'msime-english.db')},
                ]
                for changes in cases:
                    with self.subTest(changes=sorted(changes)):
                        self.assertTrue(POLICY.decide(dataclasses.replace(finding, **changes)).rejected)
                for value in (None, 0, 'false'):
                    malformed = dict(record)
                    malformed['Verified'] = value
                    self.assertTrue(POLICY.decide(POLICY.normalize_artifact_trufflehog(malformed)).rejected)
                original = path.read_bytes()
                path.write_bytes(original + b'untrusted modification')
                self.assertTrue(POLICY.decide(finding).rejected, 'same path cannot waive a changed database')
                path.write_bytes(b'not a SQLite database')
                with patch.object(POLICY, 'PUBLIC_ENGLISH_DB_SHA256', hashlib.sha256(path.read_bytes()).hexdigest()):
                    self.assertTrue(POLICY.decide(finding).rejected, 'a digest alone cannot establish public database content')
                path.write_bytes(original)
                link = path.parent / 'link.app/Contents/SharedSupport/msime/msime-english.db'
                link.parent.mkdir(parents=True)
                link.symlink_to(path)
                self.assertTrue(POLICY.decide(dataclasses.replace(finding, path=str(link))).rejected)
                with sqlite3.connect(path) as db:
                    db.execute('UPDATE english_words SET display = ?', ('different',))
                changed = hashlib.sha256(path.read_bytes()).hexdigest()
                with patch.object(POLICY, 'PUBLIC_ENGLISH_DB_SHA256', changed):
                    self.assertTrue(POLICY.decide(finding).rejected, 'matching public word/display row is required')



class PublicSourceArchiveTests(unittest.TestCase):
    def source_fixture(self, temporary):
        import release_source
        root = pathlib.Path(temporary)
        repo = root / 'repo'; repo.mkdir()
        for name in ('LICENSE.txt', 'Makefile', 'THIRD_PARTY_NOTICES.md',
                     'Owltype.xcodeproj/project.pbxproj', 'rust/msime-source.json'):
            path = repo / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('public source fixture')
        subprocess.run(['git', '-C', str(repo), 'init', '-q'], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(repo), '-c', 'core.hooksPath=/dev/null',
            '-c', 'commit.gpgsign=false', '-c', 'user.name=SourceScanTest',
            '-c', 'user.email=source-scan@example.invalid', 'commit', '-qm', 'source fixture'],
            check=True, capture_output=True)
        revision = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        checker = POLICY.source_cohort_checker()
        output = root / 'output'; release = output / 'release'; release.mkdir(parents=True)
        source = root / 'stage/Owltype-macOS-9.8.7-source'
        release_source.stage_git_source(repo, revision, source)
        db = source / 'data/owl-rime/msime/msime-english.db'; db.parent.mkdir(parents=True)
        with sqlite3.connect(db) as connection:
            connection.execute('CREATE TABLE english_words(word TEXT, display TEXT, weight INTEGER)')
            connection.execute('INSERT INTO english_words VALUES (?, ?, 1)', ('dictionary', 'dictionary'))
        db.chmod(0o644)
        seed = output / 'Build/Products/Release/Owltype.app/Contents/SharedSupport'
        (seed / 'msime').mkdir(parents=True)
        shutil.copyfile(db, seed / 'msime/msime-english.db'); (seed / 'msime/msime-english.db').chmod(0o644)
        db_hash = hashlib.sha256(db.read_bytes()).hexdigest()
        app_manifest = release / 'OWLTYPE-FILE-MANIFEST.sha256'
        app_manifest.write_text(db_hash + '  Contents/SharedSupport/msime/msime-english.db\n')
        entries, submodules = release_source.git_source_snapshot(repo, revision)
        source_sha = release_source.tree_fingerprint(entries)
        seed_sha = release_source.tree_fingerprint(release_source.file_tree_snapshot(seed))
        cohort = {'schemaVersion': checker.COHORT_SCHEMA_VERSION, 'status': 'complete',
            'version': '9.8.7', 'buildVersion': '9.8.7', 'revision': revision,
            'sourceSha256': source_sha, 'seedSha256': seed_sha, 'submodules': submodules,
            'outputRootSha256': checker.output_root_fingerprint(output), 'buildAppSha256': 'a' * 64,
            'artifacts': {name: {'state': 'stapled'} for name in ('app', 'installer-pkg', 'update-pkg', 'dmg')}}
        cohort['cohortId'] = checker.cohort_identifier(revision, '9.8.7', '9.8.7',
            cohort['outputRootSha256'], cohort['buildAppSha256'], source_sha, seed_sha, submodules)
        (source / 'OWLTYPE-SOURCE-PROVENANCE.txt').write_text(
            'Owltype source release 9.8.7\nbuild-version 9.8.7\nroot ' + revision +
            '\ncohort ' + cohort['cohortId'] + '\nsource-tree ' + source_sha + '\nseed-tree ' + seed_sha +
            '\napp-manifest ' + checker.sha256(app_manifest) + '\n')
        manifest = source / 'OWLTYPE-SOURCE-MANIFEST.sha256'
        manifest.write_text(''.join(entry.sha256 + '  ' + name + '\n' for name, entry in
            sorted(release_source.file_tree_snapshot(source).items())))
        archive = release / (source.name + '.tar.gz')
        release_source.write_deterministic_archive(source, archive)
        digest = checker.sha256(archive)
        archive.with_name(archive.name + '.sha256').write_text(digest + '  ' + archive.name + '\n')
        cohort['outputs'] = {'source-archive': {'base': 'outputRoot', 'path': 'release/' + archive.name, 'sha256': digest}}
        (release / 'OWLTYPE-RELEASE-COHORT.json').write_text(json.dumps(cohort))
        raw = 'dictionary' * 2
        record = artifact_record(raw, detector='Eraser', path=str(db)); record['Verified'] = False
        return repo, archive, source, db_hash, raw, record

    def fixture_scope(self, repo, digest, raw):
        stack = contextlib.ExitStack()
        stack.enter_context(patch.object(POLICY.source_cohort_checker(), 'ROOT', repo))
        stack.enter_context(patch.object(POLICY, 'PUBLIC_ENGLISH_DB_SHA256', digest))
        stack.enter_context(patch.object(POLICY, 'PUBLIC_ENGLISH_PAIR_SHA256', hashlib.sha256(raw.encode()).hexdigest()))
        return stack

    def test_real_source_contract_is_required_in_addition_to_all_row_predicates(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo, archive, root, digest, raw, record = self.source_fixture(temporary)
            with self.fixture_scope(repo, digest, raw):
                record['source_archive_root'] = str(root)
                finding = POLICY.normalize_artifact_trufflehog(record)
                self.assertEqual(finding.source_archive_root, '', 'scanner JSON cannot assert trusted context')
                self.assertTrue(POLICY.decide(finding).rejected, 'source-shaped path alone is not evidence')
                context = POLICY.validated_source_scan_root(archive, root)
                self.assertEqual(context, root.resolve())
                trusted = dataclasses.replace(finding, source_archive_root=str(context))
                self.assertEqual(POLICY.decide(trusted).waiver, '固定公开英文词库的词条列拼接')
                for changes in ({'verified': True}, {'verified': None}, {'raw': 'dictionaryotherwords'},
                                {'detector': 'Other'}, {'detector': 'generic-api-key'},
                                {'source': 'history'}, {'path': str(root / 'other/msime-english.db')}):
                    with self.subTest(fields=sorted(changes)):
                        self.assertTrue(POLICY.decide(dataclasses.replace(trusted, **changes)).rejected)

    def test_forged_non_source_and_modified_contexts_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo, archive, root, digest, raw, record = self.source_fixture(temporary)
            with self.fixture_scope(repo, digest, raw):
                self.assertIsNone(POLICY.validated_source_scan_root(root / 'data/owl-rime/msime/msime-english.db', root))
                fake = pathlib.Path(temporary) / 'fake' / root.name; fake.mkdir(parents=True)
                self.assertIsNone(POLICY.validated_source_scan_root(archive, fake))
                manifest = root / 'OWLTYPE-SOURCE-MANIFEST.sha256'; original = manifest.read_bytes()
                manifest.write_bytes(original + b'forged metadata')
                self.assertIsNone(POLICY.validated_source_scan_root(archive, root))
                manifest.write_bytes(original)
                db = root / 'data/owl-rime/msime/msime-english.db'; original = db.read_bytes()
                db.write_bytes(original + b'modified DB')
                self.assertIsNone(POLICY.validated_source_scan_root(archive, root))
                db.write_bytes(original)
                cohort_file = archive.parent / 'OWLTYPE-RELEASE-COHORT.json'
                cohort = json.loads(cohort_file.read_text()); cohort['outputs']['source-archive']['sha256'] = '0' * 64
                cohort_file.write_text(json.dumps(cohort))
                self.assertIsNone(POLICY.validated_source_scan_root(archive, root))

    def test_source_policy_context_never_waives_other_findings(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo, archive, root, digest, raw, record = self.source_fixture(temporary)
            report = pathlib.Path(temporary) / 'scan.jsonl'
            report.write_text(json.dumps(record) + '\n')
            with self.fixture_scope(repo, digest, raw), contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(POLICY.run_policy('artifact', 'trufflehog', report, str(archive), root), 0)
                self.assertEqual(POLICY.run_policy('artifact', 'trufflehog', report, str(archive)), 1)
                other = artifact_record(synthetic_generic_api_key(), detector='generic-api-key', path=record['SourceMetadata']['Data']['Filesystem']['file'])
                report.write_text(json.dumps(record) + '\n' + json.dumps(other) + '\n')
                self.assertEqual(POLICY.run_policy('artifact', 'trufflehog', report, str(archive), root), 1)



class ShellAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary_directory.name)
        self.fake_bin = self.root / "bin"
        self.fake_bin.mkdir()
        self.artifact = self.root / "artifact"
        self.artifact.mkdir()
        self.source_file = self.artifact / "tests" / "SyntheticTests.swift"
        self.source_file.parent.mkdir()
        self.source_file.write_text("// synthetic\n", encoding="utf-8")
        self._write_fake_scanners()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _write_executable(self, name: str, body: str) -> None:
        path = self.fake_bin / name
        path.write_text(body, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def _write_fake_scanners(self) -> None:
        self._write_executable(
            "gitleaks",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -eu
                report=""
                for arg in "$@"; do
                  case "$arg" in
                    --report-path=*) report="${arg#--report-path=}" ;;
                    --exit-code=*) findings_status="${arg#--exit-code=}" ;;
                  esac
                done
                [[ -n "$report" ]]
                [[ -n "${findings_status:-}" ]]
                case "${FAKE_GITLEAKS_MODE:-clean}" in
                  clean) printf '[]' > "$report" ;;
                  detect_sentinel)
                    target="${2:?missing scan target}"
                    if grep -R -l -F "${FAKE_SECRET_SENTINEL:?}" "$target" >/dev/null 2>&1; then
                      printf '%s' "$FAKE_GITLEAKS_REPORT" > "$report"
                      exit "$findings_status"
                    fi
                    printf '[]' > "$report"
                    ;;
                  finding)
                    printf '%s' "$FAKE_GITLEAKS_REPORT" > "$report"
                    exit "$findings_status"
                    ;;
                  partial_error)
                    printf '%s' "$FAKE_GITLEAKS_REPORT" > "$report"
                    exit 1
                    ;;
                  error) exit 1 ;;
                  *) exit 97 ;;
                esac
                """
            ),
        )
        self._write_executable(
            "trufflehog",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -eu
                case "${FAKE_TRUFFLEHOG_MODE:-clean}" in
                  clean) exit 0 ;;
                  finding) printf '%s\n' "$FAKE_TRUFFLEHOG_REPORT" ;;
                  error)
                    printf 'synthetic scanner execution error\n' >&2
                    exit 24
                    ;;
                  *) exit 98 ;;
                esac
                """
            ),
        )

    def _run_gate(
        self,
        *arguments: str,
        gitleaks_mode: str = "clean",
        gitleaks_report: list[dict[str, Any]] | None = None,
        trufflehog_mode: str = "clean",
        trufflehog_report: dict[str, Any] | None = None,
        secret_sentinel: str = "",
        use_real_gitleaks: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        scanner_bin = self.fake_bin
        if use_real_gitleaks:
            real_gitleaks = shutil.which("gitleaks", path=environment["PATH"])
            if real_gitleaks is None:
                self.skipTest("real Gitleaks is required for config integration coverage")
            scanner_bin = self.root / "real-gitleaks-bin"
            scanner_bin.mkdir(exist_ok=True)
            (scanner_bin / "gitleaks").symlink_to(real_gitleaks)
            (scanner_bin / "trufflehog").symlink_to(self.fake_bin / "trufflehog")
        environment["PATH"] = f"{scanner_bin}{os.pathsep}{environment['PATH']}"
        environment["FAKE_GITLEAKS_MODE"] = gitleaks_mode
        environment["FAKE_GITLEAKS_REPORT"] = json.dumps(gitleaks_report or [])
        environment["FAKE_TRUFFLEHOG_MODE"] = trufflehog_mode
        environment["FAKE_TRUFFLEHOG_REPORT"] = json.dumps(trufflehog_report or {})
        environment["FAKE_SECRET_SENTINEL"] = secret_sentinel
        return subprocess.run(
            ["bash", str(SCRIPT_DIR / "check-secrets.sh"), *arguments],
            cwd=REPO_ROOT,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )

    def _source_archive_with(self, relative_path: str, contents: str) -> pathlib.Path:
        source_root = self.root / ("source-" + secrets.token_hex(4))
        source_file = source_root / relative_path
        source_file.parent.mkdir(parents=True)
        source_file.write_text(contents, encoding="utf-8")
        source_archive = source_root.with_suffix(".tar.gz")
        with tarfile.open(source_archive, "w:gz") as archive:
            archive.add(source_root, arcname="Owltype-macOS-9.8.7-source")
        return source_archive

    def test_gitleaks_nonzero_distinguishes_finding_from_scan_error(self) -> None:
        finding = self._run_gate(
            gitleaks_mode="finding",
            gitleaks_report=[{"RuleID": "synthetic-rule", "File": "tests/Fake.swift"}],
        )
        self.assertEqual(finding.returncode, 1)
        self.assertIn("potential secret found: scanner=gitleaks", finding.stderr)
        self.assertNotIn("scan failed", finding.stderr)

        error = self._run_gate(gitleaks_mode="error")
        self.assertEqual(error.returncode, 1)
        self.assertIn("Gitleaks scan failed", error.stderr)
        self.assertNotIn("potential secret found", error.stderr)

        partial_error = self._run_gate(
            gitleaks_mode="partial_error",
            gitleaks_report=[{"RuleID": "synthetic-rule", "File": "tests/Fake.swift"}],
        )
        self.assertEqual(partial_error.returncode, 1)
        self.assertIn("Gitleaks scan failed", partial_error.stderr)
        self.assertNotIn("potential secret found", partial_error.stderr)

    def test_trufflehog_finding_and_scan_error_are_separate_failures(self) -> None:
        finding = self._run_gate(
            trufflehog_mode="finding",
            trufflehog_report=history_record(SYNTHETIC_CREDENTIAL_SHAPE),
        )
        self.assertEqual(finding.returncode, 1)
        self.assertIn("potential secret found: scanner=trufflehog", finding.stderr)
        self.assertNotIn(SYNTHETIC_CREDENTIAL_SHAPE, finding.stdout + finding.stderr)
        self.assertNotIn("scan error", finding.stderr)

        error = self._run_gate(trufflehog_mode="error")
        self.assertEqual(error.returncode, 24)
        self.assertIn("treat as a scan error", error.stderr)
        self.assertNotIn("potential secret found", error.stderr)

    def test_same_lob_identifier_passes_both_shell_adapters(self) -> None:
        history = self._run_gate(
            trufflehog_mode="finding",
            trufflehog_report=history_record(SYNTHETIC_LOB_IDENTIFIER),
        )
        self.assertEqual(history.returncode, 0, history.stderr)
        self.assertIn("Lob 撞测试函数名 1 条", history.stdout)

        artifact = self._run_gate(
            "--artifacts",
            str(self.artifact),
            trufflehog_mode="finding",
            trufflehog_report=artifact_record(
                SYNTHETIC_LOB_IDENTIFIER,
                path=str(self.source_file),
            ),
        )
        self.assertEqual(artifact.returncode, 0, artifact.stderr)
        self.assertIn("Lob 撞测试函数名 1 条", artifact.stdout)

    def test_source_archive_uses_the_shared_artifact_policy(self) -> None:
        source_archive = self.root / "Owltype-macOS-9.8.7-source.tar.gz"
        with tarfile.open(source_archive, "w:gz") as archive:
            archive.add(self.artifact, arcname="Owltype-macOS-9.8.7-source")

        completed = self._run_gate(
            "--artifacts",
            str(source_archive),
            trufflehog_mode="finding",
            trufflehog_report=artifact_record(
                SYNTHETIC_LOB_IDENTIFIER,
                path="Owltype-macOS-9.8.7-source/scripts/policy.selftest.py",
            ),
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("Lob 撞测试函数名 1 条", completed.stdout)
        self.assertIn(str(source_archive), completed.stdout)

    def test_source_archive_allows_the_published_sparkle_public_key(self) -> None:
        documented_public_key = next(
            line
            for line in (REPO_ROOT / "scripts" / "sparkle-key-transition.selftest.py")
            .read_text(encoding="utf-8")
            .splitlines()
            if line.startswith("NEW_KEY = ")
        )
        source_archive = self._source_archive_with(
            "scripts/sparkle-key-transition.selftest.py",
            documented_public_key + "\n",
        )

        completed = self._run_gate(
            "--artifacts",
            str(source_archive),
            use_real_gitleaks=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_source_archive_still_rejects_a_generic_api_key(self) -> None:
        synthetic_key = synthetic_generic_api_key()
        source_archive = self._source_archive_with(
            "config/runtime.env",
            f'api_key = "{synthetic_key}"\n',
        )

        completed = self._run_gate(
            "--artifacts",
            str(source_archive),
            use_real_gitleaks=True,
        )

        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertIn("rule=generic-api-key", completed.stderr)
        self.assertNotIn(synthetic_key, completed.stdout + completed.stderr)

    def test_public_key_marker_does_not_waive_a_generic_api_key_on_the_same_line(
        self,
    ) -> None:
        synthetic_key = synthetic_generic_api_key()
        documented_public_key = next(
            line
            for line in (REPO_ROOT / "scripts" / "sparkle-key-transition.selftest.py")
            .read_text(encoding="utf-8")
            .splitlines()
            if line.startswith("NEW_KEY = ")
        )
        source_archive = self._source_archive_with(
            "scripts/sparkle-key-transition.selftest.py",
            f'{documented_public_key} api_key = "{synthetic_key}"\n',
        )

        completed = self._run_gate(
            "--artifacts",
            str(source_archive),
            use_real_gitleaks=True,
        )

        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertIn("rule=generic-api-key", completed.stderr)
        self.assertNotIn(synthetic_key, completed.stdout + completed.stderr)

    def test_source_archive_rejects_unsafe_members_before_scanning(self) -> None:
        cases = ("traversal", "symlink")
        for member_type in cases:
            with self.subTest(member_type=member_type):
                source_archive = self.root / f"unsafe-{member_type}.tar.gz"
                with tarfile.open(source_archive, "w:gz") as archive:
                    member = tarfile.TarInfo(
                        "../outside" if member_type == "traversal" else "source/link"
                    )
                    if member_type == "traversal":
                        payload = b"unsafe fixture"
                        member.size = len(payload)
                        import io

                        archive.addfile(member, io.BytesIO(payload))
                    else:
                        member.type = tarfile.SYMTYPE
                        member.linkname = "/tmp/outside"
                        archive.addfile(member)
                completed = self._run_gate("--artifacts", str(source_archive))
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("ERROR:", completed.stderr)
                self.assertFalse((self.root.parent / "outside").exists())

    def test_artifact_non_source_identifier_is_rejected(self) -> None:
        configuration = self.artifact / "runtime.env"
        configuration.write_text("synthetic\n", encoding="utf-8")
        completed = self._run_gate(
            "--artifacts",
            str(self.artifact),
            trufflehog_mode="finding",
            trufflehog_report=artifact_record(
                SYNTHETIC_LOB_IDENTIFIER,
                path=str(configuration),
            ),
        )
        self.assertEqual(completed.returncode, 1)
        self.assertIn("potential secret found in artifact", completed.stderr)
        self.assertNotIn(SYNTHETIC_LOB_IDENTIFIER, completed.stdout + completed.stderr)

    def test_artifact_scan_error_is_not_reported_as_a_finding(self) -> None:
        completed = self._run_gate(
            "--artifacts",
            str(self.artifact),
            trufflehog_mode="error",
        )
        self.assertEqual(completed.returncode, 24)
        self.assertIn("failed to scan", completed.stderr)
        self.assertNotIn("potential secret found", completed.stderr)

    def test_partial_package_expansion_uses_registration_cleanup(self) -> None:
        package = self.root / "partial.pkg"
        package.write_bytes(b"synthetic")
        marker = self.root / "cleanup-observed"
        expander = self.root / "partial-expand"
        expander.write_text('#!/bin/bash\nmkdir -p "$3/Partial.app"\nexit 42\n')
        expander.chmod(0o700)
        cleanup = self.root / "cleanup.py"
        cleanup.write_text(
            "import pathlib, shutil, sys\n"
            "root = pathlib.Path(sys.argv[2])\n"
            "assert (root / '0-pkg/Partial.app').is_dir()\n"
            f"pathlib.Path({str(marker)!r}).write_text('checked before deletion')\n"
            "shutil.rmtree(root)\n"
        )
        source = (SCRIPT_DIR / "check-artifact-secrets.sh").read_text()
        source = source.replace('/usr/sbin/pkgutil', str(expander))
        source = source.replace('$repo_root/scripts/cleanup_app_registrations.py', str(cleanup))
        runner = self.root / "artifact-gate.sh"
        runner.write_text(source)
        environment = os.environ.copy()
        environment['PATH'] = str(self.fake_bin) + os.pathsep + environment['PATH']
        result = subprocess.run(['bash', str(runner), str(package)],
                                env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 70)
        self.assertTrue(marker.is_file(), 'partial App tree must use checked cleanup')

    def test_failed_detach_retains_tree_before_any_removal(self) -> None:
        image = self.root / 'synthetic.dmg'
        image.touch()
        mounted = self.root / 'mounted-path'
        removed = self.root / 'removal-attempted'
        self._write_executable('hdiutil', '#!/bin/bash\n'
                               'if [[ "$1" == attach ]]; then printf "%s" "$5" > "$MOUNTED_PATH"; exit 0; fi\n'
                               'exit 23\n')
        self._write_executable('ditto', '#!/bin/bash\nmkdir -p "$2"\n')
        normalizer = self.root / 'normalize.py'
        normalizer.write_text('pass\n')
        cleanup = self.root / 'cleanup.py'
        cleanup.write_text('import pathlib, shutil, sys\n'
                           f'pathlib.Path({str(removed)!r}).touch()\n'
                           'shutil.rmtree(sys.argv[2])\n')
        source = (SCRIPT_DIR / 'check-artifact-secrets.sh').read_text()
        source = source.replace('/usr/bin/hdiutil', str(self.fake_bin / 'hdiutil'))
        source = source.replace('/usr/bin/ditto', str(self.fake_bin / 'ditto'))
        source = source.replace('$repo_root/scripts/normalize-package-scan.py', str(normalizer))
        source = source.replace('$repo_root/scripts/cleanup_app_registrations.py', str(cleanup))
        runner = self.root / 'artifact-gate.sh'
        runner.write_text(source)
        environment = os.environ.copy()
        environment.update(PATH=str(self.fake_bin) + os.pathsep + environment['PATH'],
                           MOUNTED_PATH=str(mounted), FAKE_GITLEAKS_MODE='error')
        result = subprocess.run(['bash', str(runner), str(image)],
                                env=environment, capture_output=True, text=True)
        retained = pathlib.Path(mounted.read_text()).parent
        try:
            self.assertEqual(result.returncode, 70)
            self.assertTrue(retained.is_dir())
            self.assertFalse(removed.exists(), 'failed detach forbids tree removal')
        finally:
            shutil.rmtree(retained, ignore_errors=True)  # The mount is synthetic only.

    @unittest.skipUnless(
        sys.platform == "darwin",
        "PKG and DMG adapter coverage requires macOS packaging tools",
    )
    def test_real_pkg_and_dmg_contents_are_scanned_and_dmg_is_detached(self) -> None:
        sentinel = "OWLTYPE" + "_SECRET_SENTINEL_" + "A" * 24
        finding = [{"RuleID": "synthetic-container-secret", "File": "runtime.env"}]

        pkg_root = self.root / "pkg-root"
        pkg_app = self.root / "archive-source" / "Owltype.app"
        pkg_secret = pkg_app / "Contents" / "Resources" / "runtime.env"
        pkg_secret.parent.mkdir(parents=True)
        pkg_secret.write_text(f"credential={sentinel}\n", encoding="utf-8")
        (pkg_app / "Contents/Info.plist").write_text("fixture")
        (pkg_app / "Contents/MacOS").mkdir()
        (pkg_app / "Contents/MacOS/Owltype").write_text("fixture executable")
        archive = pkg_root / "Library/Input Methods/.Owltype.pkg-staging/Owltype.app.zip"
        archive.parent.mkdir(parents=True)
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", str(pkg_app), str(archive)],
                       check=True, capture_output=True)
        component = self.root / "Owltype-component.pkg"
        distribution = self.root / "Distribution.xml"
        product_pkg = self.root / "Owltype.pkg"
        subprocess.run(
            [
                "/usr/bin/pkgbuild",
                "--root",
                str(pkg_root),
                "--identifier",
                "im.owltype.secret-selftest",
                "--version",
                "1",
                "--install-location",
                "/",
                str(component),
            ],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            [
                "/usr/bin/productbuild",
                "--synthesize",
                "--package",
                str(component),
                str(distribution),
            ],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            [
                "/usr/bin/productbuild",
                "--distribution",
                str(distribution),
                "--package-path",
                str(self.root),
                str(product_pkg),
            ],
            check=True,
            capture_output=True,
        )

        pkg_result = self._run_gate(
            "--artifacts",
            str(product_pkg),
            gitleaks_mode="detect_sentinel",
            gitleaks_report=finding,
            secret_sentinel=sentinel,
        )
        self.assertEqual(pkg_result.returncode, 1, pkg_result.stderr)
        self.assertIn("potential secret found in artifact", pkg_result.stderr)
        self.assertNotIn(sentinel, pkg_result.stdout + pkg_result.stderr)

        dmg_root = self.root / "dmg-root"
        installer_secret = (
            dmg_root / "OwltypeInstaller.app" / "Contents" / "Resources" / "runtime.env"
        )
        installer_secret.parent.mkdir(parents=True)
        installer_secret.write_text(f"credential={sentinel}\n", encoding="utf-8")
        dmg = self.root / "Owltype-9.8.7.dmg"
        subprocess.run(
            [
                "/usr/bin/hdiutil",
                "create",
                "-volname",
                "OwlSecretSelfTest",
                "-srcfolder",
                str(dmg_root),
                "-ov",
                "-format",
                "UDZO",
                str(dmg),
            ],
            check=True,
            capture_output=True,
        )

        dmg_result = self._run_gate(
            "--artifacts",
            str(dmg),
            gitleaks_mode="detect_sentinel",
            gitleaks_report=finding,
            secret_sentinel=sentinel,
        )
        self.assertEqual(dmg_result.returncode, 1, dmg_result.stderr)
        self.assertIn("potential secret found in artifact", dmg_result.stderr)
        self.assertNotIn(sentinel, dmg_result.stdout + dmg_result.stderr)
        attached_images = subprocess.check_output(["/usr/bin/hdiutil", "info", "-plist"])
        self.assertNotIn(str(dmg).encode(), attached_images)


if __name__ == "__main__":
    unittest.main(verbosity=2)
