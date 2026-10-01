#!/usr/bin/env python3
"""Exercise #181 with a built app and pinned dict-pack files, using temporary data only.

Usage: python3 scripts/check-pinyin-mixed-input.py --app /path/Owltype.app --dicts /path/dict-pack
The dictionary root must contain the five English resources from the current manifest.
No downloads, input-source registration, or changes to the installed app/user data.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--dicts', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    app = args.app.resolve()
    shared = app / 'Contents/SharedSupport'
    framework = app / 'Contents/Frameworks'
    manifest = (root / 'sources/DictPack/OwlDictPackManifestData.swift').read_text()
    files = ['melt_eng.schema.yaml', 'melt_eng.dict.yaml', 'en_dicts/en.dict.yaml',
             'en_dicts/en_ext.dict.yaml', 'en_dicts/cn_en.txt']
    for name in files:
        line = next(line for line in manifest.splitlines() if f'path: "{name}"' in line)
        expected = re.search(r'sha256: "([^"]+)"', line)[1]
        assert hashlib.sha256((args.dicts / name).read_bytes()).hexdigest() == expected, name
    env = dict(os.environ, DYLD_LIBRARY_PATH=f'{framework}:{framework}/rime-plugins')
    with tempfile.TemporaryDirectory(prefix='owl-mixed-replay-') as scratch:
        work = Path(scratch)
        probe = work / 'probe'
        subprocess.run(['clang++', '-std=c++17', f'-I{root}/librime/src', f'-Wl,-rpath,{framework}',
                        str(root / 'tools/owl-rime-probe.cc'), str(framework / 'librime.1.dylib'),
                        '-o', str(probe)], check=True)

        def deploy(user):
            result = subprocess.run([str(app / 'Contents/MacOS/Owltype'), '--build'],
                                    env=dict(env, OWL_TEST_USER_DIR=str(user), OWL_TEST_LOG_DIR=str(user / 'logs')),
                                    capture_output=True, text=True)
            assert result.returncode == 0, result.stderr

        def check(user, keys, expected, *, commit=False, absent=False):
            result = subprocess.run([str(probe), str(shared), str(user), 'rime_ice', keys, '100'],
                                    env=env, capture_output=True, text=True, check=True)
            values = re.findall(r'^candidate\[\d+\]=(.*)$', result.stdout, re.M)
            if commit:
                passed = f'commit={expected}\n' in result.stdout
            else:
                passed = (expected not in values) if absent else (expected in values)
            assert passed, f'{user.name} {keys}:\n{result.stdout}'
            print(f'PASS: {user.name}: {keys} -> {expected}' + (' absent' if absent else ''))

        for mode in ['download', 'upgrade', 'templates', 'custom']:
            user = work / mode
            shutil.copytree(shared / '_user_seed', user)
            if mode == 'download':
                deploy(user)
                check(user, 'nihao', '你好')
                check(user, 'hello', 'hello', absent=True)
            for name in files:
                target = user / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(args.dicts / name, target)
            custom = user / 'rime_ice.custom.yaml'
            if mode == 'templates':
                custom.write_text('patch:\n  "engine/translators/+":\n    - table_translator@owl_templates\n'
                                  '  owl_templates:\n    dictionary: ""\n    user_dict: owl_templates\n'
                                  '    db_class: stabledb\n    enable_completion: false\n'
                                  '    enable_sentence: false\n    initial_quality: 99\n')
                (user / 'owl_templates.txt').write_text('# Rime table\n# coding: utf-8\n'
                    '#@/db_name\towl_templates\n#@/db_type\ttabledb\n保留模板\tzztest\t100000\n')
            if mode == 'custom':
                custom.write_text('patch:\n  "engine/translators": [script_translator]\n')
                original = custom.read_bytes()
            deploy(user)
            if mode == 'custom':
                assert custom.read_bytes() == original
                check(user, 'nihao', '你好')
                check(user, 'hello', 'hello', absent=True)
                continue
            for keys, expected in [('hello', 'hello'), ('gith', 'GitHub'), ('hell', 'hello'),
                                   ('qqqun', 'QQ群'), ('xguang', 'X光'), ('nihao', '你好')]:
                check(user, keys, expected)
            check(user, 'hello{space}', 'hello', commit=True)
            check(user, 'hello{Return}', 'hello', commit=True)
            if mode == 'templates':
                check(user, 'zztest', '保留模板')
            original = custom.read_bytes()
            deploy(user)
            assert custom.read_bytes() == original, 'Repeated deployment changed the patch'
            compiled = (user / 'build/rime_ice.schema.yaml').read_text()
            for translator in ['table_translator@melt_eng', 'table_translator@cn_en']:
                assert compiled.count(translator) == 1, translator
        print('PASS: download, upgrade, templates, user overrides, and idempotent deployment')


if __name__ == '__main__':
    main()
