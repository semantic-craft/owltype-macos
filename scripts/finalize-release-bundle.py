#!/usr/bin/env python3

"""Gate the built App bundle and leave it in its pre-signing shipping shape.

This script runs before Developer ID signing. It deliberately does NOT write the
file manifest or the SBOM: signing rewrites every native binary and stapling adds
the notarization ticket, so anything inventoried here describes a state that never
ships. inventory-release-bundle.py takes that inventory after those steps instead.
"""

import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

from famo_bundle import MANIFEST_NAME, SBOM_NAME, relative_files, sha256


ROOT = Path(__file__).resolve().parent.parent
EXPECTED_NATIVE = {
    "Contents/Frameworks/librime.1.dylib",
    "Contents/Frameworks/rime-plugins/librime-lua.dylib",
    "Contents/Frameworks/rime-plugins/librime-octagram.dylib",
    "Contents/Frameworks/rime-plugins/librime-predict.dylib",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater",
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
    "Contents/MacOS/Famo",
    "Contents/MacOS/rime_deployer",
    "Contents/MacOS/rime_dict_manager",
}
REQUIRED_LICENSES = {
    "Contents/Resources/LICENSE.txt",
    "Contents/Resources/Sparkle-LICENSE.txt",
    "Contents/Resources/THIRD_PARTY_NOTICES.md",
    "Contents/SharedSupport/FAMOTYPE-SEED-SOURCES.md",
    "Contents/SharedSupport/OpenCC.LICENSE",
    "Contents/SharedSupport/jieba.LICENSE",
    "Contents/SharedSupport/librime-lua.LICENSE",
    "Contents/SharedSupport/librime.LICENSE",
    "Contents/SharedSupport/licenses/Apache-2.0.txt",
    "Contents/SharedSupport/licenses/BSD-3-Clause.txt",
    "Contents/SharedSupport/licenses/CC-BY-3.0.txt",
    "Contents/SharedSupport/licenses/GPL-3.0-only.txt",
    "Contents/SharedSupport/licenses/LGPL-3.0-only.txt",
    "Contents/SharedSupport/licenses/MIT.txt",
    "Contents/SharedSupport/licenses/Unicode-3.0.txt",
    "Contents/SharedSupport/phrase-pinyin-data.LICENSE",
    "Contents/SharedSupport/plum.LICENSE",
    "Contents/SharedSupport/rime-ice-Credits.md",
    "Contents/SharedSupport/rime-ice.LICENSE",
}
# Single-repo era: the full product legitimately bundles the KyleBing wubi
# schemas (Apache-2.0) and the librime predict/octagram plugins (BSD).
# The remaining license blocker is upstream grammar data (*.gram from
# lotem/rime-octagram-data), which ships without a redistribution license.
FORBIDDEN_RELEASE_SUFFIXES = (".gram",)
# The privacy gate exists to keep PRIVATE home directories out of public artifacts
# (PUBLISHING_CHECKLIST: "absolute home-directory paths"). Upstream librime CI
# prebuilts (rime_deployer, librime.1.dylib, rime-plugins/*.dylib) embed the public
# GitHub-runner macOS build prefix in glog __FILE__ strings — 410+ occurrences of
# the "runner" account's "work/librime" checkout path — which identifies no person
# and cannot be scrubbed without rebuilding upstream binaries. Allow exactly that
# one public account; any other home-directory account still fails the gate.
# (Prefix strings below stay split so the public-source privacy scanner does not
# match its own gate definition.)
FORBIDDEN_HOME_PREFIX = b"/" + b"Users/"
ALLOWED_HOME_ACCOUNTS = (b"runner/",)
SPARKLE_LICENSE_SHA256 = "78babcec24fb8447551f9b5ece67042a82fd4ed14deab863d6e8f0619d0d25f6"


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def is_macho(path: Path) -> bool:
    with path.open("rb") as handle:
        magic = handle.read(4)
    return magic in {
        b"\xca\xfe\xba\xbe",
        b"\xca\xfe\xba\xbf",
        b"\xbe\xba\xfe\xca",
        b"\xbf\xba\xfe\xca",
        b"\xce\xfa\xed\xfe",
        b"\xcf\xfa\xed\xfe",
        b"\xfe\xed\xfa\xce",
        b"\xfe\xed\xfa\xcf",
    }


