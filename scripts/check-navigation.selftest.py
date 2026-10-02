#!/usr/bin/env python3
"""Exercise the navigation check's CLI with temporary repositories."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CHECK = Path(__file__).with_name('check-navigation.py')


class NavigationCheckTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='owl-navigation-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'docs').mkdir()

    def run_check(self, text, source='docs/start.md'):
        path = self.root / source
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return subprocess.run(
            [sys.executable, str(CHECK), '--root', str(self.root), '--files', source],
            capture_output=True, text=True,
        )

    def test_broken_link_reports_source_line_and_target(self):
        result = self.run_check('# Start\n\n[Policy](missing.md)\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn('docs/start.md:3', result.stdout)
        self.assertIn('missing.md', result.stdout)

    def test_inline_file_paths_in_docs_and_source_comments(self):
        for source, text in [
            ('docs/start.md', 'Read `missing.md`.\n'),
            ('sources/Entry.swift', '// See `docs/missing.md`.\n'),
        ]:
            with self.subTest(source=source):
                result = self.run_check(text, source)
                self.assertEqual(result.returncode, 1)
                self.assertIn(source + ':1', result.stdout)
                self.assertIn('missing.md', result.stdout)

    def test_historical_optional_and_fenced_examples_are_not_current_links(self):
        result = self.run_check(
            '[Old](gone.md) <!-- reference-check: historical -->\n'
            'Optional `glossary.md`. <!-- reference-check: optional -->\n'
            '```sh\n[Example](example.md)\n```\n'
            '~~~text\n`example.py`\n~~~\n'
        )
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_valid_relative_links_images_inline_paths_and_external_links(self):
        (self.root / 'docs' / 'policy.md').write_text('# Policy\n')
        (self.root / 'docs' / 'space name.md').write_text('# Space\n')
        (self.root / 'docs' / 'picture.png').write_bytes(b'fixture')
        result = self.run_check(
            '[Policy](policy.md#constraints) and `policy.md`.\n'
            '![Picture](picture.png) [Space](space%20name.md)\n'
            '[With title](policy.md "Policy") [Angle](<space name.md>)\n'
            '[External](https://example.invalid/missing.md) [Anchor](#here)\n'
            '[Mail](mailto:team@example.invalid) [Network](//example.invalid/a.md)\n'
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        result = self.run_check('// See `docs/policy.md`.\n', 'sources/Entry.swift')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_missing_scoped_source_fails(self):
        result = subprocess.run(
            [sys.executable, str(CHECK), '--root', str(self.root), '--files', 'gone.md'],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn('gone.md:1', result.stdout)

    def test_exemption_is_line_scoped_and_check_resumes_after_fence(self):
        result = self.run_check(
            '[Old](old.md) <!-- reference-check: historical -->\n'
            '```text\n[Example](gone.md)\n```\n'
            '[Current](current.md)\n'
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn('docs/start.md:5', result.stdout)
        self.assertNotIn('old.md', result.stdout)
        self.assertNotIn('gone.md', result.stdout)


if __name__ == '__main__':
    unittest.main()
