#!/usr/bin/env bash
#
# Build the self-contained Rime data used by the open-source local core.
# Every network input is pinned. The Wubi86 table uses a reviewed Apache-2.0
# source at a fixed commit; octagram data remains absent from the public seed.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${OWLTYPE_SEED_CACHE:-/tmp/owltype-rime-seed}"
source_dir="$cache_root/rime-ice"
output_dir="$repo_root/data/owl-rime"
msime_others_version="dict-v2.0.24"
msime_others_sha="9f3cae5b407038e0e4536c40582a0bc0feb732657f0ae2d38196374cede52f94"
msime_others_size="1314816"
msime_others_builder_sha="128a332cabc5fa42b1cf5f827033ad5697ff528b"
msime_others_data_sha="71dc6f6cc7a451231ee29c0a39b39adbf2e04d32"
msime_others_manifest_sha="5b656a5db35b4dcf804ce4348d8584c899d0012fe62bbbe3689204ddaba8722f"
msime_others_manifest_size="4627"
msime_others_rime_ice_sha="9e66b0729083b37d217312294f6d516c8d7234be"
msime_emoji_rows="1935"
msime_emoji_row_sha="b3939c2005a8d46b18a5421eeee35698ba7b1ae01b3c24e6f470a524710905a7"
msime_emoji_pinyin_rows="21541"
msime_emoji_pinyin_row_sha="e761e06bb14331d27d48786fe6be4e998f289344e139e1252ce53f9090a4c306"
python_pinyin_version="0.55.0"
python_pinyin_sha="df101577145af2eb1abe5656e592e34e3bb56d23"
python_pinyin_license="$repo_root/licenses/python-pinyin.LICENSE"
python_pinyin_license_sha256="1e6c90014b4912815c296ee64bb6f6280af47e6d4c5d80e86232dfc5defe764c"
rime_ice_remote="https://github.com/iDvel/rime-ice.git"
rime_ice_sha="b681a34f788795034b3b288830f4861980bc8b0d"
wubi86_sha="a194fb8b3ec41ef9dcf079d3a67876fa75f79135"
wubi86_sha256="8ccf1358b91028ed234bbe82647a0bcd0f554a8d5994042de28b146e517633e6"
wubi86_license_sha256="43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1"
chinese_ime_lm_sha="15caab4fdeb59c11f452b91884371cf30e2e5608"
chinese_ime_lm_license="$repo_root/rust/crates/chinese-ime-lm/LICENSE"
chinese_ime_lm_license_sha256="cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
unihan_version="16.0.0"
unihan_remote="https://www.unicode.org/Public/$unihan_version/ucd/Unihan.zip"
unihan_sha="b8f000df69de7828d21326a2ffea462b04bc7560022989f7cc704f10521ef3e0"
unihan_archive="$cache_root/Unihan-$unihan_version.zip"
jieba_tag="v0.42.1"
jieba_dict_remote="https://raw.githubusercontent.com/fxsjy/jieba/$jieba_tag/jieba/dict.txt"
jieba_dict_sha="7197c3211ddd98962b036cdf40324d1ea2bfaa12bd028e68faa70111a88e12a8"
jieba_dict_file="$cache_root/jieba-dict-$jieba_tag.txt"
jieba_license_remote="https://raw.githubusercontent.com/fxsjy/jieba/$jieba_tag/LICENSE"
jieba_license_sha="18ba0984839f85853b29fadaf992f7dba8fd0ca0fbeae34de2b8735222dc7a37"
jieba_license_file="$cache_root/jieba-LICENSE-$jieba_tag.txt"
ppd_sha="cee0ed6e6e4898580cafd2bd5e3723e20b214aa0"
ppd_pinyin_remote="https://raw.githubusercontent.com/mozillazg/phrase-pinyin-data/$ppd_sha/pinyin.txt"
ppd_pinyin_sha="dcc769607c220b312fea3e71cb63421298b4b891b1f7356a95ab58f2c96fff81"
ppd_pinyin_file="$cache_root/ppd-pinyin-${ppd_sha:0:12}.txt"
ppd_license_remote="https://raw.githubusercontent.com/mozillazg/phrase-pinyin-data/$ppd_sha/LICENSE"
ppd_license_sha="89ac55df747e4776088c3e77531ef61b973a1a59dd8e6a4548a58996da9a4f70"
ppd_license_file="$cache_root/ppd-LICENSE-${ppd_sha:0:12}.txt"
spdx_license_tag="v3.28.0"
license_cache="$cache_root/spdx-license-list-$spdx_license_tag"
license_specs=(
  "Apache-2.0 074e6e32c86a4c0ef8b3ed25b721ca23aca83df277cd88106ef7177c354615ff"
  "BSD-3-Clause 5a93d5831e1297ab10fe643e1a631e83be392896da14ee2951285a79012df69d"
  "CC-BY-3.0 e6bc9e9c474700b708f568bac9e5a8a9bcb2b1dad53442f5ba449fcb848b8e76"
  "GPL-3.0-only fb981668c18a279e285fc4d83fba1e836cc84dd4daa73c9697d3cfd2d8aca6e0"
  "LGPL-3.0-only 996af0513df21f7496288951c41428a03c174e9e4a9d63665c57d670f845ccb1"
  "MIT b05785f9f18e6716bab63424b11454513b9943a222595b70411009202fc592b5"
  "Unicode-3.0 f7db81051789b729fea528a63ec4c938fdcb93d9d61d97dc8cc2e9df6d47f2a1"
)

