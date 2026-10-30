# 来源与许可 · Provenance

猫头鹰输入法 Owltype 是自由软件，以 **GPLv3** 许可，是以下上游项目的派生作品。此文件完整记录其来源
脉络。README 首屏聚焦产品体验，来源细节收在此文件与 README 文末「来源与许可」段落——降位不抹除。

## 上游来源 Upstream sources

- **鼠须管 Squirrel** —— <https://github.com/rime/squirrel>（GPLv3）
  Owltype 的 macOS IMK 前端复用并精简自鼠须管的输入热路径。候选窗 / 设置 / 引导 / 表情符号面板由
  SwiftUI 重做，运行时身份、数据根与安装位置全部改为 Owltype（见下方「与鼠须管并存」）。
- **librime** —— <https://github.com/rime/librime>（BSD-3 / 组件各自许可）
  2.0.x 及以前的输入引擎基座。自 2.1.0 起 Owltype 改用水杉 Rust 引擎，公开 App 不再打包或
  动态链接 librime；保留此项以说明前端与方案配置的历史派生谱系。
- **RIME / 中州韻输入法引擎** —— <https://rime.im>
- **水杉输入法 Metasequoia IME (`msime`)** —— <https://github.com/metasequoiaime/msime>（GPLv3）
  Rust 输入引擎与运行时 crate 固定于 `macos-v0.55.0` /
  `208c10e848bbed99373ca8b609fd2142b6b0b4e2`（`rust/crates/`，经窄 C-ABI 静态链接入
  `Owltype.app`）。提取边界与宿主适配见 [`rust/msime-source.json`](rust/msime-source.json)。
  `rust/crates/owl-msime-ffi`、`rust/crates/owl-agent-mcp` 与 `rust/shared/contracts/` 是 Owltype 自有代码，
  不属于上游提取范围。
- **rmcp（MCP 官方 Rust SDK）** —— <https://github.com/modelcontextprotocol/rust-sdk>（Apache-2.0）
  固定 `=3.8.0`（crates.io），编入 `Owltype.app/Contents/Helpers/owltype-mcp`。该辅助程序编入的全部
  crates.io 依赖、版本与许可见 [`rust/crates/owl-agent-mcp/THIRD-PARTY-CRATES.md`](rust/crates/owl-agent-mcp/THIRD-PARTY-CRATES.md)
  （由 `scripts/owl-agent-mcp-licenses.py` 从 `rust/Cargo.lock` 生成，门禁核对；均为 MIT 或 Apache-2.0 可选许可），
  随对应源码归档分发；MIT 与 Apache-2.0 原文随 App 保存在 `Contents/SharedSupport/licenses`。
- **完整官方拼音、五笔、英文与上下文资源** —— 固定 `dict-v2.0.39`，来源、大小、摘要和逐项许可见
  [`msime-resources-NOTICE.md`](data/msime-resources-NOTICE.md)。生产拼音、独立五笔 86/98 码表、英文和 bigram/trigram 均原样交付。
- **chinese-ime-lm reference crate** —— <https://github.com/metasequoiaime/chinese-ime-lm>（Apache-2.0）
  Owltype 仅 vendored 上游 `reference/` 子树到 `rust/crates/chinese-ime-lm`，固定于
  `15caab4fdeb59c11f452b91884371cf30e2e5608`。该子树的 `Cargo.toml` 声明 Apache-2.0，
  许可证原文逐字保存在 [`rust/crates/chinese-ime-lm/LICENSE`](rust/crates/chinese-ime-lm/LICENSE)
  （Git blob `d645695673349e3947e8e5ae42332d0ac3164cd7`，SHA-256
  `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`）。上游项目根目录及其
  未 vendor 的训练脚本不在本源码 crate 的许可证声明范围内。
