#!/usr/bin/env python3
"""Regression: empty bundle metadata did not prevent PackageKit registering staged Apps."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import os
import stat
import zipfile

spec = importlib.util.spec_from_file_location('staged_pkg', Path(__file__).with_name('check-staged-pkg.py'))
staged_pkg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staged_pkg)


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
