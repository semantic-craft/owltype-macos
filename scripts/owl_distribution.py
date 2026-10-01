#!/usr/bin/env python3
"""Publish one verified Owltype release cohort through responsay.com."""

from __future__ import annotations

import argparse
import hashlib
import mimetypes
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, Sequence
from urllib.parse import quote


PUBLIC_ORIGIN = "https://downloads.responsay.com"
LEGACY_CLIENT_FEED_URL = "https://responsay.com/owltype/appcast.xml"
SUCCESSOR_CLIENT_FEED_URL = "https://downloads.responsay.com/owltype/v2/appcast.xml"
R2_BUCKET = "responsay-downloads"
OBJECT_PREFIX = "owltype"
WRANGLER_VERSION = "4.123.0"
IMMUTABLE_CACHE_CONTROL = "public, max-age=31536000, immutable"
STABLE_CACHE_CONTROL = "public, max-age=0, must-revalidate"
_VERSION_PATTERN = re.compile(r"[0-9]+(?:\.[0-9]+)*")


class DistributionError(RuntimeError):
    pass


@dataclass(frozen=True)
class Upload:
    source: Path
    key: str
    url: str
    sha256: str
    content_type: str
    cache_control: str
    immutable: bool


class ObjectStore(Protocol):
    def read(self, key: str) -> bytes | None: ...

    def put(
        self,
        source: Path,
        key: str,
        *,
        content_type: str,
        cache_control: str,
    ) -> None: ...


class PublicVerifier(Protocol):
    def verify(self, url: str, sha256: str) -> None: ...


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def versioned_asset_url(build_version: str, filename: str) -> str:
    _validate_version(build_version, "build version")
    if Path(filename).name != filename or "/" in filename or "\\" in filename:
        raise DistributionError(f"invalid asset filename: {filename!r}")
    return (
        f"{PUBLIC_ORIGIN}/{OBJECT_PREFIX}/releases/"
        f"{quote(build_version, safe='.')}/{quote(filename, safe='.-')}"
    )


def _validate_version(value: str, label: str) -> None:
    if not _VERSION_PATTERN.fullmatch(value):
        raise DistributionError(f"invalid {label}: {value!r}")


def sparkle_feed_key(version: str) -> str:
    """2.0.10 starts a new trust domain after loss of the v2 private key."""
    _validate_version(version, "marketing version")
    return "owltype/v3/appcast.xml" if tuple(map(int, version.split("."))) >= (2, 0, 10) else "owltype/v2/appcast.xml"


def _content_type(path: Path) -> str:
    explicit = {
        ".dmg": "application/x-apple-diskimage",
        ".gz": "application/gzip",
        ".json": "application/json",
        ".pkg": "application/octet-stream",
        ".sha256": "text/plain; charset=utf-8",
        ".txt": "text/plain; charset=utf-8",
        ".xml": "application/xml; charset=utf-8",
    }
    return explicit.get(path.suffix, mimetypes.guess_type(path.name)[0] or "application/octet-stream")


def _upload(source: Path, key: str, *, immutable: bool) -> Upload:
    return Upload(
        source=source,
        key=key,
        url=f"{PUBLIC_ORIGIN}/{quote(key, safe='/.-')}",
        sha256=sha256_file(source),
        content_type=_content_type(source),
        cache_control=(IMMUTABLE_CACHE_CONTROL if immutable else STABLE_CACHE_CONTROL),
        immutable=immutable,
    )


def build_publish_plan(
    asset_paths: Sequence[Path],
    *,
    version: str,
    build_version: str,
    feed_mode: str,
) -> list[Upload]:
    _validate_version(version, "marketing version")
    _validate_version(build_version, "build version")
    if feed_mode not in {"bridge", "successor"}:
        raise DistributionError(f"invalid Sparkle feed mode: {feed_mode!r}")
    feed_key = sparkle_feed_key(version)
    if feed_mode == "bridge" and feed_key == "owltype/v3/appcast.xml":
        raise DistributionError("v3 trust recovery requires manual installation, not a legacy bridge")
    paths = [Path(path).resolve() for path in asset_paths]
    if any(not path.is_file() or path.stat().st_size == 0 for path in paths):
        raise DistributionError("publishing contract contains a missing or empty asset")

    by_name = {path.name: path for path in paths}
    if len(by_name) != len(paths):
        raise DistributionError("publishing contract contains duplicate asset names")
    expected_names = {
        "Owltype.pkg",
        "Owltype-update.pkg",
        f"Owltype-{version}.dmg",
        "appcast.xml",
        f"Owltype-macOS-{version}-source.tar.gz",
        f"Owltype-macOS-{version}-source.tar.gz.sha256",
        "OWLTYPE-FILE-MANIFEST.sha256",
        "OWLTYPE-SBOM.spdx.json",
        "OWLTYPE-APP-PROVENANCE.txt",
        "OWLTYPE-RELEASE-COHORT.json",
    }
    if set(by_name) != expected_names:
        missing = sorted(expected_names - set(by_name))
        unexpected = sorted(set(by_name) - expected_names)
        raise DistributionError(
            f"publishing contract mismatch; missing={missing}, unexpected={unexpected}"
        )

    version_prefix = f"{OBJECT_PREFIX}/releases/{build_version}"
    plan = [
        _upload(path, f"{version_prefix}/{path.name}", immutable=True)
        for path in paths
    ]

    # The verified cohort record is also the single mutable pointer used by the website's manual
    # download redirects. Replacing one JSON object switches installer, DMG, and source together.
    plan.append(
        _upload(
            by_name["OWLTYPE-RELEASE-COHORT.json"],
            f"{OBJECT_PREFIX}/latest.json",
            immutable=False,
        )
    )

    # Current releases write only v3; v2 remains frozen for clients with the lost key.
    # The historical 2.0.1 bridge writes v2 first,
    # then commits the legacy feed last so 2.0.0 clients can cross once. Later releases never
    # touch the legacy feed, which remains pinned to the bridge forever.
    plan.append(
        _upload(by_name["appcast.xml"], feed_key, immutable=False)
    )
    if feed_mode == "bridge":
        plan.append(
            _upload(by_name["appcast.xml"], f"{OBJECT_PREFIX}/appcast.xml", immutable=False)
        )
    return plan


