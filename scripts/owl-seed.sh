#!/usr/bin/env bash
#
# Assemble the pinned official pinyin/Wubi/English/context resource set.
# Rime configuration assets remain for the existing host presentation contract.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${OWLTYPE_SEED_CACHE:-/tmp/owltype-rime-seed}"
# The cache is shared by every worktree on this Mac; concurrent gates used to collide on its git
# locks (shallow.lock). Hold one lock for the whole run; another run waits for it.
if [[ -z "${OWLTYPE_SEED_LOCKED:-}" ]]; then
  mkdir -p "$cache_root"
  OWLTYPE_SEED_LOCKED=1 exec /usr/bin/lockf -t 1800 "$cache_root/.owl-seed.lock" bash "$0" "$@"
fi
source_dir="$cache_root/rime-ice"
output_dir="$repo_root/data/owl-rime"
msime_release="$(python3 "$repo_root/scripts/msime_pin.py" get release)"
msime_manifest_sha="$(python3 "$repo_root/scripts/msime_pin.py" get manifest-sha256)"
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

if ! git -C "$source_dir" rev-parse --git-dir >/dev/null 2>&1; then
  rm -rf "$source_dir"
  mkdir -p "$cache_root"
  git init "$source_dir"
  git -C "$source_dir" remote add origin "$rime_ice_remote"
elif ! git -C "$source_dir" remote get-url origin >/dev/null 2>&1; then
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
cp "$repo_root/rust/plugins/phrase_table/LICENSE" "$output_dir/licenses/msime-latex-symbols-MIT.txt"
cp "$repo_root/rust/resources/licenses/rime-wanxiang-CC-BY-4.0.txt" "$output_dir/licenses/"

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
# Keep the legacy schema export aligned with the pinned macOS emoji default.
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

if not set_reset_after("emoji", 1):
    sys.exit("[owltype-seed][schema-patch] ERROR: emoji switch (with reset:) not found in rime_ice.schema.yaml")
if not set_states_after("emoji", "[ 👍, 😄 ]"):
    sys.exit("[owltype-seed][schema-patch] ERROR: emoji switch states not found in rime_ice.schema.yaml")
# 中英切换提示：英文态显示「英」而非「Ａ」（task 06-27 用户要求，2026-07-26 从全量种子搬入）。
if not set_states_after("ascii_mode", "[ 中, 英 ]"):
    sys.exit("[owltype-seed][schema-patch] ERROR: ascii_mode switch states not found in rime_ice.schema.yaml")
with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
print("[owltype-seed] patched rime_ice.schema.yaml: emoji reset 1 (upstream default on) states -> [👍, 😄], ascii_mode states -> [中, 英]")
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
cp "$repo_root/licenses/rime-kaomoji.LICENSE" "$output_dir/rime-kaomoji.LICENSE"
# The retained OpenCC conversion tables are Apache-2.0 data. Copy the pinned,
# hash-checked SPDX text.
cp "$license_cache/Apache-2.0.txt" "$output_dir/OpenCC.LICENSE"
cp "$repo_root/data/owltype.yaml" "$output_dir/owltype.yaml"
cp "$repo_root/rime/"*.custom.yaml "$output_dir/_user_seed/"
# Official split Wubi data supersedes the old generated 86-only overlay.
# Keep the original extreme-point notice because the official 86 base derives from it.
echo "$wubi86_license_sha256  $repo_root/licenses/wubi86-jidian.LICENSE" | shasum -a 256 --check
cp "$repo_root/licenses/wubi86-jidian.LICENSE" "$output_dir/wubi86-jidian.LICENSE"
python3 "$repo_root/scripts/fetch-msime-others.py" \
  --output "$output_dir/msime/msime-others.db"
python3 "$repo_root/scripts/fetch-msime-resources.py" --seed "$output_dir"
cp "$repo_root/data/msime-others-NOTICE.txt" "$output_dir/"

# The resource set above supersedes the legacy Rime dictionary intermediate.
cp "$repo_root/licenses/CC-BY-SA-4.0.txt" "$output_dir/licenses/CC-BY-SA-4.0.txt"
cp "$repo_root/data/msime-resources-NOTICE.md" "$output_dir/msime-resources-NOTICE.md"
cp "$repo_root/data/msime-upstream-licensing-NOTICE.md" "$output_dir/msime-upstream-licensing-NOTICE.md"
echo "0bdebfeda07d45dada625ae1317c6f833186e798b171d0db640bcf32e92a8240  $repo_root/licenses/Unlicense.txt" | shasum -a 256 --check
echo "ee820ff0db4ce628569e0975ac27dc926052a9f85d102b101edb104311ef4d90  $repo_root/licenses/Administrative-divisions-of-China-WTFPL.txt" | shasum -a 256 --check
cp "$repo_root/licenses/Unlicense.txt" "$output_dir/licenses/Unlicense.txt"
cp "$repo_root/licenses/Administrative-divisions-of-China-WTFPL.txt" "$output_dir/licenses/Administrative-divisions-of-China-WTFPL.txt"

cat > "$output_dir/OWLTYPE-SEED-SOURCES.md" <<EOF
# Owltype production resource sources

The production Rust engine uses the complete pinned official $msime_release
pinyin, split Wubi86/Wubi98 and English data plus both bigram/trigram scoring sidecars. Legacy Rime
YAML files are build intermediates and do not supply the production pinyin DB.
All official dictionary files are published unchanged; no Owl Wubi overlay is applied.
See msime-resources-NOTICE.md, msime-upstream-licensing-NOTICE.md,
msime/msime-dictionary-manifest.json and msime/OWLTYPE-UPSTREAM-RESOURCES.json
for sources, byte sizes, digests, adaptations, and redistribution boundaries.
The product's others DB remains the audited four-table emoji/kaomoji derivative.
EOF
cat > "$output_dir/OWLTYPE-SEED-MANIFEST.txt" <<EOF
Owltype production seed
official-resource-set $msime_release
manifest-sha256 $msime_manifest_sha
resource-identities msime/OWLTYPE-UPSTREAM-RESOURCES.json
wubi-resource msime/msime-wubi.db; upstream identity in resource-identities
wubi86-license $wubi86_license_sha256 wubi86-jidian.LICENSE
others-policy audited-emoji-kaomoji-four-tables; full upstream auxiliary artifact retained in build cache
model-policy separately pinned; defaults unchanged
EOF

echo "[owltype-seed] assembled official pinned production resources at $output_dir"
