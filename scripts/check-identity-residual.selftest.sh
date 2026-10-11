#!/usr/bin/env bash
# Self-test for the artifact layers of check-identity-residual.sh — the built app,
# installer app (including its embedded app), pkg payload and mounted dmg. Builds
# throwaway artifacts poisoned with the old 法墨/Famo
# identity — and with Squirrel's id, which the CLAIM tier forbids artifacts to claim — and
# asserts the gate FAILS on them, PASSES with no artifacts present, and that the
# hard/claim/product tier split and the strict flag behave as documented.
#
# It drives `--artifacts` on purpose. The source layer scans this working tree, so its
# verdict is whatever the rename has reached so far; the artifact layers are fixture-driven
# and therefore the part that can be pinned. Real on-disk artifacts are left untouched —
# every run points OWL_APP/OWL_INSTALLER_APP/OWL_PKG/OWL_DMG at nonexistent paths,
# overriding per-case.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/check-identity-residual.sh"
work="$(mktemp -d /tmp/owl-idselftest.XXXXXX)"
trap 'rm -rf "$work"' EXIT

pass=0 ; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=$((fail + 1)); }

# Run the gate's artifact layers with all real artifacts overridden away; caller args
# add/override env (last wins). Output is captured so a case can assert WHY the gate
# failed: with four layers each able to fail, an exit code alone lets one layer's
# complaint stand in for the one under test.
gate_out=""
run_gate() {
  local status=0
  gate_out="$(env OWL_APP=/nonexistent OWL_INSTALLER_APP=/nonexistent \
      OWL_PKG=/nonexistent OWL_DMG=/nonexistent "$@" \
      bash "$GATE" --artifacts 2>&1)" || status=$?
  return "$status"
}

# expect_fail <label> <expected substring in the gate's own output>
expect_fail() {
  local label="$1" reason="$2"
  if grep -qF "$reason" <<<"$gate_out"; then
    ok "$label"
  else
    bad "$label — failed, but not over \"$reason\": $(head -3 <<<"$gate_out" | tr '\n' '|')"
  fi
}

# write_app <dir> <identifier> [extra-plist-entry]
write_app() {
  local dir="$1" identifier="$2" extra="${3:-}"
  mkdir -p "$dir/Contents/MacOS"
  printf '#!/bin/sh\nexit 0\n' > "$dir/Contents/MacOS/Owltype"
  chmod +x "$dir/Contents/MacOS/Owltype"
  cat > "$dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${identifier}</string>
  ${extra}
</dict></plist>
PLIST
}

write_app "$work/clean-app/Owltype.app" "im.owltype.inputmethod.Owltype"
write_app "$work/poison-app/Owltype.app" "im.famo.inputmethod.Famo"
write_app "$work/brand-app/Owltype.app" "im.owltype.inputmethod.Owltype" \
  '<key>CFBundleName</key><string>法墨输入法</string>'
write_app "$work/claim-app/Owltype.app" "im.rime.inputmethod.Squirrel"
write_app "$work/binary-poison-app/Owltype.app" "im.owltype.inputmethod.Owltype" \
  '<key>CFBundleExecutable</key><string>Owltype</string>'
mkdir -p "$work/binary-poison-app/Owltype.app/Contents/MacOS"
printf '#!/bin/sh\n# embedded legacy identity: %s\n' "im.famo.inputmethod.Famo" \
  > "$work/binary-poison-app/Owltype.app/Contents/MacOS/Owltype"
chmod +x "$work/binary-poison-app/Owltype.app/Contents/MacOS/Owltype"
write_app "$work/clean-installer/OwltypeInstaller.app" "im.owltype.installer"
mkdir -p "$work/clean-installer/OwltypeInstaller.app/Contents/Library"
cp -R "$work/clean-app/Owltype.app" \
  "$work/clean-installer/OwltypeInstaller.app/Contents/Library/Owltype.app"
write_app "$work/empty-installer/OwltypeInstaller.app" "im.owltype.installer"
write_app "$work/poison-installer/OwltypeInstaller.app" "im.owltype.installer"
mkdir -p "$work/poison-installer/OwltypeInstaller.app/Contents/Library"
cp -R "$work/poison-app/Owltype.app" \
  "$work/poison-installer/OwltypeInstaller.app/Contents/Library/Owltype.app"

# Build one complete clean artifact set so strict structure tests can replace exactly one
# layer. This prevents an unrelated missing layer from supplying the nonzero exit status.
mkdir -p "$work/clean-pkgroot/Library/Input Methods/.Owltype.pkg-staging"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$work/clean-app/Owltype.app" "$work/clean-pkgroot/Library/Input Methods/.Owltype.pkg-staging/Owltype.app.zip"
mkdir -p "$work/clean-package"
pkgbuild --root "$work/clean-pkgroot" --identifier im.owltype.inputmethod.Owltype \
  --install-location / --component-plist "$ROOT/package/Owltype-component.plist" --version 0.0 \
  "$work/clean-package/Owltype-component.pkg" >/dev/null 2>&1
