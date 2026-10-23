#!/usr/bin/env python3
"""Unregister apps inside one caller-owned disposable tree before deleting it.

Never delete files, reset the database or stop processes. A live executable,
redirected app path or failed registration cleanup retains the caller's tree.
"""
from pathlib import Path
import shutil
import ctypes
import errno
import os
import re
import subprocess
import sys

LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def inside(path, root):
    return path == root or root in path.parents


def registered_apps():
    dump = subprocess.check_output([LSREGISTER, '-dump'], text=True)
    result = []
    for block in re.split(r'\n-{10,}\n', dump):
        if not block.lstrip().startswith('bundle id:'):
            continue
        match = re.search(r'^path:\s+(.+)$', block, re.MULTILINE)
        if match:
            result.append(Path(re.sub(r' \(0x[0-9a-fA-F]+\)$', '', match[1])))
    return result


def running_executables():
    # ps comm can be truncated to 16 characters for CLI-built executables.
    # libproc supplies the kernel's executable path without reading arguments.
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    pids = subprocess.check_output(['/bin/ps', '-U', str(os.getuid()), '-o', 'pid='], text=True)
    paths = []
    for value in pids.split():
        buffer = ctypes.create_string_buffer(4096)
        if library.proc_pidpath(int(value), buffer, len(buffer)) > 0:
            paths.append(Path(os.fsdecode(buffer.value)).resolve())
        elif ctypes.get_errno() not in (errno.ESRCH, errno.ENOENT):
            raise OSError(ctypes.get_errno(), 'Cannot inspect executable; cleanup refused')
    return paths


def prepare(root):
    """Return only after all scoped registrations are gone; raise to retain files."""
    raw = Path(root).absolute()
    if raw.is_symlink():
        raise RuntimeError(f'Refusing redirected cleanup root: {raw}')
    root = raw.resolve()
    if (root in (Path('/'), Path.home().resolve(), Path('/Library'))
            or inside(root, Path('/Applications'))
            or inside(root, Path.home().resolve() / 'Applications')
            or inside(root, Path('/Library/Input Methods'))):
        raise RuntimeError(f'Not a disposable tree: {root}')
    if sys.platform != 'darwin':
        return
    # Executables can have cwd=/ even while their bundle is inside the build tree.
    if any(inside(path, root) for path in running_executables()):
        raise RuntimeError(f'Running executable inside {root}; retained')
    # Read registered paths, including nested helpers and already-deleted products.
    # Do not follow a symlink out of the disposable tree.
    for _ in range(8):
        paths = {p for p in registered_apps() if inside(p, root)}
        if not paths:
            return
        for app in sorted(paths, key=lambda p: len(p.parts), reverse=True):
            if app.resolve() != app or not inside(app.resolve(), root):
                raise RuntimeError(f'Redirected registered path: {app}')
            result = subprocess.run([LSREGISTER, '-u', str(app)], capture_output=True, text=True)
            if result.returncode and '-10814' not in result.stdout + result.stderr:
                raise RuntimeError(f'Unregister failed for {app}: {result.returncode}')
        # Duplicate records can share one path; one -u need not remove them all.
    if any(inside(p, root) for p in registered_apps()):
        raise RuntimeError(f'Registrations survived cleanup in {root}; retained')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--remove':
        target = Path(sys.argv[2])
        prepare(target)
        if target.exists():
            shutil.rmtree(target)
        prepare(target)  # Catch delayed registrations after the last file disappears.
    elif len(sys.argv) == 2:
        prepare(sys.argv[1])
    else:
        raise SystemExit('Usage: cleanup_app_registrations.py [--remove] OWNED_BUILD_TREE')
