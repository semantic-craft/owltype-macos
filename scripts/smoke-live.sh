#!/usr/bin/env bash
# Live-machine install/update smoke gate for Famo (W1.5). Proves the INSTALLED input method is
# visible, selectable, isolated from the shared ~/Library/Rime, and coexists read-only with Squirrel
# — with a real keystroke probe through the live IMKServer. It wraps the LIVE flow (snapshot → act →
# verify), complementing the point-in-time scripts/check-installed.sh and the artifact-level
# scripts/check-release.sh.
#
# Automation is a hard gate only where reliable: the data sentinel, Squirrel coexistence, the W1.4
# --diagnose-tis diagnosis, and TextEdit real input. The rest — WeChat, menu-bar visual, notarized
# DMG install, and already-open-app update behavior — are real-machine human items (see `checklist`).
# This cannot run on a CI runner alone (osascript needs Accessibility; a live GUI session is required).
#
# Iron laws honored (de-Squirrelization plan §2): read-only only (never writes AppleEnabledInputSources
# / never selects by localized name / Squirrel strictly read-only); the update path must NOT re-enable
# or re-select (that is what `checklist update` asserts). --diagnose-tis reads TIS in a fresh process.
#
# Usage:
#   smoke-live.sh snapshot <dir>            capture read-only sentinel (Rime files+mtimes, Squirrel
#                                           mtimes, data root, --diagnose-tis) into <dir>
#   smoke-live.sh verify <before> <after>   assert data isolation + Squirrel unchanged + data root
#                                           present + post-flow TIS healthy
#   smoke-live.sh input [textedit]          real keystroke probe nihao→你好 through the live IME
#                                           (env FAMO_SMOKE_SEQUENCE / FAMO_SMOKE_EXPECT)
#   smoke-live.sh check                     run the read-only installed-app gate (check-installed.sh)
#   smoke-live.sh checklist [first-install|update]   print the real-machine human sequence
#   smoke-live.sh omnibox [checklist|trace on|off|inject <host>|judge]   #90 omnibox 宿主矩阵回归
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/owl-identity.sh
. "$ROOT/scripts/owl-identity.sh"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
info() { printf '%s\n' "$1"; }

FAMO_SMOKE_SEQUENCE="${FAMO_SMOKE_SEQUENCE:-nihao}"
FAMO_SMOKE_EXPECT="${FAMO_SMOKE_EXPECT:-你好}"

installed_exe() {
  local app="$OWL_INSTALL_PATH"
  [[ -d "$app" ]] || app="$HOME/Library/Input Methods/Famo.app"
  printf '%s/Contents/MacOS/Famo' "$app"
}

cmd_snapshot() {
  local dir="${1:?usage: smoke-live.sh snapshot <dir>}"
  mkdir -p "$dir"
  # Data sentinel (§8.4): the user's live ~/Library/Rime must not gain Famo writes across the flow.
  # Record file list AND (mtime,size,name) so a rewrite of an existing file is caught too.
  if [[ -d "$HOME/Library/Rime" ]]; then
    ( cd "$HOME/Library/Rime" && find . -type f -exec stat -f '%m %z %N' {} + 2>/dev/null | sort ) > "$dir/rime-stat.txt"
  else
    : > "$dir/rime-stat.txt"
  fi
  # Squirrel coexistence (read-only): the app bundle's file mtimes must not change.
  if [[ -d "$SQUIRREL_APP" ]]; then
    ( cd "$SQUIRREL_APP" && find . -type f -exec stat -f '%m %z %N' {} + 2>/dev/null | sort ) > "$dir/squirrel-stat.txt"
  else
    : > "$dir/squirrel-stat.txt"
  fi
  # Famo data root presence (menu selectable but no candidates ⇒ FAMO-DATA-001).
  find "$OWL_DATA_ROOT" -maxdepth 2 -type f 2>/dev/null | sort > "$dir/famo-data-root.txt" || true
  # Fresh-process TIS diagnosis via the installed binary (W1.4).
  local exe; exe="$(installed_exe)"
  if [[ -x "$exe" ]]; then
    perl -e 'alarm 20; exec @ARGV' "$exe" --diagnose-tis > "$dir/diagnose-tis.json" 2>/dev/null \
      || info "note: --diagnose-tis unavailable (stale pre-W1.4 install?) — reinstall the build under test"
  fi
  pass "snapshot written to $dir"
}

# summary.code is null on a healthy install (JSONEncoder omits nil ⇒ key absent).
diag_ok() {
  /usr/bin/python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))["summary"]
