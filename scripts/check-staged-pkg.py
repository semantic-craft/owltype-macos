#!/usr/bin/env python3
"""Audit inert PKG payloads; optionally unpack the App for signature/content gates.

No claim about live menu success: only a native install can verify that boundary.
"""
import argparse
import pathlib
import posixpath
import stat
import struct
import zlib
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
            if member.orig_filename != member.filename:
                raise ValueError('archive member contains a NUL name')
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
    if component.is_symlink() or not component.is_dir():
        raise ValueError('component must be a regular directory')
    metadata = component / 'PackageInfo'
    if metadata.is_symlink() or not metadata.is_file():
        raise ValueError('component metadata must be a regular file')
    info = ET.parse(metadata).getroot()
    if info.get('install-location') != '/':
        raise ValueError('component install-location must be /')
    if info.findall('.//bundle') or info.findall('.//relocate/*'):
        raise ValueError('component must not declare bundle registration/relocation')
    payload = component / 'Payload'
    if payload.is_symlink() or not payload.is_dir():
        raise ValueError('component payload must be a regular directory')
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


def scan_archive_metadata(archive, zipped):
    """Account for the complete ZIP32 layout before replacing its compressed view.

    Only the canonical layouts produced by our packager are supported. Reject
    prefix/trailer/gaps/overlap/ZIP64/multidisk instead of dropping opaque bytes.
    Names, both extra fields, all comments and link-target member data are scanned.
    """
    members = zipped.infolist()
    opaque = []
    with archive.open('rb') as stream:
        def read_exact(count):
            value = stream.read(count)
            if len(value) != count:
                raise ValueError('truncated ZIP structure')
            return value
        end = archive.stat().st_size - len(zipped.comment) - 22
        if end < 0:
            raise ValueError('missing ZIP end record')
        stream.seek(end)
        end_header = read_exact(22)
        record = struct.unpack('<4s4H2IH', end_header)
        opaque.append(end_header[4:] + zipped.comment)  # Fixed ZIP signatures are not opaque content.
        if (record[0] != b'PK\x05\x06' or record[1:3] != (0, 0)
                or record[3] != len(members) or record[4] != len(members)
                or len(members) >= 65535 or record[7] != len(zipped.comment)
                or record[5] + record[6] != end):
            raise ValueError('unsupported ZIP end/trailing structure')
        central = record[6]
        stream.seek(central)
        for member in members:
            raw_header = read_exact(46)
            header = struct.unpack('<4s6H3I5H2I', raw_header)
            name = read_exact(header[10]); extra = read_exact(header[11]); comment = read_exact(header[12])
            encoding = 'utf-8' if member.flag_bits & 0x800 else 'cp437'
            if (header[0] != b'PK\x01\x02' or header[13] != 0
                    or header[3] != member.flag_bits or header[4] != member.compress_type
                    or header[7:10] != (member.CRC, member.compress_size, member.file_size)
                    or header[16] != member.header_offset or name.decode(encoding) != member.orig_filename
                    or extra != member.extra or comment != member.comment):
                raise ValueError('inconsistent ZIP central directory')
            # Adjacent fields may share a token; never insert separators inside a record.
            opaque.append(raw_header[4:] + name + extra + comment)
        if stream.tell() != end:
            raise ValueError('unaccounted ZIP directory data')
        cursor = 0
        for member in sorted(members, key=lambda entry: entry.header_offset):
            if (member.header_offset != cursor or member.flag_bits & ~(0x8 | 0x800)
                    or member.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)):
                raise ValueError('ZIP gap/overlap or unsupported flags')
            stream.seek(cursor)
            raw_header = read_exact(30)
            header = struct.unpack('<4s5H3I2H', raw_header)
            name = read_exact(header[9]); extra = read_exact(header[10])
            encoding = 'utf-8' if member.flag_bits & 0x800 else 'cp437'
            if (header[0] != b'PK\x03\x04' or header[2] != member.flag_bits
                    or header[3] != member.compress_type or name.decode(encoding) != member.orig_filename):
                raise ValueError('inconsistent ZIP local header')
            expected = (member.CRC, member.compress_size, member.file_size)
            if member.flag_bits & 8:
                if any(value not in (0, actual) for value, actual in zip(header[6:9], expected)):
                    raise ValueError('unsupported ZIP64/local sizes')
            elif header[6:9] != expected:
                raise ValueError('inconsistent ZIP CRC/sizes')
            opaque.append(raw_header[4:] + name + extra)
            cursor = stream.tell() + member.compress_size
            if member.flag_bits & 8:
                stream.seek(cursor)
                first = read_exact(4)
                descriptor = read_exact(12) if first == b'PK\x07\x08' else first + read_exact(8)
                opaque.append(descriptor)
                if struct.unpack('<3I', descriptor) != expected:
                    raise ValueError('inconsistent ZIP data descriptor')
                cursor = stream.tell()
        if cursor != central:
            raise ValueError('ZIP prefix/trailing/overlapping member data')
    return b'\n'.join(opaque)


def copy_scan_member(archive, member, output):
    """Decode the complete compressed range, rejecting ignored tail bytes too."""
    decoder = zlib.decompressobj(-15) if member.compress_type == zipfile.ZIP_DEFLATED else None
    size = 0
    crc = 0
    with archive.open('rb') as source:
        source.seek(member.header_offset + 26)
        names, extra = struct.unpack('<HH', source.read(4))
        source.seek(member.header_offset + 30 + names + extra)
        remaining = member.compress_size
        while remaining:
            compressed = source.read(min(65536, remaining))
            if not compressed:
                raise ValueError('truncated compressed ZIP payload')
            remaining -= len(compressed)
            data = decoder.decompress(compressed) if decoder else compressed
            if decoder and (decoder.unused_data or decoder.unconsumed_tail):
                raise ValueError('unaccounted compressed ZIP tail')
            size += len(data)
            if size > member.file_size:
                raise ValueError('ZIP output exceeds declared member size')
            crc = zlib.crc32(data, crc)
            if output is not None:
                output.write(data)
    if (size != member.file_size or crc != member.CRC
            or (decoder is not None and not decoder.eof)):
        raise ValueError('incomplete/CRC-damaged ZIP payload')


def extract_for_scan(component, destination):
    """Materialize every validated member once; do not execute or follow links.

    This is a scan view, not an installable App. Internal links remain target
    text files, AppleDouble members remain ordinary files, and opaque ZIP
    metadata is also scanned. The caller may drop its disposable original only
    after this function completes every CRC-checked member read.
    """
    archive = check(component)
    with zipfile.ZipFile(archive) as zipped:
        metadata = scan_archive_metadata(archive, zipped)
        destination.mkdir(mode=0o700)
        for member in zipped.infolist():
            target = destination / member.filename.rstrip('/')
            mode = member.external_attr >> 16
            if member.is_dir() or stat.S_ISDIR(mode):
                if member.file_size:
                    raise ValueError('nonempty ZIP directory member')
                copy_scan_member(archive, member, None)
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('xb') as output:
                copy_scan_member(archive, member, output)
            if target.stat().st_size != member.file_size:
                raise ValueError('incomplete ZIP member scan view')
        (destination / 'archive-metadata.txt').write_bytes(metadata)
    return destination / 'Owltype.app'


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
