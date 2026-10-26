#!/usr/bin/env python3
"""Normalize only PKGs and Owltype's audited inert ZIP in a disposable scan tree.

All outer files/scripts stay in place. Ordinary ZIPs and other archive formats
remain scanner inputs; no secret policy or scanner exclusion is added here.
"""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location('staged_pkg', Path(__file__).with_name('check-staged-pkg.py'))
staged = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staged)


def normalize_expanded(root):
    for component in sorted(root.rglob('Owltype-component.pkg')):
        archive = component / 'Payload' / staged.ARCHIVE
        # A known component is never silently accepted without its inert payload.
        staged.extract_for_scan(component, component.parent / 'checked-app')
        archive.unlink()  # Only our expanded copy, after complete validated materialization.


def normalize(root):
    if root.is_symlink() or not root.is_dir():
        raise ValueError('scan root must be a disposable directory')
    normalize_expanded(root)
    for _ in range(32):
        packages = sorted(path for path in root.rglob('*.pkg') if path.is_symlink() or path.is_file())
        if not packages:
            return
        package = packages[0]
        if package.is_symlink():
            raise ValueError('package symlink is not a scan input')
        staging = Path(tempfile.mkdtemp(prefix='.package-scan-', dir=root))
        expanded = staging / 'expanded'
        subprocess.run(['/usr/sbin/pkgutil', '--expand-full', str(package), str(expanded)],
                       check=True, capture_output=True, timeout=120)
        normalize_expanded(expanded)
        package.unlink()
        expanded.rename(package)  # Same name, now all package metadata/scripts/payload are visible.
        staging.rmdir()
    raise ValueError('too many nested packages')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: normalize-package-scan.py DISPOSABLE_SCAN_TREE')
    try:
        normalize(Path(sys.argv[1]))
    except Exception as error:
        # Archive names and metadata may themselves contain secrets; never echo them.
        raise SystemExit(f'ERROR: package scan normalization failed ({type(error).__name__})') from None