code = s.get("code")
if code is not None:
    sys.stderr.write("summary.code=%s: %s\n" % (code, s.get("actionable", "")))
    sys.exit(1)
' "$1"
}

cmd_verify() {
  local before="${1:?usage: smoke-live.sh verify <before> <after>}"
  local after="${2:?usage: smoke-live.sh verify <before> <after>}"
  # 1) Data isolation: ~/Library/Rime unchanged (no Famo write leaked into the shared Rime dir).
  if ! diff -u "$before/rime-stat.txt" "$after/rime-stat.txt"; then
    fail "FAMO-DATA-002: ~/Library/Rime changed across the flow — Famo must never write there"
  fi
  pass "~/Library/Rime unchanged across the flow (data sentinel clean)"
  # 2) Squirrel coexistence: bundle unchanged (read-only).
  if ! diff -u "$before/squirrel-stat.txt" "$after/squirrel-stat.txt"; then
    fail "Squirrel.app changed across the flow — it must stay untouched/read-only"
  fi
  pass "Squirrel.app unchanged across the flow (coexistence read-only)"
  # 3) Famo data root deployed.
  [[ -s "$after/famo-data-root.txt" ]] || fail "FAMO-DATA-001: no files under $OWL_DATA_ROOT after the flow"
  pass "Famo data root populated under Application Support/Famo"
  # 4) Post-flow TIS healthy (reuse the W1.4 diagnostic summary).
  if [[ -s "$after/diagnose-tis.json" ]]; then
    diag_ok "$after/diagnose-tis.json" || fail "post-flow --diagnose-tis reports a failure code"
    pass "post-flow TIS diagnosis healthy (no summary.code)"
  else
    info "note: no diagnose-tis.json in $after — install the W1.4 build to gate TIS state here"
  fi
  pass "live smoke verify complete"
}

cmd_input() {
  local app="${1:-textedit}"
  case "$app" in
    textedit | TextEdit) input_textedit ;;
    *) fail "the input probe only automates TextEdit reliably; run '$app' from \`checklist\` (osascript readback is app-specific and fragile — PRD ceiling)" ;;
  esac
}

input_textedit() {
  # Real keystroke probe through the LIVE IMKServer: Famo must be the current source. Types the
  # sequence into a fresh TextEdit doc, commits the first candidate (space), reads it back via the
  # clipboard, compares to the expected commit. Needs Accessibility permission for System Events.
  # Tolerant: retries (clipboard capture is known-fragile per PRD). Real-machine only.
  local seq="$FAMO_SMOKE_SEQUENCE" expect="$FAMO_SMOKE_EXPECT" got="" attempt
  for attempt in 1 2 3; do
    got="$(osascript - "$seq" <<'APPLESCRIPT' 2>/dev/null || true
on run argv
  set seq to item 1 of argv
  tell application "TextEdit"
    activate
    make new document
  end tell
  delay 0.6
  tell application "System Events"
    set the clipboard to ""
    keystroke seq
    delay 0.4
    key code 49
    delay 0.3
    keystroke "a" using command down
    keystroke "c" using command down
    delay 0.2
  end tell
  delay 0.2
  return (the clipboard as text)
end run
APPLESCRIPT
)"
    got="${got//$'\n'/}"
    if [[ "$got" == *"$expect"* ]]; then
      pass "TextEdit real input: '$seq' → '$got' contains '$expect'"
      return 0
    fi
    info "attempt $attempt: got '$got' (want it to contain '$expect'); retrying"
  done
  fail "TextEdit real input did not produce '$expect' (got '$got'). Check: Famo is the current source; Accessibility is granted to the terminal/osascript; the app was reopened after install."
}

cmd_check() { bash "$ROOT/scripts/check-installed.sh"; }

