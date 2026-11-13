#!/usr/bin/env python3
"""Build pinned upstream Sparkle plus the reviewed application-relaunch patch.

UUIDs survive the release pipeline's removal/replacement of code signatures.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
from cleanup_app_registrations import prepare as prepare_registrations
from owl_bundle import unreadable_by_others
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
REVISION = "41847a58cdef7506b257591fcca6f9495df591d4"
SOURCE_SHA256 = "7c4af8fb8ba319d2b55c90af8b29ddc530d03cccac28b6b60638b032a61e5b8d"
PATCH = ROOT / "patches/sparkle/application-relaunch.patch"
RECEIPT = Path("Versions/B/Resources/OwltypeSparkleBuild.json")
UPDATER = Path("Versions/B/Updater.app/Contents/MacOS/Updater")


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def uuids(binary):
    output = subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(binary)], text=True)
    result = dict((arch, uuid) for uuid, arch in re.findall(r"UUID: ([0-9A-F-]+) \(([^)]+)\)", output))
    if set(result) != {"arm64"}:
        raise ValueError("Sparkle Updater must contain only arm64")
    return result


def identity():
    return {"upstreamRevision": REVISION, "patchSHA256": hashlib.sha256(PATCH.read_bytes()).hexdigest(),
            "builderSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}


def verify(framework):
    # A build made under a private umask is not current: the App ships it to other users.
    unreadable = unreadable_by_others(framework)
    if unreadable:
        raise ValueError("Sparkle build has entries other users cannot read (make clean-sparkle "
                         f"if a rebuild keeps them): {', '.join(unreadable[:10])}")
    receipt = json.loads((framework / RECEIPT).read_text())
    expected = {**identity(), "updaterUUIDs": uuids(framework / UPDATER)}
    if receipt != expected:
        raise ValueError("Sparkle build receipt differs from the reviewed patch or Updater binary")
    if b"openApplicationAtURL:configuration:completionHandler:" not in (framework / UPDATER).read_bytes():
        raise ValueError("Sparkle Updater lacks the application launch API")


def prepare_source(upstream, source):
    """Use the same pinned tree from Git checkouts and published source archives."""
    if (upstream / ".git").exists():
        if subprocess.check_output(["git", "-C", str(upstream), "rev-parse", "HEAD"], text=True).strip() != REVISION:
            raise ValueError("unexpected Sparkle submodule revision")
        archive = source / "upstream.tar"
        run("git", "-C", str(upstream), "archive", "--format=tar", "-o", str(archive), REVISION)
        run("tar", "-xf", str(archive), "-C", str(source))
        archive.unlink()
    else:
        shutil.copytree(upstream, source, dirs_exist_ok=True, symlinks=True)
    entries = []
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source).as_posix()
        if path.is_symlink():
            entries.append([relative, "symlink", str(path.readlink())])
        elif path.is_file():
            mode = "executable" if path.stat().st_mode & 0o111 else "file"
            entries.append([relative, mode, hashlib.sha256(path.read_bytes()).hexdigest()])
    digest = hashlib.sha256(json.dumps(entries, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()
    if digest != SOURCE_SHA256:
        raise ValueError("Sparkle source differs from the pinned upstream tree")
    run("git", "apply", "--check", str(PATCH), cwd=source)
    run("git", "apply", str(PATCH), cwd=source)


def build():
    os.umask(0o022)
    destination = ROOT / "Frameworks/Sparkle.framework"
    try:
        verify(destination)
        print("Sparkle patched build is current")
        return
    except (OSError, ValueError, subprocess.CalledProcessError):
        pass
    upstream = ROOT / "Sparkle"
    work = ROOT / "build/sparkle-patched"
    work.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="source-", dir=work) as temporary:
        source = Path(temporary)
        prepare_source(upstream, source)
        prefix_map = f"-ffile-prefix-map={source}=Sparkle"
        run("xcodebuild", "-quiet", "-project", str(source / "Sparkle.xcodeproj"),
            "-scheme", "Sparkle", "-configuration", "Release", "-derivedDataPath", str(work / "derived"),
            "ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO", "MACOSX_DEPLOYMENT_TARGET=14.0", "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "DEBUG_INFORMATION_FORMAT=dwarf-with-dsym",
            "OTHER_CFLAGS=$(inherited) " + prefix_map,
            "OTHER_CPLUSPLUSFLAGS=$(inherited) " + prefix_map, "build")
        built = work / "derived/Build/Products/Release/Sparkle.framework"
        receipt = {**identity(), "updaterUUIDs": uuids(built / UPDATER)}
        (built / RECEIPT).write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        verify(built)
        destination.parent.mkdir(exist_ok=True)
        # Publish only the validated build, preserving the previous framework on build failure.
        staged = destination.with_name("Sparkle.framework.new")
        if staged.exists():
            prepare_registrations(staged)
            shutil.rmtree(staged)
            prepare_registrations(staged)
        shutil.copytree(built, staged, symlinks=True)
        if destination.exists():
            prepare_registrations(destination)
            shutil.rmtree(destination)
            prepare_registrations(destination)
        prepare_registrations(staged)
        staged.rename(destination)
        prepare_registrations(staged)
        print("Built official Sparkle pin with application-relaunch patch")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", type=Path)
    args = parser.parse_args()
    if args.check:
        verify(args.check)
        print("Sparkle application-relaunch build verified")
    else:
        build()


if __name__ == "__main__":
    main()
