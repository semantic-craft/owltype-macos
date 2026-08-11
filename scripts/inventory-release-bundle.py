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

`check OUTPUT_ROOT` re-verifies the cohort before it is used as provenance.
DerivedData survives across commits, so "an inventory exists" is a weaker claim
than "this inventory describes the App built from this source under this output
root" — without the check, `make source-archive` would happily pair today's
source with yesterday's binary.
"""

import plistlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from famo_bundle import (
    COHORT_NAME,
    COHORT_SCHEMA_VERSION,
    INVENTORY_NAMES,
    MANIFEST_NAME,
    SBOM_NAME,
    inventory_fingerprint,
    manifest_text,
    output_root_fingerprint,
    read_cohort,
    read_provenance,
    release_paths,
    write_cohort,
    write_inventory,
)


ROOT = Path(__file__).resolve().parent.parent


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def head_revision() -> str:
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()


def bundle_version(app: Path) -> str:
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    version = str(info.get("CFBundleShortVersionString", ""))
    if not version:
        fail("bundle has no CFBundleShortVersionString")
    return version


def check(output_root: Path, app: Path, output_dir: Path) -> None:
    for name in (*INVENTORY_NAMES, COHORT_NAME):
        if not (output_dir / name).is_file():
            fail(f"inventory is incomplete, missing {name} under {output_dir}")

    try:
        cohort = read_cohort(output_dir)
    except (OSError, ValueError) as error:
        fail(f"cannot read {COHORT_NAME}: {error}")

    if cohort.get("schemaVersion") != COHORT_SCHEMA_VERSION:
        fail(
            f"cohort schema is {cohort.get('schemaVersion')!r}, "
            f"expected {COHORT_SCHEMA_VERSION}"
        )

    stamp = read_provenance(output_dir)
    revision = head_revision()
    if cohort.get("revision") != revision:
        fail(
            f"cohort revision is {cohort.get('revision')!r}, but HEAD is {revision!r}; "
            "re-run make notarized-app / make dmg so the inventory matches this commit"
        )
    if stamp.get("revision") != revision:
        fail(
            f"inventory revision is {stamp.get('revision')!r}, but cohort revision is {revision!r}"
        )

    version = bundle_version(app)
    if cohort.get("version") != version:
        fail(f"cohort version is {cohort.get('version')!r}, but the bundle is {version!r}")
    if stamp.get("version") != version:
        fail(f"inventory version is {stamp.get('version')!r}, but cohort version is {version!r}")

    expected_root = output_root_fingerprint(output_root)
    if cohort.get("outputRootSha256") != expected_root:
        fail(f"cohort belongs to a different output root, not {output_root}")

    expected_inventory = inventory_fingerprint(output_dir)
    if cohort.get("inventorySha256") != expected_inventory:
        fail("cohort inventory fingerprint does not match the current inventory")

    if (output_dir / MANIFEST_NAME).read_text() != manifest_text(app):
        fail(
            f"{MANIFEST_NAME} no longer matches the bundle at {app}; "
            "re-run make notarized-app / make dmg"
        )

    print(f"PASS: release cohort matches bundle {version} at revision {revision}")
    print(f"PASS: release cohort output root is {output_root}")


def main() -> None:
    argv = sys.argv[1:]
    if len(argv) != 2 or argv[0] not in {"record", "check"}:
        fail(f"usage: {Path(sys.argv[0]).name} record|check /path/to/release-output-root")

    command = argv[0]
    output_root, app, output_dir = release_paths(Path(argv[1]))
    if not (app / "Contents/Info.plist").is_file():
        fail(f"not a Famo app bundle: {app}")

    if command == "check":
        check(output_root, app, output_dir)
        return

    version = bundle_version(app)
    revision = head_revision()
    committed_at = subprocess.check_output(["git", "show", "-s", "--format=%cI", "HEAD"], cwd=ROOT, text=True).strip()
    created = datetime.fromisoformat(committed_at).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    count = write_inventory(app, output_dir, version, revision, created)
    write_cohort(output_root, output_dir, version, revision)

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
    print(f"PASS: {MANIFEST_NAME}, {SBOM_NAME} and {COHORT_NAME} written under {output_dir}")


if __name__ == "__main__":
    main()
