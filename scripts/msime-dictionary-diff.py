#!/usr/bin/env python3
"""Compare two msime-dictionary releases: added and removed words, weight changes, Wubi collisions.

Each directory holds one release's msime-dictionary-manifest.json and the product members
(msime-pinyin.db, msime-wubi.db, msime-english.db, msime-bigram.bin, msime-trigram.bin).
Read-only; the databases are opened immutable.

  python3 scripts/msime-dictionary-diff.py OLD_DIR NEW_DIR --json report.json --markdown report.md

"Lost unique four-code" follows the engine rule for pure Wubi
(`rust/crates/engine/src/session/composition.rs`, `wubi_unique_four_code`): four letters without
`z` whose whole native list is one row. Database quick phrases are excluded from that list by the
engine, so counting one profile table's rows per code gives the same answer.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import sys
from pathlib import Path

MEMBERS = ('msime-pinyin.db', 'msime-wubi.db', 'msime-english.db', 'msime-bigram.bin',
           'msime-trigram.bin', 'msime-others.db')
WUBI_TABLES = ('wubi86', 'wubi98')
SAMPLE = 15


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def connect(old: Path, new: Path, name: str) -> sqlite3.Connection:
    database = sqlite3.connect(f'{(new / name).resolve().as_uri()}?immutable=1', uri=True)
    database.execute('ATTACH DATABASE ? AS old', (f'{(old / name).resolve().as_uri()}?immutable=1',))
    return database


def table_names(database: sqlite3.Connection, schema: str, prefix: str) -> list[str]:
    return [row[0] for row in database.execute(
        f"SELECT name FROM {schema}.sqlite_master WHERE type='table' AND name LIKE ? ORDER BY name",
        (prefix + '%',))]


def compare_pairs(database: sqlite3.Connection, old_select: str, new_select: str) -> dict:
    """Both selects yield (key, value, weight); duplicates keep their highest weight."""
    database.execute(f'CREATE TEMP TABLE o AS SELECT key, value, max(weight) AS weight FROM ({old_select}) GROUP BY key, value')
    database.execute(f'CREATE TEMP TABLE n AS SELECT key, value, max(weight) AS weight FROM ({new_select}) GROUP BY key, value')
    database.execute('CREATE INDEX temp.o_pair ON o(key, value)')
    database.execute('CREATE INDEX temp.n_pair ON n(key, value)')
    one = lambda sql: database.execute(sql).fetchone()[0]
    result = {
        'rows_old': one('SELECT count(*) FROM o'),
        'rows_new': one('SELECT count(*) FROM n'),
        'keys_old': one('SELECT count(DISTINCT key) FROM o'),
        'keys_new': one('SELECT count(DISTINCT key) FROM n'),
        'added': one('SELECT count(*) FROM n WHERE NOT EXISTS (SELECT 1 FROM o WHERE o.key = n.key AND o.value = n.value)'),
        'removed': one('SELECT count(*) FROM o WHERE NOT EXISTS (SELECT 1 FROM n WHERE n.key = o.key AND n.value = o.value)'),
        'weight_raised': one('SELECT count(*) FROM o JOIN n USING (key, value) WHERE n.weight > o.weight'),
        'weight_lowered': one('SELECT count(*) FROM o JOIN n USING (key, value) WHERE n.weight < o.weight'),
        'added_by_length': dict(database.execute(
            'SELECT length(value), count(*) FROM n WHERE NOT EXISTS (SELECT 1 FROM o WHERE o.key = n.key AND o.value = n.value) '
            'GROUP BY 1 ORDER BY 1').fetchall()),
        'added_weight_range': list(database.execute(
            'SELECT min(weight), max(weight) FROM n WHERE NOT EXISTS (SELECT 1 FROM o WHERE o.key = n.key AND o.value = n.value)').fetchone()),
        'top_added': [list(row) for row in database.execute(
            'SELECT key, value, weight FROM n WHERE NOT EXISTS (SELECT 1 FROM o WHERE o.key = n.key AND o.value = n.value) '
            'ORDER BY weight DESC, key, value LIMIT ?', (SAMPLE,))],
        'removed_sample': [list(row) for row in database.execute(
            'SELECT key, value, weight FROM o WHERE NOT EXISTS (SELECT 1 FROM n WHERE n.key = o.key AND n.value = o.value) '
            'ORDER BY weight DESC, key, value LIMIT ?', (SAMPLE,))],
    }
    # The first candidate of a code is its highest-weight row; ties keep the lowest value.
    database.execute('CREATE TEMP TABLE o_top AS SELECT key, value FROM (SELECT key, value, row_number() OVER '
                     '(PARTITION BY key ORDER BY weight DESC, value) AS rank FROM o) WHERE rank = 1')
    database.execute('CREATE TEMP TABLE n_top AS SELECT key, value FROM (SELECT key, value, row_number() OVER '
                     '(PARTITION BY key ORDER BY weight DESC, value) AS rank FROM n) WHERE rank = 1')
    result['top_row_changed'] = one('SELECT count(*) FROM o_top JOIN n_top USING (key) WHERE o_top.value <> n_top.value')
    result['top_row_changed_sample'] = [list(row) for row in database.execute(
        'SELECT key, o_top.value, n_top.value FROM o_top JOIN n_top USING (key) WHERE o_top.value <> n_top.value '
        'ORDER BY key LIMIT ?', (SAMPLE,))]
    return result


def drop_temp(database: sqlite3.Connection) -> None:
    for name in ('o', 'n', 'o_top', 'n_top'):
        database.execute(f'DROP TABLE IF EXISTS temp.{name}')


def wubi_collisions(database: sqlite3.Connection) -> dict:
    """Codes that gained rows, and four-letter codes that are no longer one row (unique auto-commit)."""
    database.execute('CREATE TEMP TABLE oc AS SELECT key, count(*) AS c FROM o GROUP BY key')
    database.execute('CREATE TEMP TABLE nc AS SELECT key, count(*) AS c FROM n GROUP BY key')
    one = lambda sql: database.execute(sql).fetchone()[0]
    four = "length(key) = 4 AND instr(key, 'z') = 0"
    result = {
        'existing_codes_gaining_rows': one('SELECT count(*) FROM oc JOIN nc USING (key) WHERE nc.c > oc.c'),
        'codes_with_duplicates_old': one('SELECT count(*) FROM oc WHERE c > 1'),
        'codes_with_duplicates_new': one('SELECT count(*) FROM nc WHERE c > 1'),
        'unique_four_codes_old': one(f'SELECT count(*) FROM oc WHERE c = 1 AND {four}'),
        'unique_four_codes_new': one(f'SELECT count(*) FROM nc WHERE c = 1 AND {four}'),
        'lost_unique_four_code': one(f'SELECT count(*) FROM oc JOIN nc USING (key) WHERE oc.c = 1 AND nc.c > 1 AND {four}'),
        'gained_unique_four_code': one(f'SELECT count(*) FROM nc LEFT JOIN oc USING (key) WHERE nc.c = 1 AND coalesce(oc.c, 0) <> 1 AND {four}'),
        'lost_unique_four_code_sample': [list(row) for row in database.execute(
            f'SELECT key, (SELECT value FROM o WHERE o.key = oc.key), nc.c FROM oc JOIN nc USING (key) '
            f'WHERE oc.c = 1 AND nc.c > 1 AND {four} ORDER BY nc.c DESC, key LIMIT ?', (SAMPLE,))],
    }
    database.execute('DROP TABLE temp.oc')
    database.execute('DROP TABLE temp.nc')
    return result


def page_report(database: sqlite3.Connection, schema: str) -> dict:
    pragma = lambda name: database.execute(f'PRAGMA {schema}.{name}').fetchone()[0]
    sizes = dict(database.execute(f'SELECT name, sum(pgsize) FROM dbstat(?) GROUP BY name', (schema,)).fetchall())
    return {'page_size': pragma('page_size'), 'page_count': pragma('page_count'),
            'freelist_count': pragma('freelist_count'), 'bytes_by_object': sizes}


def compare(old: Path, new: Path) -> dict:
    manifests = [json.loads((root / 'msime-dictionary-manifest.json').read_text()) for root in (old, new)]
    report = {'old': {'builder': manifests[0]['format_contract_commit'], 'data': manifests[0]['custom_dictionary_commit']},
              'new': {'builder': manifests[1]['format_contract_commit'], 'data': manifests[1]['custom_dictionary_commit']},
              'members': {}}
    for name in MEMBERS:
        before, after = manifests[0]['files'].get(name), manifests[1]['files'].get(name)
        report['members'][name] = {'size_old': before and before['size'], 'size_new': after and after['size'],
                                   'changed': before != after}
        for root, spec in ((old, before), (new, after)):
            if spec and (root / name).exists() and sha256(root / name) != spec['sha256']:
                raise SystemExit(f'FAIL: {root / name} does not match its manifest')

    database = connect(old, new, 'msime-pinyin.db')
    select = lambda schema: ' UNION ALL '.join(
        f'SELECT key, value, weight FROM {schema}."{table}"' for table in table_names(database, schema, 'tbl_'))
    report['pinyin'] = compare_pairs(database, select('old'), select('main'))
    drop_temp(database)
    report['pinyin_quick_phrases'] = compare_pairs(
        database, 'SELECT key, value, weight FROM old.quick_parases', 'SELECT key, value, weight FROM main.quick_parases')
    database.close()

    database = connect(old, new, 'msime-wubi.db')
    report['wubi'] = {'pages_old': page_report(database, 'old'), 'pages_new': page_report(database, 'main')}
    for table in WUBI_TABLES:
        result = compare_pairs(database, f'SELECT key, value, weight FROM old.{table}', f'SELECT key, value, weight FROM main.{table}')
        result.update(wubi_collisions(database))
        report['wubi'][table] = result
        drop_temp(database)
    database.close()

    database = connect(old, new, 'msime-english.db')
    report['english'] = compare_pairs(
        database, 'SELECT word AS key, display AS value, weight FROM old.english_words',
        'SELECT word AS key, display AS value, weight FROM main.english_words')
    drop_temp(database)
    report['english_glosses'] = {}
    for table, key, value in (('en_zh_glosses', 'english', 'chinese_gloss'), ('zh_en_glosses', 'chinese', 'english_gloss')):
        one = lambda sql: database.execute(sql).fetchone()[0]
        report['english_glosses'][table] = {
            'rows_old': one(f'SELECT count(*) FROM old.{table}'), 'rows_new': one(f'SELECT count(*) FROM main.{table}'),
            'added': one(f'SELECT count(*) FROM main.{table} n WHERE NOT EXISTS (SELECT 1 FROM old.{table} o WHERE o.{key} = n.{key})'),
            'removed': one(f'SELECT count(*) FROM old.{table} o WHERE NOT EXISTS (SELECT 1 FROM main.{table} n WHERE n.{key} = o.{key})'),
            'changed': one(f'SELECT count(*) FROM main.{table} n JOIN old.{table} o USING ({key}) WHERE n.{value} <> o.{value}')}
    database.close()
    return report


def markdown(report: dict, old_label: str, new_label: str) -> str:
    lines = [f'# Dictionary changes: {old_label} → {new_label}', '',
             f'Builder `{report["old"]["builder"]}` → `{report["new"]["builder"]}`; '
             f'dictionary data `{report["old"]["data"]}` → `{report["new"]["data"]}`.', '',
             '| Member | Bytes before | Bytes after | Changed |', '| --- | ---: | ---: | --- |']
    for name, member in report['members'].items():
        lines.append(f'| {name} | {member["size_old"]:,} | {member["size_new"]:,} | {"yes" if member["changed"] else "no"} |')
    sections = [('Pinyin words', report['pinyin']), ('Pinyin quick phrases', report['pinyin_quick_phrases']),
                ('Wubi 86', report['wubi']['wubi86']), ('Wubi 98', report['wubi']['wubi98']),
                ('English words', report['english'])]
    lines += ['', '| Table | Rows before | Rows after | Added | Removed | Weight up | Weight down | First row changed |',
              '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for label, data in sections:
        lines.append(f'| {label} | {data["rows_old"]:,} | {data["rows_new"]:,} | {data["added"]:,} | {data["removed"]:,} '
                     f'| {data["weight_raised"]:,} | {data["weight_lowered"]:,} | {data["top_row_changed"]:,} |')
    for table, data in report['english_glosses'].items():
        lines.append(f'| English {table} | {data["rows_old"]:,} | {data["rows_new"]:,} | {data["added"]:,} | {data["removed"]:,} '
                     f'| {data["changed"]:,} changed | | |')
    lines += ['', '## Wubi collisions', '',
              '| Profile | Codes gaining rows | Codes with duplicates (before → after) | Unique four-codes (before → after) | Lost unique auto-commit | Added rows weight range |',
              '| --- | ---: | ---: | ---: | ---: | --- |']
    for table in WUBI_TABLES:
        data = report['wubi'][table]
        low, high = data['added_weight_range']
        lines.append(f'| {table} | {data["existing_codes_gaining_rows"]:,} | {data["codes_with_duplicates_old"]:,} → '
                     f'{data["codes_with_duplicates_new"]:,} | {data["unique_four_codes_old"]:,} → {data["unique_four_codes_new"]:,} '
                     f'| {data["lost_unique_four_code"]:,} | {low}–{high} |')
    for table in WUBI_TABLES:
        data = report['wubi'][table]
        lengths = ', '.join(f'{length} 字 {count:,}' for length, count in data['added_by_length'].items())
        lines += ['', f'{table} added rows by length: {lengths}.',
                  f'{table} codes that lose unique auto-commit (code, former only row, rows now): ' +
                  '; '.join(f'`{code}` {word} ({count})' for code, word, count in data['lost_unique_four_code_sample'])]
    pages = report['wubi']
    lines += ['', f'Wubi file pages: {pages["pages_old"]["page_count"]:,} → {pages["pages_new"]["page_count"]:,} '
              f'({pages["pages_new"]["page_size"]} bytes each); free pages {pages["pages_old"]["freelist_count"]} → '
              f'{pages["pages_new"]["freelist_count"]}.', '']
    for label, data in sections[:1] + sections[4:]:
        lines.append(f'{label}, highest-weight additions: ' + '; '.join(f'{value} `{key}` {weight}' for key, value, weight in data['top_added']))
        lines.append(f'{label}, first row changed (code, before, after): ' + '; '.join(
            f'`{key}` {before}→{after}' for key, before, after in data['top_row_changed_sample']))
        lines.append('')
    return '\n'.join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('old', type=Path)
    parser.add_argument('new', type=Path)
    parser.add_argument('--json', type=Path)
    parser.add_argument('--markdown', type=Path)
    args = parser.parse_args(argv)
    report = compare(args.old, args.new)
    labels = [json.loads((root / 'msime-dictionary-manifest.json').read_text()).get('release', root.name) for root in (args.old, args.new)]
    text = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    if args.json:
        args.json.write_text(text)
    if args.markdown:
        args.markdown.write_text(markdown(report, *labels))
    if not args.json and not args.markdown:
        sys.stdout.write(text)
    return 0


if __name__ == '__main__':
    sys.exit(main())
