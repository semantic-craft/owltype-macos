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
            names = ('msime-pinyin.db', 'msime-english.db', 'new-sidecar',
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

    def test_wubi_overlay_preserves_all_upstream_pinyin_rows(self):
        import sqlite3
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            upstream, owl, output = root/'official.db', root/'owl.db', root/'product.db'
            with sqlite3.connect(upstream) as db:
                db.execute('CREATE TABLE pinyin (word TEXT, weight INTEGER)')
                db.executemany('INSERT INTO pinyin VALUES (?, ?)', [('他的房间', 73), ('她的房间', 71)])
                db.execute('CREATE TABLE other_sidecar (value TEXT)')
                db.execute("INSERT INTO other_sidecar VALUES ('retained')")
            with sqlite3.connect(owl) as db:
                for table in resources.WUBI_TABLES:
                    db.execute(f'CREATE TABLE {table} (value TEXT)')
                    db.execute(f"INSERT INTO {table} VALUES ('Owl Wubi')")
            resources.overlay_wubi(upstream, owl, output)
            with sqlite3.connect(output) as db:
                self.assertEqual(db.execute('SELECT * FROM pinyin').fetchall(), [('他的房间',73), ('她的房间',71)])
                self.assertEqual(db.execute('SELECT * FROM other_sidecar').fetchall(), [('retained',)])
                self.assertEqual(db.execute('SELECT * FROM wubi86').fetchall(), [('Owl Wubi',)])

if __name__ == '__main__': unittest.main()
