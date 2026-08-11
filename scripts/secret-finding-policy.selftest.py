#!/usr/bin/env python3
"""Table-driven tests for the shared secret finding policy and shell adapters.

Every finding and scanner executable is synthetic and lives in a temporary
directory. Container tests use unsigned system packaging tools, but never real
credentials, signing identities, notarization, or Keychain state.
"""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import stat
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest
from typing import Any


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
            manifest = root / "FAMOTYPE-FILE-MANIFEST.sha256"
            manifest.write_text(f"{digest}  ./Famo\n", encoding="utf-8")
            executable = root / "MacOS" / "Famo"
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
                        "s4Famo" + "SyntheticWitness",
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
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PATH"] = f"{self.fake_bin}{os.pathsep}{environment['PATH']}"
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
        source_archive = self.root / "Famotype-macOS-9.8.7-source.tar.gz"
        with tarfile.open(source_archive, "w:gz") as archive:
            archive.add(self.artifact, arcname="Famotype-macOS-9.8.7-source")

        completed = self._run_gate(
            "--artifacts",
            str(source_archive),
            trufflehog_mode="finding",
            trufflehog_report=artifact_record(
                SYNTHETIC_LOB_IDENTIFIER,
                path="Famotype-macOS-9.8.7-source/scripts/policy.selftest.py",
            ),
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("Lob 撞测试函数名 1 条", completed.stdout)
        self.assertIn(str(source_archive), completed.stdout)

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

    def test_real_pkg_and_dmg_contents_are_scanned_and_dmg_is_detached(self) -> None:
        sentinel = "FAMOTYPE" + "_SECRET_SENTINEL_" + "A" * 24
        finding = [{"RuleID": "synthetic-container-secret", "File": "runtime.env"}]

        pkg_root = self.root / "pkg-root"
        pkg_secret = pkg_root / "Famo.app" / "Contents" / "Resources" / "runtime.env"
        pkg_secret.parent.mkdir(parents=True)
        pkg_secret.write_text(f"credential={sentinel}\n", encoding="utf-8")
        component = self.root / "Famo-component.pkg"
        distribution = self.root / "Distribution.xml"
        product_pkg = self.root / "Famo.pkg"
        subprocess.run(
            [
                "/usr/bin/pkgbuild",
                "--root",
                str(pkg_root),
                "--identifier",
                "im.famo.secret-selftest",
                "--version",
                "1",
                "--install-location",
                "/Library/Input Methods",
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
            dmg_root / "FamoInstaller.app" / "Contents" / "Resources" / "runtime.env"
        )
        installer_secret.parent.mkdir(parents=True)
        installer_secret.write_text(f"credential={sentinel}\n", encoding="utf-8")
        dmg = self.root / "Famo-9.8.7.dmg"
        subprocess.run(
            [
                "/usr/bin/hdiutil",
                "create",
                "-volname",
                "FamoSecretSelfTest",
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
