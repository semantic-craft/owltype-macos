#!/usr/bin/env python3
"""Offline regressions: no live commands, system writes, or input-source changes."""
import copy
import importlib.util
import io
from contextlib import redirect_stdout
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('live_probe', Path(__file__).with_name('check-live-ime-version.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

# Shape captured from lsappinfo on this host; synthetic PID and deliberately
# different marketing/build versions prevent accidentally checking the wrong key.
LS = '''[ NULL ] ASN:0x0-0x123:
    bundleID=[ NULL ]
    bundle path="/Library/Input Methods/Owltype.app"
    executable path="/Library/Input Methods/Owltype.app/Contents/MacOS/Owltype"
    pid = 123 !cgsConnection !signalled type=[ NULL ] flavor=[ NULL ] Version="212" Arch=!!none
'''
SOURCE = 'im.owltype.inputmethod.Owltype.Hans'


def fixture():
    disk = {'version': '212', 'marketing_version': '2.0.12', 'inode': 10}
    return {'errors': [], 'disk_before': disk, 'disk_after': copy.deepcopy(disk),
            'pids': ['123'], 'final_pids': ['123'], 'inode_check_rc': 0, 'source': SOURCE,
            'observed_at': 120, 'finished_at': 125,
            'processes': [{'pid': '123', 'pgrep_path': str(probe.EXE),
                           'command': str(probe.EXE), 'started_at': 110,
                           'ls': probe.ls_identity(LS)}]}


class LiveVersionTests(unittest.TestCase):
    def verdict(self, data):
        return probe.assess(data, '212', 100, 115, SOURCE)

    def test_current_version_passes(self):
        self.assertEqual(self.verdict(fixture()), [])

    def test_same_path_old_inode_fails(self):
        data = fixture()
        data['inode_check_rc'] = 1
        self.assertTrue(self.verdict(data))

    def test_old_start_and_same_second_are_not_new_process_proof(self):
        for start in (99, 100):
            with self.subTest(start=start):
                data = fixture()
                data['processes'][0]['started_at'] = start
                self.assertTrue(self.verdict(data))

    def test_shadow_or_old_moved_bundle_rejected(self):
        for path in ('/tmp/Owltype.app/Contents/MacOS/Owltype',
                     '/Library/Input Methods/.Owltype.app.old/Contents/MacOS/Owltype'):
            for key in ('pgrep_path', 'command'):
                with self.subTest(path=path, key=key):
                    data = fixture()
                    data['processes'][0][key] = path
                    self.assertTrue(self.verdict(data))

    def test_three_versions_must_match(self):
        for side in ('disk', 'ls', 'both'):
            with self.subTest(side=side):
                data = fixture()
                if side in ('disk', 'both'):
                    data['disk_before']['version'] = '211'
                    data['disk_after']['version'] = '211'
                if side in ('ls', 'both'):
                    data['processes'][0]['ls']['version'] = '211'
                self.assertTrue(self.verdict(data))

    def test_marketing_version_is_not_build(self):
        data = fixture()
        self.assertTrue(probe.assess(data, '2.0.12', 100, 115, SOURCE))

    def test_wrong_ls_identity_rejected(self):
        for key in ('pid', 'bundle', 'executable'):
            with self.subTest(key=key):
                data = fixture()
                data['processes'][0]['ls'][key] = 'other'
                self.assertTrue(self.verdict(data))

    def test_absent_multiple_or_churning_processes_rejected(self):
        for pids, final in (([], []), (['123', '124'], ['123', '124']), (['123'], ['124'])):
            with self.subTest(pids=pids, final=final):
                data = fixture()
                data['pids'], data['final_pids'] = pids, final
                self.assertTrue(self.verdict(data))

    def test_bundle_changed_mid_capture_rejected(self):
        data = fixture()
        data['disk_after']['inode'] = 11
        self.assertTrue(self.verdict(data))

    def test_missing_process_evidence_rejected(self):
        data = fixture()
        data['processes'] = []
        self.assertTrue(self.verdict(data))

    def test_selected_source_preserved_without_requiring_owltype(self):
        data = fixture()
        data['source'] = 'com.apple.keylayout.US'
        self.assertTrue(self.verdict(data))
        self.assertEqual(probe.assess(data, '212', 100, 115, data['source']), [])

    def test_unreadable_source_rejected(self):
        data = fixture()
        data['source'] = ''
        self.assertTrue(probe.assess(data))

    def test_sixty_second_deadline_and_invalid_times(self):
        data = fixture()
        data['finished_at'] = 175
        self.assertEqual(self.verdict(data), [])
        data['finished_at'] = 175.01
        self.assertTrue(self.verdict(data))
        self.assertTrue(probe.assess(fixture(), '212', 119, 115))
        self.assertTrue(probe.assess(fixture(), '212', 100, 121))

    def test_ps_utc_timestamp(self):
        self.assertEqual(probe.process_start(' Thu Jan  1 00:01:50 1970\n'), 110)
        with self.assertRaises(ValueError):
            probe.process_start('')

    def test_missing_or_ambiguous_ls_fields_fail_closed(self):
        for text in ('', 'ASN:0x0-0x123: Version="212"', LS + LS,
                     LS.replace('Version="212"', 'Version=[ NULL ]')):
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    probe.ls_identity(text)

    def test_positive_finite_timestamps_required(self):
        for value in ('nan', 'inf', '-1', '0'):
            with self.subTest(value=value), self.assertRaises(Exception):
                probe.epoch(value)

    def test_subprocess_timeout_and_error_fail_closed(self):
        for error in (subprocess.TimeoutExpired('fixture', 5), FileNotFoundError('fixture')):
            with self.subTest(error=error), patch.object(probe.subprocess, 'run', side_effect=error):
                capture = probe.Capture()
                with redirect_stdout(io.StringIO()):
                    rc, _ = capture.run(['fixture'])
                self.assertNotEqual(rc, 0)
                self.assertTrue(capture.errors)

    def test_budget_does_not_run_late_command(self):
        capture = probe.Capture()
        capture.deadline = 0
        with patch.object(probe.subprocess, 'run') as run, redirect_stdout(io.StringIO()):
            self.assertNotEqual(capture.run(['fixture'])[0], 0)
        run.assert_not_called()

    def test_real_collection_routes_only_read_only_commands(self):
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            self.assertEqual(kwargs['env']['LC_ALL'], 'C')
            self.assertEqual(kwargs['env']['TZ'], 'UTC')
            output = ''
            if argv[:3] == ['/usr/bin/pgrep', '-lf', 'Owltype']:
                output = f'123 {probe.EXE}\n'
            elif argv[0] == '/usr/bin/pgrep':
                output = '123\n'
            elif argv[0] == '/bin/ps':
                output = 'Thu Jan  1 00:01:50 1970' if argv[-1] == 'lstart=' else str(probe.EXE)
            elif argv[0] == '/usr/bin/lsappinfo':
                output = LS
            elif argv[0] == str(probe.EXE):
                self.assertEqual(argv[1:], ['--current-input-source'])
                output = SOURCE
            return subprocess.CompletedProcess(argv, 0, output, '')

        with patch.object(probe.subprocess, 'run', side_effect=run), \
                patch.object(probe.Capture, 'disk', return_value=fixture()['disk_before']), \
                redirect_stdout(io.StringIO()):
            data = probe.collect()
        self.assertEqual(probe.assess(data), [])
        self.assertIn([probe.sys.executable, '-B', str(probe.CHECKER)], calls)
        self.assertFalse(any(token in ('sudo', 'killall', 'open', '--install', '--select-input-source')
                             for call in calls for token in call))


if __name__ == '__main__':
    unittest.main(verbosity=2)
