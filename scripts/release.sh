#!/usr/bin/env bash
# Build the signed/notarized App-owned portion of an exact release cohort.
#
# Composition ownership intentionally stays outside this script. It does not create a source
# archive, mutate a GitHub release, or write/deploy a website appcast; the release operator
# consumes the App assets/appcast produced here.
set -euo pipefail

DEV_ID="${DEV_ID:?set DEV_ID to the Developer ID common name}"
NOTARY_PROFILE="${NOTARY_PROFILE:?set NOTARY_PROFILE to the notarytool keychain profile name}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

echo "==> 1/5 validate signing and notarization readiness"
security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application: ${DEV_ID}" || {
  echo >&2 "ERROR: Developer ID Application identity is unavailable"
  exit 1
}
security find-identity -v 2>/dev/null | grep -q "Developer ID Installer: ${DEV_ID}" || {
  echo >&2 "ERROR: Developer ID Installer identity is unavailable"
  exit 1
}
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
  echo >&2 "ERROR: NOTARY_PROFILE points to an unavailable notarytool keychain profile"
  exit 1
}

echo "==> 2/5 assemble the pinned public seed"
make famo-seed

echo "==> 3/5 build, sign, notarize, and package the App cohort"
make dmg DEV_ID="$DEV_ID" NOTARY_PROFILE="$NOTARY_PROFILE"

echo "==> 4/5 generate the signed immutable appcast"
# Call the packaging helper directly. The Makefile `archive` target depends on the phony `package`
# target and would rebuild/re-notarize the cohort a second time.
make package/sign_update
[[ -x package/sign_update ]] || {
  echo >&2 "ERROR: Sparkle sign_update helper is unavailable"
  exit 1
}
bash package/make_archive

echo "==> 5/5 run App-owned automated artifact gates"
FAMO_IDENTITY_STRICT=1 bash scripts/check-identity-residual.sh
bash scripts/check-manifest.sh
bash scripts/check-release.sh --automated-only

for artifact in package/Famo.dmg package/Famo.pkg package/Famo-update.pkg package/appcast.xml; do
  [[ -s "$artifact" ]] || {
    echo >&2 "ERROR: missing App cohort output: $artifact"
    exit 1
  }
  printf 'OUTPUT: %s\n' "$HERE/$artifact"
done

printf 'PASS: App release cohort build complete; composition/publishing steps remain external\n'
