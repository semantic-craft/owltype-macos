#!/usr/bin/env python3
"""Offline self-test for msime_pin.py: one pin, every repeated literal checked."""
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import msime_pin as PIN  # noqa: E402

MANIFEST = {
    'format_contract_commit': 'b' * 40, 'custom_dictionary_commit': 'd' * 40,
    'references': {'rime-ice': {'commit': 'e' * 40}},
    'files': {name: {'sha256': f'{index:x}' * 64, 'size': 1000 + index} for index, name in enumerate((
        'msime-pinyin.db', 'msime-wubi.db', 'msime-english.db', 'msime-bigram.bin', 'msime-trigram.bin',
        'msime-others.db', 'msime-scowl_Copyright.txt'), start=1)},
}


class PinCheckTests(unittest.TestCase):
    def make_repository(self, root: Path, release: str = 'dict-v9.9.9') -> PIN.Pin:
        manifest = json.dumps(MANIFEST).encode()
        (root / 'data').mkdir()
        (root / 'rust').mkdir()
        (root / 'data/msime-dictionary-manifest.json').write_bytes(manifest)
        (root / 'rust/msime-source.json').write_text(json.dumps({
            'tag': 'macos-v9.0.0', 'revision': 'a' * 40,
            'resources': {'release': release, 'manifest': '../data/msime-dictionary-manifest.json',
                          'manifestSha256': hashlib.sha256(manifest).hexdigest(), 'manifestSize': len(manifest)}}))
        pin = PIN.load(root)
        for relative, required in PIN.literal_sites(pin).items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('\n'.join(required) + '\n')
        baseline = root / 'tests/fixtures/pinyin-parity/baseline.json'
        baseline.parent.mkdir(parents=True, exist_ok=True)
        resources = {name: pin.files[name]['sha256'] for name in (
            'msime-bigram.bin', 'msime-pinyin.db', 'msime-others.db', 'msime-english.db',
            'msime-scowl_Copyright.txt', 'msime-trigram.bin')}
        resources['msime-dictionary-manifest.json'] = pin.manifest_sha256
        baseline.write_text(json.dumps({
            'upstream_tag': pin.engine_tag, 'upstream_commit': pin.engine_revision, 'resources': resources,
            'wubi_resources': {'msime-wubi.db': pin.files['msime-wubi.db']['sha256']},
            'wubi_resource_source': pin.url('msime-wubi.db')}))
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        subprocess.run(['git', '-C', str(root), 'add', '-A'], check=True)
        return pin

    def test_agreeing_repository_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repository(root)
            self.assertEqual(PIN.check(root), [])

    def test_stale_literal_and_stale_tag_fail(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pin = self.make_repository(root)
            notice = root / 'PROVENANCE.md'
            notice.write_text(notice.read_text().replace(pin.files['msime-wubi.db']['sha256'], '0' * 64))
            (root / 'README.md').write_text('uses dict-v9.9.8\n')
            (root / 'LESSONS.md').write_text('history may name dict-v9.9.8\n')
            subprocess.run(['git', '-C', str(root), 'add', '-A'], check=True)
            errors = PIN.check(root)
            self.assertTrue(any(e.startswith('PROVENANCE.md: missing pinned value') for e in errors), errors)
            self.assertIn('README.md:1: dict-v9.9.8 is not the pinned dict-v9.9.9', errors)
            self.assertFalse(any(e.startswith('LESSONS.md') for e in errors), errors)

    def test_baseline_and_manifest_drift_fail(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repository(root)
            baseline = root / 'tests/fixtures/pinyin-parity/baseline.json'
            data = json.loads(baseline.read_text())
            data['resources']['msime-pinyin.db'] = '0' * 64
            baseline.write_text(json.dumps(data))
            self.assertIn('baseline.json resources[msime-pinyin.db] is not the pinned digest', PIN.check(root))
            (root / 'data/msime-dictionary-manifest.json').write_text('{}')
            with self.assertRaises(PIN.Failure):
                PIN.load(root)

    def test_get_values_cover_scripts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            pin = self.make_repository(Path(temporary))
            values = pin.values()
            self.assertEqual(values['release'], 'dict-v9.9.9')
            self.assertEqual(values['msime-wubi.db:size'], '1002')
            self.assertEqual(values['rime-ice-commit'], 'e' * 40)

    def test_version_order_and_prerelease_filter(self) -> None:
        self.assertGreater(PIN.version_key('dict-v2.0.39'), PIN.version_key('dict-v2.0.4'))
        self.assertLess(PIN.version_key('macos-v0.9.9'), PIN.version_key('macos-v0.55.0'))


if __name__ == '__main__':
    unittest.main()
