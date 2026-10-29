#!/usr/bin/env python3
"""Behavioral checks for the differential comparator; no engine/resource downloads."""
import copy
import hashlib
import io
from contextlib import redirect_stderr
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

    def test_export_from_another_scheme_fails(self):
        # A transport that silently stays in Pinyin must not certify a Wubi trace.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config, request, output = [root / name for name in ('test.xctestrun', 'request.json', 'owl.json')]
            config.write_bytes(plistlib.dumps({'TestConfigurations': [{'TestTargets': [{}]}]}))
            request.write_text(json.dumps({'run_id': 'current', 'schema': 'wubi86_jidian'}))
            def export_pinyin(*args, **kwargs):
                output.write_text(json.dumps({'run_id': 'current', 'configuration': {'schema': 'rime_ice'}}))
            with patch.object(parity.subprocess, 'run', side_effect=export_pinyin):
                with self.assertRaisesRegex(ValueError, 'different input scheme'):
                    parity.owl_replay_once(config, request, output)

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


class BatchReplayTests(unittest.TestCase):
    def test_batch_builds_once_and_keeps_independent_states_even_with_a_diff(self):
        for scenario in ('equal', 'difference', 'failure', 'interrupt'):
            mismatch = scenario == 'difference'
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                fixtures = root / 'tests/fixtures/pinyin-parity'
                fixtures.mkdir(parents=True)
                library = root / 'oracle.dylib'
                library.write_bytes(b'isolated oracle fixture')
                (fixtures / 'baseline.json').write_text(json.dumps({
                    'reference_library_sha256': parity.sha256(library), 'resources': {}, 'wubi_resources': {}, 'upstream_commit': 'fixed'}))
                traces = [root / 'first.json', root / 'second.json']
                for trace, value in zip(traces, ('a', 'b')):
                    trace.write_text(json.dumps({'scheme': 'quanpin' if value == 'a' else 'wubi98',
                        'events': [{'op': 'character', 'value': value}]}))
                roots = []
                def observation(events):
                    return {'steps': [dict(event=e, consumed=True, input=e['value'],
                        preedit=e['value'], caret=1, page=0, page_size=6, has_more=False,
                        highlighted=0, candidates=['fixture'], commit=None) for e in events]}
                def reference(_library, _resources, state, events, _profile, scheme, update):
                    self.assertIsNone(update)
                    self.assertEqual(scheme, "quanpin" if events[0]["value"] == "a" else "wubi98")
                    roots.append(state.parent)
                    return dict(observation(events), preferences={'candidate_page_size': 6})
                def owl(_xctestrun, request, _output):
                    data = json.loads(request.read_text())
                    self.assertEqual(data['schema'], 'rime_ice' if data['events'][0]['value'] == 'a' else 'wubi98')
                    self.assertEqual(Path(data['state_root']).parent, roots[-1])
                    if data['events'][0]['value'] == 'b':
                        if scenario == 'failure':
                            raise RuntimeError('second replay failed')
                        if scenario == 'interrupt':
                            raise KeyboardInterrupt()
                    result = observation(data['events'])
                    if mismatch and data['events'][0]['value'] == 'a':
                        result['steps'][0]['commit'] = 'different'
                    return result
                argv = ['parity', '--reference-library', str(library),
                    '--reference-resources', str(root), '--xctestrun', 'Build/Products/probe.xctestrun',
                    '--trace', str(traces[0]), '--trace', str(traces[1]), '--output', str(root / 'out')]
                with patch.object(parity, 'ROOT', root), patch.object(parity.sys, 'argv', argv), \
                        patch.object(parity, 'source_identity', return_value={'head': 'fixed'}), \
                        patch.object(parity, 'prepare_registrations'), \
                        patch.object(parity, 'build_owl', return_value={'source': {'head': 'fixed'}}) as build, \
                        patch.object(parity, 'reference_replay', side_effect=reference), \
                        patch.object(parity, 'owl_replay', side_effect=owl):
                    if scenario in ('failure', 'interrupt'):
                        with self.assertRaises((RuntimeError, KeyboardInterrupt)):
                            parity.main()
                    else:
                        self.assertEqual(parity.main(), int(mismatch))
                    self.assertEqual(build.call_count, 1)
                    owned = build.call_args.args[0].parent.parent.parent
                self.assertFalse(owned.exists())
                self.assertNotEqual(roots[0], roots[1])
                self.assertTrue(all(not state.exists() for state in roots))
                for trace in traces:
                    receipt_path = root / 'out' / trace.stem / 'comparison.json'
                    if scenario in ('failure', 'interrupt'):
                        self.assertFalse(receipt_path.exists(), 'incomplete batches cannot publish passing receipts')
                        continue
                    receipt = json.loads(receipt_path.read_text())
                    self.assertTrue(receipt['owned_build_cleanup_verified'])
                    self.assertEqual(receipt['owl_build']['source'], {'head': 'fixed'})


