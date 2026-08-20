#!/usr/bin/env bash
#
# gen-dictpack-manifest.sh — regenerate the first-run dict-pack manifest
# (sources/DictPack/OwlDictPackManifestData.swift).
#
# 方案B（首启用户侧拉取，2026-07-24）：公开发布包只带清洁室种子（owl-seed.sh），
# 完整词库由 App 在用户机器上按本 manifest 从上游原仓库下载 → Owltype 不再分发
# 这批数据。本脚本把每个目标文件在 pin 的 commit 处逐文件下载、算 sha256，生成
# App 内嵌的 Swift 数据文件。改 pin 或增删文件后重跑本脚本并提交生成物。
#
# 逐文件校验（而非 tarball 校验）：GitHub codeload 的 commit tarball 字节不保证
# 稳定（gzip 元数据历史上变过），raw 文件内容 + 自算 sha256 才是可复现的锚。
#
# Usage:  bash scripts/gen-dictpack-manifest.sh          # uses cache, downloads missing
#         OWL_DICTPACK_REFRESH=1 bash scripts/...       # force re-download

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${OWL_DICTPACK_CACHE:-/tmp/owltype-dictpack-manifest}"
out_swift="$repo_root/sources/DictPack/OwlDictPackManifestData.swift"

# ── pins ─────────────────────────────────────────────────────────────────────
# rime-ice pin 与 owl-seed.sh 的清洁室种子同 commit：公开包里的 rime_ice.schema.yaml
# 来自 b681a34，词库必须同源，方案/词典才协调。
rime_ice_repo="iDvel/rime-ice"
rime_ice_sha="b681a34f788795034b3b288830f4861980bc8b0d"
# KyleBing 五笔 pin 与 6/29 全量种子（OWL-SEED-MANIFEST）一致。
wubi_repo="KyleBing/rime-wubi86-jidian"
wubi_sha="a194fb8b3ec41ef9dcf079d3a67876fa75f79135"
# lotem 八股文语法模型：hans 分支 HEAD（bgw 由 ~10MB 更新为 ~40MB 的加大版）。
octagram_repo="lotem/rime-octagram-data"
octagram_sha="f8ce3b534733e489a8470a7c2adf5a154e8ea069"

# dict-pack 版本：递增触发已装用户升级（fetcher 对比 .owl-dictpack.json 里的版本）。
pack_version=1