fetch_license() {
  local license_id="$1"
  local expected_sha="$2"
  local target="$license_cache/$license_id.txt"
  mkdir -p "$license_cache"
  if [[ ! -f "$target" ]] || ! echo "$expected_sha  $target" | shasum -a 256 --check --status; then
    curl --fail --location \
      "https://raw.githubusercontent.com/spdx/license-list-data/$spdx_license_tag/text/$license_id.txt" \
      --output "$target"
  fi
  echo "$expected_sha  $target" | shasum -a 256 --check
}

fetch_pinned() {
  local url="$1"
  local expected_sha="$2"
  local target="$3"
  if [[ ! -f "$target" ]] || ! echo "$expected_sha  $target" | shasum -a 256 --check --status; then
    curl --fail --location "$url" --output "$target"
  fi
  echo "$expected_sha  $target" | shasum -a 256 --check
}

if [[ ! -d "$source_dir/.git" ]]; then
  mkdir -p "$cache_root"
  git init "$source_dir"
  git -C "$source_dir" remote add origin "$rime_ice_remote"
fi

git -C "$source_dir" fetch --depth 1 origin "$rime_ice_sha"
git -C "$source_dir" checkout --detach "$rime_ice_sha"

if [[ ! -f "$unihan_archive" ]] || ! echo "$unihan_sha  $unihan_archive" | shasum -a 256 --check --status; then
  curl --fail --location "$unihan_remote" --output "$unihan_archive"
fi
echo "$unihan_sha  $unihan_archive" | shasum -a 256 --check

fetch_pinned "$jieba_dict_remote" "$jieba_dict_sha" "$jieba_dict_file"
fetch_pinned "$jieba_license_remote" "$jieba_license_sha" "$jieba_license_file"
fetch_pinned "$ppd_pinyin_remote" "$ppd_pinyin_sha" "$ppd_pinyin_file"
fetch_pinned "$ppd_license_remote" "$ppd_license_sha" "$ppd_license_file"

rm -rf "$output_dir"
mkdir -p "$output_dir/_user_seed" "$output_dir/cn_dicts" "$output_dir/licenses"

for license_spec in "${license_specs[@]}"; do
  read -r license_id license_sha <<<"$license_spec"
  fetch_license "$license_id" "$license_sha"
  cp "$license_cache/$license_id.txt" "$output_dir/licenses/"
done

# The vendored reference crate has its own Apache-2.0 license. Keep its exact
# upstream text separate from both the SPDX template and the model-weight files.
echo "$chinese_ime_lm_license_sha256  $chinese_ime_lm_license" | shasum -a 256 --check
cp "$chinese_ime_lm_license" "$output_dir/licenses/chinese-ime-lm.LICENSE"

cp -R \
  "$source_dir/lua" \
  "$source_dir/opencc" \
  "$output_dir/"
