#!/usr/bin/env python3
"""Replay one public input trace through pinned MSIME Host API and OwlRustEngine.

Build the current Owl test host with `make test TEST_ONLY=OwlRustEngineTests/testExportPinyinParityTrace`.
Then supply its .xctestrun, the reference library and resources explicitly. Exit 1 means
semantic differences, 2 means invalid/incomplete evidence. No installed app is launched.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
FIELDS = ('event', 'consumed', 'input', 'preedit', 'caret', 'page', 'page_size',
          'has_more', 'highlighted', 'candidates', 'commit')
INPUT_SCHEMES = {
    'quanpin': ('quanpin', 'rime_ice', {}),
    'wubi86': ('wubi', 'wubi86_jidian', {'wubi_profile': 'wubi86', 'wubi_mixed_pinyin': False}),
    'wubi86-mixed': ('wubi', 'wubi86_jidian_pinyin', {'wubi_profile': 'wubi86', 'wubi_mixed_pinyin': True}),
    'wubi98': ('wubi', 'wubi98', {'wubi_profile': 'wubi98', 'wubi_mixed_pinyin': False}),
}
COMMANDS = {'backspace': 0, 'commit': 2, 'cancel': 3, 'left': 4, 'right': 5,
            'home': 6, 'end': 7, 'delete': 8, 'next-page': 100, 'previous-page': 101}


def sha256(path):
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def differences(reference, owl):
    result = []
    a, b = reference['steps'], owl['steps']
    if not a or not b:
        result.append({'field': 'empty_trace', 'reference': len(a), 'owl': len(b)})
    for name, steps in [('reference', a), ('owl', b)]:
        for index, step in enumerate(steps):
            missing = sorted(set(FIELDS) - step.keys())
            if missing:
                result.append({'field': 'incomplete_step', 'side': name, 'step': index, 'missing': missing})
            for field, expected in step.get('event', {}).get('expect', {}).items():
                if field not in FIELDS or step.get(field) != expected:
                    result.append({'field': 'fixture_expectation', 'side': name, 'step': index,
                                   'observation': field, 'expected': expected, 'actual': step.get(field)})
    if len(a) != len(b):
        result.append({'field': 'step_count', 'reference': len(a), 'owl': len(b)})
    for index, (left, right) in enumerate(zip(a, b)):
        for field in FIELDS:
            if left.get(field) != right.get(field):
                result.append({'step': index, 'field': field,
                               'reference': left.get(field), 'owl': right.get(field)})
    return result


class Reference:
    def __init__(self, library):
        self.lib = C.CDLL(str(library))
        self.free = self.bind('string_free', [C.c_void_p], None)

    def bind(self, name, arguments, result=C.c_void_p):
        function = getattr(self.lib, 'msime_client_' + name)
        function.argtypes, function.restype = arguments, result
        return function

    def call(self, name, arguments, *values):
        pointer = self.bind(name, arguments)(*values)
        if not pointer:
            raise ValueError(f'{name} returned null')
        try:
            response = json.loads(C.string_at(pointer))
        finally:
            self.free(pointer)
        if not response.get('ok', False):
            raise ValueError(f'{name} failed: {response}')
        return response['value']

    def replay(self, resources, state, events, profile="native-mac-host", scheme="quanpin"):
        request = json.dumps({'resources': str(resources), 'state_root': str(state)}).encode()
        options = self.call('prepare_host', [C.c_char_p, C.c_size_t], request, len(request))
        # macOS requests these host capabilities after prepare_host; they are not
        # persisted preferences. Keep raw-host-api available to reproduce old traces.
        if profile == "native-mac-host":
            options.update(phrase_preedit=True, korean_romaja=True, quick_phrase_candidates=True)
        elif profile != "raw-host-api":
            raise ValueError(f"unsupported reference profile: {profile}")
        reference_scheme, _, preferences = INPUT_SCHEMES[scheme]
        options['preferences'].update(scheme=reference_scheme, **preferences)
        request = json.dumps(options).encode()
        handle = self.call('create', [C.c_char_p, C.c_size_t], request, len(request))['session']
        steps, views = [], []
        try:
            self.call('focus', [C.c_uint64, C.c_bool], handle, True)
            for event in events:
                op = event['op']
                self.bind('key', [C.c_uint64, C.c_uint32], C.c_uint32)(handle, 0 if op == 'character' else 0x80)
                if op == 'character':
                    response = self.call('character', [C.c_uint64, C.c_uint8, C.c_bool],
                                         handle, ord(event['value']), False)
                elif op == 'command':
                    response = self.call('command', [C.c_uint64, C.c_uint32], handle, COMMANDS[event['value']])
                elif op in ('select', 'remove'):
                    view = self.call('view', [C.c_uint64], handle)
                    candidate = view['candidates'][event['index']]
                    identity = candidate['id']
                    response = self.call('select' if op == 'select' else 'remove_candidate', [C.c_uint64, C.c_uint64, C.c_size_t],
                                         handle, identity['generation'], identity['index'])
                elif op == 'restart':
                    self.call('focus', [C.c_uint64, C.c_bool], handle, False)
                    self.call('destroy', [C.c_uint64], handle)
                    handle = self.call('create', [C.c_char_p, C.c_size_t], request, len(request))['session']
                    self.call('focus', [C.c_uint64, C.c_bool], handle, True)
                    response = {'handled': True, 'commit': None,
                                'view': self.call('view', [C.c_uint64], handle)}
                else:
                    raise ValueError(f'unsupported event {event}')
                view = response['view']
                views.append(view)
                candidates = view['candidates']
                steps.append({'event': event, 'consumed': response['handled'],
                              'input': view['editing_text'], 'preedit': view.get('phrase_prefix', '') + view['preedit'],
                              'caret': view['caret_position'], 'page': view['page'],
                              'page_size': view['page_size'],
                              'has_more': view['page'] + 1 < view['page_count'],
                              'highlighted': next((i for i, c in enumerate(candidates) if c['highlighted']), 0),
                              'candidates': [c['text'] for c in candidates], 'commit': response['commit']})
        finally:
            self.call('destroy', [C.c_uint64], handle)
        return {'options': options, 'preferences': options['preferences'], 'steps': steps, 'raw_views': views}


def restart_phases(events):
    phases = [[]]
    for event in events:
        if event['op'] == 'restart' and phases[-1]:
            phases.append([])
        phases[-1].append(event)
    return phases


def reference_replay(library, resources, state, events, profile, scheme="quanpin"):
    # A fresh interpreter per restart proves recovery from disk, beyond in-process caches.
    traces = []
    worker = """import importlib.util,json,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('parity',sys.argv[1])
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
request=json.loads(sys.stdin.read())
trace=module.Reference(request['library']).replay(Path(request['resources']),Path(request['state']),request['events'],request['profile'],request['scheme'])
sys.stdout.write(json.dumps(trace,ensure_ascii=False))
"""
    for phase in restart_phases(events):
        request = dict(library=str(library), resources=str(resources), state=str(state),
                       events=phase, profile=profile, scheme=scheme)
        result = subprocess.run([sys.executable, '-c', worker, str(Path(__file__).resolve())],
                                input=json.dumps(request), capture_output=True, text=True,
                                check=True, timeout=120)
        traces.append(json.loads(result.stdout))
    output = traces[-1]
    output['steps'] = [step for trace in traces for step in trace['steps']]
    output['raw_views'] = [view for trace in traces for view in trace['raw_views']]
    output['process_runs'] = len(traces)
    return output


def source_identity():
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=ROOT)
    untracked = {}
    for raw in git('ls-files', '--others', '--exclude-standard', '-z').split(b'\0'):
        if raw:
            path = ROOT / raw.decode()
            untracked[str(path.relative_to(ROOT))] = sha256(path)
    return {'head': git('rev-parse', 'HEAD').decode().strip(),
            'status': git('status', '--porcelain').decode(),
            'diff_sha256': hashlib.sha256(git('diff', 'HEAD', '--binary')).hexdigest(),
            'untracked_sha256': untracked}


def build_owl(xctestrun):
    if xctestrun.parent.name != 'Products' or xctestrun.parent.parent.name != 'Build':
        raise ValueError('xctestrun must be in the chosen derived-data Build/Products directory')
    before = source_identity()
    commands = [
        ['bash', 'scripts/build-rust-ffi.sh', '--native-only'],
        ['xcodebuild', '-project', 'Owltype.xcodeproj', '-scheme', 'Owltype',
         '-configuration', 'Debug', '-derivedDataPath', str(xctestrun.parent.parent.parent),
         'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'build-for-testing']]
    for command in commands:
        subprocess.run(command, cwd=ROOT, check=True, timeout=600)
    if source_identity() != before:
        raise ValueError('source changed during the Owl build')
    document = plistlib.loads(xctestrun.read_bytes())
    targets = document['TestConfigurations'][0]['TestTargets']
    target = next(t for t in targets if t['BlueprintName'] == 'OwltypeTests')
    host = Path(target['TestHostPath'].replace('__TESTROOT__', str(xctestrun.parent)))
    bundle = Path(target['TestBundlePath'].replace('__TESTHOST__', str(host)))
    return {'source': before, 'commands': commands,
            'host_sha256': sha256(host / 'Contents/MacOS/Owltype'),
            'test_bundle_sha256': sha256(bundle / 'Contents/MacOS/OwltypeTests'),
            'rust_archive_sha256': sha256(ROOT / 'lib/libowl_msime_ffi.a')}


def owl_replay_once(xctestrun, request, output):
    if output.exists():
        output.unlink()
    document = plistlib.loads(xctestrun.read_bytes())
    targets = document.get('TestConfigurations', [{}])[0].get('TestTargets', [])
    if not targets:
        targets = [value for value in document.values() if isinstance(value, dict) and 'TestBundlePath' in value]
    if not targets:
        raise ValueError('xctestrun has no test targets')
    for target in targets:
        target.setdefault('EnvironmentVariables', {}).update(
            OWL_PINYIN_PARITY_REQUEST=str(request), OWL_PINYIN_PARITY_OUTPUT=str(output))
    # __TESTROOT__ references stay relative to the original Products directory.
    with tempfile.NamedTemporaryFile(suffix='.xctestrun', dir=xctestrun.parent) as temporary:
        temporary.write(plistlib.dumps(document)); temporary.flush()
        subprocess.run(['xcodebuild', 'test-without-building', '-xctestrun', temporary.name,
                        '-destination', 'platform=macOS',
                        '-only-testing:OwltypeTests/OwlRustEngineTests/testExportPinyinParityTrace'],
                       cwd=ROOT, check=True, timeout=300)
    if not output.is_file():
        raise ValueError('Owl test did not export a trace (rebuild the current test host)')
    trace = json.loads(output.read_text())
    requested = json.loads(request.read_text())
    if requested.get('schema') and trace.get('configuration', {}).get('schema') != requested['schema']:
        raise ValueError('Owl export used a different input scheme')
    if trace.get('run_id') != requested['run_id']:
        raise ValueError('Owl export belongs to a different replay')
    return trace


def owl_replay(xctestrun, request, output):
    original = json.loads(request.read_text())
    traces = []
    try:
        for phase in restart_phases(original['events']):
            request.write_text(json.dumps(dict(original, events=phase)))
            traces.append(owl_replay_once(xctestrun, request, output))
    finally:
        request.write_text(json.dumps(original))
    result = traces[-1]
    result['steps'] = [step for trace in traces for step in trace['steps']]
    result['process_runs'] = len(traces)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-library', type=Path, required=True)
    parser.add_argument('--reference-resources', type=Path, required=True)
    parser.add_argument('--reference-build-receipt', type=Path,
                        help='build.json from build-pinyin-reference.py; omit for the pinned historical build')
    parser.add_argument('--reference-profile', choices=('native-mac-host', 'raw-host-api'),
                        default='native-mac-host', help='pinned macOS host capabilities or bare API defaults')
    parser.add_argument('--scheme', choices=tuple(INPUT_SCHEMES),
                        help='input scheme; defaults to the trace scheme, then quanpin')
    parser.add_argument('--owl-resources', type=Path, default=ROOT / 'data/owl-rime')
    parser.add_argument('--xctestrun', type=Path, required=True)
    parser.add_argument('--trace', type=Path, default=ROOT / 'tests/fixtures/pinyin-parity/tadefangjian.json')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    baseline = json.loads((ROOT / 'tests/fixtures/pinyin-parity/baseline.json').read_text())
    trace_document = json.loads(args.trace.read_text())
    scheme = args.scheme or trace_document.get('scheme', 'quanpin')
    if scheme not in INPUT_SCHEMES:
        parser.error('unsupported trace scheme: ' + scheme)
    library_hash = sha256(args.reference_library)
    if args.reference_build_receipt:
        receipt = json.loads(args.reference_build_receipt.read_text())
        if not (receipt.get('upstream_commit') == baseline['upstream_commit']
                and receipt.get('source_clean') is True
                and receipt.get('build') == baseline['reference_build']
                and receipt.get('builder_sha256') == sha256(ROOT / 'scripts/build-pinyin-reference.py')
                and receipt.get('library_sha256') == library_hash):
            parser.error('reference build receipt does not match the pinned source, builder and library')
    elif library_hash != baseline['reference_library_sha256']:
        parser.error('reference library differs from historical build; use build-pinyin-reference.py and its receipt')
    required_resources = dict(baseline['resources'])
    if scheme.startswith('wubi'):
        required_resources.update(baseline['wubi_resources'])
    for name, expected in required_resources.items():
        if sha256(args.reference_resources / name) != expected:
            parser.error(f'reference resource differs from pinned baseline: {name}')
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'comparison.json').unlink(missing_ok=True)
    events = trace_document['events']
    build = build_owl(args.xctestrun.resolve())
    with tempfile.TemporaryDirectory(prefix='owl-pinyin-parity-') as state:
        reference = reference_replay(args.reference_library.resolve(), args.reference_resources.resolve(), Path(state) / 'reference', events, args.reference_profile, scheme)
        request = args.output.resolve() / 'owl-request.json'
        request.write_text(json.dumps({'run_id': str(uuid.uuid4()), 'events': events, 'resources': str(args.owl_resources.resolve()),
                                       'state_root': str(Path(state) / 'owl'), 'schema': INPUT_SCHEMES[scheme][1], 'page_size': reference['preferences']['candidate_page_size']}))
        owl = owl_replay(args.xctestrun.resolve(), request, args.output.resolve() / 'owl.json')
    if source_identity() != build['source']:
        raise ValueError('source changed during replay')
    diff = differences(reference, owl)
    if len(owl['steps']) != len(events) or len(reference['steps']) != len(events):
        raise ValueError('trace did not replay every requested input event')
    result = {'baseline': baseline, 'reference': reference, 'owl': owl,
              'differences': diff, 'equal': not diff,
              'owl_build': build,
              'configuration_contract': {'reference': args.reference_profile,
                  'reference_host_capabilities': {
                      'source': 'platforms/macos/src/input/InputController.mm:6050-6070 MSIMESessionOptions',
                      'upstream_commit': baseline['upstream_commit'],
                      'overrides': ({'phrase_preedit': True, 'korean_romaja': True, 'quick_phrase_candidates': True}
                                    if args.reference_profile == 'native-mac-host' else {})},
                  'owl': 'empty isolated defaults, requested input schema, equal page size; other differences retained',
                  'scheme': scheme,
                  'forced_equal': [f'schema={INPUT_SCHEMES[scheme][0]}/{INPUT_SCHEMES[scheme][1]}',
                                   f'page_size={reference["preferences"]["candidate_page_size"]}']},
              'trace_sha256': sha256(args.trace), 'owl_resources': {
                  p.name: sha256(p) for p in sorted((args.owl_resources / 'msime').glob('*')) if p.is_file()}}
    (args.output / 'comparison.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'equal': not diff, 'differences': len(diff), 'output': str(args.output)}, ensure_ascii=False))
    return int(bool(diff))


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, KeyError, OSError, AttributeError, subprocess.SubprocessError) as error:
        print(f'Incomplete parity evidence: {error}', file=sys.stderr)
        raise SystemExit(2)
