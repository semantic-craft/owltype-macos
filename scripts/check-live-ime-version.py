#!/usr/bin/env python3
"""Bounded, read-only live-version evidence. A PASS is not a typing acceptance."""
import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import sys
import time

APP = Path('/Library/Input Methods/Owltype.app')
EXE = APP / 'Contents/MacOS/Owltype'
PLIST = APP / 'Contents/Info.plist'
CHECKER = Path(__file__).with_name('check-installed-process.py')


def process_start(text):
    # ps inherits LC_ALL=C and TZ=UTC. Its lstart field has one-second resolution.
    return datetime.strptime(text.strip(), '%a %b %d %H:%M:%S %Y').replace(
        tzinfo=timezone.utc).timestamp()


def ls_identity(text):
    """Parse only requested fields; unknown/missing formats fail closed."""
    patterns = {
        'pid': r'\bpid\s*=\s*(\d+)\b',
        'version': r'\bVersion="([^"\n]+)"',
        'bundle': r'\bbundle path="([^"\n]+)"',
        'executable': r'\bexecutable path="([^"\n]+)"',
    }
    values = {}
    for key, pattern in patterns.items():
        matches = re.findall(pattern, text)
        if len(matches) != 1:
            raise ValueError(f'lsappinfo: expected exactly one {key}, got {matches!r}')
        values[key] = matches[0]
    return values


def assess(data, target=None, installed_after=None, completed_at=None, expected_source=None):
    failures = list(data['errors'])
    if not data['pids']:
        failures.append('no running Owltype process')
    if len(data['pids']) != 1:
        failures.append('expected one stable Owltype server process')
    if data['pids'] != data['final_pids']:
        failures.append('process set changed during probe; capture again')
    if data['disk_before'] != data['disk_after']:
        failures.append('installed bundle changed during probe; capture again')
    disk = data['disk_before']
    if target is not None and disk.get('version') != target:
        failures.append('installed CFBundleVersion differs from target')
    for proc in data['processes']:
        pid = proc['pid']
        if proc['pgrep_path'] != str(EXE) or proc['command'] != str(EXE):
            failures.append(f'PID {pid}: executable path is not the installed server')
        if installed_after is not None and proc['started_at'] <= installed_after:
            failures.append(f'PID {pid}: start is not provably later than installation start')
        identity = proc['ls']
        if (identity['pid'] != pid or identity['bundle'] != str(APP)
                or identity['executable'] != str(EXE)):
            failures.append(f'PID {pid}: lsappinfo identity mismatch')
        if identity['version'] != disk.get('version'):
            failures.append(f'PID {pid}: lsappinfo version differs from installed CFBundleVersion')
        if target is not None and identity['version'] != target:
            failures.append(f'PID {pid}: lsappinfo version differs from target')
    if len(data['processes']) != len(data['pids']):
        failures.append('incomplete per-process evidence')
    if data['inode_check_rc'] != 0:
        failures.append('check-installed-process.py failed (live executable inode)')
    if not data['source']:
        failures.append('current input source could not be read')
    if expected_source is not None and data['source'] != expected_source:
        failures.append('selected source differs from pre-install/expected source')
    if completed_at is not None:
        if not installed_after <= completed_at <= data['observed_at']:
            failures.append('invalid installation timestamps')
        if data['finished_at'] > completed_at + 60:
            failures.append('capture did not finish within 60 seconds of installation completion')
    return failures


class Capture:
    def __init__(self):
        self.deadline = time.monotonic() + 25
        self.errors = []

    def run(self, argv, allowed=(0,)):
        print(f'\n$ {shlex.join(map(str, argv))}', flush=True)
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            self.errors.append('25-second probe budget exhausted')
            print('exit=124 (probe budget exhausted)', flush=True)
            return 124, ''
        try:
            result = subprocess.run(list(map(str, argv)), capture_output=True, text=True,
                                    timeout=min(5, remaining), check=False,
                                    env={**os.environ, 'LC_ALL': 'C', 'TZ': 'UTC'})
            print(result.stdout, end='' if result.stdout.endswith('\n') else '\n')
            if result.stderr:
                print('stderr:\n' + result.stderr, end='\n')
            print(f'exit={result.returncode}', flush=True)
            if result.returncode not in allowed:
                self.errors.append(f'{Path(str(argv[0])).name}: exit {result.returncode}')
            return result.returncode, result.stdout
        except (OSError, subprocess.TimeoutExpired) as error:
            self.errors.append(f'{Path(str(argv[0])).name}: {error}')
            print(f'exit=124/127: {error}', flush=True)
            return 124, ''

    def disk(self):
        try:
            value = plistlib.loads(PLIST.read_bytes())
            stat = EXE.stat()
            return {'version': str(value['CFBundleVersion']),
                    'marketing_version': str(value.get('CFBundleShortVersionString', '')),
                    'device': stat.st_dev, 'inode': stat.st_ino,
                    'size': stat.st_size, 'mtime_ns': stat.st_mtime_ns}
        except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
            self.errors.append(f'installed bundle: {error}')
            return {}