# ── file maps: "repo|sha|path-in-repo|dest-rel-path|patch" ───────────────────
# patch 字段：fetcher 在 sha256 校验通过后套用的既知修正（空=无）。
# wubiDateTranslator = KyleBing _trad/_trad_pinyin 里 active 的短名
# `lua_translator@date_translator` 改为 `lua_translator@*wubi86_jidian_date_translator`
# （与 owl-seed-full.sh 的必修 bug 一致）。
entries=(
  # rime-ice 全量词库（公开包缺失的 delta；lua/opencc/default.yaml/symbols 公开包已有）
  "$rime_ice_repo|$rime_ice_sha|rime_ice.dict.yaml|rime_ice.dict.yaml|"
  "$rime_ice_repo|$rime_ice_sha|cn_dicts/8105.dict.yaml|cn_dicts/8105.dict.yaml|"
  "$rime_ice_repo|$rime_ice_sha|cn_dicts/41448.dict.yaml|cn_dicts/41448.dict.yaml|"
  "$rime_ice_repo|$rime_ice_sha|cn_dicts/base.dict.yaml|cn_dicts/base.dict.yaml|"
  "$rime_ice_repo|$rime_ice_sha|cn_dicts/ext.dict.yaml|cn_dicts/ext.dict.yaml|"
  "$rime_ice_repo|$rime_ice_sha|cn_dicts/others.dict.yaml|cn_dicts/others.dict.yaml|"
  "$rime_ice_repo|$rime_ice_sha|cn_dicts/tencent.dict.yaml|cn_dicts/tencent.dict.yaml|"
  "$rime_ice_repo|$rime_ice_sha|en_dicts/en.dict.yaml|en_dicts/en.dict.yaml|"
  "$rime_ice_repo|$rime_ice_sha|en_dicts/en_ext.dict.yaml|en_dicts/en_ext.dict.yaml|"
  "$rime_ice_repo|$rime_ice_sha|en_dicts/cn_en.txt|en_dicts/cn_en.txt|"
  "$rime_ice_repo|$rime_ice_sha|en_dicts/cn_en_abc.txt|en_dicts/cn_en_abc.txt|"
  "$rime_ice_repo|$rime_ice_sha|en_dicts/cn_en_double_pinyin.txt|en_dicts/cn_en_double_pinyin.txt|"
  "$rime_ice_repo|$rime_ice_sha|en_dicts/cn_en_flypy.txt|en_dicts/cn_en_flypy.txt|"
  "$rime_ice_repo|$rime_ice_sha|en_dicts/cn_en_jiajia.txt|en_dicts/cn_en_jiajia.txt|"
  "$rime_ice_repo|$rime_ice_sha|en_dicts/cn_en_mspy.txt|en_dicts/cn_en_mspy.txt|"
  "$rime_ice_repo|$rime_ice_sha|en_dicts/cn_en_sogou.txt|en_dicts/cn_en_sogou.txt|"
  "$rime_ice_repo|$rime_ice_sha|en_dicts/cn_en_ziguang.txt|en_dicts/cn_en_ziguang.txt|"
  "$rime_ice_repo|$rime_ice_sha|melt_eng.dict.yaml|melt_eng.dict.yaml|"
  "$rime_ice_repo|$rime_ice_sha|melt_eng.schema.yaml|melt_eng.schema.yaml|"
  "$rime_ice_repo|$rime_ice_sha|radical_pinyin.dict.yaml|radical_pinyin.dict.yaml|"
  "$rime_ice_repo|$rime_ice_sha|radical_pinyin.schema.yaml|radical_pinyin.schema.yaml|"
  "$rime_ice_repo|$rime_ice_sha|double_pinyin.schema.yaml|double_pinyin.schema.yaml|"
  "$rime_ice_repo|$rime_ice_sha|double_pinyin_abc.schema.yaml|double_pinyin_abc.schema.yaml|"
  "$rime_ice_repo|$rime_ice_sha|double_pinyin_flypy.schema.yaml|double_pinyin_flypy.schema.yaml|"
  "$rime_ice_repo|$rime_ice_sha|double_pinyin_jiajia.schema.yaml|double_pinyin_jiajia.schema.yaml|"
  "$rime_ice_repo|$rime_ice_sha|double_pinyin_mspy.schema.yaml|double_pinyin_mspy.schema.yaml|"
  "$rime_ice_repo|$rime_ice_sha|double_pinyin_sogou.schema.yaml|double_pinyin_sogou.schema.yaml|"
  "$rime_ice_repo|$rime_ice_sha|double_pinyin_ziguang.schema.yaml|double_pinyin_ziguang.schema.yaml|"
  "$rime_ice_repo|$rime_ice_sha|LICENSE|rime-ice.LICENSE|"
  # KyleBing 极点五笔86 全套 + 反查依赖 + lua（对齐 owl-seed-full.sh 的 overlay 规则）
  "$wubi_repo|$wubi_sha|wubi86_jidian.dict.yaml|wubi86_jidian.dict.yaml|"
  "$wubi_repo|$wubi_sha|wubi86_jidian.schema.yaml|wubi86_jidian.schema.yaml|"
  "$wubi_repo|$wubi_sha|wubi86_jidian_extra.dict.yaml|wubi86_jidian_extra.dict.yaml|"
  "$wubi_repo|$wubi_sha|wubi86_jidian_extra_district.dict.yaml|wubi86_jidian_extra_district.dict.yaml|"
  "$wubi_repo|$wubi_sha|wubi86_jidian_user.dict.yaml|wubi86_jidian_user.dict.yaml|"
  "$wubi_repo|$wubi_sha|wubi86_jidian_user_hamster.dict.yaml|wubi86_jidian_user_hamster.dict.yaml|"
  "$wubi_repo|$wubi_sha|wubi86_jidian_pinyin.schema.yaml|wubi86_jidian_pinyin.schema.yaml|"
  "$wubi_repo|$wubi_sha|wubi86_jidian_trad.schema.yaml|wubi86_jidian_trad.schema.yaml|wubiDateTranslator"
  "$wubi_repo|$wubi_sha|wubi86_jidian_trad_pinyin.schema.yaml|wubi86_jidian_trad_pinyin.schema.yaml|wubiDateTranslator"
  "$wubi_repo|$wubi_sha|pinyin_simp.dict.yaml|pinyin_simp.dict.yaml|"
  "$wubi_repo|$wubi_sha|pinyin_simp.schema.yaml|pinyin_simp.schema.yaml|"
  "$wubi_repo|$wubi_sha|numbers.schema.yaml|numbers.schema.yaml|"
  "$wubi_repo|$wubi_sha|lua/wubi86_jidian_date_translator.lua|lua/wubi86_jidian_date_translator.lua|"
  "$wubi_repo|$wubi_sha|lua/wubi86_jidian_single_char_first_filter.lua|lua/wubi86_jidian_single_char_first_filter.lua|"
  "$wubi_repo|$wubi_sha|lua/wubi86_jidian_single_char_only.lua|lua/wubi86_jidian_single_char_only.lua|"
  "$wubi_repo|$wubi_sha|LICENSE|wubi86-jidian.LICENSE|"
  # lotem 八股文语法模型（rime_ice.custom.yaml grammar/language 指向 zh-hans-t-essay-bgw）
  "$octagram_repo|$octagram_sha|zh-hans-t-essay-bgw.gram|zh-hans-t-essay-bgw.gram|"
  "$octagram_repo|$octagram_sha|LICENSE|octagram-data.LICENSE|"
)

