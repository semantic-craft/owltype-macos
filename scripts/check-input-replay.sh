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
# 覆盖：简候选 / 空格上屏 commit / 标点 / 退格 / 翻页 / 多方案 / 简繁。金样本按方案分流：
# 被测 SharedSupport 里没有的方案逐条报 SKIP（出厂清洁室种子只带 rime_ice，五笔等走
# dict-pack），一条都没跑到则判红——「全跳过」不许读成「全过」。
# 跨 App commit 属 IMK/真机层、探针无法自动化 → 见 smoke-live.sh 的人工 checklist。
#
# 用法：  bash scripts/check-input-replay.sh        # 对已装 /Library 或 ~/Library 的 app
#         OWL_APP=/path/to/Owltype.app bash scripts/check-input-replay.sh
#
# 未签名的本地构建也能跑：finalize-release-bundle.py 按设计剥掉全部 linker 签名，
# 出厂签名要等 release 时的 DEV_ID。Apple silicon 上 dyld 拒绝把未签名 dylib 装进
# （linker-signed 的）探针进程，所以此时改在临时目录里对整个 bundle 做一份 ad-hoc
# 签名副本再跑——被测的还是这份构建产物，原产物一个字节不动。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/owl-replay-work.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [[ -n "${OWL_APP:-}" ]]; then
  APP="$OWL_APP"
elif [[ -d "/Library/Input Methods/Owltype.app" ]]; then
  APP="/Library/Input Methods/Owltype.app"
else
  APP="$HOME/Library/Input Methods/Owltype.app"
fi
PROBE="$WORK/owl-rime-probe"
PROBE_SRC="$ROOT/tools/owl-rime-probe.cc"

[[ -d "$APP" ]] || { printf 'FAIL: installed app not found: %s\n' "$APP" >&2; exit 1; }

# 未签名 bundle → 换成临时目录里的 ad-hoc 签名副本（理由见头注释）。
if ! codesign -dv "$APP" >/dev/null 2>&1; then
  printf 'note: %s 未签名（本地构建）；改跑临时目录里的 ad-hoc 签名副本\n' "$APP"
  cp -R "$APP" "$WORK/Owltype.app"
  codesign --force --deep --sign - "$WORK/Owltype.app" >/dev/null 2>&1 \
    || { printf 'FAIL: ad-hoc 签名副本失败\n' >&2; exit 1; }
  APP="$WORK/Owltype.app"
fi
SS="$APP/Contents/SharedSupport"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=1; }

[[ -d "$SS/_user_seed" ]] || { printf 'FAIL: no _user_seed in %s\n' "$SS" >&2; exit 1; }

# 探针每跑一次现编：rpath 把被测 app 的 Frameworks 烧进二进制，缓存下来的那份会指向
# 上一次的 app（ad-hoc 副本更是每次换目录），静默拿到的就是别的构建的候选。
clang++ -std=c++17 \
  -I"$ROOT/librime/src" \
  -Wl,-rpath,"$APP/Contents/Frameworks" \
  "$PROBE_SRC" \
  "$APP/Contents/Frameworks/librime.1.dylib" \
  -o "$PROBE"
[[ -x "$PROBE" ]] || { printf 'FAIL: probe not built: %s\n' "$PROBE" >&2; exit 1; }

# Empty user data root, seeded from the bundled _user_seed (fresh per run).
UD="$WORK/user"
mkdir -p "$UD"
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

# 先空跑一次探针，stderr 不吞。金样本循环里 stderr 是被丢掉的，探针根本没起来时
# 16 条会整齐地报「候选='' 期望'你好'」——读起来像方案全崩，实际是进程没跑起来。
# 这一步把「跑不起来」和「跑起来但候选不对」分开，前者直接把真错误打出来。
preflight="$("$PROBE" "$SS" "$UD" rime_ice nihao 2>&1)" || {
  printf 'FAIL: 探针无法启动（不是候选错误）：\n%s\n' "$preflight" >&2
  exit 1
}
grep -q '^candidates=' <<<"$preflight" || {
  printf 'FAIL: 探针没有输出候选行（不是候选错误）：\n%s\n' "$preflight" >&2
  exit 1
}

failed=0
ran=0
skipped=0
for row in "${GOLDEN[@]}"; do
  IFS='|' read -r dim schema keys matcher expected <<<"$row"
  label="$dim [$schema '$keys']"
  # 出厂种子是清洁室版：只带 rime_ice，五笔 / pinyin_simp / 小鹤要用户知情同意后经
  # dict-pack 下载（OWLTYPE-SEED-MANIFEST.txt 的 "wubi omitted pending provenance
  # review"）。方案不在被测 SharedSupport 里时，探针只会回空串——那跟「候选错了」在
  # 输出上分不开。按方案在场与否分流，跳过的逐条报出来，不做静默截断。
  if [[ ! -f "$SS/$schema.schema.yaml" ]]; then
    printf 'SKIP: %s → 该方案不在被测 SharedSupport 里（出厂种子未含，需 dict-pack）\n' "$label"
    skipped=$((skipped + 1))
    continue
  fi
  ran=$((ran + 1))
  out="$("$PROBE" "$SS" "$UD" "$schema" "$keys" 2>/dev/null || true)"
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
  printf 'FAIL: 输入金样本回放门（%d 条金样本，%d 条跑过，有失败）\n' "${#GOLDEN[@]}" "$ran" >&2
  exit 1
fi
# 全部跳过 = 一条都没验，输出上却和「全过」长得一样。这正是本门要挡的形态。
if (( ran == 0 )); then
  printf 'FAIL: %d 条金样本一条都没跑（%s 里没有任何金样本方案）\n' "${#GOLDEN[@]}" "$SS" >&2
  exit 1
fi
printf 'PASS: 输入金样本回放门（%d 条金样本：%d 过，%d 跳过——方案不在被测种子里）\n' \
  "${#GOLDEN[@]}" "$ran" "$skipped"
