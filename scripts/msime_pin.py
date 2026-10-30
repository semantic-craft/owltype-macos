#!/usr/bin/env python3
"""The pinned MSIME engine and dictionary release, kept in one place.

`rust/msime-source.json` names the engine tag/revision and the dictionary release with the
SHA-256 of its verbatim manifest (`data/msime-dictionary-manifest.json`); that manifest supplies
every member digest. Scripts read the pin from here. Documents, fixtures and Rust resource constants
repeat it as literals, so `check` verifies they agree and `drift` lists newer upstream tags.

  python3 scripts/msime_pin.py show            # the current pin
  python3 scripts/msime_pin.py get release     # one value, for shell scripts
  python3 scripts/msime_pin.py check           # every repeated literal agrees (offline)
  python3 scripts/msime_pin.py drift           # read-only: newer dict-v*/macos-v* upstream tags
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = 'rust/msime-source.json'
ENGINE_REPOSITORY = 'https://github.com/metasequoiaime/msime'
DICTIONARY_REPOSITORY = 'https://github.com/metasequoiaime/msime-dictionary'


class Failure(RuntimeError):
    pass


@dataclass(frozen=True)
class Pin:
    engine_tag: str
    engine_revision: str
    release: str
    manifest_sha256: str
    manifest_size: int
    manifest: dict

    @property
    def files(self) -> dict:
        return self.manifest['files']

    @property
    def builder_commit(self) -> str:
        return self.manifest['format_contract_commit']

    @property
    def data_commit(self) -> str:
        return self.manifest['custom_dictionary_commit']

    @property
    def rime_ice_commit(self) -> str:
        return self.manifest['references']['rime-ice']['commit']

    def url(self, name: str) -> str:
        return f'{DICTIONARY_REPOSITORY}/releases/download/{self.release}/{name}'

    def values(self) -> dict:
        """Flat values for `get`; shell scripts read these instead of repeating literals."""
        values = {'engine-tag': self.engine_tag, 'engine-revision': self.engine_revision,
                  'release': self.release, 'manifest-sha256': self.manifest_sha256,
                  'manifest-size': str(self.manifest_size), 'builder-commit': self.builder_commit,
                  'data-commit': self.data_commit, 'rime-ice-commit': self.rime_ice_commit}
        for name, spec in self.files.items():
            values[f'{name}:sha256'] = spec['sha256']
            values[f'{name}:size'] = str(spec['size'])
        return values


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def load(root: Path = ROOT) -> Pin:
    """Read the pin and verify the manifest it names; a stale manifest is a failure."""
    source = json.loads((root / SOURCE).read_text())
    resources = source['resources']
    manifest_path = (root / SOURCE).parent / resources['manifest']
    if (manifest_path.stat().st_size != resources['manifestSize']
            or sha256(manifest_path) != resources['manifestSha256']):
        raise Failure(f'{manifest_path.relative_to(root)} does not match the pinned manifest digest')
    return Pin(source['tag'], source['revision'], resources['release'], resources['manifestSha256'],
               resources['manifestSize'], json.loads(manifest_path.read_text()))


# Files that repeat the pin. Each entry lists the values that must appear verbatim.
def literal_sites(pin: Pin) -> dict[str, list[str]]:
    f = {name: spec['sha256'] for name, spec in pin.files.items()}
    product = ('msime-pinyin.db', 'msime-wubi.db', 'msime-english.db', 'msime-bigram.bin',
               'msime-trigram.bin', 'msime-others.db')
    return {
        'data/msime-resources-NOTICE.md': [
            f'{pin.release}](', f'/releases/tag/{pin.release})', f'{pin.manifest_size:,} bytes',
            pin.manifest_sha256, pin.builder_commit, pin.data_commit, pin.engine_revision,
            *(f'| {name} | {pin.files[name]["size"]} | {f[name]} |' for name in product)],
        'data/msime-others-NOTICE.txt': [
            pin.url('msime-others.db'), pin.url('msime-dictionary-manifest.json'),
            f'Size: {pin.files["msime-others.db"]["size"]} bytes', f'SHA-256: {f["msime-others.db"]}',
            f'Size: {pin.manifest_size} bytes', f'SHA-256: {pin.manifest_sha256}',
            f'source.commit: {pin.builder_commit}', f'custom_dictionary_commit: {pin.data_commit}',
            f'references.rime-ice.commit: {pin.rime_ice_commit}',
            f'msime/blob/{pin.builder_commit}/crates/dict-builder/src/main.rs'],
        'PROVENANCE.md': [
            f'`{pin.engine_tag}`', pin.engine_revision, f'固定 `{pin.release}`',
            f'[`{pin.release}`](https://github.com/metasequoiaime/msime-dictionary/releases/tag/{pin.release})',
            f'`{pin.release}/msime-wubi.db`', f['msime-wubi.db'], f['msime-others.db'],
            pin.builder_commit, pin.data_commit],
        'THIRD_PARTY_NOTICES.md': [f'`{pin.release}`；', f'/releases/tag/{pin.release} |'],
        'docs/operations/pinyin-parity.md': [
            f'`{pin.engine_tag}`', pin.engine_revision, f'`{pin.release}`', pin.builder_commit,
            pin.data_commit],
        'rust/crates/owl-app-core/src/resource_catalog.rs': [
            f'{pin.release}: both official 86/98 tables'],
        'rust/crates/owl-app-core/src/resource_catalog.json': [
            f'"sha256:{f["msime-wubi.db"]}"', f'"msime-{pin.engine_tag}-'],
        'tests/OwlRustEngineTests.swift': [f'"sha256:{f["msime-wubi.db"]}"', f'official {pin.release}'],
        'scripts/secret-finding-policy.py': [
            f'Public {pin.release} msime-english.db', f'"{f["msime-english.db"]}"'],
        'rust/crates/owl-msime-ffi/tests/model_parity.rs': [f'{pin.engine_tag} Host API', f'official {pin.release}'],
    }


def check_baseline(pin: Pin, root: Path) -> list[str]:
    baseline = json.loads((root / 'tests/fixtures/pinyin-parity/baseline.json').read_text())
    errors = []
    expected = {name: pin.files[name]['sha256'] for name in (
        'msime-bigram.bin', 'msime-pinyin.db', 'msime-others.db', 'msime-english.db',
        'msime-scowl_Copyright.txt', 'msime-trigram.bin')}
    expected['msime-dictionary-manifest.json'] = pin.manifest_sha256
    for name, value in expected.items():
        if baseline['resources'].get(name) != value:
            errors.append(f'baseline.json resources[{name}] is not the pinned digest')
    if baseline['wubi_resources'] != {'msime-wubi.db': pin.files['msime-wubi.db']['sha256']}:
        errors.append('baseline.json wubi_resources is not the pinned Wubi digest')
    if baseline['wubi_resource_source'] != pin.url('msime-wubi.db'):
        errors.append('baseline.json wubi_resource_source is not the pinned release URL')
    if (baseline['upstream_tag'], baseline['upstream_commit']) != (pin.engine_tag, pin.engine_revision):
        errors.append('baseline.json upstream tag/commit is not the pinned engine')
    return errors


# A dict-v tag other than the pin is stale, except in vendored upstream code (its own test
# fixtures), dated history, self-test fixtures, and the re-pin documents that name the previous
# release on purpose.
STALE_TAG_EXEMPT = (
    'rust/crates/engine/', 'rust/crates/input-runtime/', 'rust/crates/path-trust/',
    'rust/crates/client-core/', 'LESSONS.md', 'CHANGELOG.md', 'progress/',
    'docs/operations/msime-repin.md',
)
TAG = re.compile(r'dict-v\d+\.\d+\.\d+')


def stale_tags(pin: Pin, root: Path) -> list[str]:
    listed = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'], check=True,
                            capture_output=True).stdout.decode().split('\0')
    errors = []
    for relative in filter(None, listed):
        if relative.startswith(STALE_TAG_EXEMPT) or relative.endswith('.selftest.py'):
            continue
        path = root / relative
        if path.is_symlink() or not path.is_file():
            continue
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        for number, line in enumerate(text.splitlines(), 1):
            for tag in set(TAG.findall(line)) - {pin.release}:
                errors.append(f'{relative}:{number}: {tag} is not the pinned {pin.release}')
    return errors


def check(root: Path = ROOT) -> list[str]:
    pin = load(root)
    errors = []
    for relative, required in literal_sites(pin).items():
        text = (root / relative).read_text()
        errors += [f'{relative}: missing pinned value {value!r}' for value in required if value not in text]
    errors += check_baseline(pin, root)
    errors += stale_tags(pin, root)
    return errors


def version_key(tag: str) -> tuple:
    return tuple(int(part) for part in re.findall(r'\d+', tag))


def remote_tags(repository: str, prefix: str) -> list[str]:
    """Release tags without a pre-release suffix, oldest first."""
    output = subprocess.run(['git', 'ls-remote', '--tags', '--refs', repository, f'{prefix}*'],
                            check=True, capture_output=True, text=True, timeout=60).stdout
    pattern = re.compile(rf'^{re.escape(prefix)}\d+\.\d+\.\d+$')
    tags = [line.split('refs/tags/', 1)[1] for line in output.splitlines()]
    return sorted((tag for tag in tags if pattern.match(tag)), key=version_key)


def manifest_changes(pin: Pin, release: str) -> list[str]:
    url = f'{DICTIONARY_REPOSITORY}/releases/download/{release}/msime-dictionary-manifest.json'
    with urllib.request.urlopen(url, timeout=60) as response:
        latest = json.load(response)['files']
    rows = []
    for name in sorted(set(pin.files) | set(latest)):
        old, new = pin.files.get(name), latest.get(name)
        if old != new:
            size = lambda spec: f'{spec["size"]:,}' if spec else 'absent'
            same = old and new and old['size'] == new['size']
            rows.append(f'  {name}: {size(old)} -> {size(new)} bytes' + (' (content changed)' if same else ''))
    return rows


def drift(pin: Pin) -> str:
    lines = []
    for label, repository, prefix, current in (
            ('engine', ENGINE_REPOSITORY, 'macos-v', pin.engine_tag),
            ('dictionary', DICTIONARY_REPOSITORY, 'dict-v', pin.release)):
        tags = remote_tags(repository, prefix)
        newer = [tag for tag in tags if version_key(tag) > version_key(current)]
        latest = tags[-1] if tags else 'none'
        state = f'{len(newer)} newer: {", ".join(newer)}' if newer else 'up to date'
        lines.append(f'{label}: pinned {current}, upstream latest {latest} ({state})')
        if label == 'dictionary' and newer:
            changes = manifest_changes(pin, latest)
            lines.append(f'{latest} manifest members that differ from the pin:')
            lines += changes or ['  none']
    return '\n'.join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('show')
    get = commands.add_parser('get')
    get.add_argument('name')
    commands.add_parser('check')
    commands.add_parser('drift')
    args = parser.parse_args(argv)
    try:
        pin = load()
        if args.command == 'show':
            print(json.dumps(pin.values(), indent=2))
        elif args.command == 'get':
            values = pin.values()
            if args.name not in values:
                raise Failure(f'unknown value {args.name}; see `show`')
            print(values[args.name])
        elif args.command == 'check':
            errors = check()
            for error in errors:
                print(f'FAIL: {error}', file=sys.stderr)
            if errors:
                return 1
            print(f'[msime-pin] {pin.engine_tag} and {pin.release} agree across every repeated literal')
        else:
            print(drift(pin))
    except (Failure, OSError, KeyError, subprocess.SubprocessError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
