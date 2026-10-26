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
                    parity.owl_replay(config, request, output)
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
                    parity.owl_replay(config, request, output)


if __name__ == '__main__':
    unittest.main()