- **chinese-ime-lm 模型权重** —— [`model-v1`](https://github.com/metasequoiaime/chinese-ime-lm/releases/tag/model-v1)
  （Apache-2.0）。模型权重与上述源码 crate 是独立许可证据，不共用许可证文件。固定 keyboard
  与 settled 两个 safetensors，训练语料为 C4 中文部分（ODC-BY）与 LCCC（MIT）；署名随权重元数据和
  [`NOTICE`](resources/licenses/chinese-ime-lm-model-NOTICE.txt) 一同保留。
- **msime-others.db（派生 emoji 与颜文字目录）** ——
  [`dict-v2.0.39`](https://github.com/metasequoiaime/msime-dictionary/releases/tag/dict-v2.0.39)，
  固定大小 1,314,816 字节、SHA-256
  `9f3cae5b407038e0e4536c40582a0bc0feb732657f0ae2d38196374cede52f94`。发布清单记录的
  msime 构建器提交为 `8bb181be2ed36ed9559a87434cc4c9048077ff29`，msime-dictionary
  数据提交为 `75978c6a6470171cc805c74e87ef465d894a7be4`。Owltype 不发布该多来源
  整包，只在生成 seed 时保留 `emoji`、`emoji_pinyin`、`kaomoji` 与
  `kaomoji_catalog` 四表。中文关键词来自
  rime-ice（GPL-3.0-only，固定提交 `9e66b072…`），英文名称来自 Unicode Emoji
  17.0、CLDR annotations 与 Emoji 1.0 names（Unicode-3.0），多音词读音覆盖表
  由 mozillazg/python-pinyin 0.55.0 `lazy_pinyin` 生成（MIT）。发布清单、构建
  代码、输入文件摘要与许可证原文的定位见
  [`msime-others-NOTICE.txt`](data/msime-others-NOTICE.txt)。颜文字来自
  aoguai/rime_kaomoji_dict（MIT，Copyright (c) 2023 aoguai），许可证原文保留为
  [`rime-kaomoji.LICENSE`](licenses/rime-kaomoji.LICENSE)。固定 release 中的
  `kaomoji` 1,675 行、`kaomoji_catalog` 1,400 行原样保留，逐表 canonical row
  SHA-256 见上述 notice 与 `scripts/fetch-msime-others.py`；交付检查复用相同契约。
  未确认再分发许可的 PiliApp `symbol_catalog` 及其他表仍被排除。

## 内置数据与方案 Bundled data & schemas

- 雾凇拼音 rime-ice —— <https://github.com/iDvel/rime-ice>
- **水杉官方五笔 86 / 98 码表** —— 固定 `dict-v2.0.39/msime-wubi.db`，
  SHA-256 `54ee94799d8e33d5356468bdae164d21f68ce8ca0de9e6464ed4b3783924b93c`。
  两表包含原表与水杉补充词组，保留官方权重与 rowid 顺序；不再由 Owl 极点原表覆盖。
  极点 86 基础编码来自 [KyleBing/rime-wubi86-jidian](https://github.com/KyleBing/rime-wubi86-jidian)
  （Apache-2.0）；98 原表来自 [98wubi-tables](https://github.com/yanhuacuo/98wubi-tables)
  固定 `6b8b6fb9d3c34e0d5e3b17211e1f1c100e7eb697`（Unlicense），另含 Fcitx
  `dbc7154a7f0b9fc04313160ae8066ed4d8cbc446`（GPL-3.0-or-later）补充。
  水杉生成词组依据 rime-ice、人工词条、另一版五笔表及区划名称（GPL-3.0、WTFPL 等）。
  各项出处与许可保留在 [上游完整声明](data/msime-upstream-licensing-NOTICE.md)，
  极点原始许可证继续随 seed 交付为 `wubi86-jidian.LICENSE`。
- OpenCC 简繁转换数据 —— <https://github.com/BYVoid/OpenCC>（Apache-2.0）
  公开 seed 只携带转换表与配置，不链接或分发 libopencc。

各组件的完整许可条款见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## 与鼠须管并存 Coexistence

Owltype 使用独立身份，与已安装的鼠须管互不干扰；对鼠须管的任何文件与配置**只读**，绝不修改。

| 项 | 鼠须管 Squirrel | 猫头鹰 Owltype |
| --- | --- | --- |
| Bundle ID | `im.rime.inputmethod.Squirrel` | `im.owltype.inputmethod.Owltype` |
| 安装位置 | `/Library/Input Methods/Squirrel.app` | `/Library/Input Methods/Owltype.app` |
| 数据根 | `~/Library/Rime` | `~/Library/Application Support/Owltype` |

## 许可 License

GPLv3（见 [`LICENSE.txt`](LICENSE.txt)）。分发基于本项目的二进制时，必须一并提供对应的修改源码、
GPLv3 许可证文本与版权声明，不得作为闭源制品分发。

## Owltype App business core

`rust/crates/owl-app-core` and `rust/crates/owl-app-ffi` are original Owltype
code under GPL-3.0-only, separate from the fixed Metasequoia imports. They use
the workspace-pinned serde/serde_json dependencies already in the source lockfile.
Their sources and C header are part of the tracked corresponding-source inputs.
The template module also uses the existing lockfile's `regex`, `unicode-segmentation`
(MIT OR Apache-2.0) and ICU4X `icu_normalizer` (Unicode-3.0). Grapheme segmentation
preserves cursor boundaries; NFC comparison preserves Swift's canonical string equality
without rewriting authored template text or inserted values. No fixed upstream source is changed.

Library journals use `base64` 0.22 (MIT OR Apache-2.0) to preserve Foundation Data
encoding and workspace `sha2` (MIT OR Apache-2.0) for existing snapshot digests.
Storage/backup/migration modules are original Owltype code; native Foundation operations
are injected services, while Rust owns write authorization, phases and recovery.
