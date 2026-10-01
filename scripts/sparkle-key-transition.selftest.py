#!/usr/bin/env python3

"""Focused policy tests for the one-release legacy -> Owltype Sparkle key cutover."""

from __future__ import annotations

import importlib.util
import json
import plistlib
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location(
    "release_cohort_state", ROOT / "scripts/release-cohort-state.py"
)
assert spec and spec.loader
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)

NEW_KEY = "dWrr6gck5aoy5F7V00SizqQM6w9MHmZzeeQFSqYTlfM="
OLD_KEY = "3Ze0A+sHbvkQ8CLlDUIcYvm7BJS4IJLU1rNEX66F9R4="


def expect_error(label: str, expected: str, action) -> None:
    try:
        action()
    except state.CohortError as error:
        assert expected in str(error), (label, error)
        print(f"ok   {label}")
    else:
        raise AssertionError(f"{label}: expected CohortError")


assert state.select_sparkle_verification_key("2.0.2", NEW_KEY, None) == NEW_KEY
print("ok   ordinary releases verify with the public key embedded in their App")

assert state.select_sparkle_verification_key("2.0.1", NEW_KEY, OLD_KEY) == OLD_KEY
print("ok   2.0.1 may be signed once by the key trusted by installed 2.0.0 clients")

expect_error(
    "the transition override is rejected after 2.0.1",
    "only permitted for 2.0.1",
    lambda: state.select_sparkle_verification_key("2.0.2", NEW_KEY, OLD_KEY),
)
expect_error(
    "the transition must actually change trust domains",
    "must differ",
    lambda: state.select_sparkle_verification_key("2.0.1", NEW_KEY, NEW_KEY),
)
expect_error(
    "malformed public keys fail closed",
    "invalid Sparkle public key",
    lambda: state.select_sparkle_verification_key("2.0.1", NEW_KEY, "not-a-key"),
)

base = (
    "a" * 40,
    "2.0.1",
    "2.0.1",
    "b" * 64,
    "c" * 64,
    "d" * 64,
    "e" * 64,
    {},
)
ordinary_id = state.cohort_identifier(
    *base, sparkle_signing_public_key=NEW_KEY, sparkle_feed_mode="successor"
)
transition_id = state.cohort_identifier(
    *base, sparkle_signing_public_key=OLD_KEY, sparkle_feed_mode="bridge"
)
assert ordinary_id != transition_id
print("ok   the selected Sparkle verification key is bound into the cohort identity")

with tempfile.TemporaryDirectory() as directory:
    app = Path(directory) / "Owltype.app"
    (app / "Contents").mkdir(parents=True)
    with (app / "Contents/Info.plist").open("wb") as handle:
        plistlib.dump(
            {
                "SUPublicEDKey": NEW_KEY,
                "SUFeedURL": "https://downloads.responsay.com/owltype/v2/appcast.xml",
            },
            handle,
        )
    original_policy = state.SPARKLE_TRANSITION_POLICY
    fixture_policy = Path(directory) / "sparkle-key-transition.json"
    fixture_policy.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "releaseVersion": "2.0.1",
                "fromPublicKey": OLD_KEY,
                "toPublicKey": NEW_KEY,
                "legacyFeedKey": "owltype/appcast.xml",
                "successorFeedKey": "owltype/v2/appcast.xml",
            }
        ),
        encoding="utf-8",
    )
    state.SPARKLE_TRANSITION_POLICY = fixture_policy
    try:
        bridge = state.resolve_sparkle_release_policy(app, "2.0.1")
        assert bridge == {
            "sparkleFeedMode": "bridge",
            "sparkleSigningPublicKey": OLD_KEY,
            "sparkleTrustTransitionFrom": OLD_KEY,
        }
        print("ok   a temporary 2.0.1 policy resolves to the old-key bridge")

        state.SPARKLE_TRANSITION_POLICY = Path(directory) / "absent-transition.json"
        successor = state.resolve_sparkle_release_policy(app, "2.0.2")
    finally:
        state.SPARKLE_TRANSITION_POLICY = original_policy
    assert successor == {
        "sparkleFeedMode": "successor",
        "sparkleSigningPublicKey": NEW_KEY,
    }
    print("ok   removing the one-release policy makes later releases new-key-only")

with tempfile.TemporaryDirectory() as directory:
    app = Path(directory) / "Owltype.app"
    (app / "Contents").mkdir(parents=True)
    def write_feed(feed: str) -> None:
        with (app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump({"SUPublicEDKey": NEW_KEY, "SUFeedURL": feed}, handle)
    write_feed("https://downloads.responsay.com/owltype/v2/appcast.xml")
    expect_error("recovery release rejects the old client feed", "Sparkle feed",
                 lambda: state.resolve_sparkle_release_policy(app, "2.0.10"))
    write_feed("https://downloads.responsay.com/owltype/v3/appcast.xml")
    assert state.resolve_sparkle_release_policy(app, "2.0.10") == {
        "sparkleFeedMode": "successor", "sparkleSigningPublicKey": NEW_KEY,
    }
    print("ok   recovery release uses its embedded key and the new v3 trust feed")

print("\nSparkle trust policy tests passed")
