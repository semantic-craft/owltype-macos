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
DOWNLOADS_REPOSITORY = "semantic-craft/downloads"
_BINARY_SUFFIXES = (".dmg", ".pkg", ".tar.gz")
OBJECT_PREFIX = "owltype"
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

    def commit(self, message: str) -> None: ...


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
    for item in plan:
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
                raise DistributionError(f"readback mismatch: {item.key}")
            events.append(f"UPLOAD {item.key}")
    # Release assets are public on upload. latest.json (the website aliases) and the Sparkle
    # feed become public together in this one commit, after every asset is in place.
    store.commit(f"owltype: publish {plan[0].key.split('/')[-2]}")
    events.append("COMMIT")
    for item in plan:
        verifier.verify(item.url, item.sha256)
    for alias, source_item in website_aliases:
        verifier.verify(f"https://responsay.com/owltype/{alias}", source_item.sha256)
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


class GitHubDownloadsStore:
    """Binaries are Release assets of the public downloads repository; every other
    object is a file under its site/ directory, which Cloudflare Pages serves at
    PUBLIC_ORIGIN. site/_redirects maps each binary URL to its asset."""

    def __init__(self, tag: str, repository: str = DOWNLOADS_REPOSITORY, gh: str = "gh") -> None:
        if shutil.which(gh) is None:
            raise DistributionError("gh is required and must be logged in to GitHub")
        self.gh, self.repository, self.tag = gh, repository, tag
        self._workdir = tempfile.TemporaryDirectory(prefix="owl-downloads-")
        self.checkout = Path(self._workdir.name) / "downloads"
        subprocess.run([gh, "repo", "clone", repository, str(self.checkout), "--", "--depth", "1"], check=True)
        self.site = self.checkout / "site"
        self.redirects_path = self.site / "_redirects"
        self.redirects: dict[str, str] = {}
        for line in self.redirects_path.read_text(encoding="utf-8").splitlines():
            if line.strip() and not line.startswith("#"):
                path, target, *_ = line.split()
                self.redirects[path] = target
        self.assets: set[str] | None = None

    def _asset_url(self, name: str) -> str:
        return f"https://github.com/{self.repository}/releases/download/{self.tag}/{quote(name)}"

    def _release_assets(self) -> set[str]:
        if self.assets is None:
            result = subprocess.run([self.gh, "release", "view", self.tag, "-R", self.repository,
                                     "--json", "assets", "-q", ".assets[].name"],
                                    capture_output=True, text=True, check=False)
            if result.returncode != 0:
                subprocess.run([self.gh, "release", "create", self.tag, "-R", self.repository,
                                "--title", self.tag, "--notes", f"Owltype {self.tag.removeprefix('owltype-')}",
                                "--latest=false"], check=True, stdout=subprocess.DEVNULL)
                self.assets = set()
            else:
                self.assets = set(result.stdout.split())
        return self.assets

    def read(self, key: str) -> bytes | None:
        if not key.endswith(_BINARY_SUFFIXES):
            path = self.site / key
            return path.read_bytes() if path.is_file() else None
        target = self.redirects.get(f"/{key}")
        if target is None:
            return None
        try:
            with urllib.request.urlopen(target, timeout=120) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            raise

    def put(self, source: Path, key: str, *, content_type: str, cache_control: str) -> None:
        if not key.endswith(_BINARY_SUFFIXES):
            path = self.site / key
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, path)
            return
        if source.name not in self._release_assets():
            subprocess.run([self.gh, "release", "upload", self.tag, "-R", self.repository, str(source)], check=True)
            self.assets.add(source.name)
        self.redirects[f"/{key}"] = self._asset_url(source.name)
        self.redirects_path.write_text(
            "".join(f"{path} {target} 302\n" for path, target in self.redirects.items()), encoding="utf-8")

    def commit(self, message: str) -> None:
        git = ["git", "-C", str(self.checkout)]
        subprocess.run([*git, "add", "-A", "site"], check=True)
        if subprocess.run([*git, "diff", "--cached", "--quiet"], check=False).returncode == 0:
            return
        subprocess.run([*git, "commit", "-q", "-m", message], check=True)
        subprocess.run([*git, "push", "-q", "origin", "HEAD"], check=True)


class HTTPPublicVerifier:
    def verify(self, url: str, sha256: str) -> None:
        verified_url = f"{url}?owl-verify={sha256}"
        last_error: Exception | None = None
        for delay in (0, 5, 10, 20, 30, 60, 60):
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

    events = publish(plan, GitHubDownloadsStore(f"owltype-{build_version}"), HTTPPublicVerifier())
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
