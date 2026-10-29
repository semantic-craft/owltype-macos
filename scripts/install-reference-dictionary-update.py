#!/usr/bin/env python3
"""Let the fixed reference Host API install the pinned dictionary through its own updater.

The reference library carries the dictionary lock of its engine tag and refuses other bytes as
bundled resources. A newer pinned `dict-v*` reaches it the way it reaches installed users: the
Host API's dictionary update downloads the newest compatible release into
`<state>/dictionary-updates` and verifies every member. This script runs that update once in
`--output`, then requires the installed release and bytes to equal `rust/msime-source.json`.
Pass the directory to `pinyin-parity.py --reference-dictionary-update`.

The updater takes the newest upstream release, so this works when the pin is upstream's latest
`dict-v*` (the normal re-pin; see docs/operations/msime-repin.md).
"""
import argparse
import ctypes as C
import importlib.util
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
import msime_pin  # noqa: E402

spec = importlib.util.spec_from_file_location('pinyin_parity', ROOT / 'scripts/pinyin-parity.py')
PARITY = importlib.util.module_from_spec(spec)
spec.loader.exec_module(PARITY)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--reference-library', type=Path, required=True)
    parser.add_argument('--reference-resources', type=Path, required=True,
                        help='the bundled resources matching the reference dictionary lock')
    parser.add_argument('--output', type=Path, required=True, help='new state directory to install into')
    parser.add_argument('--timeout', type=int, default=1800, help='seconds to wait for the download')
    args = parser.parse_args()
    if args.output.exists():
        parser.error('--output must not exist yet')
    pin = msime_pin.load(ROOT)
    args.output.mkdir(parents=True)
    state = args.output.resolve()
    reference = PARITY.Reference(args.reference_library.resolve())
    request = json.dumps({'resources': str(args.reference_resources.resolve()), 'state_root': str(state)}).encode()
    options = reference.call('prepare_host', [C.c_char_p, C.c_size_t], request, len(request))

    def update(command, enabled=None):
        action = {'operation': 'updates', 'command': command}
        if enabled is not None:
            action['enabled'] = enabled
        body = json.dumps({'options': options, 'action': action}).encode()
        return reference.call('dictionary', [C.c_char_p, C.c_size_t], body, len(body))

    update('configure', True)
    update('check')
    deadline = time.monotonic() + args.timeout
    while True:
        status = update('status')
        if status['checked_at'] and status['phase'] not in ('checking', 'downloading'):
            break
        if time.monotonic() > deadline:
            raise SystemExit('FAIL: dictionary update did not finish in time')
        time.sleep(2)
    if status['phase'] != 'ready' or status['version'] != pin.release:
        raise SystemExit(f'FAIL: update ended {status["phase"]} at {status["version"]} ({status["error"]}); '
                         f'pinned {pin.release}')
    required = {name: spec['sha256'] for name, spec in pin.files.items()
                if name in ('msime-pinyin.db', 'msime-wubi.db', 'msime-english.db', 'msime-bigram.bin',
                            'msime-trigram.bin', 'msime-others.db', 'msime-scowl_Copyright.txt')}
    required['msime-dictionary-manifest.json'] = pin.manifest_sha256
    PARITY.verify_dictionary_update(state, pin.release, required)
    loaded = reference.call('prepare_host', [C.c_char_p, C.c_size_t], request, len(request))['resources']
    if Path(loaded).resolve().parent != (state / 'dictionary-updates' / 'generations').resolve():
        raise SystemExit(f'FAIL: reference still loads {loaded}')
    print(f'[reference-update] {pin.release} installed by the reference Host API in {state}')


if __name__ == '__main__':
    main()
