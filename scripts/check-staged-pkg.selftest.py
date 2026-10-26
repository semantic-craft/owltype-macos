#!/usr/bin/env python3
"""Regression: empty bundle metadata did not prevent PackageKit registering staged Apps."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import os
import stat
import struct
import zlib
import warnings
import shutil
import subprocess
import io
import zipfile

spec = importlib.util.spec_from_file_location('staged_pkg', Path(__file__).with_name('check-staged-pkg.py'))
staged_pkg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staged_pkg)

normalizer_spec = importlib.util.spec_from_file_location('package_scan', Path(__file__).with_name('normalize-package-scan.py'))
package_scan = importlib.util.module_from_spec(normalizer_spec)
normalizer_spec.loader.exec_module(package_scan)


class StagedPackageTests(unittest.TestCase):
    def test_rejects_the_native_failed_payload_even_with_empty_bundle_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            component = Path(directory)
            (component / 'PackageInfo').write_text('<pkg-info install-location="/"><bundle-version/><relocate/></pkg-info>')
            app = component / 'Payload/Library/Input Methods/.Owltype.pkg-staging/Owltype.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_text('same layout that PackageKit registered after postinstall')
            with self.assertRaises(ValueError):
                staged_pkg.check(component)

    def fixture(self, root):
        (root / 'PackageInfo').write_text('<pkg-info install-location="/"><bundle-version/><relocate/></pkg-info>')
        archive = root / 'Payload' / staged_pkg.ARCHIVE
        archive.parent.mkdir(parents=True)
        self.write_archive(archive)
        return archive

    def write_archive(self, archive, extras=()):
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as zipped:
            for name, content in [('Owltype.app/Contents/Info.plist', 'fixture'),
                                  ('Owltype.app/Contents/MacOS/Owltype', 'executable'), *extras]:
                zipped.writestr(name, content)

    def test_archive_extracts_for_content_gates_and_refuses_existing_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.fixture(root)
            self.assertEqual(staged_pkg.check(root), archive)
            app = staged_pkg.extract(root, root / 'checked')
            self.assertEqual((app / 'Contents/MacOS/Owltype').read_text(), 'executable')
            with self.assertRaises(FileExistsError):
                staged_pkg.extract(root, root / 'checked')

    def test_rejects_extra_payload_even_when_valid_archive_exists(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            for extra in ['Library/Input Methods/Owltype.app/Contents/Info.plist',
                          'Library/Input Methods/.Owltype.pkg-staging/Sparkle.app/Contents/Info.plist']:
                path = root / 'Payload' / extra
                path.parent.mkdir(parents=True)
                path.write_text('bundle')
                with self.assertRaises(ValueError):
                    staged_pkg.check(root)
                path.unlink()

    def test_archive_symlink_and_metadata_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.fixture(root)
            for info in ['<pkg-info install-location="/Library/Input Methods"/>',
                         '<pkg-info install-location="/"><bundle path="Owltype.app"/></pkg-info>',
                         '<pkg-info install-location="/"><relocate><location/></relocate></pkg-info>']:
                (root / 'PackageInfo').write_text(info)
                with self.assertRaises(ValueError):
                    staged_pkg.check(root)
            (root / 'PackageInfo').write_text('<pkg-info install-location="/"/>')
            archive.rename(root / 'real.zip')
            archive.symlink_to(root / 'real.zip')
            with self.assertRaises(ValueError):
                staged_pkg.check(root)

    def test_zip_paths_links_and_special_files_cannot_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.fixture(root)
            for name in ['../outside', '/absolute', 'Owltype.app/../../outside', 'Other.app/file']:
                self.write_archive(archive, [(name, 'bad')])
                with self.subTest(name=name), self.assertRaises(ValueError):
                    staged_pkg.check(root)
            for target in ['/tmp/escape', '../../../escape']:
                link = zipfile.ZipInfo('Owltype.app/Contents/link')
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                self.write_archive(archive, [(link, target)])
                with self.subTest(target=target), self.assertRaises(ValueError):
                    staged_pkg.check(root)
            link = zipfile.ZipInfo('Owltype.app/Contents/link')
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            self.write_archive(archive, [(link, 'MacOS'), ('Owltype.app/Contents/link/writer', 'bad')])
            with self.assertRaises(ValueError):
                staged_pkg.check(root)
            special = zipfile.ZipInfo('Owltype.app/Contents/fifo')
            special.external_attr = (stat.S_IFIFO | 0o600) << 16
            self.write_archive(archive, [(special, '')])
            with self.assertRaises(ValueError):
                staged_pkg.check(root)

    def test_scan_copy_preserves_every_member_and_opaque_zip_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.fixture(root)
            marker = b'opaque-comment-and-extra-marker'
            info = zipfile.ZipInfo('Owltype.app/Contents/Resources/data')
            info.comment = marker
            info.extra = struct.pack('<HH', 0xcafe, len(marker)) + marker
            link = zipfile.ZipInfo('Owltype.app/Contents/link')
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            self.write_archive(archive, [(info, 'all-member-bytes'), (link, 'MacOS'),
                ('__MACOSX/._Owltype.app', 'appledouble-content')])
            with zipfile.ZipFile(archive, 'a') as z:
                z.comment = marker
            destination = root / 'scan'
            staged_pkg.extract_for_scan(root, destination)
            self.assertEqual((destination / info.filename).read_text(), 'all-member-bytes')
            self.assertEqual((destination / '__MACOSX/._Owltype.app').read_text(), 'appledouble-content')
            self.assertFalse((destination / link.filename).is_symlink())
            self.assertEqual((destination / link.filename).read_text(), 'MacOS')
            self.assertGreaterEqual((destination / 'archive-metadata.txt').read_bytes().count(marker), 3)
            self.assertTrue(archive.is_file(), 'extraction alone never deletes caller data')

    def test_scan_copy_rejects_trailing_prefix_overlap_and_crc_damage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.fixture(root)
            original = archive.read_bytes()
            for label, content in [('trailing', original + b'unaccounted'),
                                   ('prefix', b'unaccounted' + original)]:
                archive.write_bytes(content)
                with self.subTest(label=label), self.assertRaises((ValueError, zipfile.BadZipFile)):
                    staged_pkg.extract_for_scan(root, root / label)
            archive.write_bytes(original)
            b = bytearray(original)
            central = b.find(b'PK\x01\x02')
            second = b.find(b'PK\x01\x02', central + 4)
            struct.pack_into('<I', b, second + 42, 0)
            archive.write_bytes(b)
            with self.assertRaises((ValueError, zipfile.BadZipFile)):
                staged_pkg.extract_for_scan(root, root / 'overlap')
            b = bytearray(original)
            name_length, extra_length = struct.unpack_from('<HH', b, 26)
            b[30 + name_length + extra_length] ^= 0xff
            archive.write_bytes(b)
            with self.assertRaises((ValueError, zipfile.BadZipFile, RuntimeError, zlib.error)):
                staged_pkg.extract_for_scan(root, root / 'crc')

    def test_scan_copy_rejects_compressed_tail_duplicate_and_directory_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.fixture(root)
            with zipfile.ZipFile(archive) as z:
                last = max(z.infolist(), key=lambda member: member.header_offset)
            b = bytearray(archive.read_bytes())
            central = b.find(b'PK\x01\x02')
            last_central = b.find(b'PK\x01\x02', central + 4)
            tail = b'unaccounted payload bytes'
            struct.pack_into('<I', b, last.header_offset + 18, last.compress_size + len(tail))
            struct.pack_into('<I', b, last_central + 20, last.compress_size + len(tail))
            eocd = b.rfind(b'PK\x05\x06')
            struct.pack_into('<I', b, eocd + 16, central + len(tail))
            b[central:central] = tail
            archive.write_bytes(b)
            with self.assertRaisesRegex(ValueError, 'compressed ZIP tail'):
                staged_pkg.extract_for_scan(root, root / 'compressed-tail')
            with warnings.catch_warnings():
                warnings.simplefilter('ignore', UserWarning)
                self.write_archive(archive, [('Owltype.app/Contents/Info.plist', 'duplicate')])
            with self.assertRaises(ValueError):
                staged_pkg.extract_for_scan(root, root / 'duplicate')
            self.write_archive(archive, [('Owltype.app/Contents/Resources/', 'hidden directory data')])
            with self.assertRaises(ValueError):
                staged_pkg.extract_for_scan(root, root / 'directory-data')

    def test_normalizer_removes_only_materialized_inert_zip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            component = root / 'Owltype-component.pkg'; component.mkdir()
            archive = self.fixture(component)
            nested = io.BytesIO()
            with zipfile.ZipFile(nested, 'w') as zipped:
                zipped.writestr('ordinary.txt', 'do not filter ordinary archives')
            self.write_archive(archive, [('Owltype.app/Contents/Resources/ordinary.zip', nested.getvalue())])
            script = component / 'Scripts/postinstall'; script.parent.mkdir(); script.write_text('outside script')
            (root / 'Distribution').write_text('outer distribution')
            package_scan.normalize(root)
            self.assertFalse(archive.exists())
            self.assertEqual((root / 'checked-app/Owltype.app/Contents/Resources/ordinary.zip').read_bytes(), nested.getvalue())
            self.assertEqual(script.read_text(), 'outside script')
            self.assertEqual((root / 'Distribution').read_text(), 'outer distribution')

    def test_normalizer_retains_container_on_invalid_link_or_extra_payload(self):
        for kind in ('link', 'outside', 'missing'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                component = root / 'Owltype-component.pkg'; component.mkdir()
                archive = self.fixture(component)
                if kind == 'link':
                    link = zipfile.ZipInfo('Owltype.app/Contents/link')
                    link.external_attr = (stat.S_IFLNK | 0o777) << 16
                    self.write_archive(archive, [(link, '../../../escape')])
                elif kind == 'outside':
                    (component / 'Payload/extra.txt').write_text('unexpected payload')
                else:
                    archive.unlink()
                with self.assertRaises(ValueError):
                    package_scan.normalize(root)
                if kind != 'missing':
                    self.assertTrue(archive.exists())

    @unittest.skipUnless(shutil.which('gitleaks'), 'real Gitleaks is required')
    def test_generic_key_in_each_payload_metadata_and_outer_layer_still_fails(self):
        key = ('0123456789abcdef' * 4)
        marked = ('api_key = "' + key + '"').encode()
        for location in ('member', 'archive-comment', 'member-comment', 'member-extra',
                         'appledouble', 'script', 'distribution', 'extra-comment-boundary'):
            with self.subTest(location=location), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                component = root / 'Owltype-component.pkg'; component.mkdir()
                archive = self.fixture(component)
                info = zipfile.ZipInfo('Owltype.app/Contents/Resources/data')
                if location == 'member-comment': info.comment = marked
                if location == 'extra-comment-boundary':
                    prefix, suffix = marked[:17], marked[17:]
                    info.extra = struct.pack('<HH', 0xcafe, len(prefix)) + prefix
                    info.comment = suffix
                if location == 'member-extra': info.extra = struct.pack('<HH', 0xcafe, len(marked)) + marked
                extras = [(info, marked if location == 'member' else b'plain')]
                if location == 'appledouble': extras.append(('__MACOSX/._Owltype.app', marked))
                self.write_archive(archive, extras)
                if location == 'archive-comment':
                    with zipfile.ZipFile(archive, 'a') as zipped: zipped.comment = marked
                if location == 'script':
                    script = component / 'Scripts/postinstall'; script.parent.mkdir(); script.write_bytes(marked)
                if location == 'distribution': (root / 'Distribution').write_bytes(marked)
                package_scan.normalize(root)
                result = subprocess.run(['gitleaks', 'dir', str(root), '--redact=100', '--no-banner',
                    '--no-color', '--log-level=error', '--exit-code=10',
                    '--config=' + str(Path(__file__).resolve().parents[1] / '.gitleaks.toml')],
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 10, 'normalized layer must remain visible: ' + location)
                self.assertNotIn(key, result.stdout + result.stderr)

    def test_framework_internal_symlink_survives_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.fixture(root)
            link = zipfile.ZipInfo('Owltype.app/Contents/Frameworks/Test.framework/Versions/Current')
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            self.write_archive(archive, [(link, 'A'),
                ('Owltype.app/Contents/Frameworks/Test.framework/Versions/A/Test', 'framework')])
            app = staged_pkg.extract(root, root / 'checked')
            current = app / 'Contents/Frameworks/Test.framework/Versions/Current'
            self.assertEqual(os.readlink(current), 'A')
            self.assertEqual((current / 'Test').read_text(), 'framework')


if __name__ == '__main__':
    unittest.main()
