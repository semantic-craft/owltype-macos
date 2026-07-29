#!/usr/bin/env python3

"""Inventory the App bundle exactly as it ships.

Runs as the last step of `notarized-app`, after Developer ID signing and after
`xcrun stapler staple`. Both of those rewrite the bundle — signing replaces the
code signature of every native binary, stapling writes the notarization ticket to
Contents/CodeResources — so an inventory taken before them describes an
intermediate state that is never shipped and can never be verified by anyone who
downloads the release.

The manifest and SBOM are written to an output directory outside the bundle. That
is what makes the result reproducible: the inventory cannot perturb the thing it
inventories, so re-running against an unchanged bundle reproduces both files byte
for byte, no matter what a previous release left behind in DerivedData.

Verifying a downloaded release:

    cd /path/to/Famo.app && shasum -a 256 -c /path/to/FAMOTYPE-FILE-MANIFEST.sha256
"""

import plistlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from famo_bundle import MANIFEST_NAME, SBOM_NAME, write_inventory


ROOT = Path(__file__).resolve().parent.parent


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def main() -> None:
    if len(sys.argv) != 3:
        fail(f"usage: {Path(sys.argv[0]).name} /path/to/Famo.app /path/to/output-directory")

    app = Path(sys.argv[1]).resolve()
    output_dir = Path(sys.argv[2]).resolve()
    if not (app / "Contents/Info.plist").is_file():
        fail(f"not a Famo app bundle: {app}")
    # The whole point of writing outside the bundle; guard it rather than trust it.
    if output_dir == app or app in output_dir.parents:
        fail(f"inventory output must live outside the bundle, got {output_dir}")

    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    version = str(info.get("CFBundleShortVersionString", ""))
    if not version:
        fail("bundle has no CFBundleShortVersionString")

    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    committed_at = subprocess.check_output(["git", "show", "-s", "--format=%cI", "HEAD"], cwd=ROOT, text=True).strip()
    created = datetime.fromisoformat(committed_at).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    count = write_inventory(app, output_dir, version, revision, created)

    # A stapled ticket means this really is the shipping state. Unsigned builds
    # (CI has no DEV_ID) legitimately have none — say which one this is, so an
    # inventory taken at the wrong point in the pipeline is visible in the log.
    stapled = subprocess.run(
        ["xcrun", "stapler", "validate", str(app)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0

    print(f"PASS: inventoried release bundle {version} ({count} files)")
    if stapled:
        print("PASS: bundle carries a stapled notarization ticket")
    else:
        print("NOTE: bundle carries no notarization ticket (unsigned build)")
    print(f"PASS: {MANIFEST_NAME} and {SBOM_NAME} written under {output_dir}")


if __name__ == "__main__":
    main()
