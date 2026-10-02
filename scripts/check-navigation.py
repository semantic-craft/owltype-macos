#!/usr/bin/env python3
"""Check maintained navigation, not historical research or generated artifacts."""
import argparse
import re
from pathlib import Path
from urllib.parse import unquote, urlsplit

DEFAULT_FILES = (
    'AGENTS.md',
    'docs/agents/domain.md',
    'docs/agents/issue-tracker.md',
    'docs/agents/triage-labels.md',
    'docs/operations/installation.md',
    'installer/Sources/InstallerActivationPolicy.swift',
    'tests/InstallerActivationPolicyTests.swift',
    'sources/Activation/InputSource.swift',
    'scripts/preinstall',
    'scripts/postinstall',
)
LINK = re.compile(r'!?\[[^\]\n]*\]\(\s*(<[^>]+>|[^\s)]+)(?:\s+"[^"\n]*")?\s*\)')

INLINE = re.compile(r'`([^`\n]+)`')
FILE_PATH = re.compile(r'[^\s`<>*]+\.(?:md|swift|sh|py|yml|yaml|json|txt)$')


def references(line):
    for match in LINK.finditer(line):
        yield match[1].strip('<>')
    for match in INLINE.finditer(LINK.sub('', line)):
        if FILE_PATH.fullmatch(match[1]) or re.fullmatch(r'[\w./-]+/', match[1]):
            yield match[1]


def check(root, files):
    errors = []
    for name in files:
        source = root / name
        if not source.is_file():
            errors.append(f'{name}:1: missing navigation source')
            continue
        fence = None
        for number, line in enumerate(source.read_text().splitlines(), 1):
            if source.suffix == '.md':
                delimiter = re.match(r'^\s{0,3}(`{3,}|~{3,})(.*)$', line)
                if fence:
                    if delimiter and delimiter[1][0] == fence[0] and len(delimiter[1]) >= len(fence) and not delimiter[2].strip():
                        fence = None
                    continue
                if delimiter:
                    fence = delimiter[1]
                    continue
                if re.search(r'<!-- reference-check: (historical|optional) -->', line):
                    continue
            for target in references(line):
                parsed = urlsplit(target)
                if parsed.scheme or parsed.netloc or not parsed.path:
                    continue
                base = source.parent if source.suffix == '.md' else root
                if not (base / unquote(parsed.path)).exists():
                    errors.append(f'{name}:{number}: missing reference: {target}')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--files', nargs='+', default=DEFAULT_FILES)
    args = parser.parse_args()
    errors = check(args.root.resolve(), args.files)
    for error in errors:
        print(error)
    if not errors:
        print(f'navigation references: ok ({len(args.files)} files)')
    return 1 if errors else 0


if __name__ == '__main__':
    raise SystemExit(main())
