# MSIME dictionary dict-v2.0.24 → dict-v2.0.39

Owltype moved from dict-v2.0.24 to dict-v2.0.39 (published 2026-10-25, the newest `dict-v*` on
2026-10-29) for #314. The engine stays at macos-v0.55.0. Every number below comes from
`scripts/msime-dictionary-diff.py` over the two official releases, each checked against its own
manifest:

```sh
python3 scripts/msime-dictionary-diff.py OLD_DIR NEW_DIR --json diff.json --markdown diff.md
```

## Why msime-wubi.db grew from 14.5 MB to 95 MB

Upstream started deriving Wubi codes for the multi-character words it already had in pinyin
(msime commits `1f4106681`, #8582, and `31a16d14e`, #8629, 2026-10-18; both are ancestors of
macos-v0.55.0). The builder takes rime-ice main and supplement words with weight ≥ 100, the
administrative-division supplement and the hand-curated `custom/words.txt`, computes each word's
full code from the profile's single-character codes, and skips any word the base table already
codes. Each profile gained about 604,000 rows, all with weight 0–9, so original table rows keep
first place on a shared code.

The file is a plain SQLite database with no free pages. Of its 95.0 MB, the two tables hold
37.3 MB, the `UNIQUE(key, value)` indexes 35.9 MB and the `(key, weight)` lookup indexes 21.7 MB.
`VACUUM` would not shrink it.