def publish(
    plan: Sequence[Upload],
    store: ObjectStore,
    verifier: PublicVerifier,
) -> list[str]:
    keys = [item.key for item in plan]
    bridge = keys[-3:] == [
        f"{OBJECT_PREFIX}/latest.json",
        f"{OBJECT_PREFIX}/v2/appcast.xml",
        f"{OBJECT_PREFIX}/appcast.xml",
    ]
    feed_key = keys[-1] if keys and keys[-1] == "owltype/v3/appcast.xml" else "owltype/v2/appcast.xml"
    successor = keys[-2:] == [
        f"{OBJECT_PREFIX}/latest.json", feed_key,
    ] and f"{OBJECT_PREFIX}/appcast.xml" not in keys
    if feed_key == "owltype/v3/appcast.xml" and any(
        key in {"owltype/appcast.xml", "owltype/v2/appcast.xml"} for key in keys
    ):
        raise DistributionError("v3 releases must not overwrite earlier trust feeds")
    if not bridge and not successor:
        raise DistributionError("latest pointer and Sparkle feed commit order is invalid")

    events: list[str] = []
    immutable = [item for item in plan if item.immutable]
    by_name = {item.source.name: item for item in immutable}
    try:
        website_aliases = (
            ("Owltype.pkg", by_name["Owltype.pkg"]),
            ("Owltype-update.pkg", by_name["Owltype-update.pkg"]),
            (
                "Owltype.dmg",
                next(item for item in immutable if item.source.suffix == ".dmg"),
            ),
            (
                "source.tar.gz",
                next(
                    item
                    for item in immutable
                    if item.source.name.endswith("-source.tar.gz")
                ),
            ),
        )
    except (KeyError, StopIteration) as error:
        raise DistributionError("publish plan is missing a website download alias") from error
    aliases_verified = False
    for item in plan:
        # Website aliases are backed by latest.json. Versioned appcast objects appear earlier in
        # the immutable batch and must not trigger this check while aliases still point at the
        # previous release. Verify only after latest.json has been committed, immediately before
        # the mutable successor feed becomes visible.
        if item.key == feed_key and not aliases_verified:
            for alias, source_item in website_aliases:
                verifier.verify(
                    f"https://responsay.com/owltype/{alias}", source_item.sha256
                )
            aliases_verified = True
        existing = store.read(item.key)
        if item.immutable and existing is not None:
            existing_sha256 = hashlib.sha256(existing).hexdigest()
            if existing_sha256 != item.sha256:
                raise DistributionError(
                    f"immutable object already exists with different content: {item.key}"
                )
            events.append(f"REUSE {item.key}")
        else:
            store.put(
                item.source,
                item.key,
                content_type=item.content_type,
                cache_control=item.cache_control,
            )
            written = store.read(item.key)
            if written is None or hashlib.sha256(written).hexdigest() != item.sha256:
                raise DistributionError(f"R2 readback mismatch: {item.key}")
            events.append(f"UPLOAD {item.key}")
        verifier.verify(item.url, item.sha256)
    appcast_sha256 = next(
        item.sha256 for item in plan if item.key == feed_key
    )
    client_feed_url = f"{PUBLIC_ORIGIN}/{feed_key}"
    verifier.verify(client_feed_url, appcast_sha256)
    events.append(f"VERIFY {client_feed_url}")
    if bridge:
        verifier.verify(LEGACY_CLIENT_FEED_URL, appcast_sha256)
        events.append(f"VERIFY {LEGACY_CLIENT_FEED_URL}")
    return events