sed \
  -e '/^[[:space:]]*- melt_eng[[:space:]]/d' \
  -e '/^[[:space:]]*- radical_pinyin[[:space:]]/d' \
  -e '/affix_segmentor@radical_lookup/d' \
  -e '/table_translator@melt_eng/d' \
  -e '/table_translator@cn_en/d' \
  -e '/table_translator@radical_lookup/d' \
  -e '/reverse_lookup_filter@radical_reverse_lookup/d' \
  -e '/lua_filter@\*search@radical_pinyin/d' \
  "$source_dir/rime_ice.schema.yaml" > "$output_dir/rime_ice.schema.yaml"
# Owltype 出厂默认：候选 emoji 关（emoji switch reset 1→0）+ off 态标签 💀→👍（rime-ice 的骷髅
# 不吉利，每次重新部署 reset 都会弹一次；2026-07-26 用户要求换大拇指，on 态保留 😄）。
# 必须落共享 schema——用户目录 custom.yaml 覆盖不到升级用户（首次 seed 不覆盖已有文件）。
# 锚定编辑，找不到即硬失败；check-release.sh 有对应断言。清洁室重写时曾把 reset 补丁弄丢
# （1.4.23 带 reset:1 出厂，2026-07-24 复补）。
python3 - "$output_dir/rime_ice.schema.yaml" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    lines = f.readlines()

def set_reset_after(name, value):
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
            if t.startswith("reset:"):
                lines[j] = f"{lines[j][:cur_indent]}reset: {value}\n"
                return True
    return False

def set_states_after(name, states_literal):
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
    sys.exit("[owltype-seed][schema-patch] ERROR: emoji switch (with reset:) not found in rime_ice.schema.yaml")
if not set_states_after("emoji", "[ 👍, 😄 ]"):
    sys.exit("[owltype-seed][schema-patch] ERROR: emoji switch states not found in rime_ice.schema.yaml")
# 中英切换提示：英文态显示「英」而非「Ａ」（task 06-27 用户要求，2026-07-26 从全量种子搬入）。
if not set_states_after("ascii_mode", "[ 中, 英 ]"):
    sys.exit("[owltype-seed][schema-patch] ERROR: ascii_mode switch states not found in rime_ice.schema.yaml")
with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
print("[owltype-seed] patched rime_ice.schema.yaml: emoji reset 1 -> 0 (factory off) states -> [👍, 😄], ascii_mode states -> [中, 英]")
PYEOF
cp "$repo_root/data/rime_ice.public.dict.yaml" "$output_dir/rime_ice.dict.yaml"
python3 "$repo_root/scripts/unihan-to-rime.py" \
  "$unihan_archive" "$output_dir/cn_dicts/owltype_unicode.dict.yaml"
python3 "$repo_root/scripts/build-owltype-base.py" \
  "$unihan_archive" "$jieba_dict_file" "$ppd_pinyin_file" \
  "$output_dir/cn_dicts/owltype_base.dict.yaml" \
  "$unihan_version-jieba${jieba_tag#v}-ppd${ppd_sha:0:7}"
cp "$source_dir/default.yaml" "$output_dir/"
cp \
  "$source_dir"/symbols_v.yaml \
  "$source_dir"/symbols_caps_v.yaml \
  "$source_dir"/custom_phrase.txt \
  "$output_dir/" 2>/dev/null || true