cmd_checklist() {
  local scenario="${1:-first-install}"
  cat <<HEADER
=== Famo live install smoke — real-machine sequence (${scenario}) ===
Precondition: install the NOTARIZED build (DMG/pkg from scripts/release.sh). An ad-hoc/unsigned local
copy is bounced back to the previous input method by Tahoe (pit 10) and is not a valid smoke target.
Evidence dir suggestion: EV=/tmp/famo-smoke && mkdir -p "\$EV"
HEADER
  if [[ "$scenario" == update ]]; then
    cat <<'UPDATE'

UPDATE scenario (asserts the shipped 1.3.32 no-logout update; closes that open loop):
  0. Old Famo already installed and SELECTED; pre-open TextEdit, Chrome, WeChat.
  1. smoke-live.sh snapshot "$EV/before"
  2. Trigger the Sparkle update (Famo-update.pkg). Update path = park on ABC → replace in place →
     switch back (immediate select + a deferred job that re-selects across PackageKit's final
     registration window; watch: tail -f
     /private/tmp/im.famo.inputmethod.Famo.deferred-update-select.log). It MUST NOT re-enable
     — a second enable manufactures a ghost TIS
     record. (Packaging is gated by check-release.sh: Famo-update.pkg has NO RequireLogout. Live:
     step 4's --diagnose-tis must still show a single clean Hans source, no duplicate/ghost row.)
  3. For each pre-opened app, record honestly: can type now, OR needs app reopen. An already-open app
     not attaching to the new IMKServer is a SYSTEM ceiling (WeChat included) — "needs reopen" is NOT
     a failure; note it.
  4. smoke-live.sh snapshot "$EV/after"  &&  smoke-live.sh verify "$EV/before" "$EV/after"
  5. smoke-live.sh check    — asserts a SINGLE Hans source; an illegal re-enable shows as a duplicate.
  6. Reopen TextEdit → smoke-live.sh input textedit   (real keystroke nihao→你好)
  7. Menu-bar icon visible = 法墨; input menu lists 法墨 exactly once (no duplicate/ghost).
  8. NO-STEAL variant (second pass): switch to ABC yourself BEFORE triggering the update. After
     install, Famo must NOT be selected (no source-stealing), but the input menu MUST still list
     法墨 — the deferred job runs unconditionally and refreshes the menu agents after the receipt
     boundary (same log file; expect "menu-refreshed"). 1.6.0 red light: menu missing 法墨 while
     the TIS probe showed enabled=true/selectable=true (FAMO-TIS-006).
UPDATE
  else
    cat <<'FIRST'

FIRST-INSTALL scenario (clean account):
  1. smoke-live.sh snapshot "$EV/before"
  2. Install the notarized DMG → run the GUI installer → grant "允许启用输入法" → menu shows 法墨.
     First install activates without logout (1.3.32). If it half-activates, --diagnose-tis names the
     failing layer + FAMO-* code instead of "reboot/logout".
  3. Select 法墨 from the input menu.
  4. smoke-live.sh snapshot "$EV/after"  &&  smoke-live.sh verify "$EV/before" "$EV/after"
  5. smoke-live.sh check                 (installed-app read-only gate)
  6. smoke-live.sh input textedit        (real keystroke nihao→你好; override via
                                          FAMO_SMOKE_SEQUENCE / FAMO_SMOKE_EXPECT)
FIRST
  fi
  cat <<'MANUAL'

MANUAL witness items (attach to the release decision alongside "$EV" evidence):
  - Terminal + Chrome real input: type nihao → 你好 (automation is TextEdit-only here; these are
    best-effort by hand).
  - WeChat: manual witness only (osascript readback unreliable) — type nihao → 你好, screenshot.
  - Menu-bar icon renders as the Famo icon (visual).
Result marker (check-release.sh gates on this line in its manual smoke doc): Status: PASS
MANUAL
}

# ── #90 omnibox 宿主矩阵回归 (task 07-12-omnibox-host-matrix-regression, spec #88 §2.3/§5) ──
# 固化「5 宿主 × 4 操作类」为可重复清单：注入靠 osascript，判读靠 FamoDebugLiveInputTrace 日志
# ——omnibox/终端/微信 的 readback 不可靠（PRD 天花板），trace 是可判据的替代。#89 每键重发的证据
# 面：合成期退格全 handled=true / 零 commitComposition finalize / ESC 后 marked text 清空（无 zws
# 残留）。真机注入需 Accessibility（用户在场）；本脚手架可离线 dry-print 清单。

omnibox_log() { printf '%s' "$(getconf DARWIN_USER_TEMP_DIR)famo-live-input-trace.log"; }

cmd_omnibox() {
  local action="${1:-checklist}"
  case "$action" in
    trace)        shift; omnibox_trace "$@" ;;
    inject)       shift; omnibox_inject "$@" ;;
    judge)        shift; omnibox_judge "$@" ;;
    checklist | "") omnibox_checklist ;;
    *) fail "unknown omnibox action '$action' — one of: checklist | trace <on|off> | inject <host> | judge [log]" ;;
  esac
}

