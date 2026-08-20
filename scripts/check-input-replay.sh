#!/usr/bin/env bash
# 输入金样本回放回归门（引擎级）—— Plan_v2 §4 第二波 M4.2。
#
# 金样本回放保护热路径：动 composition/candidate 相关代码之前跑一遍，防方案/配置回归。
# 固定测试词库 = 已装 app 的 SharedSupport 方案；空用户数据根 = 每跑一次全新 mktemp 目录
# 从 _user_seed 播种（与 check-installed.sh 同法，零污染真机 ~/Library/Rime）。
#
# 复用现有 tools/owl-rime-probe.cc（rime->simulate_key_sequence 已支持 {BackSpace}/
# {Page_Down}/标点/commit），无需改探针。金值均实测 pin。
#
# 覆盖：简候选 / 空格上屏 commit / 标点 / 退格 / 翻页 / 多方案 / 简繁。
# 跨 App commit 属 IMK/真机层、探针无法自动化 → 见 smoke-live.sh 的人工 checklist。
#
# 用法：  bash scripts/check-input-replay.sh        # 对已装 /Library 或 ~/Library 的 app
#         OWL_APP=/path/to/Owltype.app bash scripts/check-input-replay.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -n "${OWL_APP:-}" ]]; then
  APP="$OWL_APP"
elif [[ -d "/Library/Input Methods/Owltype.app" ]]; then
  APP="/Library/Input Methods/Owltype.app"
else
  APP="$HOME/Library/Input Methods/Owltype.app"
fi
SS="$APP/Contents/SharedSupport"
PROBE="$ROOT/build/owl-rime-probe"
PROBE_SRC="$ROOT/tools/owl-rime-probe.cc"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=1; }

[[ -d "$APP" ]] || { printf 'FAIL: installed app not found: %s\n' "$APP" >&2; exit 1; }
[[ -d "$SS/_user_seed" ]] || { printf 'FAIL: no _user_seed in %s\n' "$SS" >&2; exit 1; }

# Build the probe from source if missing/stale (same invocation as check-installed.sh).
if [[ ! -x "$PROBE" || "$PROBE_SRC" -nt "$PROBE" ]]; then
  mkdir -p "$ROOT/build"
  clang++ -std=c++17 \
    -I"$ROOT/librime/src" \
    -Wl,-rpath,"$APP/Contents/Frameworks" \
    "$PROBE_SRC" \
    "$APP/Contents/Frameworks/librime.1.dylib" \
    -o "$PROBE"
fi
[[ -x "$PROBE" ]] || { printf 'FAIL: probe not built: %s\n' "$PROBE" >&2; exit 1; }

# Empty user data root, seeded from the bundled _user_seed (fresh per run).
UD="$(mktemp -d "${TMPDIR:-/tmp}/owl-replay.XXXXXX")"
trap 'rm -rf "$UD"' EXIT
cp -R "$SS/_user_seed/." "$UD/"
mkdir -p "$UD/build"
export DYLD_LIBRARY_PATH="$APP/Contents/Frameworks:$APP/Contents/Frameworks/rime-plugins:${DYLD_LIBRARY_PATH:-}"

# Golden table: 维度|方案|按键序列|匹配器|期望
#   cand1     candidate[1] 文本（去掉 tab 注释）== 期望
#   commit    commit 文本 == 期望（含标点映射、空格上屏）
#   preedit   preedit 文本 == 期望（退格改组码）
#   cand1-not candidate[1] 非空且 != 期望（翻页移出首页首选）
# 金值均由探针实测 pin（2026-07-05，已装 1.3.34 SharedSupport）。
GOLDEN=(
  "简·候选|rime_ice|nihao|cand1|你好"
  "commit·空格上屏|rime_ice|nihao{space}|commit|你好"
  "标点·逗号|rime_ice|,|commit|，"
  "标点·句号|rime_ice|.|commit|。"
  "退格·改组码|rime_ice|nihao{BackSpace}|preedit|ni ha"
  # #90（G3，吸收 #84）omnibox 退格序列金样本：逐码退，引擎 preedit 逐步缩短（不整段清）——
  # 锁死引擎侧「退格全退 vs 逐码退」的正确行为，与 IMK 每键重发（#89）形成双层网。金值 2026-07-12
  # 探针实测 pin（已装 1.4.5 SharedSupport）。
  "退格·逐码2|rime_ice|nihao{BackSpace}{BackSpace}|preedit|ni h"
  "退格·逐码3|rime_ice|nihao{BackSpace}{BackSpace}{BackSpace}|preedit|ni"
  "退格·退到单码|rime_ice|nihao{BackSpace}{BackSpace}{BackSpace}{BackSpace}|preedit|n"
  "退格·五笔混输|wubi86_jidian_pinyin|nihao{BackSpace}|preedit|niha"
  "翻页·移出首页|rime_ice|nihao{Page_Down}|cand1-not|你好"
  "简·pinyin_simp|pinyin_simp|nihao|cand1|你好"
  "双拼·小鹤|double_pinyin_flypy|nihc|cand1|你好"
  "五笔·极点|wubi86_jidian|wqvb|cand1|你好"
  "五笔·拼音反查|wubi86_jidian_pinyin|nihao|cand1|你好"
  "简繁·简(国)|wubi86_jidian|lgyi|commit|国"
  "简繁·繁(國)|wubi86_jidian_trad|lgyi|commit|國"
)

# Extract a single output field from probe stdout. For candidate[1], strip the tab-comment.
field() { # <output> <prefix>
  local out="$1" prefix="$2" line
  line="$(grep -m1 -F "$prefix" <<<"$out" || true)"
  line="${line#"$prefix"}"
  printf '%s' "${line%%$'\t'*}"
}

failed=0
for row in "${GOLDEN[@]}"; do
  IFS='|' read -r dim schema keys matcher expected <<<"$row"
  out="$("$PROBE" "$SS" "$UD" "$schema" "$keys" 2>/dev/null || true)"
  label="$dim [$schema '$keys']"
  case "$matcher" in
    cand1)
      got="$(field "$out" 'candidate[1]=')"
      [[ "$got" == "$expected" ]] && pass "$label → 候选1=$got" || fail "$label → 候选1='$got' 期望'$expected'" ;;
    commit)
      got="$(field "$out" 'commit=')"
      [[ "$got" == "$expected" ]] && pass "$label → 上屏=$got" || fail "$label → 上屏='$got' 期望'$expected'" ;;
    preedit)
      got="$(field "$out" 'preedit=')"
      [[ "$got" == "$expected" ]] && pass "$label → preedit=$got" || fail "$label → preedit='$got' 期望'$expected'" ;;
    cand1-not)
      got="$(field "$out" 'candidate[1]=')"
      if [[ -n "$got" && "$got" != "$expected" ]]; then
        pass "$label → 翻页后候选1=${got}（已移出首页首选）"
      else
        fail "$label → 翻页后候选1='$got' 不应为空且应 != '$expected'"
      fi ;;
    *)
      fail "$label → 未知匹配器 $matcher" ;;
  esac
done

if (( failed )); then
  printf 'FAIL: 输入金样本回放门（%d 条金样本，有失败）\n' "${#GOLDEN[@]}" >&2
  exit 1
fi
printf 'PASS: 输入金样本回放门（%d 条金样本全过）\n' "${#GOLDEN[@]}"
