#!/usr/bin/env python3
"""Squash-merge a pull request only when a passed full-gate receipt names its exact head.

    python3 scripts/merge-pr.py <number>

The receipt is a `scripts/verify.py full` result.json under OWL_VERIFICATION_DIR (default
~/Projects/_shared-work/owltype/verification). It must say `passed`, start and end on the
pull request's head commit with a clean tree and unchanged source. GitHub merges only that
head (`--match-head-commit`), so a push after the gate is refused too. Prints the receipt it
used, for the pull request record.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def verification_dir() -> Path:
    return Path(os.environ.get('OWL_VERIFICATION_DIR',
                               str(Path.home() / 'Projects/_shared-work/owltype/verification'))).expanduser()


def passing_receipt(root: Path, head: str) -> Path | None:
    """The newest passed full-gate receipt for `head`, or None."""
    found = []
    for result in root.glob('*/result.json'):
        try:
            data = json.loads(result.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            continue
        before, after = data.get('before') or {}, data.get('after') or {}
        if (data.get('scope') == 'full' and data.get('status') == 'passed'
                and before.get('head') == head and after.get('head') == head
                and before.get('status', '') == '' and data.get('source_unchanged') is True):
            found.append((data.get('finished_at', ''), result.parent))
    return max(found)[1] if found else None


def gh(*args: str) -> str:
    return subprocess.run(['gh', *args], check=True, capture_output=True, text=True).stdout


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('number', type=int)
    parser.add_argument('--dry-run', action='store_true', help='find the receipt, do not merge')
    args = parser.parse_args(argv)
    view = json.loads(gh('pr', 'view', str(args.number), '--json', 'headRefOid,state'))
    if view['state'] != 'OPEN':
        print(f'merge-pr: #{args.number} is {view["state"]}', file=sys.stderr)
        return 1
    head = view['headRefOid']
    receipt = passing_receipt(verification_dir(), head)
    if receipt is None:
        print(f'merge-pr: refusing #{args.number}: no passed full-gate receipt for head {head} '
              f'under {verification_dir()}. Run scripts/gate.sh on that exact commit first.', file=sys.stderr)
        return 1
    print(f'merge-pr: #{args.number} head {head} gate receipt {receipt / "summary.md"}')
    if args.dry_run:
        return 0
    subprocess.run(['gh', 'pr', 'merge', str(args.number), '--squash', '--delete-branch',
                    '--match-head-commit', head], check=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
