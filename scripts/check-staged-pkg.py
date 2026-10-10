#!/usr/bin/env python3
"""Audit inert PKG payloads; optionally unpack the App for signature/content gates.

No claim about live menu success: only a native install can verify that boundary.
"""
import argparse
import pathlib
import posixpath
import stat
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

ARCHIVE = pathlib.Path('Library/Input Methods/.Owltype.pkg-staging/Owltype.app.zip')


def validate_archive(archive):
    """Reject paths/links that could escape the fresh extraction directory."""
    with zipfile.ZipFile(archive) as zipped:
        names = set()
        entries = {}
        links = set()
        for member in zipped.infolist():
            name = member.filename.rstrip('/')
            path = pathlib.PurePosixPath(name)
            if (not name or name.startswith('/') or '\\' in name or
                    '..' in path.parts or str(path) != name or name in names):
                raise ValueError(f'unsafe/duplicate archive member: {name}')
            names.add(name)
            entries[name] = member
            if not (path.parts[0] == 'Owltype.app' or
                    name == '__MACOSX' or name == '__MACOSX/._Owltype.app' or
                    path.parts[:2] == ('__MACOSX', 'Owltype.app')):
                raise ValueError(f'archive member outside Owltype.app: {name}')
            mode = member.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK):
                raise ValueError(f'special archive member: {name}')
            if stat.S_ISLNK(mode):
                if member.file_size > 4096:
                    raise ValueError('oversized symlink')
                target = zipped.read(member).decode('utf-8')
                resolved = posixpath.normpath(posixpath.join(str(path.parent), target))
                if (target.startswith('/') or '..' in pathlib.PurePosixPath(target).parts or '\\' in target or
                        not resolved.startswith('Owltype.app/')):
                    raise ValueError(f'escaping symlink: {name}')
                links.add(path)
        for name in names:
            if any(parent in links for parent in pathlib.PurePosixPath(name).parents):
                raise ValueError(f'archive writes through symlink: {name}')
        required = {'Owltype.app/Contents/Info.plist', 'Owltype.app/Contents/MacOS/Owltype'}
        if (not required <= names or any(pathlib.PurePosixPath(name) in links for name in required) or
                any(entries[name].is_dir() or stat.S_ISDIR(entries[name].external_attr >> 16)
                    for name in required if name in entries)):
            raise ValueError('archive missing regular App metadata/executable')


def check(component):
    info = ET.parse(component / 'PackageInfo').getroot()
    if info.get('install-location') != '/':
        raise ValueError('component install-location must be /')
    if info.findall('.//bundle') or info.findall('.//relocate/*'):
        raise ValueError('component must not declare bundle registration/relocation')
    payload = component / 'Payload'
    archive = payload / ARCHIVE
    if not archive.is_file() or archive.is_symlink():
        raise ValueError('inert App archive payload is missing')
    # Even empty component metadata let PackageKit register a staged .app in the native failure.
    # The only non-directory payload entry must now be the archive, including nested Sparkle.
    for path in payload.rglob('*'):
        relative = path.relative_to(payload)
        if path.is_symlink():
            raise ValueError(f'payload symlink: {relative}')
        if relative == ARCHIVE or (relative in ARCHIVE.parents and path.is_dir()):
            continue
        raise ValueError(f'payload outside inert archive: {relative}')
    validate_archive(archive)
    return archive


def extract(component, destination):
    archive = check(component)
    destination.mkdir(mode=0o700)  # Refuse reuse or extraction through an existing symlink.
    subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(destination)], check=True)
    app = destination / 'Owltype.app'
    if not (app / 'Contents/Info.plist').is_file():
        raise ValueError('extracted App missing')
    return app


def main():
    if sys.argv[1:] == ['--self-test']:
        return subprocess.call([sys.executable, str(pathlib.Path(__file__).with_name('check-staged-pkg.selftest.py'))])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('component', type=pathlib.Path)
    parser.add_argument('--extract-to', type=pathlib.Path)
    args = parser.parse_args()
    try:
        print(extract(args.component, args.extract_to) if args.extract_to else check(args.component))
    except (ValueError, OSError, ET.ParseError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        parser.exit(1, f'FAIL: {error}\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
