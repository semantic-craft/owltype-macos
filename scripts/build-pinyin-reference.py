#!/usr/bin/env python3
"""Build the unmodified pinned MSIME Host API in an explicit external artifact directory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def sha256(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    baseline = json.loads((root / 'tests/fixtures/pinyin-parity/baseline.json').read_text())
    output = args.output.expanduser().resolve()
    if root == output or root in output.parents:
        parser.error('choose an artifact directory outside the source checkout')
    output.mkdir(parents=True, exist_ok=True)
    source = output / 'msime'
    if not source.exists():
        subprocess.run(['git', 'init', str(source)], check=True)
    def git(*arguments):
        return subprocess.check_output(['git', '-C', str(source), *arguments], text=True).strip()
    if git('status', '--porcelain'):
        parser.error('reference source has local changes; use a clean artifact directory')
    subprocess.run(['git', '-C', str(source), 'fetch', '--depth=1',
                    'https://github.com/metasequoiaime/msime.git', baseline['upstream_commit']], check=True)
    subprocess.run(['git', '-C', str(source), 'checkout', '--detach', baseline['upstream_commit']], check=True)
    target = baseline['reference_build']['target']
    toolchain = baseline['reference_build']['rustc']
    environment = {**os.environ, 'MACOSX_DEPLOYMENT_TARGET': '14.0',
                   'RUSTFLAGS': f'--remap-path-prefix={source}=msime',
                   'CARGO_TARGET_DIR': str(output / 'target')}
    subprocess.run(['cargo', '+' + toolchain, 'build', '--locked', '--manifest-path', str(source / 'Cargo.toml'),
                    '--package', 'msime-host-api', '--release', '--target', target], env=environment, check=True)
    if git('status', '--porcelain'):
        raise ValueError('build modified the pinned source')
    library = output / 'libmsime_host_api.dylib'
    shutil.copy2(output / 'target' / target / 'release' / library.name, library)
    receipt = {'upstream_commit': git('rev-parse', 'HEAD'), 'source_tree': git('rev-parse', 'HEAD^{tree}'),
               'source_clean': True, 'build': baseline['reference_build'],
               'builder_sha256': sha256(Path(__file__).resolve()), 'library_sha256': sha256(library)}
    (output / 'build.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(f'Reference: {library}\nReceipt: {output / "build.json"}')


if __name__ == '__main__':
    main()