def remove_linker_signatures(app: Path, native_paths: set[str]) -> None:
    for relative in sorted(native_paths):
        path = app / relative
        subprocess.run(["codesign", "--remove-signature", str(path)], check=True)
        load_commands = subprocess.check_output(["otool", "-l", str(path)], text=True)
        if "LC_CODE_SIGNATURE" in load_commands:
            fail(f"linker signature remains after removal: {relative}")


def contains_private_home_path(data: bytes) -> bool:
    index = data.find(FORBIDDEN_HOME_PREFIX)
    while index >= 0:
        rest = data[index + len(FORBIDDEN_HOME_PREFIX):]
        if not any(rest.startswith(account) for account in ALLOWED_HOME_ACCOUNTS):
            return True
        index = data.find(FORBIDDEN_HOME_PREFIX, index + len(FORBIDDEN_HOME_PREFIX))
    return False


def verify_no_private_build_paths(files: list[tuple[str, Path]]) -> None:
    for relative, path in files:
        if contains_private_home_path(path.read_bytes()):
            fail(f"absolute home path embedded in release file: {relative}")


def verify_seed(app: Path) -> None:
    source_seed = ROOT / "data/famo-rime"
    bundled_seed = app / "Contents/SharedSupport"
    if not source_seed.is_dir():
        fail("data/famo-rime is missing; run make famo-seed")
    source = {path.relative_to(source_seed).as_posix(): sha256(path) for path in source_seed.rglob("*") if path.is_file()}
    bundled = {path.relative_to(bundled_seed).as_posix(): sha256(path) for path in bundled_seed.rglob("*") if path.is_file()}
    if source != bundled:
        fail("bundled SharedSupport does not exactly match the pinned generated seed")


def main() -> None:
    if len(sys.argv) != 2:
        fail(f"usage: {Path(sys.argv[0]).name} /path/to/Famo.app")

    app = Path(sys.argv[1]).resolve()
    if not (app / "Contents/Info.plist").is_file():
        fail(f"not a Famo app bundle: {app}")

    resources = app / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    # Releases up to 1.5.15 wrote these two into the bundle. DerivedData survives
    # across releases, so drop any leftovers instead of shipping an inventory that
    # describes some earlier build.
    (resources / SBOM_NAME).unlink(missing_ok=True)
    (resources / MANIFEST_NAME).unlink(missing_ok=True)

    sparkle_license = ROOT / "Sparkle/LICENSE"
    if not sparkle_license.is_file() or sha256(sparkle_license) != SPARKLE_LICENSE_SHA256:
        fail("pinned Sparkle license is missing or differs from the reviewed 2.6.2 text")
    shutil.copyfile(sparkle_license, resources / "Sparkle-LICENSE.txt")

    verify_seed(app)
    files = relative_files(app)
    verify_no_private_build_paths(files)
    paths = {relative for relative, _ in files}
    missing_licenses = REQUIRED_LICENSES - paths
    if missing_licenses:
        fail(f"missing license bundle entries: {', '.join(sorted(missing_licenses))}")

    forbidden = sorted(
        relative for relative in paths
        if relative.lower().endswith(FORBIDDEN_RELEASE_SUFFIXES)
    )
    if forbidden:
        fail(f"forbidden release content: {', '.join(forbidden)}")

    native_targets = {
        path.resolve().relative_to(app).as_posix()
        for _, path in files
        if is_macho(path)
    }
    if native_targets != EXPECTED_NATIVE:
        fail(f"native inventory differs: expected {sorted(EXPECTED_NATIVE)}, got {sorted(native_targets)}")
    remove_linker_signatures(app, native_targets)
    if not os.access(app / "Contents/MacOS/rime-install", os.X_OK):
        fail("Contents/MacOS/rime-install is not executable")

    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    version = str(info.get("CFBundleShortVersionString", ""))
    build = str(info.get("CFBundleVersion", ""))
    if not version or not build:
        fail(f"incomplete version metadata: {version!r} / {build!r}")
    if info.get("SUFeedURL") != "https://responsay.com/owltype/appcast.xml":
        fail("Sparkle feed differs from the reviewed public endpoint")
    if not info.get("SUPublicEDKey") or info.get("SUEnableAutomaticChecks") is not True:
        fail("Sparkle verification key or automatic checks are missing")

    print(f"PASS: release bundle {version} (build {build}) finalized")
    print(f"PASS: {len(native_targets)} unsigned native targets, {len(relative_files(app))} bundle files")
    print("PASS: inventory deferred to inventory-release-bundle.py (runs after signing and stapling)")


if __name__ == "__main__":
    main()
