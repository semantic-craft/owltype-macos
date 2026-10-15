#!/usr/bin/env python3
"""Offline regressions for the actual live-trace judge; no app or system settings."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('smoke-live.sh')

class TraceJudgeTests(unittest.TestCase):
    def judge(self, text):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'trace.log'
            log.write_text(text)
            return subprocess.run(['bash', str(SCRIPT), 'omnibox', 'judge', str(log)],
                                  capture_output=True, text=True)

    def test_empty_or_unrelated_log_is_not_acceptance(self):
        for text in ['', 'unrelated diagnostic\n', 'markedText send len=0 keepAlive=false sel=0\n']:
            with self.subTest(text=text):
                result = self.judge(text)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn('PASS:', result.stdout)

    def test_unfinished_composition_is_not_acceptance(self):
        result = self.judge('markedText send len=5 keepAlive=false sel=0\n')
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_composition_followed_by_clear_passes(self):
        result = self.judge('markedText send len=5 keepAlive=false sel=0\n'
                            'markedText send len=0 keepAlive=false sel=0\n')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_forced_finalize_still_fails(self):
        result = self.judge('markedText send len=5 keepAlive=false sel=0\n'
                            'commitComposition finalize\n'
                            'markedText send len=0 keepAlive=false sel=0\n')
        self.assertNotEqual(result.returncode, 0)

if __name__ == '__main__':
    unittest.main()
