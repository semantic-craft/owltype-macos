#!/usr/bin/env python3

"""Drive every signed release artifact through one fail-closed cohort state machine."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import plistlib
import subprocess
import sys
import tarfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath

from owl_bundle import (
    COHORT_SCHEMA_VERSION,
    INVENTORY_NAMES,
    RELEASE_ARTIFACTS,
    RELEASE_ARTIFACT_STATES,
    RELEASE_OUTPUTS,
    artifact_sha256,
    cohort_identifier,
    describe_artifact_path,
    inventory_fingerprint,
    manifest_text,
    output_root_fingerprint,
    read_cohort,
    read_provenance,
    release_paths,
    resolve_artifact_path,
    sha256,
    validate_app_executable,
    validate_cohort_shape,
    write_cohort,
)
from owl_distribution import versioned_asset_url
from release_source import (
    FileEntry,
    SourceSnapshotError,
    file_tree_snapshot,
    git_source_snapshot,
    tree_fingerprint,
    validate_deterministic_archive_metadata,
)


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ADAPTER = ROOT / "package/apple_tool_adapter"
SPARKLE_SIGNATURE_VERIFIER = ROOT / "scripts/verify-sparkle-eddsa.swift"
SPARKLE_TRANSITION_POLICY = ROOT / "scripts/sparkle-key-transition.json"
RETRYABLE_EXIT = 75
REJECTED_EXIT = 65
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
OWL_COHORT_NAMESPACE = "https://responsay.com/owltype/release-cohort"


class CohortError(RuntimeError):
    pass


def head_revision() -> str:
    return subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()


def bundle_versions(app: Path) -> tuple[str, str]:
    try:
        validate_app_executable(app)
    except ValueError as error:
        raise CohortError(str(error)) from error
    try:
        with (app / "Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise CohortError(f"cannot read release App version: {error}") from error
    version = str(info.get("CFBundleShortVersionString", ""))
    build_version = str(info.get("CFBundleVersion", ""))
    if not version or not build_version:
        raise CohortError("release App has incomplete version metadata")
    return version, build_version


def bundle_sparkle_public_key(app: Path) -> str | None:
    try:
        with (app / "Contents/Info.plist").open("rb") as handle:
            value = plistlib.load(handle).get("SUPublicEDKey")
    except (OSError, plistlib.InvalidFileException) as error:
        raise CohortError(f"cannot read App Sparkle public key: {error}") from error
    return value if isinstance(value, str) and value else None


def bundle_sparkle_feed_url(app: Path) -> str | None:
    try:
        with (app / "Contents/Info.plist").open("rb") as handle:
            value = plistlib.load(handle).get("SUFeedURL")
    except (OSError, plistlib.InvalidFileException) as error:
        raise CohortError(f"cannot read App Sparkle feed URL: {error}") from error
    return value if isinstance(value, str) and value else None


def validate_sparkle_public_key(value: str) -> None:
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as error:
        raise CohortError("invalid Sparkle public key encoding") from error
    if len(decoded) != 32:
        raise CohortError("invalid Sparkle public key length")


def select_sparkle_verification_key(
    version: str, app_public_key: str, transition_public_key: str | None
) -> str:
    validate_sparkle_public_key(app_public_key)
    if transition_public_key is None:
        return app_public_key
    validate_sparkle_public_key(transition_public_key)
    if version != "2.0.1":
        raise CohortError("Sparkle key transition is only permitted for 2.0.1")
    if transition_public_key == app_public_key:
        raise CohortError("Sparkle transition key must differ from the App public key")
    return transition_public_key


def resolve_sparkle_release_policy(app: Path, version: str) -> dict[str, str] | None:
    app_public_key = bundle_sparkle_public_key(app)
    if app_public_key is None:
        return None
    app_feed_url = bundle_sparkle_feed_url(app)
    successor_feed_key = "owltype/v2/appcast.xml"
    successor_feed_url = f"https://downloads.responsay.com/{successor_feed_key}"
    if app_feed_url != successor_feed_url:
        raise CohortError("release App does not use the permanent Owltype Sparkle feed")

    if SPARKLE_TRANSITION_POLICY.is_file():
        try:
            policy = json.loads(SPARKLE_TRANSITION_POLICY.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise CohortError(f"cannot read Sparkle transition policy: {error}") from error
        expected_keys = {
            "schemaVersion",
            "releaseVersion",
            "fromPublicKey",
            "toPublicKey",
            "legacyFeedKey",
            "successorFeedKey",
        }
        if not isinstance(policy, dict) or set(policy) != expected_keys:
            raise CohortError("Sparkle transition policy has an invalid shape")
        if policy["schemaVersion"] != 1:
            raise CohortError("Sparkle transition policy has the wrong schema version")
        if policy["legacyFeedKey"] != "owltype/appcast.xml":
            raise CohortError("Sparkle transition policy has the wrong legacy feed")
        if policy["successorFeedKey"] != successor_feed_key:
            raise CohortError("Sparkle transition policy has the wrong successor feed")
        if policy["releaseVersion"] == version:
            if policy["toPublicKey"] != app_public_key:
                raise CohortError("Sparkle transition target does not match the App public key")
            signing_key = select_sparkle_verification_key(
                version, app_public_key, str(policy["fromPublicKey"])
            )
            return {
                "sparkleFeedMode": "bridge",
                "sparkleSigningPublicKey": signing_key,
                "sparkleTrustTransitionFrom": signing_key,
            }

    validate_sparkle_public_key(app_public_key)
    return {
        "sparkleFeedMode": "successor",
        "sparkleSigningPublicKey": app_public_key,
    }


def validate_identity(cohort: dict, output_root: Path, app: Path) -> None:
    try:
        validate_cohort_shape(cohort)
    except ValueError as error:
        raise CohortError(str(error)) from error
    revision = head_revision()
    version, build_version = bundle_versions(app)
    root_sha = output_root_fingerprint(output_root)
    if cohort.get("revision") != revision:
        raise CohortError(
            f"cohort revision is {cohort.get('revision')!r}, but HEAD is {revision!r}"
        )
    if cohort.get("version") != version:
        raise CohortError(
            f"cohort version is {cohort.get('version')!r}, but the App is {version!r}"
        )
    if cohort.get("buildVersion") != build_version:
        raise CohortError(
            f"cohort build version is {cohort.get('buildVersion')!r}, "
            f"but the App is {build_version!r}"
        )
    if cohort.get("outputRootSha256") != root_sha:
        raise CohortError(
            f"cohort belongs to a different output root, not {output_root}"
        )
    build_sha = cohort.get("buildAppSha256")
    if not isinstance(build_sha, str) or not build_sha:
        raise CohortError("cohort has no build App identity")
    try:
        app_seed_sha = tree_fingerprint(
            file_tree_snapshot(app / "Contents/SharedSupport")
        )
    except SourceSnapshotError as error:
        raise CohortError(f"cannot validate release App seed: {error}") from error
    if cohort.get("seedSha256") != app_seed_sha:
        raise CohortError("release App seed does not match the cohort binding")
    sparkle_signing_public_key = str(cohort.get("sparkleSigningPublicKey", ""))
    sparkle_feed_mode = str(cohort.get("sparkleFeedMode", ""))
    if sparkle_signing_public_key:
        expected_policy = resolve_sparkle_release_policy(app, version)
        if expected_policy is None or any(
            cohort.get(key) != value for key, value in expected_policy.items()
        ):
            raise CohortError("cohort Sparkle policy does not match this release source")
    expected_id = cohort_identifier(
        revision,
        version,
        build_version,
        root_sha,
        build_sha,
        str(cohort["sourceSha256"]),
        str(cohort["seedSha256"]),
        dict(cohort["submodules"]),
        sparkle_signing_public_key=sparkle_signing_public_key,
        sparkle_feed_mode=sparkle_feed_mode,
    )
    if cohort.get("cohortId") != expected_id:
        raise CohortError("cohort identity digest is invalid")


def validate_artifacts(cohort: dict, output_root: Path) -> None:
    artifacts = cohort["artifacts"]
    for name, record in artifacts.items():
        try:
            path = resolve_artifact_path(record, output_root, ROOT)
            current_sha = artifact_sha256(path)
        except (OSError, ValueError) as error:
            raise CohortError(f"cannot validate artifact {name}: {error}") from error
        if record.get("sha256") != current_sha:
            raise CohortError(f"artifact {name} does not match its cohort binding")


def parse_source_provenance(archive: Path) -> dict[str, str]:
    try:
        with tarfile.open(archive, "r:gz") as handle:
            matches = [
                member
                for member in handle.getmembers()
                if Path(member.name).name == "OWLTYPE-SOURCE-PROVENANCE.txt"
                and len(Path(member.name).parts) == 2
                and member.isfile()
            ]
            if len(matches) != 1:
                raise CohortError("source archive has no unique top-level provenance file")
            extracted = handle.extractfile(matches[0])
            if extracted is None:
                raise CohortError("source archive provenance cannot be read")
            lines = extracted.read().decode("utf-8").splitlines()
    except (OSError, tarfile.TarError, UnicodeDecodeError) as error:
        raise CohortError(f"cannot inspect source archive provenance: {error}") from error

    values: dict[str, str] = {}
    if lines:
        values["title"] = lines[0]
    for line in lines[1:]:
        key, separator, value = line.partition(" ")
        if separator:
            values[key] = value
    return values


def validate_source_archive(
    archive: Path, cohort: dict, output_dir: Path
) -> None:
    version = str(cohort["version"])
    expected_name = f"Owltype-macOS-{version}-source.tar.gz"
    if archive.name != expected_name:
        raise CohortError(
            f"source archive name is {archive.name!r}, expected {expected_name!r}"
        )
    try:
        validate_deterministic_archive_metadata(archive, expected_name.removesuffix(".tar.gz"))
    except SourceSnapshotError as error:
        raise CohortError(f"source archive metadata is invalid: {error}") from error
    provenance = parse_source_provenance(archive)
    if provenance.get("title") != f"Owltype source release {version}":
        raise CohortError("source archive version does not match the release cohort")
    if provenance.get("build-version") != cohort.get("buildVersion"):
        raise CohortError("source archive build version does not match the release cohort")
    if provenance.get("root") != cohort.get("revision"):
        raise CohortError("source archive revision does not match the release cohort")
    if provenance.get("cohort") != cohort.get("cohortId"):
        raise CohortError("source archive embeds a different cohort identity")
    manifest = output_dir / "OWLTYPE-FILE-MANIFEST.sha256"
    if provenance.get("app-manifest") != sha256(manifest):
        raise CohortError("source archive app inventory does not match the release cohort")

    expected_root = expected_name.removesuffix(".tar.gz")
    try:
        with tarfile.open(archive, "r:gz") as handle:
            regular: dict[str, tarfile.TarInfo] = {}
            members: set[str] = set()
            for member in handle.getmembers():
                path = PurePosixPath(member.name)
                if (
                    path.is_absolute()
                    or not path.parts
                    or path.parts[0] != expected_root
                    or ".." in path.parts
                ):
                    raise CohortError("source archive contains a member outside its release root")
                normalized = path.as_posix()
                if normalized in members:
                    raise CohortError(f"source archive repeats {normalized}")
                members.add(normalized)
                if member.isdir():
                    continue
                if not member.isfile():
                    raise CohortError(
                        f"source archive contains unsupported member type: {normalized}"
                    )
                if len(path.parts) < 2:
                    raise CohortError("source archive release root is not a directory")
                relative = PurePosixPath(*path.parts[1:]).as_posix()
                regular[relative] = member

            manifest_name = "OWLTYPE-SOURCE-MANIFEST.sha256"
            source_manifest = regular.pop(manifest_name, None)
            if source_manifest is None:
                raise CohortError("source archive has no source manifest")
            extracted_manifest = handle.extractfile(source_manifest)
            if extracted_manifest is None:
                raise CohortError("source archive manifest cannot be read")
            listed: dict[str, str] = {}
            for line in extracted_manifest.read().decode("utf-8").splitlines():
                digest, separator, relative = line.partition("  ")
                if (
                    not separator
                    or len(digest) != 64
                    or any(character not in "0123456789abcdef" for character in digest)
                    or not relative
                    or relative in listed
                ):
                    raise CohortError("source archive manifest has an invalid entry")
                listed[relative] = digest
            if set(listed) != set(regular):
                raise CohortError("source archive manifest does not cover every source file")
            required = {
                "OWLTYPE-SOURCE-PROVENANCE.txt",
                "Owltype.xcodeproj/project.pbxproj",
                "LICENSE.txt",
                "Makefile",
                "THIRD_PARTY_NOTICES.md",
            }
            if not required.issubset(regular):
                raise CohortError("source archive is missing required corresponding source")
            actual_entries: dict[str, FileEntry] = {}
            for relative, member in regular.items():
                extracted = handle.extractfile(member)
                if extracted is None:
                    raise CohortError(f"source archive cannot read {relative}")
                digest = hashlib.sha256()
                for chunk in iter(lambda: extracted.read(1024 * 1024), b""):
                    digest.update(chunk)
                if digest.hexdigest() != listed[relative]:
                    raise CohortError(f"source archive manifest mismatch for {relative}")
                actual_entries[relative] = FileEntry(
                    mode=member.mode & 0o7777,
                    sha256=digest.hexdigest(),
                )
    except (OSError, tarfile.TarError, UnicodeDecodeError) as error:
        raise CohortError(f"cannot validate source archive manifest: {error}") from error

    try:
        expected_source, expected_submodules = git_source_snapshot(
            ROOT, str(cohort["revision"])
        )
    except SourceSnapshotError as error:
        raise CohortError(f"cannot reconstruct cohort source revision: {error}") from error
    expected_source_sha = tree_fingerprint(expected_source)
    if (
        cohort.get("sourceSha256") != expected_source_sha
        or cohort.get("submodules") != expected_submodules
    ):
        raise CohortError("cohort source binding does not match its revision and submodules")

    provenance_name = "OWLTYPE-SOURCE-PROVENANCE.txt"
    seed_prefix = "data/owl-rime/"
    archived_source = {
        relative: entry
        for relative, entry in actual_entries.items()
        if relative != provenance_name and not relative.startswith(seed_prefix)
    }
    expected_source_without_data = {
        relative: FileEntry(mode=entry.mode, sha256=entry.sha256)
        for relative, entry in expected_source.items()
    }
    if archived_source != expected_source_without_data:
        raise CohortError("source archive tracked source does not match the cohort revision")

    archived_seed = {
        relative.removeprefix(seed_prefix): entry
        for relative, entry in actual_entries.items()
        if relative.startswith(seed_prefix)
    }
    try:
        app = release_paths(output_dir.parent)[1]
        app_seed = file_tree_snapshot(app / "Contents/SharedSupport")
    except SourceSnapshotError as error:
        raise CohortError(f"cannot read release App seed: {error}") from error
    app_seed_without_data = {
        relative: FileEntry(mode=entry.mode, sha256=entry.sha256)
        for relative, entry in app_seed.items()
    }
    if archived_seed != app_seed_without_data:
        raise CohortError("source archive seed does not match the release App")
    if tree_fingerprint(app_seed) != cohort.get("seedSha256"):
        raise CohortError("release App seed does not match the cohort binding")
    if provenance.get("source-tree") != cohort.get("sourceSha256"):
        raise CohortError("source archive provenance has a different source tree")
    if provenance.get("seed-tree") != cohort.get("seedSha256"):
        raise CohortError("source archive provenance has a different seed tree")

    sidecar = archive.with_name(f"{archive.name}.sha256")
    try:
        fields = sidecar.read_text().strip().split()
    except OSError as error:
        raise CohortError(f"cannot read source archive checksum: {error}") from error
    if len(fields) != 2 or fields[0] != sha256(archive) or fields[1] != archive.name:
        raise CohortError("source archive checksum does not match the release cohort output")


def validate_appcast(appcast: Path, cohort: dict, output_root: Path) -> None:
    try:
        root = ET.parse(appcast).getroot()
    except (OSError, ET.ParseError) as error:
        raise CohortError(f"cannot parse appcast: {error}") from error

    channels = root.findall("./channel")
    all_items = root.findall(".//item")
    all_enclosures = root.findall(".//enclosure")
    if root.tag != "rss" or len(channels) != 1 or len(all_items) != 1:
        raise CohortError("appcast must contain exactly one channel and one item")
    item = all_items[0]
    if item not in channels[0].findall("./item") or len(all_enclosures) != 1:
        raise CohortError("appcast item must contain exactly one enclosure")
    enclosure = all_enclosures[0]
    if enclosure not in item.findall("./enclosure"):
        raise CohortError("appcast enclosure must belong to the release item")

    def unique_text(tag: str, label: str) -> str | None:
        elements = item.findall(f"./{tag}")
        if len(elements) != 1:
            raise CohortError(f"appcast item must contain exactly one {label}")
        return elements[0].text

    version = str(cohort["version"])
    short_version = unique_text(
        f"{{{SPARKLE_NAMESPACE}}}shortVersionString", "short version"
    )
    appcast_build_version = unique_text(
        f"{{{SPARKLE_NAMESPACE}}}version", "build version"
    )
    if (
        short_version != version
        or appcast_build_version != cohort.get("buildVersion")
    ):
        raise CohortError(
            f"appcast version is {short_version!r}/{appcast_build_version!r}, "
            f"expected {version!r}/{cohort.get('buildVersion')!r}"
        )
    embedded_cohort = unique_text(
        f"{{{OWL_COHORT_NAMESPACE}}}releaseCohort", "release cohort"
    )
    if embedded_cohort != cohort.get("cohortId"):
        raise CohortError("appcast embeds a different cohort identity")

    sparkle_version = enclosure.get(f"{{{SPARKLE_NAMESPACE}}}version")
    sparkle_short_version = enclosure.get(
        f"{{{SPARKLE_NAMESPACE}}}shortVersionString"
    )
    expected_url = versioned_asset_url(str(cohort["buildVersion"]), "Owltype-update.pkg")
    if (
        sparkle_version != cohort.get("buildVersion")
        or sparkle_short_version != version
    ):
        raise CohortError("appcast enclosure version does not match the release cohort")
    if enclosure.get("url") != expected_url:
        raise CohortError("appcast enclosure URL does not match the release cohort version")
    if enclosure.get(f"{{{SPARKLE_NAMESPACE}}}installationType") != "package":
        raise CohortError("appcast installation type must be package")

    update_record = cohort["artifacts"].get("update-pkg")
    if not update_record:
        raise CohortError("appcast has no cohort update package")
    update_package = resolve_artifact_path(update_record, output_root, ROOT)
    embedded_update_sha = unique_text(
        f"{{{OWL_COHORT_NAMESPACE}}}updatePackageSha256", "update package hash"
    )
    if embedded_update_sha != update_record.get("sha256"):
        raise CohortError("appcast update package hash does not match the release cohort")
    try:
        enclosure_length = int(enclosure.get("length", ""))
    except ValueError as error:
        raise CohortError("appcast enclosure length is invalid") from error
    if enclosure_length != update_package.stat().st_size:
        raise CohortError("appcast enclosure length does not match the cohort update package")
    signature = enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edSignature")
    if not signature:
        raise CohortError("appcast enclosure has no Sparkle signature")
    app = release_paths(output_root)[1]
    public_key = cohort.get("sparkleSigningPublicKey") or bundle_sparkle_public_key(app)
    if not isinstance(public_key, str) or not public_key:
        raise CohortError("release App has no Sparkle public key")
    # Sparkle 2.6.2's sign_update --verify derives its public key from a private
    # seed or Keychain entry. The release validator must instead trust only the
    # public key shipped in this exact App, so use the system Ed25519 primitive.
    verified = subprocess.run(
        [
            "/usr/bin/swift",
            str(SPARKLE_SIGNATURE_VERIFIER),
            str(update_package),
            signature,
            public_key,
        ],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if verified.returncode:
        raise CohortError("appcast EdDSA signature does not verify with the App public key")


def validate_output(
    name: str,
    path: Path,
    cohort: dict,
    output_root: Path,
    output_dir: Path,
) -> None:
    if name == "source-archive":
        validate_source_archive(path, cohort, output_dir)
    elif name == "appcast":
        validate_appcast(path, cohort, output_root)
    else:
        raise CohortError(f"unknown release output {name!r}")


def validate_outputs(
    cohort: dict, output_root: Path, output_dir: Path, *, require_all: bool
) -> None:
    outputs = cohort.get("outputs", {})
    if require_all and set(outputs) != set(RELEASE_OUTPUTS):
        missing = sorted(set(RELEASE_OUTPUTS) - set(outputs))
        raise CohortError(f"release cohort outputs are incomplete: missing {', '.join(missing)}")
    for name, record in outputs.items():
        try:
            path = resolve_artifact_path(record, output_root, ROOT)
            current_sha = artifact_sha256(path)
        except (OSError, ValueError) as error:
            raise CohortError(f"cannot validate output {name}: {error}") from error
        if record.get("sha256") != current_sha:
            raise CohortError(f"output {name} does not match its cohort binding")
        validate_output(name, path, cohort, output_root, output_dir)


def validate_inventory(
    cohort: dict, app: Path, output_dir: Path, *, require: bool
) -> None:
    if not cohort.get("inventorySha256") and not require:
        return
    for inventory_name in INVENTORY_NAMES:
        if not (output_dir / inventory_name).is_file():
            raise CohortError(f"release inventory is missing {inventory_name}")
    if cohort.get("inventorySha256") != inventory_fingerprint(output_dir):
        raise CohortError("cohort inventory fingerprint does not match the current inventory")
    provenance = read_provenance(output_dir)
    if provenance.get("version") != cohort.get("version"):
        raise CohortError("inventory version does not match the release cohort")
    if provenance.get("build-version") != cohort.get("buildVersion"):
        raise CohortError("inventory build version does not match the release cohort")
    if provenance.get("revision") != cohort.get("revision"):
        raise CohortError("inventory revision does not match the release cohort")
    if provenance.get("cohort") != cohort.get("cohortId"):
        raise CohortError("inventory embeds a different cohort identity")
    if (output_dir / "OWLTYPE-FILE-MANIFEST.sha256").read_text() != manifest_text(app):
        raise CohortError("release inventory manifest does not match the cohort App")


def load_validated(output_root_arg: str) -> tuple[Path, Path, Path, dict]:
    output_root, app, output_dir = release_paths(Path(output_root_arg))
    try:
        cohort = read_cohort(output_dir)
    except (OSError, ValueError) as error:
        raise CohortError(f"cannot read release cohort: {error}") from error
    validate_identity(cohort, output_root, app)
    validate_artifacts(cohort, output_root)
    validate_inventory(cohort, app, output_dir, require=False)
    validate_outputs(cohort, output_root, output_dir, require_all=False)
    return output_root, app, output_dir, cohort


def require_active(cohort: dict) -> None:
    if cohort.get("status") == "failed":
        failure = cohort.get("failure", {})
        raise CohortError(
            f"cohort is failed at {failure.get('artifact', '?')}/{failure.get('phase', '?')}; rebuild it"
        )
    if cohort.get("status") == "complete":
        raise CohortError(
            "cohort is already complete; rebuild before replacing artifacts"
        )


def expected_artifact_name(cohort: dict, name: str) -> str:
    names = {
        "installer-pkg": "Owltype.pkg",
        "update-pkg": "Owltype-update.pkg",
        "dmg": f"Owltype-{cohort['version']}.dmg",
    }
    try:
        return names[name]
    except KeyError as error:
        raise CohortError(f"artifact {name} has no external filename") from error


def initialize(output_root_arg: str) -> None:
    output_root, app, output_dir = release_paths(Path(output_root_arg))
    if not app.is_dir():
        raise CohortError(f"release App does not exist: {app}")
    revision = head_revision()
    version, build_version = bundle_versions(app)
    sparkle_policy = resolve_sparkle_release_policy(app, version)
    sparkle_signing_public_key = (
        sparkle_policy["sparkleSigningPublicKey"] if sparkle_policy else ""
    )
    sparkle_feed_mode = sparkle_policy["sparkleFeedMode"] if sparkle_policy else ""
    app_sha = artifact_sha256(app)
    root_sha = output_root_fingerprint(output_root)
    try:
        source_entries, submodules = git_source_snapshot(ROOT, revision)
        source_sha = tree_fingerprint(source_entries)
        seed_sha = tree_fingerprint(
            file_tree_snapshot(app / "Contents/SharedSupport")
        )
    except SourceSnapshotError as error:
        raise CohortError(f"cannot bind release source: {error}") from error
    output_dir.mkdir(parents=True, exist_ok=True)
    cohort = {
        "artifacts": {
            "app": {
                **describe_artifact_path(app, output_root, ROOT),
                "sha256": app_sha,
                "state": "built",
            }
        },
        "buildAppSha256": app_sha,
        "buildVersion": build_version,
        "outputRootSha256": root_sha,
        "revision": revision,
        "schemaVersion": COHORT_SCHEMA_VERSION,
        "seedSha256": seed_sha,
        "sourceSha256": source_sha,
        "status": "active",
        "submodules": submodules,
        "version": version,
    }
    if sparkle_policy:
        cohort.update(sparkle_policy)
    cohort["cohortId"] = cohort_identifier(
        revision,
        version,
        build_version,
        root_sha,
        app_sha,
        source_sha,
        seed_sha,
        submodules,
        sparkle_signing_public_key=sparkle_signing_public_key,
        sparkle_feed_mode=sparkle_feed_mode,
    )
    write_cohort(output_dir, cohort)
    print(f"PASS: initialized release cohort {cohort['cohortId']} for {version}")


def register(output_root_arg: str, name: str, artifact_arg: str) -> None:
    output_root, _, output_dir, cohort = load_validated(output_root_arg)
    require_active(cohort)
    if name == "app":
        raise CohortError("the App is registered only by cohort initialization")
    if name in cohort["artifacts"]:
        raise CohortError(
            f"artifact {name} is already registered; rebuild the cohort first"
        )
    artifact = Path(artifact_arg).resolve()
    expected_name = expected_artifact_name(cohort, name)
    if artifact.name != expected_name:
        raise CohortError(
            f"artifact {name} is named {artifact.name!r}, expected {expected_name!r}"
        )
    sha = artifact_sha256(artifact)
    result = subprocess.run(
        [str(adapter_path()), "cohort-id", name, str(artifact), cohort["cohortId"]],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        diagnostic = result.stderr.strip() or f"adapter exit {result.returncode}"
        raise CohortError(
            f"cannot inspect embedded cohort identity for {name}: {diagnostic}"
        )
    embedded_id = result.stdout.strip()
    if embedded_id != cohort["cohortId"]:
        raise CohortError(f"artifact {name} embeds a different cohort identity")
    cohort["artifacts"][name] = {
        **describe_artifact_path(artifact, output_root, ROOT),
        "sha256": sha,
        "state": "built",
    }
    write_cohort(output_dir, cohort)
    print(f"PASS: registered {name} in release cohort {cohort['cohortId']}")


def print_cohort_id(output_root_arg: str) -> None:
    _, _, _, cohort = load_validated(output_root_arg)
    if cohort.get("status") == "failed":
        require_active(cohort)
    print(cohort["cohortId"])


def require_artifact(output_root_arg: str, name: str, states: list[str]) -> None:
    _, _, _, cohort = load_validated(output_root_arg)
    if cohort.get("status") == "failed":
        require_active(cohort)
    record = cohort["artifacts"].get(name)
    if not record:
        raise CohortError(f"artifact {name} is not registered in this cohort")
    if record.get("state") not in states:
        raise CohortError(
            f"artifact {name} is {record.get('state')!r}, expected one of {', '.join(states)}"
        )
    print(f"PASS: artifact {name} is {record['state']} in cohort {cohort['cohortId']}")


def appcast_ready(output_root_arg: str) -> None:
    _, _, _, cohort = load_validated(output_root_arg)
    if cohort.get("status") == "failed":
        require_active(cohort)
    for name in RELEASE_ARTIFACTS:
        state = cohort["artifacts"].get(name, {}).get("state")
        if state != "stapled":
            raise CohortError(
                f"appcast requires cohort artifact {name} to be stapled, got {state!r}"
            )
    print(f"PASS: release cohort {cohort['cohortId']} is ready for appcast")


def register_output(output_root_arg: str, name: str, output_arg: str) -> None:
    output_root, _, output_dir, cohort = load_validated(output_root_arg)
    if cohort.get("status") != "complete":
        raise CohortError("release outputs require a complete stapled cohort")
    if name in cohort.get("outputs", {}):
        raise CohortError(f"output {name} is already bound to this cohort")
    path = Path(output_arg).resolve()
    validate_output(name, path, cohort, output_root, output_dir)
    cohort.setdefault("outputs", {})[name] = {
        **describe_artifact_path(path, output_root, ROOT),
        "sha256": artifact_sha256(path),
    }
    write_cohort(output_dir, cohort)
    print(f"PASS: bound {name} to release cohort {cohort['cohortId']}")


def verify_chain(output_root_arg: str) -> None:
    output_root, app, output_dir, cohort = load_validated(output_root_arg)
    if cohort.get("status") != "complete":
        raise CohortError("release cohort is not complete")
    for name in ("installer-pkg", "update-pkg", "dmg"):
        expected_name = expected_artifact_name(cohort, name)
        record = cohort["artifacts"][name]
        path = resolve_artifact_path(record, output_root, ROOT)
        if path.name != expected_name:
            raise CohortError(
                f"artifact {name} is named {path.name!r}, expected {expected_name!r}"
            )

    validate_inventory(cohort, app, output_dir, require=True)
    validate_outputs(cohort, output_root, output_dir, require_all=True)
    print(
        f"PASS: complete release chain {cohort['cohortId']} verifies for {cohort['version']}"
    )


def output_path(output_root_arg: str, name: str) -> None:
    output_root, _, _, cohort = load_validated(output_root_arg)
    record = cohort.get("outputs", {}).get(name)
    if not record:
        raise CohortError(f"output {name} is not bound to this cohort")
    print(resolve_artifact_path(record, output_root, ROOT))


def artifact_path(output_root_arg: str, name: str) -> None:
    output_root, _, _, cohort = load_validated(output_root_arg)
    record = cohort["artifacts"].get(name)
    if not record:
        raise CohortError(f"artifact {name} is not registered in this cohort")
    print(resolve_artifact_path(record, output_root, ROOT))


def adapter_path() -> Path:
    configured = os.environ.get("OWL_APPLE_TOOL_ADAPTER")
    adapter = Path(configured).resolve() if configured else DEFAULT_ADAPTER
    if not adapter.is_file() or not os.access(adapter, os.X_OK):
        raise CohortError(f"Apple tool adapter is not executable: {adapter}")
    return adapter


def retry_delay(phase: str) -> float:
    override = os.environ.get("OWL_RELEASE_RETRY_DELAY_SECONDS")
    if override is not None:
        return float(override)
    return 8.0 if phase == "sign" else 20.0


def run_adapter(command: list[str], phase: str, attempts: int) -> int:
    for attempt in range(1, attempts + 1):
        result = subprocess.run(command, cwd=ROOT, check=False)
        if result.returncode == 0:
            return 0
        if result.returncode != RETRYABLE_EXIT or attempt == attempts:
            return result.returncode
        print(
            f"[owltype] {phase} transient failure; retry {attempt}/{attempts}",
            file=sys.stderr,
        )
        delay = retry_delay(phase)
        if delay:
            time.sleep(delay)
    raise AssertionError("unreachable retry loop")


def fail_transition(
    output_dir: Path,
    cohort: dict,
    name: str,
    artifact: Path,
    phase: str,
    returncode: int,
) -> None:
    reason = (
        "rejected"
        if returncode == REJECTED_EXIT
        else ("timeout" if returncode == RETRYABLE_EXIT else f"tool-exit-{returncode}")
    )
    record = cohort["artifacts"][name]
    if artifact.exists():
        record["sha256"] = artifact_sha256(artifact)
    record["state"] = "failed"
    cohort["status"] = "failed"
    cohort["failure"] = {"artifact": name, "phase": phase, "reason": reason}
    write_cohort(output_dir, cohort)
    raise CohortError(f"{name} {phase} {reason}; cohort is now failed")


def persist_transition(
    output_dir: Path, cohort: dict, name: str, artifact: Path, state: str
) -> None:
    record = cohort["artifacts"][name]
    record["sha256"] = artifact_sha256(artifact)
    record["state"] = state
    if all(
        cohort["artifacts"].get(artifact_name, {}).get("state") == "stapled"
        for artifact_name in RELEASE_ARTIFACTS
    ):
        cohort["status"] = "complete"
    write_cohort(output_dir, cohort)
    print(f"PASS: {name} transitioned to {state}")


def seal(
    output_root_arg: str,
    name: str,
    identity: str,
    notary_profile: str,
) -> None:
    output_root, _, output_dir, cohort = load_validated(output_root_arg)
    require_active(cohort)
    record = cohort["artifacts"].get(name)
    if not record:
        raise CohortError(f"artifact {name} is not registered in this cohort")
    if record.get("state") != "built":
        raise CohortError(
            f"artifact {name} must be built before sealing, got {record.get('state')!r}"
        )
    if name != "app" and cohort["artifacts"]["app"].get("state") != "stapled":
        raise CohortError(
            "package and DMG transitions require the cohort App to be stapled"
        )
    if name == "dmg":
        for dependency in ("installer-pkg", "update-pkg"):
            if cohort["artifacts"].get(dependency, {}).get("state") != "stapled":
                raise CohortError(
                    f"DMG transition requires {dependency} from this cohort to be stapled"
                )

    artifact = resolve_artifact_path(record, output_root, ROOT)
    adapter = adapter_path()
    signed_output = artifact
    if name in {"installer-pkg", "update-pkg"}:
        signed_output = artifact.with_name(f".{artifact.name}.signed")
        signed_output.unlink(missing_ok=True)
    sign_command = [
        str(adapter),
        "sign",
        name,
        identity,
        str(artifact),
        str(signed_output),
    ]
    returncode = run_adapter(sign_command, "sign", 5)
    if returncode:
        signed_output.unlink(missing_ok=True)
        fail_transition(output_dir, cohort, name, artifact, "sign", returncode)
    if signed_output != artifact:
        signed_output.replace(artifact)
    persist_transition(output_dir, cohort, name, artifact, "signed")

    before_notary = artifact_sha256(artifact)
    notary_command = [str(adapter), "notarize", name, notary_profile, str(artifact)]
    returncode = run_adapter(notary_command, "notarize", 3)
    if returncode:
        fail_transition(output_dir, cohort, name, artifact, "notarize", returncode)
    if artifact_sha256(artifact) != before_notary:
        fail_transition(output_dir, cohort, name, artifact, "notarize", 70)
    persist_transition(output_dir, cohort, name, artifact, "notarized")

    staple_command = [str(adapter), "staple", name, str(artifact)]
    returncode = run_adapter(staple_command, "staple", 1)
    if returncode:
        fail_transition(output_dir, cohort, name, artifact, "staple", returncode)
    persist_transition(output_dir, cohort, name, artifact, "stapled")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    initialize_parser = subparsers.add_parser("initialize")
    initialize_parser.add_argument("output_root")

    register_parser = subparsers.add_parser("register")
    register_parser.add_argument("output_root")
    register_parser.add_argument("artifact", choices=RELEASE_ARTIFACTS)
    register_parser.add_argument("path")

    id_parser = subparsers.add_parser("id")
    id_parser.add_argument("output_root")

    require_parser = subparsers.add_parser("require")
    require_parser.add_argument("output_root")
    require_parser.add_argument("artifact", choices=RELEASE_ARTIFACTS)
    require_parser.add_argument("states", nargs="+", choices=RELEASE_ARTIFACT_STATES)

    appcast_parser = subparsers.add_parser("appcast-ready")
    appcast_parser.add_argument("output_root")

    register_output_parser = subparsers.add_parser("register-output")
    register_output_parser.add_argument("output_root")
    register_output_parser.add_argument("output", choices=RELEASE_OUTPUTS)
    register_output_parser.add_argument("path")

    verify_chain_parser = subparsers.add_parser("verify-chain")
    verify_chain_parser.add_argument("output_root")

    output_path_parser = subparsers.add_parser("output-path")
    output_path_parser.add_argument("output_root")
    output_path_parser.add_argument("output", choices=RELEASE_OUTPUTS)

    artifact_path_parser = subparsers.add_parser("artifact-path")
    artifact_path_parser.add_argument("output_root")
    artifact_path_parser.add_argument("artifact", choices=RELEASE_ARTIFACTS)

    seal_parser = subparsers.add_parser("seal")
    seal_parser.add_argument("output_root")
    seal_parser.add_argument("artifact", choices=RELEASE_ARTIFACTS)
    seal_parser.add_argument("identity")
    seal_parser.add_argument("notary_profile")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        if args.command == "initialize":
            initialize(args.output_root)
        elif args.command == "id":
            print_cohort_id(args.output_root)
        elif args.command == "register":
            register(args.output_root, args.artifact, args.path)
        elif args.command == "require":
            require_artifact(args.output_root, args.artifact, args.states)
        elif args.command == "appcast-ready":
            appcast_ready(args.output_root)
        elif args.command == "register-output":
            register_output(args.output_root, args.output, args.path)
        elif args.command == "verify-chain":
            verify_chain(args.output_root)
        elif args.command == "output-path":
            output_path(args.output_root, args.output)
        elif args.command == "artifact-path":
            artifact_path(args.output_root, args.artifact)
        elif args.command == "seal":
            seal(args.output_root, args.artifact, args.identity, args.notary_profile)
        else:
            raise AssertionError(f"unhandled command {args.command}")
    except (CohortError, OSError, ValueError) as error:
        raise SystemExit(f"FAIL: {error}") from error


if __name__ == "__main__":
    main()