productbuild --synthesize --package "$work/clean-package/Owltype-component.pkg" \
  "$work/clean-dist.xml" >/dev/null 2>&1
productbuild --distribution "$work/clean-dist.xml" --package-path "$work/clean-package" \
  "$work/clean.pkg" >/dev/null 2>&1

mkdir -p "$work/clean-dmgroot"
cp -R "$work/clean-installer/OwltypeInstaller.app" \
  "$work/clean-dmgroot/OwltypeInstaller.app"
hdiutil create -volname OwltypeCleanSelfTest -srcfolder "$work/clean-dmgroot" \
  -ov -format UDZO "$work/clean.dmg" >/dev/null 2>&1

run_strict_clean() {
  run_gate OWL_IDENTITY_STRICT=1 \
    OWL_APP="$work/clean-app/Owltype.app" \
    OWL_INSTALLER_APP="$work/clean-installer/OwltypeInstaller.app" \
    OWL_PKG="$work/clean.pkg" \
    OWL_DMG="$work/clean.dmg" \
    "$@"
}

# --- positive: no artifacts present → artifact layers pass (no false positive) ---
if run_gate; then ok "positive: no artifacts present passes"; else bad "positive: no-artifact run should exit 0"; fi

# --- negative A: built app carries the old bundle id → fails even non-strict ---
if run_gate OWL_APP="$work/poison-app/Owltype.app"; then
  bad "negative A: built app with the old bundle id should fail the gate"
else
  expect_fail "negative A: built app with the old bundle id fails the gate" \
    "hard identity residue in built app"
fi

# --- negative E: the plist is clean but the executable embeds a former hard identity.
# This catches compiled compatibility code that a plist/resource-only scan cannot see. ---
if run_gate OWL_APP="$work/binary-poison-app/Owltype.app"; then
  bad "negative E: built executable with the old bundle id should fail the gate"
else
  expect_fail "negative E: built executable with the old bundle id fails the gate" \
    "hard identity residue in built app"
fi

# --- negative D: built app claiming Squirrel's id → fails even non-strict. The CLAIM tier
# is enforced on artifacts only (a bundle claims an id; source text merely names one), so
# this case is the whole proof that moving it off the source layer did not disarm it. ---
if run_gate OWL_APP="$work/claim-app/Owltype.app"; then
  bad "negative D: built app claiming Squirrel's id should fail the gate"
else
  expect_fail "negative D: built app claiming Squirrel's id fails the gate" \
    "hard identity residue in built app"
fi

# --- tier split: brand-only residue (no hard id) warns, and OWL_IDENTITY_STRICT=1 fails it.
# That flag is what §2.5 gates the merge on, so both directions are pinned. ---
if run_gate OWL_APP="$work/brand-app/Owltype.app"; then
  ok "tier split: brand-only residue warns in non-strict mode"
else
  bad "tier split: brand-only residue should not fail the gate in non-strict mode"
fi
if run_gate OWL_IDENTITY_STRICT=1 OWL_APP="$work/brand-app/Owltype.app"; then
  bad "tier split: brand-only residue should fail under OWL_IDENTITY_STRICT=1"
else
  expect_fail "tier split: brand-only residue fails under OWL_IDENTITY_STRICT=1" \
    "product identity residue in built app (strict)"
fi

# --- strict demands every layer was actually looked at: a layer with nothing to scan reads
# exactly like a clean one, which is how a renamed artifact would slip through §7 Gate 1. ---
if run_strict_clean OWL_APP=/nonexistent; then
  bad "strict: a missing built app should fail the gate"
else
  expect_fail "strict: a missing built app fails the gate" \
    "OWL_APP must name the built app in strict mode"
fi
if run_strict_clean OWL_INSTALLER_APP=/nonexistent; then
  bad "strict: a missing installer app should fail the gate"
else
  expect_fail "strict: a missing installer app fails the gate" \
    "OWL_INSTALLER_APP must name the built installer app in strict mode"
fi
if run_strict_clean OWL_INSTALLER_APP="$work/empty-installer/OwltypeInstaller.app"; then
  bad "strict: an installer without its embedded app should fail the gate"
else
  expect_fail "strict: an installer without its embedded app fails the gate" \
    "OwltypeInstaller.app has no embedded Owltype.app (strict)"
fi
if run_strict_clean OWL_PKG=/nonexistent; then
  bad "strict: a missing pkg should fail the gate"