class DictionaryUpdateTests(unittest.TestCase):
    def make_update(self, root, version, content):
        generation = root / 'dictionary-updates/generations' / ('0' * 64)
        generation.mkdir(parents=True)
        (generation / 'msime-pinyin.db').write_bytes(content)
        (root / 'dictionary-updates/installed.json').write_text(json.dumps({'active': {'version': version}}))
        return {'msime-pinyin.db': hashlib.sha256(b'pinned').hexdigest()}

    def test_update_must_select_the_pinned_release_with_pinned_bytes(self):
        for version, content, error in (('dict-v9.0.1', b'pinned', None),
                                        ('dict-v9.0.0', b'pinned', 'not the pinned'),
                                        ('dict-v9.0.1', b'other', 'no installed reference generation')):
            with self.subTest(version=version, content=content), tempfile.TemporaryDirectory() as directory:
                required = self.make_update(Path(directory), version, content)
                if error is None:
                    parity.verify_dictionary_update(Path(directory), 'dict-v9.0.1', required)
                else:
                    with self.assertRaisesRegex(ValueError, error):
                        parity.verify_dictionary_update(Path(directory), 'dict-v9.0.1', required)

    def test_newer_pin_than_the_reference_lock_requires_the_installed_update(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixtures = root / 'tests/fixtures/pinyin-parity'
            fixtures.mkdir(parents=True)
            library = root / 'oracle.dylib'
            library.write_bytes(b'isolated oracle fixture')
            (root / 'lock.db').write_bytes(b'lock')
            (fixtures / 'baseline.json').write_text(json.dumps({
                'reference_library_sha256': parity.sha256(library), 'upstream_commit': 'fixed',
                'resources': {'pin.db': '0' * 64}, 'wubi_resources': {},
                'engine_lock_resources': {'lock.db': parity.sha256(root / 'lock.db')}}))
            trace = root / 'trace.json'
            trace.write_text(json.dumps({'events': [{'op': 'character', 'value': 'a'}]}))
            argv = ['parity', '--reference-library', str(library), '--reference-resources', str(root),
                    '--xctestrun', 'Build/Products/probe.xctestrun', '--trace', str(trace), '--output', str(root / 'out')]
            with patch.object(parity, 'ROOT', root), patch.object(parity.sys, 'argv', argv), \
                    patch.object(parity, 'build_owl') as build, redirect_stderr(io.StringIO()) as stderr:
                with self.assertRaises(SystemExit):
                    parity.main()
            self.assertIn('--reference-dictionary-update', stderr.getvalue())
            build.assert_not_called()


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

    def test_fresh_reference_worker_imports_its_script_dependencies(self):
        import subprocess
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / 'missing-oracle-library.dylib'
            with self.assertRaises(subprocess.CalledProcessError) as failure:
                parity.reference_replay(missing, Path(directory), Path(directory),
                                        [{'op': 'character', 'value': 'a'}], 'native-mac-host')
            self.assertIn(str(missing), failure.exception.stderr)
            self.assertNotIn('ModuleNotFoundError', failure.exception.stderr)

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
