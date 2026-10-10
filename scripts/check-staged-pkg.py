#!/usr/bin/env python3
"""Reject packages that let PackageKit overwrite/register the live input method."""
import pathlib
import sys
import tempfile
import xml.etree.ElementTree as ET

STAGED_APP = pathlib.Path('Library/Input Methods/.Owltype.pkg-staging/Owltype.app')


def check(component):
    info = ET.parse(component / 'PackageInfo').getroot()
    if info.get('install-location') != '/':
        raise ValueError('component install-location must be /')
    if info.findall('.//bundle') or info.findall('.//relocate/*'):
        raise ValueError('component must not register or relocate a staged bundle')
    payload = component / 'Payload'
    staged = payload / STAGED_APP
    if any(path.is_symlink() for path in [staged, *staged.parents] if path == payload or payload in path.parents):
        raise ValueError('staged app ancestors must not be symlinks')
    if not (staged / 'Contents/Info.plist').is_file():
        raise ValueError('staged app payload is missing')
    # No sibling payload may target the live App or any other machine/user state.
    for path in payload.rglob('*'):
        relative = path.relative_to(payload)
        if relative == STAGED_APP or STAGED_APP in relative.parents or relative in STAGED_APP.parents:
            continue
        raise ValueError(f'payload escapes staging: {relative}')
    return staged


def selftest():
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        app = root / 'Payload' / STAGED_APP
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_text('fixture')
        info = root / 'PackageInfo'
        valid = '<pkg-info install-location="/"><bundle-version/><relocate/></pkg-info>'
        info.write_text(valid)
        assert check(root) == app
        for bad in ['<pkg-info install-location="/Library/Input Methods"/>',
                    '<pkg-info install-location="/"><bundle path="Owltype.app"/></pkg-info>',
                    '<pkg-info install-location="/"><relocate><location/></relocate></pkg-info>']:
            info.write_text(bad)
            try:
                check(root)
            except ValueError:
                pass
            else:
                raise AssertionError('unsafe component accepted')
        info.write_text(valid)
        escaped = root / 'Payload/Library/Input Methods/Owltype.app'
        escaped.mkdir()
        try:
            check(root)
        except ValueError:
            pass
        else:
            raise AssertionError('live bundle payload accepted')
    print('PASS: staged package structure, registration/relocation and live-payload rejection')


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        selftest()
    elif len(sys.argv) == 2:
        try:
            print(check(pathlib.Path(sys.argv[1])))
        except (ValueError, OSError, ET.ParseError) as error:
            raise SystemExit(f'FAIL: {error}') from error
    else:
        raise SystemExit('usage: check-staged-pkg.py EXPANDED_COMPONENT | --self-test')
