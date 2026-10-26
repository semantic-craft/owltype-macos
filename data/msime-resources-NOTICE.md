# Production dictionary resource provenance

Owltype pins the public desktop release
[metasequoiaime/msime-dictionary dict-v2.0.24](https://github.com/metasequoiaime/msime-dictionary/releases/tag/dict-v2.0.24).
The verbatim release manifest is `msime-dictionary-manifest.json` (4,627 bytes,
SHA-256 `5b656a5db35b4dcf804ce4348d8584c899d0012fe62bbbe3689204ddaba8722f`).
Its builder/format-contract revision is `128a332cabc5fa42b1cf5f827033ad5697ff528b`
and dictionary source revision is `71dc6f6cc7a451231ee29c0a39b39adbf2e04d32`.
The manifest records `includes_unlicensed_inputs: false` and the four excluded
unlicensed inputs. That flag covers the builder inputs; it does not erase the
separately documented symbol redistribution gap below.

| Release member | Bytes | SHA-256 | Production handling |
| --- | ---: | --- | --- |
| msime-pinyin.db | 73723904 | 7c672458e6068c22c07b33b146c5a07f4e734959abc3bddd2784fe18a7582a76 | All upstream pinyin data retained; Owl Wubi overlay only |
| msime-english.db | 4526080 | d216f66cab7edb9072ba7a07f3fe35623e76870438b76d360a89cc2a4795d3cd | Verbatim |
| msime-bigram.bin | 12000016 | 79607ae9fcd80ef6df2f001cfbc1fa6048f81c1de00f45c634bbc8e132642d88 | Verbatim |
| msime-trigram.bin | 12000016 | 59e4eeba6f3e96cc46f3ae1477e9268187bb9df346634564e989889b282d68ea | Verbatim |
| msime-others.db | 1314816 | 9f3cae5b407038e0e4536c40582a0bc0feb732657f0ae2d38196374cede52f94 | Complete file in build cache; audited emoji derivative in product |

`fetch-msime-resources.py` downloads every file named by the pinned manifest into
the build cache and verifies every byte size and digest before publishing any
member. It never consults an installed input method or a personal directory.
The generated `msime/OWLTYPE-UPSTREAM-RESOURCES.json` records the actual shipped
identities, including the pinyin digest after Wubi overlay. Only `wubi86`,
`wubi98`, and `owl_seed_wubi86_source` are replaced from the existing audited
Owl seed. All other upstream tables and scoring data are preserved. The existing
`wubi86-jidian.LICENSE` and `msime/msime-wubi86-source.json` continue to describe
that Apache-2.0 Wubi source and import counts.

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
permission. Japanese/Wubi release members and their notices likewise remain in
the build cache; Owl's existing Wubi resource stays authoritative. Neural model
weights are separately pinned and handled by the model resource workflow.
