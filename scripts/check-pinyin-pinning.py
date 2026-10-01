#!/usr/bin/env python3
"""Real librime pin/replay/commit regression in temporary data only.
Run with --app /path/to/Owltype.app (copy-owl-seed must have populated SharedSupport).
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve()
    root = Path(__file__).resolve().parent.parent
    shared = app / 'Contents/SharedSupport'
    framework = app / 'Contents/Frameworks'
    env = dict(os.environ, DYLD_LIBRARY_PATH=f'{framework}:{framework}/rime-plugins')
    with tempfile.TemporaryDirectory(prefix='owl-pin-replay-') as scratch:
        work = Path(scratch)
        user = work / 'user'
        shutil.copytree(shared / '_user_seed', user)
        subprocess.run([str(app / 'Contents/MacOS/Owltype'), '--build'], check=True,
                       env=dict(env, OWL_TEST_USER_DIR=str(user), OWL_TEST_LOG_DIR=str(work / 'logs')),
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        probe = work / 'probe'
        subprocess.run(['clang++', '-std=c++17', f'-I{root}/librime/src', f'-Wl,-rpath,{framework}',
                        str(root / 'tools/owl-rime-probe.cc'), str(framework / 'librime.1.dylib'),
                        '-o', str(probe)], check=True)

        def run(keys, pins='', **extra):
            result = subprocess.run([str(probe), str(shared), str(user), 'rime_ice', keys, '30'],
                                    env=dict(env, OWL_PROBE_PINNED_WORDS=pins, **extra),
                                    capture_output=True, text=True, check=True)
            assert 'Lua error' not in result.stderr, result.stderr
            candidates = re.findall(r'^candidate\[\d+\]=(.*)$', result.stdout, re.M)
            commit = re.search(r'^commit=(.*)$', result.stdout, re.M)[1]
            return candidates, commit

        baseline, _ = run('shixing')
        assert baseline and '试行' in baseline, baseline
        pinned = 'shixing\t0\t试行'
        values, _ = run('shixing', pinned)
        assert values[0] == '试行' and values.count('试行') == 1, values
        assert run('shixing{space}', pinned)[1] == '试行'
        assert run('shixing1', pinned)[1] == '试行'
        assert run('shixing2', pinned)[1] == next(w for w in baseline if w != '试行')
        assert run('sx', pinned)[0] == run('sx')[0], 'abbreviated input must not use full-code pins'
        assert run('nihao', pinned)[0] == run('nihao')[0], 'unrelated code changed'
        assert run('shixing', 'shixing\t1\t試行')[0] == baseline, 'traditional pin leaked into simplified mode'
        assert run('shixing', 'shixing\t1\t試行', OWL_PROBE_TRADITIONAL='1')[0][0] == '試行'
        assert run('shixing', '', OWL_PROBE_PIN_UPDATE=pinned)[0][0] == '试行', 'live insertion failed'
        assert run('shixing', pinned, OWL_PROBE_PIN_UPDATE='')[0] == baseline, 'live removal failed'
        assert run('shixing', '', OWL_PROBE_PIN_UPDATE=pinned,
                   OWL_PROBE_AFTER_UPDATE_KEYS='{space}')[1] == '试行', 'replay committed the wrong word'
        print('PASS: pin priority, deduplication, space/numeric commits, full-code and mode isolation, live pin/unpin replay')


if __name__ == '__main__':
    main()
