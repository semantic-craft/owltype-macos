#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from owl_distribution import (
    CLIENT_FEED_URL,
    IMMUTABLE_CACHE_CONTROL,
    STABLE_CACHE_CONTROL,
    WRANGLER_VERSION,
    DistributionError,
    WranglerR2Store,
    build_publish_plan,
    publish,
    versioned_asset_url,
)


class FakeObjectStore:
    def __init__(self, existing: dict[str, bytes] | None = None) -> None:
        self.objects = dict(existing or {})
        self.puts: list[str] = []

    def read(self, key: str) -> bytes | None:
        return self.objects.get(key)

    def put(
        self,
        source: Path,
        key: str,
        *,
        content_type: str,
        cache_control: str,
    ) -> None:
        del content_type, cache_control
        self.objects[key] = source.read_bytes()
        self.puts.append(key)


class FakePublicVerifier:
    def __init__(self) -> None:
        self.verified: list[tuple[str, str]] = []

    def verify(self, url: str, sha256: str) -> None:
        self.verified.append((url, sha256))


def fixture_assets(root: Path, version: str) -> list[Path]:
    names = [
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
    ]
    assets = []
    for index, name in enumerate(names):
        path = root / name
        path.write_bytes(f"fixture-{index}-{name}\n".encode())
        assets.append(path)
    return assets


class DistributionPlanTests(unittest.TestCase):
    def test_versioned_update_url_uses_responsay_download_host(self) -> None:
        self.assertEqual(
            versioned_asset_url("162", "Owltype-update.pkg"),
            "https://downloads.responsay.com/owltype/releases/162/Owltype-update.pkg",
        )

    def test_versioned_update_url_rejects_path_segments(self) -> None:
        with self.assertRaises(DistributionError):
            versioned_asset_url("1.6.2", "../Owltype-update.pkg")
        with self.assertRaises(DistributionError):
            versioned_asset_url("1..6", "Owltype-update.pkg")

    def test_plan_uploads_complete_cohort_then_atomic_pointer_and_feed_last(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            assets = fixture_assets(Path(directory), "1.6.2")
            plan = build_publish_plan(
                assets,
                version="1.6.2",
                build_version="162",
            )

        versioned = plan[:10]
        self.assertEqual(len(versioned), 10)
        self.assertTrue(all(item.immutable for item in versioned))
        self.assertTrue(
            all(item.cache_control == IMMUTABLE_CACHE_CONTROL for item in versioned)
        )
        self.assertEqual(
            versioned[1].url,
            "https://downloads.responsay.com/owltype/releases/162/Owltype-update.pkg",
        )
        self.assertEqual(plan[-2].key, "owltype/latest.json")
        self.assertEqual(plan[-1].key, "owltype/appcast.xml")
        self.assertEqual(plan[-1].cache_control, STABLE_CACHE_CONTROL)
        self.assertFalse(plan[-1].immutable)
        self.assertEqual(plan[-1].source.name, "appcast.xml")
        self.assertNotIn("owltype/latest/Owltype-update.pkg", [item.key for item in plan])

    def test_plan_rejects_incomplete_corresponding_source_contract(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            assets = fixture_assets(Path(directory), "1.6.2")
            assets = [path for path in assets if not path.name.endswith("-source.tar.gz")]
            with self.assertRaisesRegex(DistributionError, "publishing contract"):
                build_publish_plan(assets, version="1.6.2", build_version="162")


class PublisherTests(unittest.TestCase):
    def test_r2_store_requires_the_exact_pinned_wrangler(self) -> None:
        with patch("owl_distribution.shutil.which", return_value=None):
            with self.assertRaisesRegex(DistributionError, WRANGLER_VERSION):
                WranglerR2Store()
        with (
            patch("owl_distribution.shutil.which", return_value="/fixture/wrangler"),
            patch(
                "owl_distribution.subprocess.check_output",
                return_value="4.124.0\n",
            ),
        ):
            with self.assertRaisesRegex(DistributionError, "version mismatch"):
                WranglerR2Store()

    def test_publish_is_idempotent_for_matching_immutable_objects_and_feed_is_last(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            assets = fixture_assets(Path(directory), "1.6.2")
            plan = build_publish_plan(
                assets,
                version="1.6.2",
                build_version="162",
            )
            first = plan[0]
            store = FakeObjectStore({first.key: first.source.read_bytes()})
            verifier = FakePublicVerifier()
            events = publish(plan, store, verifier)

        self.assertEqual(events[0], f"REUSE {first.key}")
        self.assertNotIn(first.key, store.puts)
        self.assertEqual(store.puts[-1], "owltype/appcast.xml")
        self.assertEqual(len(verifier.verified), len(plan) + 5)
        manual_urls = [url for url, _ in verifier.verified[-6:-1]]
        self.assertEqual(
            manual_urls,
            [
                "https://responsay.com/owltype/Owltype.pkg",
                "https://responsay.com/owltype/Owltype-update.pkg",
                "https://responsay.com/owltype/Owltype.dmg",
                "https://responsay.com/owltype/source.tar.gz",
                "https://downloads.responsay.com/owltype/appcast.xml",
            ],
        )
        self.assertEqual(verifier.verified[-1][0], CLIENT_FEED_URL)

    def test_website_aliases_do_not_confuse_installer_with_update_package(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            assets = fixture_assets(Path(directory), "1.6.3")
            assets.sort(key=lambda path: path.name != "Owltype-update.pkg")
            plan = build_publish_plan(
                assets,
                version="1.6.3",
                build_version="1.6.3",
            )
            verifier = FakePublicVerifier()
            publish(plan, FakeObjectStore(), verifier)

        installer = next(item for item in plan if item.source.name == "Owltype.pkg")
        update = next(item for item in plan if item.source.name == "Owltype-update.pkg")
        verified = dict(verifier.verified)
        self.assertNotEqual(installer.sha256, update.sha256)
        self.assertEqual(
            verified["https://responsay.com/owltype/Owltype.pkg"], installer.sha256
        )
        self.assertEqual(
            verified["https://responsay.com/owltype/Owltype-update.pkg"], update.sha256
        )

    def test_publish_rejects_replacement_of_immutable_versioned_object(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            assets = fixture_assets(Path(directory), "1.6.2")
            plan = build_publish_plan(
                assets,
                version="1.6.2",
                build_version="162",
            )
            expected = hashlib.sha256(plan[0].source.read_bytes()).hexdigest()
            store = FakeObjectStore({plan[0].key: b"different release"})
            with self.assertRaisesRegex(DistributionError, "immutable object"):
                publish(plan, store, FakePublicVerifier())

        self.assertEqual(plan[0].sha256, expected)


if __name__ == "__main__":
    unittest.main()
