#!/usr/bin/env python3
"""Replay short-code priority and mixed-English placement through real Rime using isolated data.

Usage: python3 scripts/check-pinyin-short-code.py --app /path/Owltype.app --dicts /path/dict-pack
Only the English dictionaries are copied; no live user database is read or changed.
"""
import argparse
from collections import Counter
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def latin(text):
    """Mirror the filter: a Latin row without Han characters."""
    return re.search(r'[A-Za-z]', text) is not None and re.search(r'[\u3400-\u9fff\uf900-\ufaff\U00020000-\U000323af]', text) is None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--dicts', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    app = args.app.resolve()
    shared = app / 'Contents/SharedSupport'
    framework = app / 'Contents/Frameworks'
    env = dict(os.environ, DYLD_LIBRARY_PATH=f'{framework}:{framework}/rime-plugins')
    with tempfile.TemporaryDirectory(prefix='owl-short-code-') as scratch:
        work = Path(scratch)
        user = work / 'user'
        shutil.copytree(shared / '_user_seed', user)
        for name in ['melt_eng.schema.yaml', 'melt_eng.dict.yaml', 'en_dicts/en.dict.yaml',
                     'en_dicts/en_ext.dict.yaml', 'en_dicts/cn_en.txt']:
            target = user / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(args.dicts / name, target)
        subprocess.run([str(app / 'Contents/MacOS/Owltype'), '--build'], check=True,
                       env=dict(env, OWL_TEST_USER_DIR=str(user), OWL_TEST_LOG_DIR=str(work / 'logs')),
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        probe = work / 'probe'
        subprocess.run(['clang++', '-std=c++17', f'-I{root}/librime/src', f'-Wl,-rpath,{framework}',
                        str(root / 'tools/owl-rime-probe.cc'), str(framework / 'librime.1.dylib'),
                        '-o', str(probe)], check=True)

        timings = []

        def run(keys, directory=user, schema="rime_ice", **extra):
            result = subprocess.run([str(probe), str(shared), str(directory), schema, keys, '1000'],
                                    env=dict(env, OWL_PROBE_TIMING="1", **extra), capture_output=True, text=True, check=True)
            assert 'Lua error' not in result.stderr, result.stderr
            assert 'failed to select schema' not in result.stderr, result.stderr
            timings.append((keys, int(re.search(r'^input_us=(\d+)$', result.stdout, re.M)[1])))
            values = re.findall(r'^candidate\[\d+\]=(.*)$', result.stdout, re.M)
            commit = re.search(r'^commit=(.*)$', result.stdout, re.M)[1]
            return values, commit

        values, _ = run('de')
        assert values[:3] == ['的', '得', '地'], values[:8]
        baseline = work / 'baseline'
        shutil.copytree(user, baseline)
        # Bypass only the owned filter in the control fixture, keeping all translators intact.
        (baseline / 'lua/owltype_pinned_words.lua').write_text(
            'return {func=function(input) for c in input:iter() do yield(c) end end}\n')
        original = run('de', baseline)[0]
        assert original.index('的') > 100, 'fixture must reproduce the long English prefix'
        assert len(original) < 1000, 'comparison must include the complete candidate stream'
        assert Counter(values) == Counter(original), 'lost or duplicated candidates'
        def same_rows(keys):
            current, control = run(keys)[0], run(keys, baseline)[0]
            assert len(current) == len(control) and len(set(current)) == len(current), keys
            # Moving English to the tail changes which rows a truncated (1000-row) window holds.
            if len(control) < 1000:
                assert Counter(current) == Counter(control), keys
            return current

        # Whole-syllable input: English never competes by weight, so every Chinese row comes first.
        assert values == [x for x in values if not latin(x)] + [x for x in values if latin(x)], values[:40]
        for keys in ['di', 'shi', 'nihao']:
            current = same_rows(keys)
            assert not any(latin(x) for x in current[:8]), (keys, current[:8])
        # An English word equal to input that pinyin cannot spell leads; otherwise one English
        # row takes the second seat and the rest follow the Chinese rows.
        for keys, word in [('hello', 'hello'), ('dir', 'dir'), ('github', 'GitHub')]:
            current = same_rows(keys)
            assert current[0] == word, (keys, current[:5])
        for keys in ['hel', 'gith']:
            current = same_rows(keys)
            assert not latin(current[0]) and latin(current[1]), (keys, current[:5])
        assert run('hello{space}')[1] == 'hello'
        assert run('def{BackSpace}')[0] == values, 'backspace must restore short-code priority'
        assert run('de', OWL_PROBE_ASCII='1') == ([], ''), 'ASCII input passes through to host'
        assert run('de', OWL_PROBE_PINNED_WORDS='de\t0\t德')[0][:4] == ['德', '的', '得', '地']
        # Redeploying an existing managed block must not duplicate or lose the filter.
        patch = (user / 'rime_ice.custom.yaml').read_bytes()
        subprocess.run([str(app / 'Contents/MacOS/Owltype'), '--build'], check=True,
                       env=dict(env, OWL_TEST_USER_DIR=str(user), OWL_TEST_LOG_DIR=str(work / 'logs')),
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        assert (user / 'rime_ice.custom.yaml').read_bytes() == patch
        assert run('de')[0] == values
        for code in ['a', 'd', 'q', 'z']:
            assert len(run(code)[0]) >= 3
        assert run('de{space}')[1] == '的'
        assert run('de2')[1] == '得'
        assert run('de4')[1] == values[3], 'English numeric commit must match reordered row'
        assert run('de{Page_Down}1')[1] == values[8], 'page 2 selection must match reordered stream'
        print('PASS: real dictionary ordering, no loss/duplicates, English lead/seat, backspace, pins, ASCII, redeploy and commits')
        print('Input + first page latency (microseconds, excludes startup):', timings)

        # A small real-engine translator fixture covers exhausted streams and explicit
        # phrases independently of whichever dictionary pack is installed.
        (user / 'short_fixture.schema.yaml').write_text(
            'schema:\n  schema_id: short_fixture\n  name: Short fixture\n  version: "1"\n'
            'engine:\n  processors: [ascii_composer, speller, selector, express_editor]\n'
            '  segmentors: [ascii_segmentor, abc_segmentor, fallback_segmentor]\n'
            '  translators: [lua_translator@*short_fixture]\n'
            '  filters: [lua_filter@*owltype_pinned_words]\n'
            'speller:\n  alphabet: abcdefghijklmnopqrstuvwxyz\n')
        (user / 'lua/short_fixture.lua').write_text("""
local cases = {
  a = {{'completion', 'alpha'}, {'phrase', '啊'}, {'completion', 'also'}, {'phrase', '阿'}},
  b = {{'completion', 'beta'}, {'completion', 'book'}},
  c = {{'user_table', 'CUSTOM'}, {'completion', 'cat'}, {'phrase', '从'},
       {'phrase', '才'}, {'phrase', '次'}, {'phrase', '此'}},
  d = {{'completion', 'demo'}, {'phrase', '𠀀'}, {'phrase', '的'}, {'phrase', '地'}},
  qwy = {{'phrase', '前'}, {'completion', 'Qwy'}, {'phrase', '钱'}, {'completion', 'qwyz'}},
  qwz = {{'phrase', '前'}, {'completion', 'qwzzz'}, {'phrase', '钱'}, {'completion', 'qwz'}},
  qwx = {{'phrase', '前'}, {'phrase', '钱'}, {'phrase', '千'}, {'completion', 'qwxa'},
         {'completion', 'qwxb'}},
  ta = {{'completion', 'tab'}, {'completion', 'ta'}, {'phrase', '他'}, {'phrase', '她'}},
}
return function(code, seg)
  for _, item in ipairs(cases[code] or cases.a) do
    yield(Candidate(item[1], seg.start, seg._end, item[2], ''))
  end
end
""")
        (user / 'default.custom.yaml').write_text(
            'patch:\n  \"schema_list/@next\": {schema: short_fixture}\n')
        (user / 'build/default.yaml').unlink(missing_ok=True)
        for code, expected in [('a', ['啊', '阿', 'alpha', 'also']), ('b', ['beta', 'book']),
                               ('c', ['CUSTOM', '从', '才', '次', '此', 'cat']),
                               ('d', ['𠀀', '的', '地', 'demo']),
                               ('aaa', ['啊', '阿', 'alpha', 'also']),
                               ('qwy', ['Qwy', '前', '钱', 'qwyz']),
                               ('qwz', ['前', 'qwzzz', '钱', 'qwz']),
                               ('qwx', ['前', 'qwxa', '钱', '千', 'qwxb']),
                               ('ta', ['他', '她', 'ta', 'tab'])]:
            actual = run(code, schema='short_fixture')[0]
            assert actual == expected, (code, actual, expected)
        print('PASS: fewer than three/no Chinese, explicit ASCII phrase, extended Han, English lead and seat')


if __name__ == '__main__':
    main()
