#!/usr/bin/env python3
"""Bind manual typing evidence to a specific TextEdit process and window.

Never installs, changes input sources, or synthesizes keystrokes. A successful
save observation still requires the user's confirmation of physical Wubi input.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time
from urllib.parse import unquote, urlparse


def validate(binding, before, after, baseline, saved, started, completed, role):
    errors = []
    for observation in (before, after):
        if observation['binding'] != binding:
            errors.append('Host/window identity changed')
        if observation['frontPID'] != binding['pid'] or not observation['focused']:
            errors.append('Bound window was not focused')
        if observation['source'] != 'im.owltype.inputmethod.Owltype.Hans':
            errors.append('Owltype Hans was not selected')
    if not completed <= before['observedAt'] <= saved['mtime'] <= after['observedAt'] <= completed + 60:
        errors.append('Save not bracketed by observations within 60 seconds')
    if saved['mtime_ns'] <= baseline['mtime_ns'] or saved['nihao_count'] <= baseline['nihao_count']:
        errors.append('No newly saved nihao')
    if saved['nihao_count'] != after['nihaoCount']:
        errors.append('Saved text differs from bound window')
    if role == 'old' and binding['launched'] >= started:
        errors.append('Old host was not running before installation')
    if role == 'new' and binding['launched'] <= completed:
        errors.append('New host predates installation completion')
    return errors


def file_state(binding):
    url = urlparse(binding['document'])
    if url.scheme != 'file' or url.netloc not in ('', 'localhost'):
        raise ValueError('Expected a local document')
    path = Path(unquote(url.path))
    stat = path.stat()
    if path.suffix == '.rtf':
        content = subprocess.check_output(['/usr/bin/textutil', '-convert', 'txt', '-stdout', str(path)], text=True, timeout=2)
    else:
        content = path.read_text()
    if path.stat().st_mtime_ns != stat.st_mtime_ns:
        raise ValueError('Document changed during observation')
    return {'mtime': stat.st_mtime, 'mtime_ns': stat.st_mtime_ns, 'nihao_count': content.count('你好')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', required=True)
    parser.add_argument('--binding', type=Path, required=True)
    parser.add_argument('--completed', type=float, required=True)
    parser.add_argument('--started', type=float, required=True)
    parser.add_argument('--role', choices=['old', 'new'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    binding = json.loads(args.binding.read_text())
    baseline = file_state(binding)

    def observe():
        return json.loads(subprocess.check_output([args.helper, 'inspect', str(args.binding)], text=True, timeout=2))

    before = observe()
    # Other restored copies can share the same file. Baseline the bound window,
    # not whichever process last saved that path.
    baseline['nihao_count'] = before['nihaoCount']
    print(f'请在已调出的{args.role}窗口选猫头鹰，用五笔新增“你好”并按⌘S；脚本会自动切换下一窗口。', flush=True)
    while time.time() <= args.completed + 60:
        time.sleep(.15)
        before_read = observe()
        saved = file_state(binding)
        after = observe()
        if saved['mtime_ns'] != baseline['mtime_ns']:
            errors = validate(binding, before, after, baseline, saved, args.started, args.completed, args.role)
            record = dict(binding=binding, before=before, after=after, baseline=baseline, saved=saved, errors=errors)
            args.output.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
            if errors:
                raise ValueError('; '.join(errors))
            screenshot = args.output.with_suffix('.png')
            subprocess.run(['/usr/sbin/screencapture', '-m', '-x', str(screenshot)], check=True, timeout=3)
            if not screenshot.is_file() or not screenshot.stat().st_size:
                raise ValueError('Save screenshot missing')
            print(f'HOST_SAVE_VERIFIED role={args.role} pid={binding["pid"]}; manual Wubi confirmation still required')
            return
        # A save may occur after this file read but before `after`. Keep the
        # observation preceding the file read as the next save's lower bound.
        before = before_read
    raise ValueError('60-second window expired; not a confirmed product failure')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        raise SystemExit(f'STOP: {exc}') from exc