# Toggle the dev trace default + start a clean judging window. Note: the running IME process reads
# this at keyDown time; changing the default needs the IME re-attached (switch away/back to Famo, or
# reopen the target app) to take effect. Only ever writes FamoDebugLiveInputTrace — never a schema.
omnibox_trace() {
  local mode="${1:?usage: smoke-live.sh omnibox trace <on|off>}"
  local log; log="$(omnibox_log)"
  case "$mode" in
    on)
      defaults write "$OWL_BUNDLE_ID" FamoDebugLiveInputTrace -bool true
      : > "$log" 2>/dev/null || true   # fresh judging window
      pass "trace ON — log: $log (cleared for a fresh window)"
      info "生效需重挂法墨进程：切走再切回法墨输入源，或重开目标 App。"
      ;;
    off)
      defaults delete "$OWL_BUNDLE_ID" FamoDebugLiveInputTrace 2>/dev/null || true
      pass "trace OFF (FamoDebugLiveInputTrace removed)"
      ;;
    *) fail "omnibox trace: use on|off" ;;
  esac
}

# Inject the omnibox regression sequence (compose whole → backspace ladder → ESC). Judge via trace,
# NOT readback (osascript readback for omnibox/terminal/WeChat is unreliable — the PRD ceiling).
# Only TextEdit/Safari are reliably scriptable; others are manual (see `omnibox checklist`).
omnibox_inject() {
  local host="${1:?usage: smoke-live.sh omnibox inject <textedit|safari>}"
  local seq="${FAMO_SMOKE_SEQUENCE:-nihao}"
  case "$host" in
    textedit | TextEdit) omnibox_inject_osascript "TextEdit" "$seq" "textedit" ;;
    safari | Safari)     omnibox_inject_osascript "Safari"   "$seq" "safari" ;;
    *) fail "omnibox inject scripts textedit|safari only (osascript-reliable); VS Code/iTerm2/微信 → manual items in \`omnibox checklist\`" ;;
  esac
}

omnibox_inject_osascript() {
  local app="$1" seq="$2" kind="$3" n=${#2}
  info "inject '$seq' into $app: compose → backspace ×$n → ESC (judge via trace, not readback)"
  # NB: `hostKind`, not `kind` — `kind` is a reserved AppleScript property (`set kind to …` errors
  # -10006). System Events keystrokes need Accessibility granted to the running terminal/osascript.
  osascript - "$app" "$seq" "$n" "$kind" <<'APPLESCRIPT' || fail "osascript injection failed (see the error above) — if it's 'not allowed assistive access', grant Accessibility to your terminal; also ensure Famo is the current input source"
on run argv
  set appName to item 1 of argv
  set seq to item 2 of argv
  set n to (item 3 of argv) as integer
  set hostKind to item 4 of argv
  tell application (appName) to activate
  delay 0.6
  if hostKind is "textedit" then
    tell application "TextEdit" to make new document
    delay 0.4
  end if
  tell application "System Events"
    if hostKind is "safari" then
      keystroke "l" using command down -- focus the address bar
      delay 0.3
    end if
    keystroke seq
    delay 0.4
    repeat n times
      key code 51 -- Delete/Backspace: retreat one code unit
      delay 0.15
    end repeat
    delay 0.2
    key code 53 -- ESC: cancel composition
    delay 0.2
    if hostKind is "safari" then key code 53 -- second ESC dismisses the omnibox
  end tell
  return "injected"
end run
APPLESCRIPT
  pass "$app injected — run \`smoke-live.sh omnibox judge\` to read the trace"
}

# Parse the trace log into the #89/#90 verdicts. All fields are length/bool/enum (privacy §4).
omnibox_judge() {
  local log; log="${1:-$(omnibox_log)}"
  [[ -f "$log" ]] || fail "trace log not found: $log (run \`omnibox trace on\` then inject first)"
  info "=== omnibox trace judge: $log ==="
  local finalize sends handledFalse lastSend
  finalize="$(grep -c 'commitComposition finalize' "$log" || true)"
  sends="$(grep -c 'markedText send' "$log" || true)"
  handledFalse="$(grep -c 'process after handled=false' "$log" || true)"
  info "markedText send (resend count)                              : $sends"
  info "commitComposition finalize (forced; should be 0 on backspace): $finalize"
  info "process after handled=false (pass-through rounds)           : $handledFalse"
  lastSend="$(grep 'markedText send' "$log" | tail -1 || true)"
  info "last markedText send (after ESC/clear should be len=0)      : ${lastSend:-<none>}"
  echo
  if [[ "$finalize" == "0" ]]; then
    pass "zero commitComposition finalize (no forced-kill recurrence)"
  else
    fail "commitComposition finalize=$finalize — non-zero during omnibox backspace = kill suspicion, review by hand"
  fi
  case "$lastSend" in
    *"len=0"*)          pass "last marked text len=0 (client cleared, no zws residue)" ;;
    "")                 info "note: no markedText send lines (trace not active, or nothing injected)" ;;
    *"keepAlive=true"*) fail "last marked text keepAlive=true not cleared — zws residue suspicion, review by hand" ;;
    *)                  info "note: last send not len=0 (fine if mid-composition; after ESC expect a len=0 closer)" ;;
  esac
}

