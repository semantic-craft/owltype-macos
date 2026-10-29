#!/usr/bin/env python3
"""Offline checks for merge-pr.py: only a passed, clean full gate on the exact head counts."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('merge_pr', Path(__file__).with_name('merge-pr.py'))
merge_pr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(merge_pr)

HEAD = 'a' * 40
OTHER = 'b' * 40


def receipt(root: Path, name: str, **overrides) -> None:
    data = {'scope': 'full', 'status': 'passed', 'before': {'head': HEAD, 'status': ''},
            'after': {'head': HEAD}, 'source_unchanged': True, 'finished_at': name}
    for key, value in overrides.items():
        data[key] = value
    (root / name).mkdir()
    (root / name / 'result.json').write_text(json.dumps(data), encoding='utf-8')


class PassingReceiptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_passed_clean_full_gate_on_the_head_counts(self):
        receipt(self.root, '1')
        receipt(self.root, '2')
        self.assertEqual(merge_pr.passing_receipt(self.root, HEAD), self.root / '2')

    def test_anything_else_is_refused(self):
        receipt(self.root, 'failed', status='failed')
        receipt(self.root, 'focused', scope='swift')
        receipt(self.root, 'other-head', before={'head': OTHER, 'status': ''}, after={'head': OTHER})
        receipt(self.root, 'moved', after={'head': OTHER})
        receipt(self.root, 'dirty', before={'head': HEAD, 'status': ' M sources/x.swift\n'})
        receipt(self.root, 'changed', source_unchanged=False)
        (self.root / 'broken').mkdir()
        (self.root / 'broken' / 'result.json').write_text('{', encoding='utf-8')
        self.assertIsNone(merge_pr.passing_receipt(self.root, HEAD))


if __name__ == '__main__':
    unittest.main()
