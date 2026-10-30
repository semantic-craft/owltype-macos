#!/usr/bin/env python3
"""Require an explicit architectural owner for every shipped Swift source."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def check(root=ROOT):
    inventory = json.loads((root / 'docs/agents/business-ownership.json').read_text())
    files = inventory['files']
    paths = [row['path'] for row in files]
    actual = set()
    for directory in ('sources', 'installer/Sources', 'installer/Shared'):
        actual.update(p.relative_to(root).as_posix() for p in (root / directory).rglob('*.swift'))
    if len(paths) != len(set(paths)) or set(paths) != actual:
        raise ValueError(f'Business ownership drift: missing={sorted(actual-set(paths))}, stale={sorted(set(paths)-actual)}')
    for row in files:
        if row['role'] not in ('native', 'adapter', 'split', 'migrate') or not row['reason']:
            raise ValueError(f'Invalid ownership: {row["path"]}')
        if row['role'] in ('split', 'migrate'):
            if not isinstance(row['issue'], int) or row['target'] != 'owl-app-core':
                raise ValueError(f'Missing migration owner: {row["path"]}')
        elif row['issue'] is not None or row['target'] != 'Swift':
            raise ValueError(f'Invalid native owner: {row["path"]}')
    print(f'business ownership: {len(paths)} Swift sources accounted for (classification, not proof of migration)')

if __name__ == '__main__':
    check()
