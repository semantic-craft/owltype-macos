#!/usr/bin/env python3

import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


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
    "Contents/SharedSupport/librime-lua.LICENSE",
    "Contents/SharedSupport/librime.LICENSE",
    "Contents/SharedSupport/licenses/Apache-2.0.txt",
    "Contents/SharedSupport/licenses/BSD-3-Clause.txt",
    "Contents/SharedSupport/licenses/CC-BY-3.0.txt",
    "Contents/SharedSupport/licenses/GPL-3.0-only.txt",
    "Contents/SharedSupport/licenses/LGPL-3.0-only.txt",
    "Contents/SharedSupport/licenses/MIT.txt",
    "Contents/SharedSupport/licenses/Unicode-3.0.txt",
    "Contents/SharedSupport/plum.LICENSE",
    "Contents/SharedSupport/rime-essay.AUTHORS",
    "Contents/SharedSupport/rime-essay.LICENSE",
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
COMPONENTS = (
    ("Famotype", None, "GPL-3.0-only", "https://github.com/semantic-craft/famotype-macos"),
    ("Squirrel-derived frontend", "4db2c85ac639c229e14fd9424f79c3c4f97ce478", "GPL-3.0-only", "https://github.com/rime/squirrel"),
    ("librime", "33e78140250125871856cdc5b42ddc6a5fcd3cd4", "BSD-3-Clause", "https://github.com/rime/librime"),
    ("librime-lua", "ec52e48ea18f11af37717a01c337f853215cf70b", "BSD-3-Clause", "https://github.com/hchunhui/librime-lua"),
    ("plum", "b1be1969f914cc005add4090631b855db00c2591", "LGPL-3.0-only", "https://github.com/rime/plum"),
    ("Sparkle", "41847a58cdef7506b257591fcca6f9495df591d4", "MIT", "https://github.com/sparkle-project/Sparkle"),
    ("rime-ice configuration", "b681a34f788795034b3b288830f4861980bc8b0d", "GPL-3.0-only", "https://github.com/iDvel/rime-ice"),
    ("rime-essay", "e9b1a374a6ea015fca5bdd04318924b4483ac35a", "LGPL-3.0-only", "https://github.com/rime/rime-essay"),
    ("Unicode Unihan", "16.0.0", "Unicode-3.0", "https://www.unicode.org/Public/16.0.0/ucd/Unihan.zip"),
    ("OpenCC", "556ed22496d650bd0b13b6c163be9814637970ae", "Apache-2.0", "https://github.com/BYVoid/OpenCC"),
)


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


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


def relative_files(app: Path) -> list[tuple[str, Path]]:
    return sorted(
        ((path.relative_to(app).as_posix(), path) for path in app.rglob("*") if path.is_file()),
        key=lambda item: item[0],
    )


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


def make_sbom(app: Path, version: str, revision: str, created: str) -> dict:
    files = []
    for relative, path in relative_files(app):
        identifier = hashlib.sha256(relative.encode()).hexdigest()[:24]
        files.append(
            {
                "SPDXID": f"SPDXRef-File-{identifier}",
                "checksums": [{"algorithm": "SHA256", "checksumValue": sha256(path)}],
                "copyrightText": "NOASSERTION",
                "fileName": f"./{relative}",
                "licenseConcluded": "NOASSERTION",
            }
        )

    packages = []
    for index, (name, component_version, license_id, source) in enumerate(COMPONENTS, start=1):
        packages.append(
            {
                "SPDXID": f"SPDXRef-Package-{index}",
                "copyrightText": "NOASSERTION",
                "downloadLocation": source,
                "filesAnalyzed": False,
                "licenseConcluded": license_id,
                "licenseDeclared": license_id,
                "name": name,
                "versionInfo": component_version or version,
            }
        )

    return {
        "SPDXID": "SPDXRef-DOCUMENT",
        "creationInfo": {"created": created, "creators": ["Tool: famotype-finalize-release-bundle"]},
        "dataLicense": "CC0-1.0",
        "documentNamespace": f"https://github.com/semantic-craft/famotype-macos/releases/{version}/spdx/{revision}",
        "files": files,
        "name": f"Famotype-{version}",
        "packages": packages,
        "relationships": [
            {"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-Package-1"},
            *(
                {"spdxElementId": "SPDXRef-Package-1", "relationshipType": "DEPENDS_ON", "relatedSpdxElement": f"SPDXRef-Package-{index}"}
                for index in range(2, len(packages) + 1)
            ),
        ],
        "spdxVersion": "SPDX-2.3",
    }


def main() -> None:
    if len(sys.argv) != 2:
        fail(f"usage: {Path(sys.argv[0]).name} /path/to/Famo.app")

    app = Path(sys.argv[1]).resolve()
    if not (app / "Contents/Info.plist").is_file():
        fail(f"not a Famo app bundle: {app}")

    resources = app / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    sbom_path = resources / "FAMOTYPE-SBOM.spdx.json"
    manifest_path = resources / "FAMOTYPE-FILE-MANIFEST.sha256"
    sbom_path.unlink(missing_ok=True)
    manifest_path.unlink(missing_ok=True)

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

    native = {relative for relative, path in files if is_macho(path)}
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
    if not version or version != build:
        fail(f"version/build mismatch: {version!r} / {build!r}")
    if info.get("SUFeedURL") != "https://responsay.com/famo/appcast.xml":
        fail("Sparkle feed differs from the reviewed public endpoint")
    if not info.get("SUPublicEDKey") or info.get("SUEnableAutomaticChecks") is not True:
        fail("Sparkle verification key or automatic checks are missing")

    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    committed_at = subprocess.check_output(["git", "show", "-s", "--format=%cI", "HEAD"], cwd=ROOT, text=True).strip()
    created = datetime.fromisoformat(committed_at).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    sbom_path.write_text(json.dumps(make_sbom(app, version, revision, created), ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    manifest_lines = [
        f"{sha256(path)}  {relative}"
        for relative, path in relative_files(app)
        if path != manifest_path
    ]
    manifest_path.write_text("\n".join(manifest_lines) + "\n")

    expected_manifest_paths = {relative for relative, path in relative_files(app) if path != manifest_path}
    recorded_manifest_paths = {line.split("  ", 1)[1] for line in manifest_lines}
    if recorded_manifest_paths != expected_manifest_paths:
        fail("file manifest does not cover the complete bundle")

    print(f"PASS: release bundle {version} finalized")
    print(f"PASS: {len(native_targets)} unsigned native targets, {len(expected_manifest_paths)} hashed bundle files")
    print(f"PASS: SPDX SBOM and SHA-256 file manifest written under {resources}")


if __name__ == "__main__":
    main()
