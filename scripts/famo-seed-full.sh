#!/usr/bin/env bash
#
# ⚠ FULL seed profile — personal/local builds only. It assembles the complete
# rime-ice dictionaries (mixed/unverified upstream license chain) and expects
# the lotem grammar data. Do NOT redistribute apps built from this seed; public
# releases must use scripts/famo-seed.sh (the audited clean-room seed).

#
# famo-seed.sh — assemble Famo's self-contained Rime data (ADR-0004 cycle 2).
#
# Base = rime-ice (iDvel, 雾凇拼音). task 06-27 由 oh-my-rime (薄荷 rime_mint) 换回 rime-ice
# （纯雾凇路线：不带万象、不带声调 preedit、零 dict-swap hack）。Produces:
#   data/famo-rime/            — shared Rime data (→ Famo.app/Contents/SharedSupport at build)
#   data/famo-rime/_user_seed/ — our *.custom.yaml (first-run copies these into user_data_dir)
#
# data/famo-rime/ is gitignored (≈70 MB); regenerate with this script. The upstream LICENSE is
# copied alongside; the manifest records the resolved upstream commit.
#
# 拼音底座 = rime-ice stock 全拼 (rime_ice)。带声调全拼/万象 NOT bundled — that was the oh-my-rime
#   (rime_mint) era; reverted in task 06-27 per user. No 万象 dict-swap / 去调头 hack anywhere.
#   super_comment / emoji 等仍是 rime-ice 原生；Famo 只翻 emoji 出厂默认值。
# Famo 不携带任何 Rime 法学层（法学能力在后续「技能平台」，不在本配置）。
#
# 五笔 = KyleBing/rime-wubi86-jidian (Apache-2.0) 全套 overlay：
#   • 带入 4 个 wubi 变体 (wubi86_jidian / _pinyin / _trad / _trad_pinyin)、其反查依赖
#     pinyin_simp.schema.yaml + pinyin_simp.dict.yaml、numbers.schema.yaml、各 wubi dict、3 个 KyleBing lua。
#   • overlay 顺序：在 rime-ice base 拷贝之后做（同名文件以 KyleBing 为准）。
#   • 只拷 *.schema.yaml *.dict.yaml lua/*.lua LICENSE；不拷 KyleBing 的 *.custom.yaml（会覆盖 Famo 配置）。
#   • 必修 bug：KyleBing 的 _trad / _trad_pinyin schema 里 active 的 `lua_translator@date_translator`
#     是短名，改成 KyleBing 自带、按 `*` 约定自动加载的 `*wubi86_jidian_date_translator`（与底座无关，稳）。
#
# Famo deltas over stock rime-ice (全部经 _user_seed/*.custom.yaml + 下方 reset patch)：
#   • emoji reset 1 -> 0  (出厂关候选 emoji，保留开关，菜单/Ctrl+Shift+E 可开回)
#   • grammar = lotem zh-hans-t-essay-bgw (rime_ice.custom.yaml)；gram 由 data/plum/ hop 进来
#   • menu/page_size 8 (default.custom.yaml)
#   • macOS 皮肤 (famo.custom.yaml)
#
# NOTE (lotem 八股文 grammar)：LOTEM essay-bgw grams (zh-hans/hant, ~9–11MB) 是 ACTIVE 语法模型，
#   必须打包——Famo 的 rime_ice.custom.yaml 把 grammar/language 指向它。action-build 经 plum
#   (SQUIRREL_BUNDLED_RECIPES) 取到 data/plum/，这里 hop 进 seed。缺失=warn 不 fail（config-only seed）。
#
# Usage:  bash scripts/famo-seed.sh            # uses /tmp clone cache, clones if missing
#         FAMO_SEED_REFRESH=1 bash scripts/...  # force re-clone
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"        # repo root
DEFAULT_CONFIG_SOURCE="$HERE/rime"   # in-repo audited Rime config (single-repo era)
CONFIG_SOURCE="${FAMO_CONFIG_SOURCE_DIR:-$DEFAULT_CONFIG_SOURCE}"
[[ -d "$CONFIG_SOURCE" ]] || {
  echo >&2 "[famo-seed] ERROR: config source directory not found (set FAMO_CONFIG_SOURCE_DIR)"
  exit 1
}
ROOT_CONFIG_DIR="$(cd "$CONFIG_SOURCE" && pwd)"                  # root-owned config package
for required_config in default.custom.yaml rime_ice.custom.yaml famo.custom.yaml; do
  [[ -f "$ROOT_CONFIG_DIR/$required_config" ]] || {
    echo >&2 "[famo-seed] ERROR: FAMO_CONFIG_SOURCE_DIR missing $required_config"
    exit 1
  }
