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
  Rust 输入引擎与运行时 crate（`rust/crates/`，经窄 C-ABI 静态链接入 `Owltype.app`）。
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

## 内置数据与方案 Bundled data & schemas

- 雾凇拼音 rime-ice —— <https://github.com/iDvel/rime-ice>
- 极点五笔 86 —— <https://github.com/KyleBing/rime-wubi86-jidian>（Apache-2.0）
  生产 `msime-pinyin.db` 的 `wubi86` 表直接导入固定
  [`a194fb8b3ec41ef9dcf079d3a67876fa75f79135`](https://github.com/KyleBing/rime-wubi86-jidian/tree/a194fb8b3ec41ef9dcf079d3a67876fa75f79135)
  中的 `wubi86_jidian.dict.yaml`（SHA-256
  `8ccf1358b91028ed234bbe82647a0bcd0f554a8d5994042de28b146e517633e6`）。
  固定源文件共有 89,273 条数据行；89,272 条形状有效接受，其中 3 条重复以最高权重合并，
  去重后写入 89,269 条唯一记录，拒绝 1 条。拒绝项是第 7911 行 `\tcokg\t10\t全角空格`
  （文本列为空），不会被静默当作 Wubi 词条导入。
  许可证原文逐字保留为 seed 根目录的 `wubi86-jidian.LICENSE`；完整五笔方案由用户侧固定源拉取，
  不进入公开 App payload。
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
