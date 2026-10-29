#!/usr/bin/env python3
"""Offline self-test for msime-dictionary-diff.py on two tiny releases."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

spec = importlib.util.spec_from_file_location('diff', Path(__file__).with_name('msime-dictionary-diff.py'))
DIFF = importlib.util.module_from_spec(spec)
spec.loader.exec_module(DIFF)


def release(root: Path, pinyin, wubi86, wubi98, glosses) -> None:
    root.mkdir()
    with closing(sqlite3.connect(root / 'msime-pinyin.db', isolation_level=None)) as db:
        db.execute('CREATE TABLE tbl_2_a (key TEXT, jp TEXT, value TEXT, weight INTEGER)')
        db.execute('CREATE TABLE quick_parases (key TEXT, value TEXT, weight INTEGER)')
        db.executemany('INSERT INTO tbl_2_a VALUES (?, "", ?, ?)', pinyin)
    with closing(sqlite3.connect(root / 'msime-wubi.db', isolation_level=None)) as db:
        for table, rows in (('wubi86', wubi86), ('wubi98', wubi98)):
            db.execute(f'CREATE TABLE {table} (key TEXT, value TEXT, weight INTEGER, UNIQUE(key, value))')
            db.executemany(f'INSERT INTO {table} VALUES (?, ?, ?)', rows)
    with closing(sqlite3.connect(root / 'msime-english.db', isolation_level=None)) as db:
        db.execute('CREATE TABLE english_words (word TEXT, display TEXT, weight INTEGER)')
        db.execute('CREATE TABLE en_zh_glosses (english TEXT PRIMARY KEY, chinese_gloss TEXT)')
        db.execute('CREATE TABLE zh_en_glosses (chinese TEXT PRIMARY KEY, english_gloss TEXT)')
        db.execute("INSERT INTO english_words VALUES ('hello', 'hello', 5)")
        db.executemany('INSERT INTO en_zh_glosses VALUES (?, ?)', glosses)
    files = {}
    for name in DIFF.MEMBERS:
        path = root / name
        files[name] = ({'size': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                       if path.exists() else {'size': 0, 'sha256': '0' * 64})
    (root / 'msime-dictionary-manifest.json').write_text(json.dumps({
        'format_contract_commit': 'b' * 40, 'custom_dictionary_commit': 'd' * 40, 'files': files}))


class DictionaryDiffTests(unittest.TestCase):
    def test_counts_words_weights_and_lost_unique_four_codes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            old, new = Path(temporary) / 'old', Path(temporary) / 'new'
            release(old, [("a'a", '啊啊', 10), ("a'ba", '阿爸', 5)],
                    [('sebv', '极限', 10), ('ggtt', '五', 3), ('aaab', '旧', 1)], [('sebv', '极限', 10)],
                    [('apple', '苹果')])
            release(new, [("a'a", '啊啊', 20), ("a'ba", '阿爸', 5), ("a'ba", '阿巴', 9)],
                    [('sebv', '极限', 10), ('ggtt', '五', 3), ('ggtt', '五五', 2), ('bbbx', '新', 1)],
                    [('sebv', '极限', 10)], [('apple', '苹果树')])
            report = DIFF.compare(old, new)
            self.assertEqual((report['pinyin']['added'], report['pinyin']['weight_raised']), (1, 1))
            self.assertEqual(report['pinyin']['top_row_changed'], 1)
            wubi = report['wubi']['wubi86']
            self.assertEqual((wubi['added'], wubi['removed']), (2, 1))
            self.assertEqual(wubi['lost_unique_four_code'], 1)
            self.assertEqual(wubi['lost_unique_four_code_sample'], [['ggtt', '五', 2]])
            self.assertEqual(wubi['added_weight_range'], [1, 2])
            self.assertEqual(report['english_glosses']['en_zh_glosses']['changed'], 1)
            text = DIFF.markdown(report, 'old', 'new')
            self.assertIn('| wubi86 | 1 |', text)
            self.assertIn('`ggtt` 五 (2)', text)

    def test_member_that_does_not_match_its_manifest_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            old, new = Path(temporary) / 'old', Path(temporary) / 'new'
            for root in (old, new):
                release(root, [], [], [], [])
            (new / 'msime-wubi.db').write_bytes(b'tampered')
            with self.assertRaises(SystemExit):
                DIFF.compare(old, new)


if __name__ == '__main__':
    unittest.main()
