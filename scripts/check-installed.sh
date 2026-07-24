#!/usr/bin/env bash
# Read-only installed-app smoke gate for the local Famo dev install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/famo-identity.sh
. "$ROOT/scripts/famo-identity.sh"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

if [[ -n "${FAMO_APP:-}" ]]; then
  APP="$FAMO_APP"
elif [[ -d "/Library/Input Methods/Famo.app" ]]; then
  APP="/Library/Input Methods/Famo.app"
else
  APP="$HOME/Library/Input Methods/Famo.app"
fi
if [[ -z "${FAMO_APP:-}" &&
      -d "/Library/Input Methods/Famo.app" &&
      -d "$HOME/Library/Input Methods/Famo.app" ]]; then
  fail "duplicate Famo installs found in /Library and ~/Library"
fi
EXE="$APP/Contents/MacOS/Famo"
DOMAIN="$FAMO_BUNDLE_ID"
SQUIRREL_DOMAIN="$SQUIRREL_BUNDLE_ID"
PROBE="$ROOT/build/famo-rime-probe"
PROBE_SRC="$ROOT/tools/famo-rime-probe.cc"

[[ -d "$APP" ]] || fail "installed app not found: $APP"
[[ -x "$EXE" ]] || fail "installed executable not found: $EXE"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
pass "codesign verifies installed app"

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
[[ "$bundle_id" == "$DOMAIN" ]] || fail "unexpected bundle id: $bundle_id"
pass "bundle id is $DOMAIN"

plutil -p "$APP/Contents/Resources/en.lproj/InfoPlist.strings" | grep -q '"im.famo.inputmethod.Famo.Hans" => "法墨输入法"' ||
  fail "installed Famo Hans menu label is not localized as 法墨输入法"
pass "installed Famo Hans menu label is localized"

[[ -s "$APP/Contents/Resources/LICENSE.txt" ]] || fail "missing GPL license in installed app resources"
[[ -s "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md" ]] || fail "missing third-party notices in installed app resources"
grep -q 'librime' "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md" || fail "third-party notices do not mention librime"
grep -q 'wubi86' "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md" || fail "third-party notices do not mention wubi86"
pass "installed app carries GPL license and third-party notices"

for file in \
  "famo.yaml" \
  "rime_ice.schema.yaml" \
  "rime_ice.dict.yaml" \
  "double_pinyin_flypy.schema.yaml" \
  "pinyin_simp.schema.yaml" \
  "pinyin_simp.dict.yaml" \
  "wubi86_jidian.schema.yaml" \
  "wubi86_jidian_pinyin.schema.yaml" \
  "wubi86_jidian_trad.schema.yaml" \
  "wubi86_jidian_trad_pinyin.schema.yaml"
do
  [[ -s "$APP/Contents/SharedSupport/$file" ]] || fail "installed app missing SharedSupport/$file"
done
pass "installed app bundles Famo frontend config, rime_ice (雾凇全拼), 小鹤双拼, 简体拼音, and 极点五笔全套 (KyleBing wubi86_jidian* + pinyin_simp 反查)"

[[ ! -e "$APP/Contents/SharedSupport/squirrel.yaml" ]] || fail "installed Famo app still bundles SharedSupport/squirrel.yaml"
! grep -q "$HOME/Library/Input Methods/Famo.app" "$APP/Contents/SharedSupport/famo.yaml" ||
  fail "installed Famo frontend config still references user-level Famo.app"
[[ -s "$APP/Contents/SharedSupport/_user_seed/famo.custom.yaml" ]] || fail "installed seed missing famo.custom.yaml"
[[ ! -e "$APP/Contents/SharedSupport/_user_seed/squirrel.custom.yaml" ]] || fail "installed Famo seed still bundles squirrel.custom.yaml"
pass "installed app uses Famo frontend config names"

for s in rime_ice pinyin_simp double_pinyin_flypy \
         wubi86_jidian wubi86_jidian_pinyin wubi86_jidian_trad wubi86_jidian_trad_pinyin; do
  grep -q "schema: $s" "$APP/Contents/SharedSupport/_user_seed/default.custom.yaml" || fail "installed seed does not enable $s"
