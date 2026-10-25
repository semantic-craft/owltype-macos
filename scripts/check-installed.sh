#!/usr/bin/env bash
# Read-only installed-app smoke gate for the local Owltype dev install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/owl-identity.sh
. "$ROOT/scripts/owl-identity.sh"

# 断言失败只记账、不退出：fail-fast 会让第一条 FAIL 掩盖后面所有检查（2026-07-27 实测——
# 一条过时的 SharedSupport 断言把 TIS 层与候选级探针整段藏了起来，真回归无从发现）。
FAILURES=()
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES+=("$1"); }
# 多条断言共用一句结论时，fail 不再退出会让该结论无条件打印，出现「FAIL: Owltype Hans is not
# current」后紧跟「PASS: ...current and usable」的自相矛盾输出。pass_clean 只在本组一条没错
# 时才下结论；两者都把游标推到当前失败数，于是下一组的起点自动接上，无需手工标记组边界。
# 彼此独立、不共用结论的断言（如 check_default_off 逐项）继续用 pass。
MARK=0
pass() { printf 'PASS: %s\n' "$1"; MARK=${#FAILURES[@]}; }
pass_clean() {
  if (( ${#FAILURES[@]} == MARK )); then printf 'PASS: %s\n' "$1"; fi
  MARK=${#FAILURES[@]}
}
# 前置条件失败后续检查全无意义（app 都不在，codesign/探针只会连环报错）——这类仍立即退出。
die() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

if [[ -n "${OWL_APP:-}" ]]; then
  APP="$OWL_APP"
elif [[ -d "/Library/Input Methods/Owltype.app" ]]; then
  APP="/Library/Input Methods/Owltype.app"
else
  APP="$HOME/Library/Input Methods/Owltype.app"
fi
if [[ -z "${OWL_APP:-}" &&
      -d "/Library/Input Methods/Owltype.app" &&
      -d "$HOME/Library/Input Methods/Owltype.app" ]]; then
  die "duplicate Owltype installs found in /Library and ~/Library"
fi
EXE="$APP/Contents/MacOS/Owltype"
DOMAIN="$OWL_BUNDLE_ID"
SQUIRREL_DOMAIN="$SQUIRREL_BUNDLE_ID"
TIS_MODE="${OWL_TIS_MODE:-interactive}"

case "$TIS_MODE" in
  interactive|hosted) ;;
  *) die "unsupported OWL_TIS_MODE: $TIS_MODE" ;;
esac

[[ -d "$APP" ]] || die "installed app not found: $APP"
[[ -x "$EXE" ]] || die "installed executable not found: $EXE"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
pass_clean "codesign verifies installed app"

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
[[ "$bundle_id" == "$DOMAIN" ]] || fail "unexpected bundle id: $bundle_id"
pass_clean "bundle id is $DOMAIN"

plutil -p "$APP/Contents/Resources/en.lproj/InfoPlist.strings" | grep -q '"im.owltype.inputmethod.Owltype.Hans" => "猫头鹰输入法"' ||
  fail "installed Owltype Hans menu label is not localized as 猫头鹰输入法"
pass_clean "installed Owltype Hans menu label is localized"

[[ -s "$APP/Contents/Resources/LICENSE.txt" ]] || fail "missing GPL license in installed app resources"
[[ -s "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md" ]] || fail "missing third-party notices in installed app resources"
grep -Eq 'msime|Metasequoia' "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md" || fail "third-party notices do not mention the msime Rust engine"
grep -q 'wubi86' "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md" || fail "third-party notices do not mention wubi86"
pass_clean "installed app carries GPL license and third-party notices"

python3 "$ROOT/scripts/check-rust-delivery.py" "$APP"
pass_clean "installed app delivers the Rust engine and complete SQLite resources"

# 五笔/简体拼音/小鹤双拼不进包是方案B的设计，但必须由 dictpack 清单兜住——清单一旦漏项，
# 新用户首启拉不到这些方案，而包里也没有，等于永久缺失（本机看不出来：老用户目录有历史文件垫着）。
DICTPACK_MANIFEST="$ROOT/sources/DictPack/OwlDictPackManifestData.swift"
if [[ -f "$DICTPACK_MANIFEST" ]]; then
  for dest in \
    "wubi86_jidian.schema.yaml" \
    "wubi86_jidian.dict.yaml" \
    "wubi86_jidian_pinyin.schema.yaml" \
    "wubi86_jidian_trad.schema.yaml" \
    "wubi86_jidian_trad_pinyin.schema.yaml" \
    "pinyin_simp.schema.yaml" \
    "pinyin_simp.dict.yaml" \
    "double_pinyin_flypy.schema.yaml"
  do
    grep -q "dest: \"$dest\"" "$DICTPACK_MANIFEST" || fail "dictpack manifest does not cover $dest"
  done
  pass_clean "dictpack manifest covers 极点五笔全套/简体拼音/小鹤双拼"
else
  fail "dictpack manifest not found: $DICTPACK_MANIFEST"
fi

run_tis_probe() {
  /usr/bin/swift - <<'SWIFT'
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
let owlPrefix = "im.owltype.inputmethod.Owltype"
let squirrelPrefix = ["im", "rime", "inputmethod", "Squirrel"].joined(separator: ".")

print("current=\(currentID)")
for source in sources {
  guard let id = stringProperty(source, kTISPropertyInputSourceID),
        id.hasPrefix(owlPrefix) || id.hasPrefix(squirrelPrefix) else { continue }
  let enabled = boolProperty(source, kTISPropertyInputSourceIsEnabled)
  let selected = boolProperty(source, kTISPropertyInputSourceIsSelected)
  let selectable = boolProperty(source, kTISPropertyInputSourceIsSelectCapable)
  print("\(id) enabled=\(enabled) selected=\(selected) selectable=\(selectable)")
}
SWIFT
}
tis_output=$(run_tis_probe)

printf '%s\n' "$tis_output"
[[ $(grep -c '^im\.owltype\.inputmethod\.Owltype ' <<<"$tis_output") -eq 1 ]] || fail "duplicate Owltype root input source"
[[ $(grep -c '^im\.owltype\.inputmethod\.Owltype\.Hans ' <<<"$tis_output") -eq 1 ]] || fail "duplicate Owltype Hans input source"
[[ $(grep -c '^im\.owltype\.inputmethod\.Owltype\.Hant ' <<<"$tis_output") -eq 1 ]] || fail "duplicate Owltype Hant input source"
if [[ "$TIS_MODE" == "interactive" ]] &&
   ! grep -q '^current=im\.owltype\.inputmethod\.Owltype\.Hans$' <<<"$tis_output"; then
  # 更新路径的选中态还原是 postinstall 调度的延迟任务（收据 ≤30s + 还原 ≤60s 窗口，
  # 见 scripts/postinstall 4b）。装完立刻探测会撞上还原在途——有界等待后复测一次，
  # 别把在途还原判成失败；真失败只是晚 ~90s 报出，不会漏报。
  for _ in $(seq 1 45); do
    sleep 2
    [[ "$("$EXE" --current-input-source 2>/dev/null)" == "im.owltype.inputmethod.Owltype.Hans" ]] && break
  done
  tis_output=$(run_tis_probe)
  printf '%s\n' "$tis_output"
fi
if [[ "$TIS_MODE" == "interactive" ]]; then
  grep -q '^current=im\.owltype\.inputmethod\.Owltype\.Hans$' <<<"$tis_output" || fail "Owltype Hans is not current"
  grep -q '^im\.owltype\.inputmethod\.Owltype\.Hans enabled=true selected=true selectable=true$' <<<"$tis_output" || fail "Owltype Hans is not enabled/selected/selectable"
  pass_clean "TIS reports Owltype Hans current and usable"
else
  grep -Eq '^im\.owltype\.inputmethod\.Owltype\.Hans enabled=true selected=(true|false) selectable=true$' <<<"$tis_output" ||
    fail "Owltype Hans is not enabled and selectable in the hosted Aqua session"
  pass_clean "TIS reports Owltype Hans uniquely registered, enabled, and selectable"
fi

# W1.4: Owltype-owned structured six-layer TIS diagnostic (read-only; OWL-* codes). On this known-good
# install every TIS layer is healthy → summary carries no "code" (JSONEncoder omits nil). Any failure
# emits an actionable OWL-* code instead of "reboot/logout". The alarm guards a stale pre-W1.4
# binary, which has no such flag and would launch the IME event loop instead of exiting.
diag_json=$(perl -e 'alarm 20; exec @ARGV' "$EXE" --diagnose-tis) ||
  fail "--diagnose-tis did not exit within 20s (reinstall the build under test)"
printf '%s\n' "$diag_json"
if [[ "$TIS_MODE" == "interactive" ]]; then
  printf '%s' "$diag_json" | /usr/bin/python3 -c '
import json, sys
s = json.load(sys.stdin)["summary"]
code = s.get("code")
if code is not None:
    sys.stderr.write("summary.code=%s: %s\n" % (code, s.get("actionable", "")))
    sys.exit(1)
' || fail "--diagnose-tis reports a failure code on a known-good install"
  pass_clean "Owltype --diagnose-tis reports all TIS layers healthy (no summary.code)"
else
  printf '%s' "$diag_json" | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
assert isinstance(d["summary"], dict)
assert "im.owltype.inputmethod.Owltype.Hans" in d["identity"]["expectedSourceIDs"]
' || fail "--diagnose-tis did not return the expected hosted-session diagnostic shape"
  pass_clean "Owltype --diagnose-tis returns structured hosted-session diagnostics"
fi

if [[ -d "$SQUIRREL_APP" ]]; then
  squirrel_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SQUIRREL_APP/Contents/Info.plist")
  [[ "$squirrel_bundle_id" == "$SQUIRREL_DOMAIN" ]] || fail "unexpected Squirrel bundle id: $squirrel_bundle_id"
  pass_clean "system Squirrel app remains separate"
  if [[ "$TIS_MODE" == "interactive" ]]; then
    ! grep -Eq '^im\.rime\.inputmethod\.Squirrel.* selected=true' <<<"$tis_output" ||
      fail "Squirrel is selected while Owltype smoke expects Owltype current"
    pass_clean "TIS reports Squirrel is not selected"
  else
    pass "hosted TIS mode does not require changing the current input source"
  fi
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

check_default_off OwlCloudLaneEnabled
check_default_off OwlLocalModelLaneEnabled
check_default_off OwlSensitiveModeEnabled

if [[ -d "$HOME/Library/Rime" ]] &&
   find "$HOME/Library/Rime" \( -iname '*owltype*' -o -iname '*猫头鹰*' \) -print -quit | grep -q .; then
  fail "found Owltype-specific files under live ~/Library/Rime"
fi
pass_clean "live ~/Library/Rime has no Owltype-specific files"

if (( ${#FAILURES[@]} > 0 )); then
  printf '\n%d check(s) failed:\n' "${#FAILURES[@]}" >&2
  printf '  - %s\n' "${FAILURES[@]}" >&2
  exit 1
fi

pass_clean "installed Owltype smoke gate complete"