The same upstream change made macOS MSIME itself ship the Wubi table as an on-demand resource
pack (`37257c40f`, #8860, also in macos-v0.55.0): its full and pinyin editions download
`msime-wubi.db` when the user picks Wubi, and only its Wubi edition bundles it. The engine
Owltype vendors already contains the matching code paths (`EngineOptions::wubi_dictionary`,
`merge_downloaded_wubi`, and Wubi journal rows skipped while the table is absent).

## What changed for users

- Pinyin: 39 new words, no removals, about 588,000 re-weighted rows; 13,568 spellings get a
  different first row. The bigram/trigram context models changed too, so sentence order moves:
  `tadefangjian` now starts with 他的房间 instead of 它的房间.
- Wubi 86 and 98: about 604,000 derived phrases each. 45,938 (86) and 43,575 (98) four-letter
  codes that used to auto-commit their only row now show a list, because a derived phrase shares
  the code. Some codes collect long lists of templated phrases (`fgfk`: 192 rows, mostly
  越来越…). 186 private-use rows left Wubi 86; 7,968 extension-area rows left Wubi 98.
- English: same 74,157 words; 8,373 English→Chinese glosses reworded, 19 Chinese→English
  glosses added.
- Owltype behaves exactly like the fixed upstream Host API on the new set: every pinyin, Wubi
  86/98 and keyboard-model replay agrees (see the pull request for the evidence).

Builder `128a332cabc5fa42b1cf5f827033ad5697ff528b` → `8bb181be2ed36ed9559a87434cc4c9048077ff29`; dictionary data `71dc6f6cc7a451231ee29c0a39b39adbf2e04d32` → `75978c6a6470171cc805c74e87ef465d894a7be4`.

| Member | Bytes before | Bytes after | Changed |
| --- | ---: | ---: | --- |
| msime-pinyin.db | 73,723,904 | 73,916,416 | yes |
| msime-wubi.db | 14,536,704 | 94,982,144 | yes |
| msime-english.db | 4,526,080 | 4,526,080 | yes |
| msime-bigram.bin | 12,000,016 | 12,000,016 | yes |
| msime-trigram.bin | 12,000,016 | 12,000,016 | yes |
| msime-others.db | 1,314,816 | 1,314,816 | no |

| Table | Rows before | Rows after | Added | Removed | Weight up | Weight down | First row changed |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Pinyin words | 953,674 | 953,713 | 39 | 0 | 353,662 | 234,712 | 13,568 |
| Pinyin quick phrases | 8 | 8 | 0 | 0 | 0 | 0 | 0 |
| Wubi 86 | 126,078 | 729,717 | 603,825 | 186 | 1,297 | 12,175 | 4,992 |
| Wubi 98 | 135,372 | 731,247 | 603,843 | 7,968 | 856 | 9,976 | 5,220 |
| English words | 74,157 | 74,157 | 0 | 0 | 0 | 0 | 0 |
| English en_zh_glosses | 66,817 | 66,817 | 0 | 0 | 8,373 changed | | |
| English zh_en_glosses | 19,661 | 19,680 | 19 | 0 | 0 changed | | |

## Wubi collisions

| Profile | Codes gaining rows | Codes with duplicates (before → after) | Unique four-codes (before → after) | Lost unique auto-commit | Added rows weight range |
| --- | ---: | ---: | ---: | ---: | --- |
| wubi86 | 63,978 | 21,614 → 137,467 | 65,047 → 87,860 | 45,938 | 0–9 |
| wubi98 | 62,934 | 24,719 → 139,303 | 63,610 → 90,344 | 43,575 | 0–9 |

wubi86 added rows by length: 2 字 54,859, 3 字 187,558, 4 字 252,554, 5 字 61,709, 6 字 28,323, 7 字 10,985, 8 字 6,289, 9 字 672, 10 字 474, 11 字 130, 12 字 105, 13 字 62, 14 字 50, 15 字 22, 16 字 10, 17 字 3, 18 字 6, 19 字 5, 20 字 5, 21 字 1, 22 字 1, 24 字 1, 29 字 1.
wubi86 codes that lose unique auto-commit (code, former only row, rows now): `fgfk` 雨露 (192); `wgwk` 侠侣 (172); `ygyk` 广开言路 (169); `rgrk` 捕捉 (121); `tgtk` 征程 (120); `kgkk` 号哭 (108); `ngnk` 怔忡 (93); `rggh` 后下 (80); `uguk` 病况 (79); `qgqk` 够不够 (78); `rbgo` 提出来 (74); `gtgg` 珄 (65); `kfgo` 跑过来 (58); `dfgr` 万无一失 (54); `fggr` 雨珠 (52)

wubi98 added rows by length: 2 字 54,872, 3 字 187,562, 4 字 252,555, 5 字 61,709, 6 字 28,323, 7 字 10,985, 8 字 6,289, 9 字 672, 10 字 474, 11 字 130, 12 字 105, 13 字 62, 14 字 50, 15 字 22, 16 字 10, 17 字 3, 18 字 6, 19 字 5, 20 字 5, 21 字 1, 22 字 1, 24 字 1, 29 字 1.
wubi98 codes that lose unique auto-commit (code, former only row, rows now): `sdsk` 椅 (123); `kdkk` 顺口 (100); `gfgt` 万无一失 (99); `ndnk` 忧悒 (92); `rbgu` 提出来 (84); `gdft` 天才 (71); `ffft` 无声无息 (69); `gwft` 与会者 (69); `dfft` 奋起直追 (62); `gfdt` 万劫不复 (61); `rbfc` 凶魂 (61); `kfgu` 跑过来 (59); `rfbn` 挂了 (58); `guft` 来者 (54); `ufgu` 站起来 (53)

Wubi file pages: 3,549 → 23,189 (4096 bytes each); free pages 0 → 0.

Pinyin words, highest-weight additions: 嘉实 `jia'shi` 3333; 千问 `qian'wen` 3333; 挽昼 `wan'zhou` 3333; 小艺 `xiao'yi` 3333; 折戟 `zhe'ji` 3333; 本地模型 `ben'di'mo'xing` 100; 本地优先 `ben'di'you'xian` 100; 词频学习 `ci'pin'xue'xi` 100; 低尺寸 `di'chi'cun` 100; 端侧模型 `duan'ce'mo'xing` 100; 反向查码 `fan'xiang'cha'ma` 100; 菲欧妮 `fei'ou'ni` 100; 甘道夫 `gan'dao'fu` 100; 个人词库 `ge'ren'ci'ku` 100; 候选窗预编辑 `hou'xuan'chuang'yu'bian'ji` 100
Pinyin words, first row changed (code, before, after): `a'bi` 阿鼻→阿碧; `a'bing` 阿冰→阿炳; `a'bo` 阿伯→阿波; `a'bu'jia` 阿布贾→阿布加; `a'de'lai'de` 阿得莱德→阿德莱德; `a'fu'jia'de'luo'chang'shu` 阿伏加德罗常数→阿伏伽德罗常数; `a'hua` 阿华→阿花; `a'jie` 阿姐→阿杰; `a'kui'na` 阿奎纳→阿奎那; `a'la` 啊啦→阿拉; `a'li'an'na` 阿莉安娜→阿里安娜; `a'mao` 阿猫→阿毛; `a'meng` 阿盟→阿蒙; `a'mu'er` 阿穆尔→阿木尔; `a'ni'ya` 阿妮亚→阿尼亚


## Cost of the new Wubi table: two ways to ship it

Measured on 2026-10-29 on the maintainer's Mac (Apple silicon) with the three layouts below; the
user still has to choose. Package sizes rebuild the voided 2.1.1 Release App with each resource
layout the way `package/make_package` (ditto zip inside `pkgbuild`) and `package/make_dmg` (UDZO)
do, unsigned. Launch, latency and memory come from Owltype's C ABI (the same calls the IMK
session makes): a fresh process creating a session on an empty user root (first launch), the same
root again (later launches), then 20 pinyin sentences or 400 Wubi codes typed key by key.
Three runs each; medians shown.