done
pass "installed seed enables 雾凇全拼/简体拼音/小鹤双拼/极点五笔全套"

tis_output=$(/usr/bin/swift - <<'SWIFT'
import Carbon
import Foundation

func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
  guard let value = TISGetInputSourceProperty(source, key) else { return nil }
  return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
}

func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
  guard let value = TISGetInputSourceProperty(source, key) else { return false }
  return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
}

let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
let currentID = stringProperty(current, kTISPropertyInputSourceID) ?? ""
let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
let famoPrefix = "im.famo.inputmethod.Famo"
let squirrelPrefix = ["im", "rime", "inputmethod", "Squirrel"].joined(separator: ".")

print("current=\(currentID)")
for source in sources {
  guard let id = stringProperty(source, kTISPropertyInputSourceID),
        id.hasPrefix(famoPrefix) || id.hasPrefix(squirrelPrefix) else { continue }
  let enabled = boolProperty(source, kTISPropertyInputSourceIsEnabled)
  let selected = boolProperty(source, kTISPropertyInputSourceIsSelected)
  let selectable = boolProperty(source, kTISPropertyInputSourceIsSelectCapable)
  print("\(id) enabled=\(enabled) selected=\(selected) selectable=\(selectable)")
}
SWIFT
)

printf '%s\n' "$tis_output"
[[ $(grep -c '^im\.famo\.inputmethod\.Famo ' <<<"$tis_output") -eq 1 ]] || fail "duplicate Famo root input source"
[[ $(grep -c '^im\.famo\.inputmethod\.Famo\.Hans ' <<<"$tis_output") -eq 1 ]] || fail "duplicate Famo Hans input source"
[[ $(grep -c '^im\.famo\.inputmethod\.Famo\.Hant ' <<<"$tis_output") -eq 1 ]] || fail "duplicate Famo Hant input source"
grep -q '^current=im\.famo\.inputmethod\.Famo\.Hans$' <<<"$tis_output" || fail "Famo Hans is not current"
grep -q '^im\.famo\.inputmethod\.Famo\.Hans enabled=true selected=true selectable=true$' <<<"$tis_output" || fail "Famo Hans is not enabled/selected/selectable"
pass "TIS reports Famo Hans current and usable"

# W1.4: Famo-owned structured six-layer TIS diagnostic (read-only; FAMO-* codes). On this known-good
# install every TIS layer is healthy → summary carries no "code" (JSONEncoder omits nil). Any failure
# emits an actionable FAMO-* code instead of "reboot/logout". The alarm guards a stale pre-W1.4
# binary, which has no such flag and would launch the IME event loop instead of exiting.
diag_json=$(perl -e 'alarm 20; exec @ARGV' "$EXE" --diagnose-tis) ||
  fail "--diagnose-tis did not exit within 20s (reinstall the build under test)"
printf '%s\n' "$diag_json"
printf '%s' "$diag_json" | /usr/bin/python3 -c '
import json, sys
s = json.load(sys.stdin)["summary"]
code = s.get("code")
if code is not None:
    sys.stderr.write("summary.code=%s: %s\n" % (code, s.get("actionable", "")))
    sys.exit(1)
' || fail "--diagnose-tis reports a failure code on a known-good install"
pass "Famo --diagnose-tis reports all TIS layers healthy (no summary.code)"

if [[ -d "$SQUIRREL_APP" ]]; then
  squirrel_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SQUIRREL_APP/Contents/Info.plist")
  [[ "$squirrel_bundle_id" == "$SQUIRREL_DOMAIN" ]] || fail "unexpected Squirrel bundle id: $squirrel_bundle_id"
  pass "system Squirrel app remains separate"
  ! grep -Eq '^im\.rime\.inputmethod\.Squirrel.* selected=true' <<<"$tis_output" ||
    fail "Squirrel is selected while Famo smoke expects Famo current"
  pass "TIS reports Squirrel is not selected"
