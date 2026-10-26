#!/usr/bin/env python3
"""Resource acquisition transaction: failures must leave the usable set untouched."""
import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('resources', Path(__file__).with_name('fetch-msime-resources.py'))
resources = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(resources)

class AcquisitionTests(unittest.TestCase):
    def test_corrupt_member_does_not_publish_partial_set(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, output = root/'source', root/'output'
            source.mkdir(); output.mkdir()
            (output/'first').write_bytes(b'old first')
            (output/'second').write_bytes(b'old second')
            (source/'first').write_bytes(b'new first')
            (source/'second').write_bytes(b'corrupt')
            files = {name: {'size': len(value), 'sha256': hashlib.sha256(value).hexdigest()}
                     for name, value in [('first', b'new first'), ('second', b'new second')]}
            with self.assertRaises(resources.Failure):
                resources.acquire(files, source.as_uri()+'/', output)
            self.assertEqual((output/'first').read_bytes(), b'old first')
            self.assertEqual((output/'second').read_bytes(), b'old second')

    def test_verified_set_is_published_and_corrupt_cache_is_repaired(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, output = root/'source', root/'output'
            source.mkdir(); output.mkdir()
            payload = b'official dictionary bytes'
            (source/'dictionary').write_bytes(payload)
            (output/'dictionary').write_bytes(b'corrupt cached bytes')
            files = {'dictionary': {'size':len(payload), 'sha256':hashlib.sha256(payload).hexdigest()}}
            resources.acquire(files, source.as_uri()+'/', output)
            self.assertEqual((output/'dictionary').read_bytes(), payload)

    def test_cache_publish_failure_restores_existing_and_absent_members(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, output = root/'source', root/'output'
            source.mkdir(); output.mkdir()
            names = ('dictionary', 'new-sidecar', 'manifest.json')
            old = {'dictionary': b'old dictionary', 'manifest.json': b'old manifest'}
            for name, payload in old.items(): (output/name).write_bytes(payload)
            files = {}
            for name in names:
                payload = ('new '+name).encode()
                (source/name).write_bytes(payload)
                files[name] = {'size':len(payload), 'sha256':hashlib.sha256(payload).hexdigest()}
            real_replace = resources.os.replace
            def fail_manifest(path, target):
                if Path(path).name == 'manifest.json' and Path(target).name == 'manifest.json' and Path(target).parent == output:
                    raise OSError('injected cache publication failure')
                return real_replace(path, target)
            with mock.patch.object(resources.os, 'replace', fail_manifest), self.assertRaises(OSError):
                resources.acquire(files, source.as_uri()+'/', output)
            self.assertEqual({p.name:p.read_bytes() for p in output.iterdir()}, old)

    def test_product_publish_failure_restores_resources_manifest_and_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            staged, output = root/'staged', root/'product'
            staged.mkdir(); output.mkdir()
            names = ('msime-pinyin.db', 'msime-wubi.db', 'msime-english.db', 'new-sidecar',
                     'msime-dictionary-manifest.json', 'OWLTYPE-UPSTREAM-RESOURCES.json')
            old = {name:('old '+name).encode() for name in names if name != 'new-sidecar'}
            for name, payload in old.items(): (output/name).write_bytes(payload)
            for name in names: (staged/name).write_bytes(('new '+name).encode())
            real_replace = resources.os.replace
            def fail_record(path, target):
                if Path(path).name == 'OWLTYPE-UPSTREAM-RESOURCES.json' and Path(target).name == 'OWLTYPE-UPSTREAM-RESOURCES.json' and Path(target).parent == output:
                    raise OSError('injected product publication failure')
                return real_replace(path, target)
            with mock.patch.object(resources.os, 'replace', fail_record), self.assertRaises(OSError):
                resources.publish_set(staged, output, names)
            self.assertEqual({p.name:p.read_bytes() for p in output.iterdir()}, old)

    def test_product_keeps_official_split_wubi_and_pinyin_bytes(self):
        import sqlite3
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cache, output = root/'cache', root/'product'
            cache.mkdir(); output.mkdir()
            with sqlite3.connect(cache/'msime-pinyin.db') as db:
                db.execute('CREATE TABLE pinyin (word TEXT, weight INTEGER)')
                db.execute("INSERT INTO pinyin VALUES ('他的房间', 73)")
            with sqlite3.connect(cache/'msime-wubi.db') as db:
                for table in ('wubi86', 'wubi98'):
                    db.execute(f'CREATE TABLE {table} (key TEXT, value TEXT, weight INTEGER)')
                    db.executemany(f'INSERT INTO {table} VALUES (?, ?, ?)',
                                   [('a', '工', 20), ('a', '戈', 10), ('aaaa', '劳斯莱斯', 9)])
            # A previous product has an Owl overlay. Official publication replaces it,
            # preserving the original upstream pinyin file and row-order-sensitive Wubi.
            (output/'msime-pinyin.db').write_bytes(b'old Owl overlay')
            for name in ('msime-english.db', 'msime-bigram.bin', 'msime-trigram.bin', 'msime-scowl_Copyright.txt'):
                (cache/name).write_bytes(('official '+name).encode())
            manifest = {'source': {'commit':'fixed-builder'}, 'custom_dictionary_commit':'fixed-data',
                        'files':{p.name:{'size':p.stat().st_size,'sha256':resources.digest(p)} for p in cache.iterdir()}}
            manifest_path = root/'manifest.json'
            manifest_path.write_text(json.dumps(manifest))
            resources.publish_product(cache, output, manifest, manifest_path)
            for name in ('msime-pinyin.db', 'msime-wubi.db'):
                self.assertEqual((output/name).read_bytes(), (cache/name).read_bytes())
            with sqlite3.connect(output/'msime-wubi.db') as db:
                self.assertEqual(db.execute('SELECT value FROM wubi86 ORDER BY rowid').fetchall(),
                                 [('工',), ('戈',), ('劳斯莱斯',)])
            record=json.loads((output/'OWLTYPE-UPSTREAM-RESOURCES.json').read_text())
            self.assertEqual(record['files']['msime-wubi.db']['sha256'], manifest['files']['msime-wubi.db']['sha256'])

if __name__ == '__main__': unittest.main()