else
  expect_fail "strict: a missing pkg fails the gate" \
    "OWL_PKG must name the built installer pkg in strict mode"
fi

# --- negative F: the GUI installer outer bundle is clean, but the embedded App it will copy to
# /Library/Input Methods carries the predecessor identity. The outer scan alone cannot see this. ---
if run_gate OWL_INSTALLER_APP="$work/poison-installer/OwltypeInstaller.app"; then
  bad "negative F: installer with a poison embedded App should fail the gate"
else
  expect_fail "negative F: installer with a poison embedded App fails the gate" \
    "hard identity residue in OwltypeInstaller.app embedded Owltype.app"
fi

# --- negative B: pkg payload plist carries a HARD token → fails even non-strict ---
mkdir -p "$work/pkgroot/Library/Input Methods/.Owltype.pkg-staging"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$work/poison-app/Owltype.app" "$work/pkgroot/Library/Input Methods/.Owltype.pkg-staging/Owltype.app.zip"
pkgbuild --root "$work/pkgroot" --identifier im.owltype.inputmethod.Owltype \
  --install-location / --component-plist "$ROOT/package/Owltype-component.plist" --version 0.0 "$work/Owltype-component.pkg" >/dev/null 2>&1
productbuild --synthesize --package "$work/Owltype-component.pkg" "$work/dist.xml" >/dev/null 2>&1
productbuild --distribution "$work/dist.xml" --package-path "$work" "$work/poison.pkg" >/dev/null 2>&1
if run_gate OWL_PKG="$work/poison.pkg"; then
  bad "negative B: poison pkg (old bundle id in payload plist) should fail the gate"
else
  expect_fail "negative B: poison pkg (old bundle id in payload plist) fails the gate" \
    "hard identity residue in pkg payload"
fi

# --- negative C: DMG loose file carries a HARD token → gate must fail ---
mkdir -p "$work/dmgroot"
printf '#!/bin/sh\n# %s\n' "Famo_Connection" > "$work/dmgroot/uninstall-owltype.sh"
hdiutil create -volname OwltypeSelfTest -srcfolder "$work/dmgroot" -ov -format UDZO "$work/poison.dmg" >/dev/null 2>&1
if run_gate OWL_DMG="$work/poison.dmg"; then
  bad "negative C: poison DMG loose file (Famo_Connection) should fail the gate"
else
  expect_fail "negative C: poison DMG loose file (Famo_Connection) fails the gate" \
    "hard identity residue in DMG loose files"
fi


# --- negative G: the mounted DMG path must independently scan the embedded App copy. ---
mkdir -p "$work/dmg-embedded-root"
cp -R "$work/poison-installer/OwltypeInstaller.app" \
  "$work/dmg-embedded-root/OwltypeInstaller.app"
hdiutil create -volname OwltypeEmbeddedSelfTest -srcfolder "$work/dmg-embedded-root" \
  -ov -format UDZO "$work/poison-embedded.dmg" >/dev/null 2>&1
if run_gate OWL_DMG="$work/poison-embedded.dmg"; then
  bad "negative G: DMG with a poison embedded App should fail the gate"
else
  expect_fail "negative G: DMG with a poison embedded App fails the gate" \
    "hard identity residue in DMG embedded Owltype.app"
fi

# --- strict DMG shape: a mounted image must carry the outer installer and its embedded App.
# These cases pin the fail-closed branches independently of identity-residue fixtures. ---
mkdir -p "$work/dmg-rootless-root"
printf 'shape fixture\n' > "$work/dmg-rootless-root/README.txt"
hdiutil create -volname OwltypeRootlessSelfTest -srcfolder "$work/dmg-rootless-root" \
  -ov -format UDZO "$work/rootless.dmg" >/dev/null 2>&1
if run_strict_clean OWL_DMG="$work/rootless.dmg"; then
  bad "strict: a DMG without its root installer should fail the gate"
else
  expect_fail "strict: a DMG without its root installer fails the gate" \
    "DMG has no OwltypeInstaller.app at its root (strict)"
fi

mkdir -p "$work/dmg-empty-installer-root"
cp -R "$work/empty-installer/OwltypeInstaller.app" \
  "$work/dmg-empty-installer-root/OwltypeInstaller.app"
hdiutil create -volname OwltypeEmptyInstallerSelfTest -srcfolder "$work/dmg-empty-installer-root" \
  -ov -format UDZO "$work/empty-installer.dmg" >/dev/null 2>&1
if run_strict_clean OWL_DMG="$work/empty-installer.dmg"; then
  bad "strict: a DMG installer without its embedded app should fail the gate"
else
  expect_fail "strict: a DMG installer without its embedded app fails the gate" \
    "DMG installer has no embedded Owltype.app (strict)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