else
  pass "no system Squirrel app found"
fi

check_default_off() {
  local key="$1"
  local value
  if value=$(/usr/bin/defaults read "$DOMAIN" "$key" 2>/dev/null); then
    case "$value" in
      0|false|FALSE|False|no|NO|No) pass "$key is false" ;;
      *) fail "$key is set to $value" ;;
    esac
  else
    pass "$key is unset"
  fi
}

check_default_off FamoCloudLaneEnabled
check_default_off FamoLocalModelLaneEnabled
check_default_off FamoSensitiveModeEnabled

if [[ -d "$HOME/Library/Rime" ]] &&
   find "$HOME/Library/Rime" \( -iname '*famo*' -o -iname '*法墨*' \) -print -quit | grep -q .; then
  fail "found Famo-specific files under live ~/Library/Rime"
fi
pass "live ~/Library/Rime has no Famo-specific files"

if [[ ! -x "$PROBE" || "$PROBE_SRC" -nt "$PROBE" ]]; then
  mkdir -p "$ROOT/build"
  clang++ -std=c++17 \
    -I"$ROOT/librime/src" \
    -Wl,-rpath,"$APP/Contents/Frameworks" \
    "$PROBE_SRC" \
    "$APP/Contents/Frameworks/librime.1.dylib" \
    -o "$PROBE"
fi
pass "probe binary is built from source"

PROBE_USER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/famo-rime-probe.XXXXXX")"
trap 'rm -rf "$PROBE_USER_DIR"' EXIT
cp -R "$APP/Contents/SharedSupport/_user_seed/." "$PROBE_USER_DIR/"
mkdir -p "$PROBE_USER_DIR/build"
export DYLD_LIBRARY_PATH="$APP/Contents/Frameworks:$APP/Contents/Frameworks/rime-plugins:${DYLD_LIBRARY_PATH:-}"

pinyin_output=$("$PROBE" "$APP/Contents/SharedSupport" "$PROBE_USER_DIR" rime_ice nihao)
printf '%s\n' "$pinyin_output"
grep -q $'candidate\\[1\\]=你好' <<<"$pinyin_output" || fail "rime_ice nihao did not return 你好 first"
pass "rime_ice nihao probe returns 你好"

pinyin_simp_output=$("$PROBE" "$APP/Contents/SharedSupport" "$PROBE_USER_DIR" pinyin_simp nihao)
printf '%s\n' "$pinyin_simp_output"
grep -q $'candidate\\[1\\]=你好' <<<"$pinyin_simp_output" || fail "pinyin_simp nihao did not return 你好 first"
pass "pinyin_simp nihao probe returns 你好"

wubi_output=$("$PROBE" "$APP/Contents/SharedSupport" "$PROBE_USER_DIR" wubi86_jidian wqvb)
printf '%s\n' "$wubi_output"
grep -q $'candidate\\[1\\]=你好' <<<"$wubi_output" || fail "wubi86_jidian wqvb did not return 你好 first"
pass "wubi86_jidian wqvb probe returns 你好"

wubi_pinyin_output=$("$PROBE" "$APP/Contents/SharedSupport" "$PROBE_USER_DIR" wubi86_jidian_pinyin nihao)
printf '%s\n' "$wubi_pinyin_output"
grep -q $'candidate\\[1\\]=你好' <<<"$wubi_pinyin_output" || fail "wubi86_jidian_pinyin nihao did not return 你好 first"
pass "wubi86_jidian_pinyin nihao probe returns 你好"

# 出厂默认（落共享 rime_ice.schema.yaml 的 reset）：emoji 关（纯雾凇无带声调 preedit）。
ice_schema="$APP/Contents/SharedSupport/rime_ice.schema.yaml"
grep -A3 'name: emoji' "$ice_schema" | grep -q 'reset: 0' ||
  fail "installed rime_ice.schema.yaml does not default emoji off (reset: 0)"
pass "installed rime_ice default: emoji off"

pass "installed Famo smoke gate complete"
