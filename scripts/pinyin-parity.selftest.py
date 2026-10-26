#!/usr/bin/env python3
"""Behavioral checks for the differential comparator; no engine/resource downloads."""
import copy
import importlib.util
from pathlib import Path
import unittest
import json
import plistlib
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('parity', Path(__file__).with_name('pinyin-parity.py'))
parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parity)


class DifferentialTests(unittest.TestCase):
    def test_observes_complete_order_paging_consumption_caret_and_commit(self):
        step = {'event': {'op': 'character', 'value': 'a'}, 'consumed': True,
                'input': 'a', 'preedit': 'a', 'caret': 1, 'page': 0, 'page_size': 6,
                'has_more': True, 'highlighted': 0,
                'candidates': ['啊', '阿', '呵', '吖', '嗄', '腌'], 'commit': None}
        trace = {'steps': [step]}
        self.assertEqual(parity.differences(trace, copy.deepcopy(trace)), [])
        for field, value in [('candidates', ['啊', '阿', '呵', '吖', '腌', '嗄']),
                             ('page', 1), ('highlighted', 1), ('consumed', False),
                             ('caret', 0), ('commit', '阿'), ('has_more', False),
                             ('input', ''), ('preedit', '阿'), ('page_size', 9)]:
            changed = copy.deepcopy(trace)
            changed['steps'][0][field] = value
            with self.subTest(field=field):
                self.assertEqual(parity.differences(trace, changed)[0]['field'], field)

    def test_equal_traces_cannot_hide_failed_learning_checkpoint(self):
        event = {'op': 'restart', 'expect': {'candidates': ['尼', '你']}}
        step = dict(event=event, consumed=True, input='', preedit='', caret=0,
                    page=0, page_size=6, has_more=False, highlighted=0,
                    candidates=['你', '尼'], commit=None)
        trace = {'steps': [step]}
        differences = parity.differences(trace, copy.deepcopy(trace))
        self.assertEqual([d['field'] for d in differences],
                         ['fixture_expectation', 'fixture_expectation'])

    def test_incomplete_trace_cannot_pass(self):
        self.assertTrue(parity.differences({"steps": [{}]}, {"steps": [{}]}))
        self.assertTrue(parity.differences({"steps": []}, {"steps": []}))

    def test_missing_step_cannot_pass(self):
        self.assertTrue(parity.differences({'steps': [{}]}, {'steps': []}))


class ExportTransportTests(unittest.TestCase):
    def test_stale_export_is_removed_and_missing_export_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config, request, output = [root / name for name in ('test.xctestrun', 'request.json', 'owl.json')]
            config.write_bytes(plistlib.dumps({'TestConfigurations': [{'TestTargets': [{}]}]}))
            request.write_text(json.dumps({'run_id': 'current'}))
            output.write_text(json.dumps({'run_id': 'old', 'steps': []}))
            with patch.object(parity.subprocess, 'run'):
                with self.assertRaisesRegex(ValueError, 'did not export'):
                    parity.owl_replay_once(config, request, output)
            self.assertFalse(output.exists())

    def test_export_from_another_run_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config, request, output = [root / name for name in ('test.xctestrun', 'request.json', 'owl.json')]
            config.write_bytes(plistlib.dumps({'TestConfigurations': [{'TestTargets': [{}]}]}))
            request.write_text(json.dumps({'run_id': 'current'}))
            def export_other_run(*args, **kwargs):
                output.write_text(json.dumps({'run_id': 'other'}))
            with patch.object(parity.subprocess, 'run', side_effect=export_other_run):
                with self.assertRaisesRegex(ValueError, 'different replay'):
                    parity.owl_replay_once(config, request, output)


class BuildLifecycleTests(unittest.TestCase):
    def test_owned_build_is_removed_after_success_failure_and_interruption(self):
        for failure in [None, RuntimeError("build failed"), KeyboardInterrupt()]:
            with self.subTest(failure=type(failure).__name__):
                with tempfile.TemporaryDirectory() as caller:
                    caller = Path(caller)
                    sentinel = caller / 'keep.txt'
                    sentinel.write_text('caller data')
                    chosen = caller / 'Build/Products/Owltype_macosx.xctestrun'
                    cleaned = []
                    with patch.object(parity, 'prepare_registrations', side_effect=lambda p: cleaned.append(Path(p))):
                        try:
                            with parity.owned_owl_build(chosen) as actual:
                                owned = actual.parent.parent.parent
                                self.assertNotEqual(owned, caller)
                                app = actual.parent / 'Debug/Owltype.app'
                                app.mkdir(parents=True)
                                (app / 'retained.txt').write_text('build')
                                if failure is not None:
                                    raise failure
                        except (RuntimeError, KeyboardInterrupt):
                            if failure is None:
                                raise
                    self.assertFalse(owned.exists())
                    self.assertEqual(cleaned, [owned, owned])
                    self.assertEqual(sentinel.read_text(), 'caller data')

    def test_sigterm_runs_owned_build_cleanup(self):
        import subprocess
        import signal
        script = """import importlib.util,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
spec=importlib.util.spec_from_file_location('parity',Path(sys.argv[1])/'pinyin-parity.py')
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
p.prepare_registrations=lambda root: None
with p.owned_owl_build(Path('Build/Products/probe.xctestrun')) as chosen:
 print(chosen.parent.parent.parent,flush=True)
 sys.stdin.readline()
"""
        process = subprocess.Popen([parity.sys.executable, '-c', script, str(Path(__file__).parent)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            owned = Path(process.stdout.readline().strip())
            self.assertTrue(owned.is_dir())
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=10), 128 + signal.SIGTERM)
            self.assertFalse(owned.exists())
        finally:
            if process.poll() is None:
                process.kill(); process.wait()
            process.stdin.close(); process.stdout.close()

    def test_failed_unregister_retains_only_owned_build(self):
        with tempfile.TemporaryDirectory() as caller:
            chosen = Path(caller) / 'Build/Products/Owltype_macosx.xctestrun'
            with patch.object(parity, 'prepare_registrations', side_effect=RuntimeError('live app')):
                with self.assertRaisesRegex(RuntimeError, 'live app'):
                    with parity.owned_owl_build(chosen) as actual:
                        owned = actual.parent.parent.parent
            self.assertTrue(owned.exists())
            import shutil
            shutil.rmtree(owned)


if __name__ == '__main__':
    unittest.main()
