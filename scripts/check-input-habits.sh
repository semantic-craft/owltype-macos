#!/usr/bin/env bash
# Isolated acceptance: production controller + real Rime + native text view, then engine replay.
# Does not install/register/select an IME or access the user's Rime data.
# Requires the repository's existing native dependencies (same prerequisite as make debug).
# Optional: OWL_HABITS_DICTS=/path/to/verified/full-dictionary-fixture enables English replay.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DERIVED="${OWL_HABITS_DERIVED_DATA:-/tmp/owltype-input-habits-build}"
EVIDENCE="$(mktemp -d /tmp/owltype-habits-acceptance.XXXXXX)"
APP="$DERIVED/Build/Products/Debug/Owltype.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Xcode may register the test host in LaunchServices. Remove just this build's claim.
trap '"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true' EXIT
printf 'Evidence: %s\n' "$EVIDENCE"
git rev-parse HEAD > "$EVIDENCE/base-commit.txt"
git status --short > "$EVIDENCE/working-tree.txt"
XCODE=(xcodebuild -project Owltype.xcodeproj -scheme Owltype -configuration Debug
  -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-)
"${XCODE[@]}" build-for-testing > "$EVIDENCE/build.log" 2>&1 || { tail -40 "$EVIDENCE/build.log"; exit 1; }
make copy-owl-seed DERIVED_DATA_PATH="$DERIVED" OWL_CONFIG=Debug > "$EVIDENCE/seed.log" 2>&1
"${XCODE[@]}" test-without-building -resultBundlePath "$EVIDENCE/tests.xcresult" \
  -only-testing:OwltypeTests/OwlInputHabitsIntegrationTests \
  -only-testing:OwltypeTests/OwlInputHabitsTests \
  -only-testing:OwltypeTests/OwlGetAppOptionsRoundTripTests \
  -only-testing:OwltypeTests/OwlQuickSendPanelModelTests \
  -only-testing:OwltypeTests/OwlPinyinMixedInputTests \
  -only-testing:OwltypeTests/OwlKeyboardPatchBuilderTests \
  -only-testing:OwltypeTests/OwlSettingsCoverageTests \
  -only-testing:OwltypeTests/OwlSettingsActionTests \
  -only-testing:OwltypeTests/OwlSettingsE2ETests \
  -only-testing:OwltypeTests/RimeSeamTests > "$EVIDENCE/tests.log" 2>&1 \
  || { tail -60 "$EVIDENCE/tests.log"; exit 1; }
rg 'Executed .* tests|TEST EXECUTE SUCCEEDED' "$EVIDENCE/tests.log" | tail -3
python3 scripts/check-pinyin-pinning.py --app "$APP" | tee "$EVIDENCE/pinning.log"
OWL_APP="$APP" bash scripts/check-input-replay.sh > "$EVIDENCE/golden.log" 2>&1 \
  || { tail -40 "$EVIDENCE/golden.log"; exit 1; }
tail -1 "$EVIDENCE/golden.log"
if [[ -n "${OWL_HABITS_DICTS:-}" ]]; then
  python3 scripts/check-pinyin-mixed-input.py --app "$APP" --dicts "$OWL_HABITS_DICTS" | tee "$EVIDENCE/mixed.log"
else
  printf 'SKIP: full English dictionary replay (set OWL_HABITS_DICTS to a verified fixture)\n'
fi
shasum -a 256 "$APP/Contents/MacOS/Owltype" > "$EVIDENCE/executable.sha256"
printf 'PASS: isolated input-habits acceptance; evidence %s\n' "$EVIDENCE"
printf 'NOT RUN: installed IMK transport, system focus changes, native candidate context-menu tracking.\n'