| | dict-v2.0.24 today | 2.0.39, Wubi table bundled (A) | 2.0.39, Wubi table downloaded on demand (B) |
| --- | ---: | ---: | ---: |
| Installed App | 205 MiB | 282 MiB | 191 MiB |
| Installer / update PKG | 112.8 MB | 150.5 MB (+37.7) | 105.7 MB (−7.1) |
| DMG | 121.2 MB | 161.6 MB (+40.4) | 113.9 MB |
| Wubi download when the user picks Wubi | — | — | 95.0 MB raw, 45.0 MB zip, 21.7 MB xz |
| First launch (prepare the working dictionary) | 0.55–0.57 s | 3.1 s pinyin, 4.3 s Wubi | 0.29 s; Wubi users pay about 3–4 s once when the table arrives |
| Later launches | 12–13 ms | 12–16 ms | 11 ms |
| Working dictionary on disk (`msime-user`) | 116 MB | 223–226 MB | 98 MB (+ the table once downloaded) |
| Resource store copy after the dictionary prompt | 141 MB | 218 MB | 127 MB |
| Resident memory after typing | 34 MiB Wubi, 80 MiB pinyin | 35 / 81 MiB | 80 MiB pinyin |
| Pinyin key latency p50 / p95 | 0.4 / 1.1 ms | 0.4 / 2.4 ms | 0.4 / 2.3 ms |
| Wubi first-key latency p50 / p95 | 0.4 / 0.7 ms | 2.0 / 8–35 ms | same as A once downloaded |
| Wubi keys 2–4 p95 | ≤ 0.6 ms | ≤ 1.6 ms | same as A |

For scale: the published 2.1.0 update PKG is 61.9 MB; 2.1.1 already grew to about 113 MB with the
complete official dictionary, independent of this re-pin.

The resident-memory column is the probe process (SQLite page cache plus models), not the
installed IMK process. Wubi's first key grows because a one-letter prefix now scans 230,000 codes
instead of 91,000; its p95 varied between runs from 4 to 35 ms with occasional spikes above
50 ms, so it can cost a frame. Option B does not change Wubi lookups; it only keeps the table out
of the App for people who never type Wubi.

Option B is not implemented. The engine side already exists (see above); Owltype would need a
download and verification step for the table, its own Wubi availability rule in the schema menu,
and the upgrade window upstream accepted: after an update, Wubi stays unavailable until the table
arrives (upstream falls back to the last Chinese scheme). Wubi users who update offline cannot
type Wubi until they reconnect or import the file.

Reproduce: `python3 scripts/msime-dictionary-diff.py` for the tables above; the size, launch and
latency probes and their raw output live with the #314 evidence in the maintainer's shared work
folder.