omnibox_checklist() {
  local log; log="$(omnibox_log)"
  cat <<OMNIBOX
=== Famo omnibox 宿主矩阵回归 — 可重复清单 (#90 / spec #88 §2.3/§5) ===
前置：
  1. 装公证包（DMG/pkg），法墨为当前输入源（ad-hoc/未签名会被 Tahoe 弹回，非有效目标）。
  2. 开 trace：  smoke-live.sh omnibox trace on   （写 FamoDebugLiveInputTrace + 清空日志窗口）
     然后切走再切回法墨（或重开目标 App）让 defaults 生效。
  3. 日志路径：  $log

宿主 × 操作矩阵（每格四操作：①整句拼音 ②退格逐码 ③上屏 ④连续输入 ≥20 轮采样）：
  - TextEdit（对照基线）  注入: smoke-live.sh omnibox inject textedit   判读: 眼见 + omnibox judge
  - Safari 地址栏         注入: smoke-live.sh omnibox inject safari     判读: trace judge（readback 不可靠）
  - VS Code               注入: 人工敲                                  判读: 眼见 + omnibox judge
  - iTerm2（原始动机+echo）注入: 人工敲                                  判读: 眼见 + judge（见 §R3）
  - 微信                  注入: 人工敲                                  判读: 眼见（readback 不可靠）
  Chrome omnibox 已在 #89 真机全绿（五笔混输 + 纯拼音双方案）——回归时补测即可。

判据（每宿主，跑 smoke-live.sh omnibox judge 或眼见）：
  - 整句拼音：逐键都在组码、无吞字；omnibox 里 preedit 逐字增长。
  - 退格逐码：每次退一个码位（对齐 TextEdit），**不整段清光**（「退格全退」根症）；trace 中
    合成期退格全 handled=true，零 commitComposition finalize。
  - 上屏：空格/回车落已转换中文；强制切走窗口时落**已转换中文**（FamoForcedFinalize，#79/§2.4）。
  - 连续输入 ≥20 轮：squirrel#906「时常出现但非每次」——多轮采样才算稳定（§2.1）。
  - ESC/删空：marked text 收尾 len=0，无零宽字符（U+200B）残留（#89 面①③）。
  - 空码专项（五笔混输，主线仓#91）：nihao 退一格成 niha（极点词典零候选）→
    候选面板整个隐藏 = 零候选死锁守卫行为，**不是合成死亡**（继续退格到 nih 面板应回来；
    此时空格/回车会把原始码上屏）。判读：内嵌组码 niha 应仍在文档（G2 build 上
    markedText send len=4，非 len=0）；面板在空码轮保留显示 preedit = #91 修复后的期望。

§R3 zws / 每键重发副作用专项（§5 风险）：
  - iTerm2：合成期终端 echo 是否混入 zws？commit 后行内是否有不可见字符（\`cat -v\` 验）？
  - 微信：合成浮层/输入框是否显示零宽方块或异常光标？
  - 不变量（renderer 单测已锁，此处只眼见复核）：zws 只在 marked text；commit 永远走 insertText
    不含 zws；raw preedit 空的回合渲染必为空串 = setMarkedText("") 清理，绝不注入 zws。

收尾：
  - 关 trace：  smoke-live.sh omnibox trace off
  - 核对用户默认未被动（本脚本从不写这两项，仅提示核对）：
      defaults read $OWL_BUNDLE_ID FamoKeyboardInputMethod   # 期望 wubi
      defaults read $OWL_BUNDLE_ID WubiScheme                # 期望 pinyinMix
Result marker: Status: PASS
OMNIBOX
}

case "${1:-help}" in
  snapshot)  shift; cmd_snapshot "$@" ;;
  verify)    shift; cmd_verify "$@" ;;
  input)     shift; cmd_input "$@" ;;
  check)     shift; cmd_check "$@" ;;
  checklist) shift; cmd_checklist "$@" ;;
  omnibox)   shift; cmd_omnibox "$@" ;;
  help | -h | --help) sed -n '2,34p' "$0" ;;
  *) fail "unknown subcommand '${1}' — run: smoke-live.sh help" ;;
esac