if compgen -G "$repo_root/data/opencc/*" >/dev/null; then
  cp "$repo_root"/data/opencc/* "$output_dir/opencc/"
fi

cp "$source_dir/LICENSE" "$output_dir/rime-ice.LICENSE"
cp "$source_dir/others/docs/Credits.md" "$output_dir/rime-ice-Credits.md"
cp "$jieba_license_file" "$output_dir/jieba.LICENSE"
cp "$ppd_license_file" "$output_dir/phrase-pinyin-data.LICENSE"
echo "$python_pinyin_license_sha256  $python_pinyin_license" | shasum -a 256 --check
cp "$python_pinyin_license" "$output_dir/python-pinyin.LICENSE"
# The retained OpenCC conversion tables are Apache-2.0 data. Copy the pinned,
# hash-checked SPDX text instead of reaching into an uninitialized librime tree.
cp "$license_cache/Apache-2.0.txt" "$output_dir/OpenCC.LICENSE"
cp "$repo_root/data/owltype.yaml" "$output_dir/owltype.yaml"
cp "$repo_root/rime/"*.custom.yaml "$output_dir/_user_seed/"
python3 "$repo_root/scripts/build-owltype-msime-seed-db.py" "$output_dir"
python3 "$repo_root/scripts/build-owltype-msime-seed-db.py" --check "$output_dir"
python3 "$repo_root/scripts/fetch-msime-others.py" \
  --output "$output_dir/msime/msime-others.db"
cp "$repo_root/data/msime-others-NOTICE.txt" "$output_dir/"

cat > "$output_dir/OWLTYPE-SEED-SOURCES.md" <<EOF
# Owltype public seed source map

The Chinese dictionary in this seed has exactly these data inputs:

- \`cn_dicts/owltype_base.dict.yaml\` is generated from jieba \`dict.txt\` at
  tag \`$jieba_tag\` (MIT), phrase-pinyin-data \`pinyin.txt\` at revision
  \`$ppd_sha\` (MIT), and Unicode $unihan_version Unihan fields \`kTGH\`,
  \`kTGHZ2013\`, \`kMandarin\`, and \`kHanyuPinlu\` under Unicode-3.0. Every
  entry is restricted to the 通用规范汉字表 character set (Unihan \`kTGH\` 2013),
  which keeps traditional-form and rare characters out of the word candidates.
- \`cn_dicts/owltype_unicode.dict.yaml\` is generated from Unicode $unihan_version
  \`Unihan_Readings.txt\` field \`kMandarin\` under Unicode-3.0. It carries no
  weights, so it only serves as a rare-character fallback below owltype_base.
- \`msime/msime-pinyin.db:wubi86\` imports
  KyleBing/rime-wubi86-jidian \`$wubi86_sha\`'s \`wubi86_jidian.dict.yaml\`
  (Apache-2.0). The pinned source SHA-256 is \`$wubi86_sha256\`. It has
  89,273 data rows: 89,272 shape-valid rows are accepted, 3 are duplicate
  pairs merged by highest weight, 89,269 unique rows are written, and 1 row
  is rejected because its text column is empty (source line 7911).
  \`wubi86-jidian.LICENSE\` is verified as
  SHA-256 \`$wubi86_license_sha256\` and copied to the seed unchanged.

Only the curated \`pinyin.txt\` file of phrase-pinyin-data is used. Its
\`large_pinyin.txt\`, \`cc_cedict.txt\`, and \`zdic_*\` files are excluded
because their provenance is CC BY-SA or crawled data. rime-essay is no longer
distributed with this seed.

The rime-ice schemas, Lua helpers, OpenCC tables, symbols, and configuration are
from revision \`$rime_ice_sha\` under GPL-3.0-only with its retained Credits.

\`msime/msime-others.db\` is derived at seed time from the pinned
\`$msime_others_version\` release artifact (size $msime_others_size, SHA-256
\`$msime_others_sha\`). The release manifest records msime builder commit
\`$msime_others_builder_sha\` and msime-dictionary data commit
\`$msime_others_data_sha\`. Owltype retains only these two tables:

- \`emoji\`: $msime_emoji_rows rows, canonical row SHA-256
  \`$msime_emoji_row_sha\`.
- \`emoji_pinyin\`: $msime_emoji_pinyin_rows rows, canonical row SHA-256
  \`$msime_emoji_pinyin_row_sha\`.

Chinese keywords come from rime-ice's emoji map (GPL-3.0-only); English names
use Unicode Emoji 17.0, CLDR annotations and Emoji 1.0 names (Unicode-3.0).
The pinned msime builder computes per-character readings with the Rust
\`pinyin\` crate and applies phrase overrides generated by
mozillazg/python-pinyin \`$python_pinyin_version\` (MIT); the verbatim
\`python-pinyin.LICENSE\` is included. The release artifact's other tables,
including kaomoji and PiliApp symbol data, are not copied into Owltype. See
\`msime-others-NOTICE.txt\` for the release manifest, fixed builder/input paths
and input file hashes.

\`licenses/chinese-ime-lm.LICENSE\` is the verbatim Apache-2.0 text from the
chinese-ime-lm \`reference/\` source crate at revision \`$chinese_ime_lm_sha\`.
It covers that vendored source crate only; the project's model weights have a
separate model lock, license, and notice.

No rime-ice \`cn_dicts\` or \`en_dicts\` file is distributed. In particular,
the upstream 8105, base, ext, 41448, Tencent, and miscellaneous dictionaries are
excluded rather than relying on an unverified or mixed-source license chain.
EOF

{
  echo "Owltype local-core Rime seed"
  echo "rime-ice $rime_ice_sha"
  echo "source $rime_ice_remote"
  echo "unicode-unihan $unihan_version $unihan_sha"
  echo "source $unihan_remote"
  echo "jieba $jieba_tag $jieba_dict_sha"
  echo "source https://github.com/fxsjy/jieba"
  echo "phrase-pinyin-data $ppd_sha $ppd_pinyin_sha"
  echo "source https://github.com/mozillazg/phrase-pinyin-data"
  echo "license-texts SPDX license-list-data $spdx_license_tag"
  echo "dictionary inputs include Unicode Unihan, jieba dict.txt, phrase-pinyin-data pinyin.txt, and pinned rime-wubi86-jidian wubi86_jidian.dict.yaml"
  echo "rime-wubi86-jidian $wubi86_sha"
  echo "source https://github.com/KyleBing/rime-wubi86-jidian"
  echo "wubi86-dictionary $wubi86_sha256"
  echo "wubi86-license $wubi86_license_sha256 wubi86-jidian.LICENSE"
  echo "wubi86-counts source-total=89273 accepted=89272 unique=89269 duplicate=3 rejected=1"
  echo "wubi86-rejected source-line-7911 empty-text cokg"
  echo "msime-others derived-emoji $msime_others_version source-sha256=$msime_others_sha source-size=$msime_others_size"
  echo "source https://github.com/metasequoiaime/msime-dictionary/releases/download/$msime_others_version/msime-others.db"
  echo "msime-others-manifest $msime_others_manifest_sha size=$msime_others_manifest_size"
  echo "source https://github.com/metasequoiaime/msime-dictionary/releases/download/$msime_others_version/msime-dictionary-manifest.json"
  echo "msime-others-builder metasequoiaime/msime $msime_others_builder_sha"
  echo "msime-others-data metasequoiaime/msime-dictionary $msime_others_data_sha"
  echo "msime-others-rime-ice $msime_others_rime_ice_sha"
  echo "msime-others-tables emoji,emoji_pinyin"
  echo "msime-others-emoji rows=$msime_emoji_rows row-sha256=$msime_emoji_row_sha"
  echo "msime-others-emoji-pinyin rows=$msime_emoji_pinyin_rows row-sha256=$msime_emoji_pinyin_row_sha"
  echo "msime-others-licensing GPL-3.0-only+Unicode-3.0+MIT"
  echo "msime-others-sources emoji=rime-ice-GPL-3.0-only names=Unicode-Emoji-17.0+CLDR+Emoji-1.0-Unicode-3.0 readings=pinyin-crate+Rust-builder overrides=python-pinyin-$python_pinyin_version-MIT"
  echo "python-pinyin $python_pinyin_version $python_pinyin_sha"
  echo "python-pinyin-license $python_pinyin_license_sha256 python-pinyin.LICENSE"
  echo "source https://github.com/mozillazg/python-pinyin/tree/v$python_pinyin_version"
  echo "msime-others-notice msime-others-NOTICE.txt"
  echo "chinese-ime-lm-reference $chinese_ime_lm_sha"
  echo "source https://github.com/metasequoiaime/chinese-ime-lm/tree/$chinese_ime_lm_sha/reference"
  echo "chinese-ime-lm-license $chinese_ime_lm_license_sha256 licenses/chinese-ime-lm.LICENSE"
  echo "chinese-ime-lm-license-scope vendored-reference-source-not-model-weights"
  echo "rime-essay removed from the public seed after traditional-form review"
  echo "rime-ice cn_dicts and en_dicts omitted after provenance review"
  echo "wubi derivation: pinned Apache-2.0 wubi86_jidian.dict.yaml imported into msime-pinyin.db"
  echo "octagram data omitted from the local-core seed"
} > "$output_dir/OWLTYPE-SEED-MANIFEST.txt"

echo "[owltype-seed] assembled pinned rime-ice seed at $output_dir"