mkdir -p "$cache_root" "$(dirname "$out_swift")"

sha256_of() { /usr/bin/shasum -a 256 "$1" | cut -d' ' -f1; }

fetch_one() {  # repo sha path -> prints local cache path
  local repo="$1" sha="$2" path="$3"
  local key; key="$(echo "$repo@$sha/$path" | tr '/@' '__')"
  local target="$cache_root/$key"
  if [[ -n "${OWL_DICTPACK_REFRESH:-}" ]]; then rm -f "$target"; fi
  if [[ ! -s "$target" ]]; then
    curl --fail --silent --location --retry 3 \
      "https://raw.githubusercontent.com/$repo/$sha/$path" --output "$target"
  fi
  echo "$target"
}

echo "[dictpack] fetching $(( ${#entries[@]} )) files → $cache_root"
rows=""
total_bytes=0
for e in "${entries[@]}"; do
  IFS='|' read -r repo sha path dest patch <<<"$e"
  f="$(fetch_one "$repo" "$sha" "$path")"
  h="$(sha256_of "$f")"
  bytes=$(stat -f %z "$f")
  total_bytes=$(( total_bytes + bytes ))
  patch_swift="nil"
  [[ -n "$patch" ]] && patch_swift=".$patch"
  rows+="    .init(repo: \"$repo\", ref: \"$sha\", path: \"$path\", dest: \"$dest\", sha256: \"$h\", size: $bytes, patch: $patch_swift),"$'\n'
  echo "  $dest  $bytes  $h"
done

cat >"$out_swift" <<SWIFT
//
//  OwlDictPackManifestData.swift
//  Owltype
//
//  GENERATED by scripts/gen-dictpack-manifest.sh — DO NOT EDIT BY HAND.
//  改 pin / 增删文件：编辑脚本里的 pins 与 entries，重跑脚本，提交本文件。
//
//  rime-ice   $rime_ice_sha
//  wubi       $wubi_sha
//  octagram   $octagram_sha
//  total payload bytes: $total_bytes
//

extension OwlDictPackManifest {
  /// 当前发布口径的完整词库清单（方案B：首启用户侧拉取）。
  static let current = OwlDictPackManifest(version: $pack_version, files: [
$rows  ])
}
SWIFT

echo "[dictpack] wrote $out_swift (payload $(( total_bytes / 1024 / 1024 )) MB)"