done
CACHE="${FAMO_SEED_CACHE:-/tmp/famo-fetch}"
OUT="$HERE/data/famo-rime"

RIME_ICE_URL="https://github.com/iDvel/rime-ice.git"
WUBI_URL="https://github.com/KyleBing/rime-wubi86-jidian.git"

clone() {  # url dir
  local url="$1" dir="$2"
  if [ -n "${FAMO_SEED_REFRESH:-}" ]; then rm -rf "$CACHE/$dir"; fi
  if [ ! -d "$CACHE/$dir/.git" ]; then
    mkdir -p "$CACHE"
    git clone --depth 1 "$url" "$CACHE/$dir"
  fi
}

echo "[famo-seed] fetching sources → $CACHE"
clone "$RIME_ICE_URL" rime-ice
RIME_ICE_DIR="$CACHE/rime-ice"
clone "$WUBI_URL" rime-wubi86-jidian
WUBI_DIR="$CACHE/rime-wubi86-jidian"

echo "[famo-seed] assembling → $OUT"
rm -rf "$OUT"; mkdir -p "$OUT/_user_seed"

# --- rime-ice base (拼音: dicts, lua, opencc, schemas, base default config) ---
cp -R "$RIME_ICE_DIR/cn_dicts" "$RIME_ICE_DIR/en_dicts" "$RIME_ICE_DIR/lua" "$RIME_ICE_DIR/opencc" "$OUT/"
# rime-ice 的 opencc/ 只带自定义配置(emoji/others)，不含标准 OpenCC 转换数据。简繁(simplifier@traditionalize,
# opencc_config: s2t.json) 依赖标准数据(s2t.json + STCharacters/STPhrases.ocd2 等) → 从 deps 构建出的
# data/opencc/ 补齐(与 rime-ice 自定义文件不重名,合并即可)。缺失=简繁静默失效(task 06-27 修)。
if ls "$HERE"/data/opencc/*.json >/dev/null 2>&1; then
  cp "$HERE"/data/opencc/*.json "$HERE"/data/opencc/*.ocd2 "$OUT/opencc/"
  echo "[famo-seed] bundled standard OpenCC data (s2t/t2s/s2tw/… + .ocd2) from data/opencc/"
else
  echo "[famo-seed] WARNING: data/opencc/*.json 缺失(先 make deps) — 简繁(s2t) 转换数据未打包!"
fi
cp "$RIME_ICE_DIR"/*.schema.yaml "$RIME_ICE_DIR"/*.dict.yaml "$OUT/"
cp "$RIME_ICE_DIR/default.yaml" "$OUT/"
# 现代 rime-ice 无根 rime.lua —— lua 全用 `*` 前缀自动加载（lua_translator@*date_translator 等，从 lua/ 取），无需根脚本。
cp "$RIME_ICE_DIR"/symbols_v.yaml "$RIME_ICE_DIR"/symbols_caps_v.yaml "$RIME_ICE_DIR"/custom_phrase.txt "$OUT/" 2>/dev/null || true
cp "$RIME_ICE_DIR/LICENSE" "$OUT/rime-ice.LICENSE"
cp "$HERE/data/famo.yaml" "$OUT/famo.yaml"

# --- KyleBing 五笔 overlay (Apache-2.0) — 必须在 rime-ice base 拷贝之后 ---------------------
# KyleBing 的 wubi86_jidian.* 覆盖任何同名文件（顺序很重要）；并带入 pinyin_simp（变体反查依赖）、
# numbers、3 个变体 schema、各 wubi dict、3 个 KyleBing lua。
# 只拷 *.schema.yaml *.dict.yaml lua/*.lua LICENSE —— 不拷 KyleBing 的 *.custom.yaml（会覆盖 Famo 配置）。
cp "$WUBI_DIR"/*.schema.yaml "$WUBI_DIR"/*.dict.yaml "$OUT/"
cp "$WUBI_DIR"/lua/*.lua "$OUT/lua/"
cp "$WUBI_DIR/LICENSE" "$OUT/wubi86-jidian.LICENSE"

# 必修 bug：KyleBing 的 _trad / _trad_pinyin schema 里 active 的 `lua_translator@date_translator`
# 是短名 → 改成 KyleBing 自带、按 `*` 约定自动加载的 `*wubi86_jidian_date_translator`（其 lua 已随上面拷入）。
# 只动这两个文件、只改该 active 行（不碰注释里的 `*` 前缀行）。
for trad in wubi86_jidian_trad.schema.yaml wubi86_jidian_trad_pinyin.schema.yaml; do
  /usr/bin/sed -i '' \
    's/^\(  *\)- lua_translator@date_translator/\1- lua_translator@*wubi86_jidian_date_translator/' \
    "$OUT/$trad"
done

# --- Famo prefs/skin layer (仅 user-dir seed；无法学层) ---
cp "$ROOT_CONFIG_DIR/default.custom.yaml" "$ROOT_CONFIG_DIR/rime_ice.custom.yaml" \
  "$ROOT_CONFIG_DIR/famo.custom.yaml" "$OUT/_user_seed/"

# --- Famo reset 默认 = SHARED schema base change（覆盖升级用户）-------------------------------
# emoji reset 1->0（出厂关候选 emoji）。必须落共享 rime_ice.schema.yaml（Rime 永远把它作 base 加载）；
# 用户目录 custom.yaml 覆盖不到升级用户（seedUserDirIfNeeded 从不覆盖用户已有文件）。锚定 python 编辑，
# 保留上游其余 verbatim。纯雾凇无带声调 preedit，故不设 tone_display（rime-ice 也无此 switch）。
SCHEMA="$OUT/rime_ice.schema.yaml"
python3 - "$SCHEMA" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    lines = f.readlines()

def set_reset_after(name, value):
    """在 switches 块里找 `- name: <name>`（容忍行尾注释），把其后（同一 switch 块内）的 `reset:` 行设为 value。
    找不到该 switch 或其 reset 行则返回 False（由调用方报错）—— rime-ice 的 emoji switch 一贯自带 reset:1。"""
    for i, ln in enumerate(lines):
        s = ln.strip()
        if not s.startswith("- name:"):
            continue
        tok = s[len("- name:"):].strip().split("#")[0].split()
        if not tok or tok[0] != name:
            continue
        base_indent = len(ln) - len(ln.lstrip())
        for j in range(i + 1, len(lines)):
            t = lines[j].lstrip()
            cur_indent = len(lines[j]) - len(t)
            if t.startswith("- ") or (t and cur_indent <= base_indent):
                break  # 离开本 switch 块
            if t.startswith("reset:"):
                lines[j] = f"{lines[j][:cur_indent]}reset: {value}\n"
                return True
    return False

def set_states_after(name, states_literal):
    """在 switches 块里找 `- name: <name>`，把其后（同一 switch 块内）的 `states:` 行替换为 states_literal。"""
    for i, ln in enumerate(lines):
        s = ln.strip()
        if not s.startswith("- name:"):
            continue
        tok = s[len("- name:"):].strip().split("#")[0].split()
        if not tok or tok[0] != name:
            continue
        base_indent = len(ln) - len(ln.lstrip())
        for j in range(i + 1, len(lines)):
            t = lines[j].lstrip()
            cur_indent = len(lines[j]) - len(t)
            if t.startswith("- ") or (t and cur_indent <= base_indent):
                break
            if t.startswith("states:"):
                lines[j] = f"{lines[j][:cur_indent]}states: {states_literal}\n"
                return True
    return False

if not set_reset_after("emoji", 0):
    sys.exit("[famo-seed][schema-patch] ERROR: emoji switch (with reset:) not found in rime_ice.schema.yaml")
# emoji 状态标签：off 态 rime-ice 用 💀 骷髅（不吉利），改 👋（再见）；on 态保留 😄（task 06-27 用户要求）。
if not set_states_after("emoji", "[ 👋, 😄 ]"):
    sys.exit("[famo-seed][schema-patch] ERROR: emoji switch states not found in rime_ice.schema.yaml")
# 中英切换提示：英文态显示「英」而非「Ａ」(task 06-27 用户要求)。
if not set_states_after("ascii_mode", "[ 中, 英 ]"):
    sys.exit("[famo-seed][schema-patch] ERROR: ascii_mode switch states not found in rime_ice.schema.yaml")

with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
print("[famo-seed][schema-patch] rime_ice.schema.yaml: emoji reset->0 states->[👋,😄], ascii_mode states->[中,英]")
PYEOF

# --- lotem 八股文 grammar (.gram) — 存在则打包（Famo grammar pref 需要）---
PLUM_DIR="$HERE/data/plum"
for gram in zh-hans-t-essay-bgw.gram zh-hant-t-essay-bgw.gram; do
  if [ -f "$PLUM_DIR/$gram" ]; then
    cp "$PLUM_DIR/$gram" "$OUT/$gram"
    echo "[famo-seed] bundled lotem grammar: $gram ($(du -h "$OUT/$gram" | cut -f1))"
  else
    echo "[famo-seed] WARNING: lotem grammar $gram NOT in $PLUM_DIR — NOT bundled"
    echo "[famo-seed]          (grammar pref no-ops until 'make plum-data' / action-install fetches it)"
  fi
done

# --- manifest ---
cat > "$OUT/FAMO-SEED-MANIFEST.txt" <<EOF
Famo self-contained Rime seed — assembled by scripts/famo-seed.sh (ADR-0004 cycle 2).

Base = rime-ice (iDvel 雾凇拼音)，task 06-27 由 oh-my-rime (rime_mint) 换回（纯雾凇，无万象/无带调 preedit）。

Source:
  rime-ice  iDvel/rime-ice  @ $(git -C "$RIME_ICE_DIR" rev-parse HEAD)  (see rime-ice.LICENSE)
            拼音底座：rime_ice 全拼方案 / cn_dicts / en_dicts / lua / opencc / default.yaml。
  五笔 overlay KyleBing/rime-wubi86-jidian  @ $(git -C "$WUBI_DIR" rev-parse HEAD)  (Apache-2.0, see wubi86-jidian.LICENSE)
            极点五笔 86 全套（wubi86_jidian / _pinyin / _trad / _trad_pinyin）+ 反查依赖 pinyin_simp
            + numbers + KyleBing lua。无法学五笔。
  Famo prefs  packages/rime-law-config  (本仓：default/rime_ice/famo custom.yaml + 皮肤；无法学层)

拼音底座 = rime_ice（rime-ice stock 全拼）。无万象、无带声调 preedit、无 dict-swap hack。

Famo reset 改动（SHARED schema，覆盖升级用户）：
  rime_ice.schema.yaml: emoji reset 1->0（出厂关候选 emoji）

grammar = lotem zh-hans-t-essay-bgw（~9MB），由 data/plum/ 打包进来。万象 LTS .gram (~420MB) 不打包。

Layout:
  shared (→ SharedSupport, shared_data_dir): *.schema.yaml (rime_ice patched + KyleBing wubi86_jidian* / pinyin_simp / numbers overlay), *.dict.yaml, cn_dicts/, en_dicts/, lua/ (含 KyleBing wubi86_jidian_*.lua), opencc/, symbols_v/symbols_caps_v/custom_phrase, default.yaml, zh-han{s,t}-t-essay-bgw.gram
  _user_seed/ (→ user_data_dir 首次运行): default.custom.yaml, rime_ice.custom.yaml, famo.custom.yaml
EOF

echo "[famo-seed] done. size: $(du -sh "$OUT" | cut -f1)"