class WranglerR2Store:
    def __init__(self, bucket: str = R2_BUCKET) -> None:
        self.bucket = bucket
        executable = shutil.which("wrangler")
        if executable is None:
            raise DistributionError(
                f"wrangler {WRANGLER_VERSION} is required; install that exact version first"
            )
        version = subprocess.check_output(
            [executable, "--version"], text=True
        ).strip()
        if version.split()[-1] != WRANGLER_VERSION:
            raise DistributionError(
                f"wrangler version mismatch: expected {WRANGLER_VERSION}, got {version!r}"
            )
        self.command = [executable]

    def read(self, key: str) -> bytes | None:
        with tempfile.TemporaryDirectory(prefix="owl-r2-readback-") as directory:
            destination = Path(directory) / "object"
            result = subprocess.run(
                [
                    *self.command,
                    "r2",
                    "object",
                    "get",
                    f"{self.bucket}/{key}",
                    "--remote",
                    "--file",
                    str(destination),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
            if result.returncode == 0:
                return destination.read_bytes()
            if "The specified key does not exist" in result.stdout:
                return None
            raise DistributionError(f"wrangler could not read {key}:\n{result.stdout.rstrip()}")

    def put(
        self,
        source: Path,
        key: str,
        *,
        content_type: str,
        cache_control: str,
    ) -> None:
        with source.open("rb") as input_stream:
            subprocess.run(
                [
                    *self.command,
                    "r2",
                    "object",
                    "put",
                    f"{self.bucket}/{key}",
                    "--remote",
                    "--pipe",
                    "--content-type",
                    content_type,
                    "--cache-control",
                    cache_control,
                ],
                stdin=input_stream,
                check=True,
            )


class HTTPPublicVerifier:
    def verify(self, url: str, sha256: str) -> None:
        verified_url = f"{url}?owl-verify={sha256}"
        last_error: Exception | None = None
        for delay in (0, 1, 2, 4):
            if delay:
                time.sleep(delay)
            digest = hashlib.sha256()
            try:
                request = urllib.request.Request(
                    verified_url,
                    headers={"Cache-Control": "no-cache", "User-Agent": "OwlReleaseVerifier/1"},
                )
                with urllib.request.urlopen(request, timeout=30) as response:
                    if response.status != 200:
                        raise DistributionError(f"public URL returned HTTP {response.status}: {url}")
                    for chunk in iter(lambda: response.read(1024 * 1024), b""):
                        digest.update(chunk)
                if digest.hexdigest() == sha256:
                    return
                last_error = DistributionError(f"public readback hash mismatch: {url}")
            except (OSError, urllib.error.URLError, DistributionError) as error:
                last_error = error
        raise DistributionError(f"public readback failed for {url}: {last_error}")


def _load_verified_cohort(
    repo_root: Path, output_root: Path
) -> tuple[list[Path], str, str, str]:
    state = repo_root / "scripts/release-cohort-state.py"
    gate = repo_root / "scripts/check-published-release.sh"
    subprocess.run(
        [
            sys.executable,
            str(state),
            "require-publish-authorization",
            str(output_root),
        ],
        check=True,
    )
    result = subprocess.run(
        ["bash", str(gate), "--print0", str(output_root)],
        stdout=subprocess.PIPE,
        check=True,
    )
    assets = [Path(value.decode()) for value in result.stdout.split(b"\0") if value]

    import json

    cohort_path = output_root / "release/OWLTYPE-RELEASE-COHORT.json"
    with cohort_path.open(encoding="utf-8") as handle:
        cohort = json.load(handle)
    version = str(cohort["version"])
    build_version = str(cohort["buildVersion"])
    feed_mode = str(cohort.get("sparkleFeedMode", ""))
    if feed_mode not in {"bridge", "successor"}:
        raise DistributionError("verified cohort has no valid Sparkle feed mode")

    appcast = next((path for path in assets if path.name == "appcast.xml"), None)
    expected_url = versioned_asset_url(build_version, "Owltype-update.pkg")
    if appcast is None or expected_url not in appcast.read_text(encoding="utf-8"):
        raise DistributionError(f"verified appcast does not reference {expected_url}")
    return assets, version, build_version, feed_mode


def main(argv: Sequence[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    if argv and argv[0] == "asset-url":
        if len(argv) != 3:
            raise DistributionError("usage: owl_distribution.py asset-url BUILD_VERSION FILENAME")
        print(versioned_asset_url(argv[1], argv[2]))
        return 0

    parser = argparse.ArgumentParser(
        description="Publish one complete, verified Owltype release cohort to responsay.com"
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--publish", action="store_true")
    parser.add_argument("--output-root", required=True, type=Path)
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parent.parent
    output_root = args.output_root.expanduser().resolve()
    assets, version, build_version, feed_mode = _load_verified_cohort(repo_root, output_root)
    plan = build_publish_plan(
        assets, version=version, build_version=build_version, feed_mode=feed_mode
    )

    if args.dry_run:
        for item in plan:
            mode_label = "IMMUTABLE" if item.immutable else "STABLE"
            print(f"WOULD_UPLOAD {mode_label} {item.source} -> {item.url}")
        print("PASS: complete responsay.com publication order rendered; no remote state changed")
        return 0

    events = publish(plan, WranglerR2Store(), HTTPPublicVerifier())
    for event in events:
        print(event)
    print(
        f"PASS: Owltype {version} (build {build_version}) published; "
        f"Sparkle feed mode {feed_mode} committed successfully"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (DistributionError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1) from error
