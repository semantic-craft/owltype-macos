#!/usr/bin/env python3
"""Exercise verification receipts through the CLI in disposable Git repositories."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='owl-verify-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'repo'
        self.root.mkdir()
        (self.root / 'scripts').mkdir()
        shutil.copy(Path(__file__).with_name('verify.py'), self.root / 'scripts/verify.py')
        for name in ('check-navigation.py', 'check-navigation.selftest.py'):
            (self.root / 'scripts' / name).write_text('print("checked")\n')
        self.git('init', '-q')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@users.noreply.github.com',
                 'commit', '-qm', 'fixture')
        self.records = Path(self.temp.name) / 'records'

    def add_submodule(self):
        upstream = Path(self.temp.name) / 'upstream'
        upstream.mkdir()
        (upstream / 'vendored.txt').write_text('vendored\n')
        for command in (['init', '-q'], ['add', '.'], ['commit', '-qm', 'vendored']):
            subprocess.check_call(['git', '-c', 'user.name=Fixture',
                                   '-c', 'user.email=fixture@users.noreply.github.com', *command],
                                  cwd=upstream)
        self.git('-c', 'protocol.file.allow=always', 'submodule', 'add', '--quiet', str(upstream), 'vendor')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@users.noreply.github.com',
                 'commit', '-qm', 'vendor submodule')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True).strip()

    def run_check(self, *arguments, env=None):
        result = subprocess.run(
            [sys.executable, str(self.root / 'scripts/verify.py'), *(arguments or ('navigation',))],
            cwd=self.root, env={**os.environ, 'OWL_VERIFICATION_DIR': str(self.records), **(env or {})},
            capture_output=True, text=True,
        )
        receipts = list(self.records.glob('*/result.json'))
        self.assertEqual(len(receipts), 1, result.stdout + result.stderr)
        return result, json.loads(receipts[0].read_text()), receipts[0].parent

    def test_success_records_revision_commands_logs_and_limits(self):
        result, receipt, folder = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(receipt['status'], 'passed')
        self.assertEqual(receipt['before']['head'], self.git('rev-parse', 'HEAD'))
        self.assertTrue(receipt['source_unchanged'])
        self.assertEqual([step['exit_code'] for step in receipt['steps']], [0, 0])
        self.assertIn('installed input-method acceptance', receipt['not_covered'])
        self.assertIn('checked', (folder / '01.log').read_text())
        self.assertTrue((folder / 'summary.md').is_file())

    def test_failed_command_keeps_exit_status_and_marks_remaining_checks_not_run(self):
        (self.root / 'scripts/check-navigation.selftest.py').write_text('raise SystemExit(7)\n')
        result, receipt, _ = self.run_check()
        self.assertEqual(result.returncode, 7)
        self.assertEqual(receipt['status'], 'failed')
        self.assertEqual(receipt['steps'][1]['status'], 'not-run')

    def test_edit_during_check_cannot_be_reported_as_pass(self):
        (self.root / 'scripts/check-navigation.py').write_text(
            'from pathlib import Path\nPath("new-source.txt").write_text("changed")\n')
        result, receipt, _ = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(receipt['status'], 'source-changed')
        self.assertFalse(receipt['source_unchanged'])

    def test_submodule_initialization_during_check_is_not_a_source_change(self):
        self.add_submodule()
        self.git('submodule', 'deinit', '--force', '--', 'vendor')
        self.assertFalse((self.root / 'vendor/.git').exists())
        (self.root / 'scripts/check-navigation.py').write_text(
            'import subprocess\nsubprocess.run(["git", "-c", "protocol.file.allow=always", '
            '"submodule", "update", "--init", "--recursive"], check=True)\n')
        result, receipt, _ = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(receipt['status'], 'passed')
        self.assertTrue((self.root / 'vendor/.git').exists())
        self.assertEqual(receipt['before']['submodules'], {'vendor': 'pinned'})
        self.assertEqual(receipt['after']['submodules'], {'vendor': 'pinned'})

    def test_edit_inside_a_submodule_during_check_is_a_source_change(self):
        self.add_submodule()
        (self.root / 'scripts/check-navigation.py').write_text(
            'from pathlib import Path\nPath("vendor/vendored.txt").write_text("changed")\n')
        result, receipt, _ = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(receipt['status'], 'source-changed')
        self.assertEqual(receipt['before']['submodules'], {'vendor': 'pinned'})
        self.assertEqual(receipt['after']['submodules']['vendor']['status'], ' M vendored.txt\n')

    def test_unknown_swift_selection_is_rejected_before_building(self):
        result = subprocess.run(
            [sys.executable, str(self.root / 'scripts/verify.py'), 'swift', '--test', 'MissingTests'],
            cwd=self.root, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn('unknown test', result.stderr)

    def test_runner_preserves_command_umask_and_keeps_receipts_private(self):
        (self.root / 'scripts/check-navigation.py').write_text('import os\nprint(oct(os.umask(0)))\n')
        current = os.umask(0)
        os.umask(current)
        result, _, folder = self.run_check()
        self.assertEqual(result.returncode, 0)
        self.assertEqual((folder / '02.log').read_text().strip(), oct(current))
        self.assertEqual(folder.stat().st_mode & 0o777, 0o700)

    def test_mixed_swift_selection_requires_evidence_for_each_case(self):
        (self.root / 'tests').mkdir()
        (self.root / 'tests/FixtureTests.swift').write_text(
            'class FixtureTests { func testOne() {} func testTwo() {} }')
        (self.root / 'Makefile').write_text('# fixture\n')
        adapters = Path(self.temp.name) / 'bin'
        adapters.mkdir()
        adapter = adapters / 'make'
        adapter.write_text("#!/bin/sh\necho \"Test Case '-[OwltypeTests.FixtureTests testOne]' passed (0.01 seconds).\"\n")
        adapter.chmod(0o755)
        result, receipt, _ = self.run_check(
            'swift', '--test', 'FixtureTests/testOne', '--test', 'FixtureTests/testTwo',
            env={'PATH': str(adapters) + os.pathsep + os.environ['PATH']})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(receipt['steps'][0]['unverified_tests'], ['FixtureTests/testTwo'])

    def test_swift_dispatches_settings_ui_to_its_own_scheme_and_checks_its_receipt(self):
        (self.root / 'tests').mkdir()
        (self.root / 'tests/OwlSettingsUITests.swift').write_text(
            'class OwlSettingsUITests { func testNavigation() {} }')
        (self.root / 'Makefile').write_text('# fixture\n')
        adapters = Path(self.temp.name) / 'bin'
        adapters.mkdir()
        make = adapters / 'make'
        make.write_text('#!/bin/sh\ntest "$1" = deps\n')
        make.chmod(0o755)
        xcodebuild = adapters / 'xcodebuild'
        xcodebuild.write_text(
            '#!/bin/sh\n'
            'case "$*" in *"-scheme OwltypeUITests"*"-only-testing:OwltypeUITests/OwlSettingsUITests/testNavigation") '
            """echo "Test Case '-[OwltypeUITests.OwlSettingsUITests testNavigation]' passed (0.01 seconds)." ;; """
            '*) exit 9 ;; esac\n')
        xcodebuild.chmod(0o755)
        result, receipt, _ = self.run_check(
            'swift', '--test', 'OwlSettingsUITests/testNavigation',
            env={'PATH': str(adapters) + os.pathsep + os.environ['PATH']})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([step['status'] for step in receipt['steps']], ['passed', 'passed'])

    def test_gate_initializes_submodules_before_any_check_reads_the_tree(self):
        shutil.copy(Path(__file__).with_name('gate.sh'), self.root / 'scripts/gate.sh')
        for mode in ([], ['--quick']):
            stages = subprocess.check_output(['bash', 'scripts/gate.sh', '--list-stages', *mode],
                                             cwd=self.root, text=True).split()
            self.assertEqual(stages[:2], ['tools', 'submodules'], stages)
            self.assertIn('portable_scripts', stages)

    def test_gate_failure_records_completed_failed_and_unrun_stages(self):
        shutil.copy(Path(__file__).with_name('gate.sh'), self.root / 'scripts/gate.sh')
        (self.root / 'scripts/check-public-source.sh').write_text('exit 9\n')
        adapters = Path(self.temp.name) / 'bin'
        adapters.mkdir()
        for name in ('gitleaks', 'trufflehog', 'swiftlint', 'xcodegen'):
            adapter = adapters / name
            adapter.write_text('#!/bin/sh\nexit 0\n')
            adapter.chmod(0o755)
        result, receipt, _ = self.run_check('full', env={'PATH': str(adapters) + os.pathsep + os.environ['PATH']})
        self.assertEqual(result.returncode, 9)
        stages = receipt['gate_stages']
        failed = [stage['name'] for stage in stages].index('source_boundary')
        self.assertEqual({stage['status'] for stage in stages[:failed]}, {'passed'})
        self.assertEqual(stages[failed]['status'], 'failed')
        self.assertTrue(all(stage['status'] == 'not-run' for stage in stages[failed + 1:]))
        self.assertGreaterEqual(stages[failed]['elapsed_seconds'], 0)

    def test_interrupt_stops_descendants_even_when_leader_exits_first(self):
        pidfile = Path(self.temp.name) / 'child.pid'
        child = ('import os,signal,time; from pathlib import Path; '
                 'signal.signal(signal.SIGTERM,signal.SIG_IGN); '
                 f'Path({str(pidfile)!r}).write_text(str(os.getpid())); time.sleep(60)')
        (self.root / 'scripts/check-navigation.selftest.py').write_text(
            f'import subprocess,sys\nsubprocess.Popen([sys.executable,"-c",{child!r}]).wait()\n')
        process = subprocess.Popen(
            [sys.executable, str(self.root / 'scripts/verify.py'), 'navigation'],
            cwd=self.root, env={**os.environ, 'OWL_VERIFICATION_DIR': str(self.records)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        pid = None
        try:
            deadline = time.monotonic() + 10
            while not pidfile.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(pidfile.exists())
            pid = int(pidfile.read_text())
            process.terminate()
            process.communicate(timeout=10)
            self.assertEqual(process.returncode, 130)
            receipt = json.loads(next(self.records.glob('*/result.json')).read_text())
            self.assertEqual(receipt['status'], 'interrupted')
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
            else:
                self.fail('check descendant survived interruption')
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            if pid is not None:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


if __name__ == '__main__':
    unittest.main()
