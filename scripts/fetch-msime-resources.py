#!/usr/bin/env python3
"""Acquire the pinned official desktop dictionaries; retain Owl's audited Wubi overlay.

Never reads an installed input method or a personal resource directory. The complete
release stays in the download cache; only the reviewed product subset is published.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
RELEASE = 'dict-v2.0.24'
BASE_URL = f'https://github.com/metasequoiaime/msime-dictionary/releases/download/{RELEASE}/'
MANIFEST_SHA = '5b656a5db35b4dcf804ce4348d8584c899d0012fe62bbbe3689204ddaba8722f'
PRODUCT_FILES = ('msime-pinyin.db', 'msime-english.db', 'msime-bigram.bin',
                 'msime-trigram.bin', 'msime-scowl_Copyright.txt')
WUBI_TABLES = ('wubi86', 'wubi98', 'owl_seed_wubi86_source')

class Failure(RuntimeError):
    pass

def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()

def verify(path, spec):
    if path.is_symlink() or not path.is_file() or path.stat().st_size != spec['size'] or digest(path) != spec['sha256']:
        raise Failure(f'resource size/hash mismatch: {path.name}')

def acquire(files, base_url, output):
    """Verify every downloaded member before publishing any of the set."""
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.resources-', dir=output.parent) as tmp:
        staged = Path(tmp)
        for name, spec in files.items():
            if Path(name).name != name:
                raise Failure('unsafe resource name')
            try:
                verify(output/name, spec)
                shutil.copyfile(output/name, staged/name)
            except Failure:
                with urllib.request.urlopen(base_url+name, timeout=120) as response, (staged/name).open('wb') as stream:
                    shutil.copyfileobj(response, stream)
            verify(staged/name, spec)
        for name in files:
            os.replace(staged/name, output/name)

def overlay_wubi(upstream, owl, output):
    """Keep upstream pinyin tables intact; add only Owl's existing Wubi tables."""
    shutil.copyfile(upstream, output)
    with sqlite3.connect(output) as connection:
        connection.execute('ATTACH DATABASE ? AS owl', (str(owl),))
        with connection:
            for table in WUBI_TABLES:
                connection.execute(f'DROP TABLE IF EXISTS main."{table}"')
                sql = connection.execute('SELECT sql FROM owl.sqlite_master WHERE type=? AND name=?', ('table', table)).fetchone()
                if sql is None:
                    raise Failure(f'missing Owl Wubi table: {table}')
                connection.execute(sql[0])
                connection.execute(f'INSERT INTO main."{table}" SELECT * FROM owl."{table}"')
                for (index_sql,) in connection.execute('SELECT sql FROM owl.sqlite_master WHERE type=? AND tbl_name=? AND sql IS NOT NULL', ('index', table)).fetchall():
                    connection.execute(index_sql)
        if connection.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
            raise Failure('invalid assembled pinyin database')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seed', type=Path, default=ROOT/'data/owl-rime')
    parser.add_argument('--cache', type=Path, default=Path(os.environ.get('OWLTYPE_MSIME_RESOURCE_CACHE', '/tmp/owltype-msime-resources')))
    args = parser.parse_args()
    manifest_path = ROOT/'data/msime-dictionary-manifest.json'
    verify(manifest_path, {'size':4627, 'sha256':MANIFEST_SHA})
    manifest = json.loads(manifest_path.read_text())
    if manifest['licensing']['includes_unlicensed_inputs'] is not False:
        raise Failure('upstream set includes unlicensed inputs')
    cache = args.cache/RELEASE
    # Retain the full release, including unused auxiliary files, under one pin.
    acquire(manifest['files'], BASE_URL, cache)
    output = args.seed/'msime'
    with tempfile.TemporaryDirectory(prefix='.official-', dir=args.seed) as tmp:
        stage = Path(tmp)
        for name in PRODUCT_FILES:
            shutil.copyfile(cache/name, stage/name)
        overlay_wubi(cache/'msime-pinyin.db', output/'msime-pinyin.db', stage/'msime-pinyin.db')
        shutil.copyfile(manifest_path, stage/'msime-dictionary-manifest.json')
        record = {'release': RELEASE, 'manifestSha256': MANIFEST_SHA,
                  'upstreamSource': manifest['source'], 'dictionaryCommit': manifest['custom_dictionary_commit'],
                  'files': {name:{'size':(stage/name).stat().st_size, 'sha256':digest(stage/name),
                                   'upstream':manifest['files'][name]} for name in PRODUCT_FILES},
                  'pinyinAdaptation':'Only wubi86, wubi98 and owl_seed_wubi86_source replaced from Owl audited seed',
                  'othersPolicy':'Full artifact retained in build cache; product uses audited emoji-only derivative; symbol_catalog redistribution unconfirmed'}
        (stage/'OWLTYPE-UPSTREAM-RESOURCES.json').write_text(json.dumps(record, ensure_ascii=False, indent=2)+'\n')
        for path in stage.iterdir():
            os.replace(path, output/path.name)
    print(f'[msime-resources] verified {RELEASE}, full pinyin/English/context; Owl Wubi preserved')

if __name__ == '__main__': main()
