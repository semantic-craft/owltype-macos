#!/usr/bin/env python3
"""Acquire and publish the pinned official desktop dictionaries without candidate-data overlays.

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
import tempfile
import urllib.request

import msime_pin
from resource_publish import publish_artifacts

ROOT = Path(__file__).resolve().parents[1]
PIN = msime_pin.load(ROOT)
RELEASE = PIN.release
BASE_URL = f'https://github.com/metasequoiaime/msime-dictionary/releases/download/{RELEASE}/'
MANIFEST_SHA = PIN.manifest_sha256
PRODUCT_FILES = ('msime-pinyin.db', 'msime-wubi.db', 'msime-english.db', 'msime-bigram.bin',
                 'msime-trigram.bin', 'msime-scowl_Copyright.txt')

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

def publish_set(staged, output, names):
    """Publish verified resources and their identity metadata with the seed transaction."""
    publish_artifacts([(output/name, staged/name) for name in names])

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
        publish_set(staged, output, files)

def publish_product(cache, output, manifest, manifest_path):
    """Publish original pinyin and split Wubi data together with verified identities."""
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.official-', dir=output.parent) as tmp:
        stage = Path(tmp)
        for name in PRODUCT_FILES:
            verify(cache/name, manifest['files'][name])
            shutil.copyfile(cache/name, stage/name)
        shutil.copyfile(manifest_path, stage/'msime-dictionary-manifest.json')
        record = {'release': RELEASE, 'manifestSha256': digest(manifest_path),
                  'upstreamSource': manifest['source'], 'dictionaryCommit': manifest['custom_dictionary_commit'],
                  'files': {name:{'size':(stage/name).stat().st_size, 'sha256':digest(stage/name),
                                   'upstream':manifest['files'][name]} for name in PRODUCT_FILES},
                  'dictionaryAdaptation':'None; official pinyin, Wubi86/Wubi98, English and context files are unchanged',
                  'othersPolicy':'Full artifact retained in build cache; product uses audited emoji and MIT kaomoji derivative; symbol_catalog redistribution unconfirmed'}
        (stage/'OWLTYPE-UPSTREAM-RESOURCES.json').write_text(json.dumps(record, ensure_ascii=False, indent=2)+'\n')
        publish_set(stage, output, [path.name for path in stage.iterdir()])

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seed', type=Path, default=ROOT/'data/owl-rime')
    parser.add_argument('--cache', type=Path, default=Path(os.environ.get('OWLTYPE_MSIME_RESOURCE_CACHE', '/tmp/owltype-msime-resources')))
    args = parser.parse_args()
    manifest_path = ROOT/'data/msime-dictionary-manifest.json'
    verify(manifest_path, {'size':PIN.manifest_size, 'sha256':MANIFEST_SHA})
    manifest = json.loads(manifest_path.read_text())
    if manifest['licensing']['includes_unlicensed_inputs'] is not False:
        raise Failure('upstream set includes unlicensed inputs')
    cache = args.cache/RELEASE
    # Retain the full release, including unused auxiliary files, under one pin.
    acquire(manifest['files'], BASE_URL, cache)
    publish_product(cache, args.seed/'msime', manifest, manifest_path)
    print(f'[msime-resources] verified {RELEASE}, official pinyin/Wubi86/Wubi98/English/context unchanged')

if __name__ == '__main__': main()