def collect():
    capture = Capture()
    data = {'observed_at': time.time(), 'errors': capture.errors, 'processes': []}
    capture.run(['/usr/bin/sw_vers'])
    capture.run(['/usr/bin/uname', '-m'])
    data['disk_before'] = capture.disk()
    print('installed=' + json.dumps(data['disk_before'], sort_keys=True), flush=True)
    _, raw = capture.run(['/usr/bin/pgrep', '-lf', 'Owltype'], allowed=(0, 1))
    paths = dict(re.findall(r'^(\d+)\s+(.+)$', raw, re.MULTILINE))
    pid_args = ['/usr/bin/pgrep', '-U', str(os.getuid()), '-x', 'Owltype']
    _, text = capture.run(pid_args, allowed=(0, 1))
    data['pids'] = sorted(text.split())
    for pid in data['pids']:
        if not pid.isdigit():
            capture.errors.append('invalid PID output')
            continue
        _, started = capture.run(['/bin/ps', '-p', pid, '-o', 'lstart='])
        _, command = capture.run(['/bin/ps', '-p', pid, '-o', 'command='])
        _, info = capture.run(['/usr/bin/lsappinfo', 'info', '-only',
                               'pid,bundlepath,executablepath,CFBundleVersion', pid])
        try:
            data['processes'].append({'pid': pid, 'pgrep_path': paths.get(pid),
                                      'command': command.strip(),
                                      'started_at': process_start(started),
                                      'ls': ls_identity(info)})
        except ValueError as error:
            capture.errors.append(str(error))
    data['inode_check_rc'], _ = capture.run([sys.executable, '-B', CHECKER])
    # Main.swift handles this read-only CLI before NSApplication/IMK/Rime setup.
    _, source = capture.run([EXE, '--current-input-source'])
    data['source'] = source.strip()
    _, final = capture.run(pid_args, allowed=(0, 1))
    data['final_pids'] = sorted(final.split())
    data['disk_after'] = capture.disk()
    data['finished_at'] = time.time()
    return data


def epoch(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError('expected positive finite Unix epoch seconds')
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--snapshot', action='store_true', help='observation only; never an acceptance PASS')
    parser.add_argument('--target-version', help='target CFBundleVersion, not marketing version')
    parser.add_argument('--installed-after', type=epoch, help='epoch recorded BEFORE installation begins')
    parser.add_argument('--completed-at', type=epoch, help='epoch recorded when installation completes')
    parser.add_argument('--expect-selected', help='exact pre-install source ID; checked without changing it')
    args = parser.parse_args()
    required = (args.target_version, args.installed_after, args.completed_at)
    if args.snapshot and any(value is not None for value in required):
        parser.error('--snapshot cannot be combined with version/time acceptance arguments')
    if not args.snapshot and any(value is None for value in required):
        parser.error('provide --snapshot OR all of --target-version --installed-after --completed-at')
    if sys.platform != 'darwin' or os.getuid() == 0:
        parser.error('run as the logged-in macOS user, without sudo')
    data = collect()
    failures = assess(data, args.target_version, args.installed_after, args.completed_at, args.expect_selected)
    print('\nEVIDENCE_JSON=' + json.dumps(data, sort_keys=True))
    for failure in failures:
        print('FAIL: ' + failure)
    print('MANUAL_PENDING: input-menu screenshot; old/new TextEdit actual 你好 commit; no logout prompt')
    status = 'FAIL' if failures else ('OBSERVATION' if args.snapshot else 'PASS_VERSION_ONLY')
    print(f'RESULT={status}')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
