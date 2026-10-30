#!/usr/bin/env python3
"""Require an explicit architectural owner for every shipped Swift source and enforce boundary lock."""
import json
import sys
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

    split_files = []
    migrate_files = []
    for row in files:
        role = row.get('role')
        if role not in ('native', 'adapter', 'split', 'migrate') or not row.get('reason'):
            raise ValueError(f'Invalid ownership: {row.get("path")}')
        if role == 'split':
            split_files.append(row['path'])
        elif role == 'migrate':
            migrate_files.append(row['path'])
        elif role in ('native', 'adapter'):
            if row.get('issue') is not None or row.get('target') != 'Swift':
                raise ValueError(f'Invalid native/adapter owner: {row.get("path")}')

    if split_files or migrate_files:
        errors = []
        if split_files:
            errors.append(f"Boundary lock violation: {len(split_files)} split file(s) remain: {split_files}")
        if migrate_files:
            errors.append(f"Boundary lock violation: {len(migrate_files)} migrate file(s) remain: {migrate_files}")
        sys.stderr.write("\n".join(errors) + "\n")
        sys.exit(1)

    print(f'business ownership: {len(paths)} Swift sources accounted for (boundary locked: 0 split, 0 migrate)')

if __name__ == '__main__':
    check()
