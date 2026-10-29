# Production dictionary resource provenance

Owltype pins the public desktop release
[metasequoiaime/msime-dictionary dict-v2.0.39](https://github.com/metasequoiaime/msime-dictionary/releases/tag/dict-v2.0.39).
The verbatim release manifest is `msime-dictionary-manifest.json` (4,769 bytes,
SHA-256 `d697cc197ac4c61fc6447a42eb8cb96d9913bec4ebdd79fad4c68d91f37bbb55`).
Its builder/format-contract revision is `8bb181be2ed36ed9559a87434cc4c9048077ff29`
and dictionary source revision is `75978c6a6470171cc805c74e87ef465d894a7be4`.
The manifest records `includes_unlicensed_inputs: false` and the four excluded
unlicensed inputs. That flag covers the builder inputs; it does not erase the
separately documented symbol redistribution gap below.

| Release member | Bytes | SHA-256 | Production handling |
| --- | ---: | --- | --- |
| msime-pinyin.db | 73916416 | e8d7a7bc8f990b6553d5d5199e652d29d86015dc8f48498689108fca408fc935 | Verbatim; no Owl Wubi overlay |
| msime-wubi.db | 94982144 | 54ee94799d8e33d5356468bdae164d21f68ce8ca0de9e6464ed4b3783924b93c | Verbatim; official 86 and 98 base tables plus supplements |
| msime-english.db | 4526080 | 1b5497d6764f15ebd2f86225c29b0fa1e45961638dfb0e13859214fbfc6f4bfd | Verbatim |
| msime-bigram.bin | 12000016 | 3513db47cbe2f035af969b1c3ba8d414f760d70ab404ad49c477630799f94c6b | Verbatim |
| msime-trigram.bin | 12000016 | 818e87be6f4d6ba5004a64533fae543c8738d03899d37495d0fb818eaaa5495c | Verbatim |
| msime-others.db | 1314816 | 9f3cae5b407038e0e4536c40582a0bc0feb732657f0ae2d38196374cede52f94 | Complete file in build cache; audited emoji derivative in product |

`fetch-msime-resources.py` downloads every file named by the pinned manifest into
the build cache and verifies every byte size and digest before publishing any
member. It never consults an installed input method or a personal directory.
The generated `msime/OWLTYPE-UPSTREAM-RESOURCES.json` records the actual shipped
identities. The official pinyin database and split Wubi database are unchanged;
no Owl-specific Wubi tables are overlaid. Runtime generation assembly uses the
upstream split-table merger so learning can write the same mutable generation
that candidates read, while the published resources remain immutable.

The official Wubi86 base derives from extreme-point Jidian (Apache-2.0). Its
Wubi98 base derives from yanhuacuo/98wubi-tables revision
`6b8b6fb9d3c34e0d5e3b17211e1f1c100e7eb697` (Unlicense), with Fcitx revision
`dbc7154a7f0b9fc04313160ae8066ed4d8cbc446` (GPL-3.0-or-later). Both generated
phrase supplements also draw on GPL-3.0 rime-ice/manual words and WTFPL place
names, following the original version's single-character codes. The full
upstream notice below records each input. The original Apache text remains
`wubi86-jidian.LICENSE`; GPL-3.0, Unlicense and WTFPL texts accompany the seed.

The verbatim upstream notice from msime source revision
`208c10e848bbed99373ca8b609fd2142b6b0b4e2` is included as
`msime-upstream-licensing-NOTICE.md`. It distinguishes GPL-3.0 rime-ice,
MIT pinyin corrections/translations, SCOWL, and the Chinese Wikipedia context
statistics. Owl retains the GPL/MIT/Unicode license texts and the release's exact
`msime-scowl_Copyright.txt`, which must accompany its SCOWL-derived word list.

The two context sidecars are derived from the Chinese Wikipedia 20260901
pages-articles dump: <https://dumps.wikimedia.org/zhwiki/20260901/>.
Attribution: Chinese Wikipedia contributors. These two files are distributed
under [CC-BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/); the files
are unchanged. The verbatim license text is included as
`licenses/CC-BY-SA-4.0.txt`, from SPDX license-list-data `v3.28.0`. Their source and build method are recorded in the upstream
notice and pinned builder. The CC-BY-SA license applies to those sidecars.

Upstream explicitly states that PiliApp `symbol_catalog` redistribution permission
is unconfirmed. Owl therefore does not ship the complete `msime-others.db` in
this change. Only the audited `emoji`, `emoji_pinyin`, `kaomoji` and
`kaomoji_catalog` tables enter the product. The latter two retain the MIT-licensed
aoguai/rime_kaomoji_dict data unchanged from the pinned release, with the verbatim
`rime-kaomoji.LICENSE`. Their exact row counts and canonical hashes and the emoji
source licenses are recorded in `msime-others-NOTICE.txt`; the acquisition and
delivery checks enforce that same four-table production contract. The full auxiliary release is retained in the
build cache for future reviewed use; acquisition does not claim redistribution
permission. Japanese release members remain in the build cache. Wubi is now an unchanged
production member rather than a cache-only input. Neural model
weights are separately pinned and handled by the model resource workflow.

Additional retained license texts for official Wubi data:
- `licenses/Unlicense.txt`: SPDX license-list-data `v3.28.0/text/Unlicense.txt`,
  SHA-256 `0bdebfeda07d45dada625ae1317c6f833186e798b171d0db640bcf32e92a8240`.
- `licenses/Administrative-divisions-of-China-WTFPL.txt`: verbatim msime revision
  `208c10e848bbed99373ca8b609fd2142b6b0b4e2` resource notice, SHA-256
  `ee820ff0db4ce628569e0975ac27dc926052a9f85d102b101edb104311ef4d90`.
