# Third-party notices

本文件是源码树的组件索引，不替代上游要求随二进制附带的许可证全文。

| Component | Version / revision | License | Source |
|---|---|---|---|
| Squirrel-derived frontend | lineage parent `4db2c85…` | GPL v3 | https://github.com/rime/squirrel |
| librime | `33e78140250125871856cdc5b42ddc6a5fcd3cd4` | BSD-3-Clause | https://github.com/rime/librime |
| librime-lua | `ec52e48ea18f11af37717a01c337f853215cf70b` | BSD-3-Clause | https://github.com/hchunhui/librime-lua |
| plum | `b1be1969f914cc005add4090631b855db00c2591` | LGPL-3.0 | https://github.com/rime/plum |
| rime-ice configuration | `b681a34f788795034b3b288830f4861980bc8b0d` | GPL-3.0-only plus retained credits | https://github.com/iDvel/rime-ice |
| rime-essay preset vocabulary | `e9b1a374a6ea015fca5bdd04318924b4483ac35a` | LGPL-3.0-only | https://github.com/rime/rime-essay |
| Unicode Unihan | `16.0.0` | Unicode-3.0 | https://www.unicode.org/Public/16.0.0/ucd/Unihan.zip |
| OpenCC | supplied by pinned librime build inputs | Apache-2.0 | https://github.com/BYVoid/OpenCC |

`make bootstrap` 校验 librime 1.17.0 官方构建包的 SHA-256：

- `rime-33e7814-macOS-universal.tar.bz2`: `11d8dc663c6ec06d5ccb6111ba664a9e7b631b703ac6acd07cffbac664021850`
- `rime-deps-33e7814-macOS-universal.tar.bz2`: `dfe6047e87be271963d7466bd1a6e3d9e660c30e5e73e4bb94e8782c0a6ac8df`

公开 seed 的中文词典只使用 Unicode 16.0.0 `Unihan_Readings.txt` 的 `kMandarin`
字段和 rime-essay 的 `essay.txt`。rime-ice 的 `cn_dicts` 与 `en_dicts` 全部不分发，
从而排除《通用规范汉字表》《现代汉语常用词表》及其他混合来源。生成 seed 时同时
携带 `FAMOTYPE-SEED-SOURCES.md`、固定快照的 `rime-ice-Credits.md`、rime-essay
的 AUTHORS/许可证，以及适用于实际文件的完整许可证和署名。

生成的 seed 还携带固定在 SPDX license-list-data `v3.28.0` 的 Apache-2.0、BSD-3-Clause、
CC-BY-3.0、GPL-3.0-only、LGPL-3.0-only、MIT 与 Unicode-3.0 全文；这些通用条款与
`rime-ice-Credits.md` 的逐来源署名共同分发。

当前仓库不分发公开二进制。二进制发布门在完整 license bundle、SBOM、固定内容散列和对应源码
验证全部通过前保持关闭。
