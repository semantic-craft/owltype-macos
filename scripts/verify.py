#!/usr/bin/env python3
"""Run a focused check or the existing gate and retain a local verification receipt."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
LIMITS = ['installed input-method acceptance', 'credential-gated Live suites',
          'signing, notarization and remote publication']


def snapshot(root=ROOT, pinned=None):
    """Describe the checkout at root; a submodule that matches its gitlink is 'pinned'."""
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=root)

    untracked = {}
    for raw in git('ls-files', '--others', '--exclude-standard', '-z').split(b'\0'):
        if not raw:
            continue
        name = os.fsdecode(raw)
        path = root / name
        content = os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes()
        untracked[name] = {'sha256': hashlib.sha256(content).hexdigest(),
                           'mode': path.lstat().st_mode}
    submodules = {}
    for entry in git('ls-files', '--stage', '-z').split(b'\0'):
        if not entry.startswith(b'160000 '):
            continue
        metadata, name = entry.split(b'\t', 1)
        name = os.fsdecode(name)
        path = root / name
        # The gate initializes submodules at their gitlinks. An uninitialized submodule cannot
        # differ from its gitlink, so it records like a clean initialized one and the
        # initialization is not a source change; any other state is recorded in full.
        submodules[name] = (snapshot(path, metadata.split()[1].decode())
                            if (path / '.git').exists() else 'pinned')
    state = {
        'head': git('rev-parse', 'HEAD').decode().strip(),
        'status': git('status', '--porcelain=v1', '--untracked-files=all', '--ignore-submodules=none').decode(),
        'tracked_diff_sha256': hashlib.sha256(git('diff', 'HEAD', '--binary', '--no-ext-diff',
                                                '--no-textconv', '--ignore-submodules=none')).hexdigest(),
        'untracked_sha256': untracked,
        'submodules': submodules,
    }
    if pinned is not None and state == {
            'head': pinned, 'status': '', 'tracked_diff_sha256': hashlib.sha256(b'').hexdigest(),
            'untracked_sha256': {}, 'submodules': dict.fromkeys(submodules, 'pinned')}:
        return 'pinned'
    return state


def plan(scope, tests):
    python = sys.executable
    if scope == 'navigation':
        return [[python, f'scripts/{name}.py'] for name in
                ('check-navigation.selftest', 'check-navigation')]
    if scope == 'distribution':
        return [[python, 'scripts/owl-distribution.selftest.py'],
                [python, 'scripts/check-installed-process.py', '--self-test'],
                ['bash', 'scripts/check-live-ime-version.sh', '--self-test'],
                [python, 'scripts/check-ime-host-evidence.selftest.py'],
                ['bash', 'scripts/release-chain.selftest.sh']]
    if scope == 'workflow':
        return [[python, 'scripts/verify.selftest.py'],
                [python, 'scripts/check-navigation.selftest.py'],
                [python, 'scripts/check-navigation.py']]
    if scope == 'swift':
        return [['make', 'test', 'DERIVED_DATA_PATH=build/focused-tests',
                 'TEST_ONLY=' + ' '.join(tests)]]
    return [['bash', 'scripts/gate.sh'] + (['--quick'] if scope == 'quick' else [])]


def save(folder, receipt):
    temporary = folder / 'result.json.tmp'
    temporary.write_text(json.dumps(receipt, indent=2, ensure_ascii=True) + '\n')
    temporary.replace(folder / 'result.json')
    lines = [f"Verification: {receipt['status']}", '',
             f"Scope: {receipt['scope']}",
             f"Commit: {receipt['before']['head']}",
             f"Worktree initially dirty: {bool(receipt['before']['status'])}",
             f"Source unchanged at end: {receipt.get('source_unchanged', 'pending')}",
             f"Started (UTC): {receipt['started_at']}",
             f"Elapsed seconds: {receipt.get('elapsed_seconds', 'pending')}", '',
             'Commands:', '']
    for step in receipt['steps']:
        lines.append(f"- {step['status']}: `{shlex.join(step['command'])}` "
                     f"({step.get('elapsed_seconds', 'pending')} s; "
                     f"exit {step.get('exit_code', 'pending')}; {step['log']})")
    lines += ['', 'Not covered:', ''] + ['- ' + item for item in receipt['not_covered']]
    if 'gate_stages' in receipt:
        lines += ['', 'Gate stages:', ''] + [
            f"- {item['name']}: {item['status']} ({item.get('elapsed_seconds', 'pending')} s)"
            for item in receipt['gate_stages']]
    lines += ['', 'Local evidence; review before sharing. A dirty-tree result is not a PR-head gate.']
    (folder / 'summary.md').write_text('\n'.join(lines) + '\n')


def run_step(command, log, on_line):
    with log.open('wb') as output:
        process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True,
                                   env={**os.environ, 'OWL_VERIFICATION_ACTIVE': '1'})
        try:
            for line in process.stdout:
                output.write(line)
                output.flush()
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
                on_line(line)
            return process.wait()
        finally:
            # The leader may exit before its children; clean the group, not just wait().
            try:
                os.killpg(process.pid, signal.SIGTERM)
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    process.poll()
                    os.killpg(process.pid, 0)
                    time.sleep(0.05)
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('scope', choices=['navigation', 'distribution', 'workflow', 'swift', 'quick', 'full'])
    parser.add_argument('--test', action='append', default=[], metavar='CLASS[/METHOD]',
                        help='required for swift; repeat to select more tests')
    parser.add_argument('--dry-run', action='store_true', help='print commands; create no receipt')
    args = parser.parse_args()
    if (args.scope == 'swift') != bool(args.test):
        parser.error('swift requires --test; other scopes do not accept --test')
    if any(not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*(/[A-Za-z_][A-Za-z_0-9]*)?', name)
           for name in args.test):
        parser.error('--test must be CLASS or CLASS/METHOD')
    for selection in args.test:
        suite, _, method = selection.partition('/')
        sources = [path.read_text() for path in (ROOT / 'tests').glob('*.swift')
                   if re.search(r'\bclass\s+' + re.escape(suite) + r'\b', path.read_text())]
        if not sources or (method and (not method.startswith('test') or not any(re.search(r'\bfunc\s+' + re.escape(method) + r'\s*\(', source)
                                             for source in sources))):
            parser.error(f'unknown test: {selection}')
        if f'-skip-testing:OwltypeTests/{suite}' in (ROOT / 'Makefile').read_text():
            parser.error(f'{suite} is excluded by the offline test contract')
    commands = plan(args.scope, args.test)
    if args.dry_run:
        for command in commands:
            print(shlex.join(command))
        return 0

    caller_umask = os.umask(0o077)
    evidence = Path(os.environ.get('OWL_VERIFICATION_DIR',
                    str(Path.home() / 'Projects/_shared-work/owltype/verification'))).expanduser().resolve()
    if evidence == ROOT or ROOT in evidence.parents:
        parser.error('OWL_VERIFICATION_DIR must be outside the checkout to survive build cleanup')
    evidence.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-')
                                  + args.scope + '-', dir=evidence))
    os.umask(caller_umask)
    before = snapshot()
    receipt = {
        'schema_version': 1, 'scope': args.scope, 'status': 'running',
        'started_at': datetime.now(timezone.utc).isoformat(), 'before': before,
        'not_covered': LIMITS + ([] if args.scope == 'full' else ['full merge gate']),
        'steps': [{'command': command, 'status': 'not-run', 'log': f'{i:02}.log'}
                  for i, command in enumerate(commands, 1)],
    }
    if args.scope in ('full', 'quick'):
        names = subprocess.check_output(commands[0] + ['--list-stages'], cwd=ROOT, text=True).splitlines()
        receipt['gate_stages'] = [{'name': name, 'status': 'not-run'} for name in names]
    gate_index = -1
    gate_started = 0

    def finish_stage(status):
        if gate_index >= 0:
            receipt['gate_stages'][gate_index].update(
                status=status, elapsed_seconds=round(time.monotonic() - gate_started, 3))

    def on_line(line):
        nonlocal gate_index, gate_started
        if 'gate_stages' not in receipt or not line.startswith(b'OWL_GATE_STAGE\t'):
            return
        name = line.decode().strip().split('\t', 1)[1]
        finish_stage('passed')
        gate_index += 1
        if gate_index >= len(receipt['gate_stages']) or receipt['gate_stages'][gate_index]['name'] != name:
            raise ValueError(f'unexpected gate stage: {name}')
        gate_started = time.monotonic()
        receipt['gate_stages'][gate_index]['status'] = 'running'
        save(folder, receipt)

    save(folder, receipt)
    print(f'Verification evidence: {folder}', flush=True)
    started = time.monotonic()
    code = 0
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        for step in receipt['steps']:
            step['status'] = 'running'
            save(folder, receipt)
            step_started = time.monotonic()
            try:
                code = run_step(step['command'], folder / step['log'], on_line)
                if code == 0 and 'gate_stages' in receipt and gate_index != len(receipt['gate_stages']) - 1:
                    raise ValueError('gate exited without executing all planned stages')
                if code == 0 and args.scope == 'swift':
                    text = (folder / step['log']).read_text(errors='replace')
                    executed = re.findall(r"Test Case '-\[OwltypeTests\.(\w+) (\w+)\]' passed", text)
                    missing = [selection for selection in args.test if not any(
                        selection == suite or selection == f'{suite}/{method}' for suite, method in executed)]
                    if missing:
                        step['unverified_tests'] = missing
                        print('No passing XCTest cases for: ' + ', '.join(missing), file=sys.stderr)
                        code = 1
            except KeyboardInterrupt:
                code = 130
            except (OSError, ValueError) as error:
                print(str(error), file=sys.stderr)
                step['error'] = str(error)
                code = 127
            step.update(exit_code=code, elapsed_seconds=round(time.monotonic() - step_started, 3),
                        status='passed' if code == 0 else 'interrupted' if code == 130 else 'failed')
            finish_stage(step['status'])
            save(folder, receipt)
            if code:
                break
        receipt['status'] = 'passed' if code == 0 else 'interrupted' if code == 130 else 'failed'
    except KeyboardInterrupt:
        receipt['status'] = 'interrupted'
        code = 130
    finally:
        receipt['elapsed_seconds'] = round(time.monotonic() - started, 3)
        receipt['finished_at'] = datetime.now(timezone.utc).isoformat()
        try:
            receipt['after'] = snapshot()
            receipt['source_unchanged'] = receipt['before'] == receipt['after']
            if not receipt['source_unchanged']:
                receipt['status'] = 'source-changed'
                code = code or 1
        except (OSError, subprocess.CalledProcessError) as error:
            receipt['status'] = 'snapshot-failed'
            receipt['error'] = str(error)
            code = code or 1
        save(folder, receipt)
        print(f"Verification {receipt['status']}: {folder / 'summary.md'}", flush=True)
    return code if code >= 0 else 128 - code


if __name__ == '__main__':
    raise SystemExit(main())
