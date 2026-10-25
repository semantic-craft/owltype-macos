# 来源与许可 · Provenance

猫头鹰输入法 Owltype 是自由软件，以 **GPLv3** 许可，是以下上游项目的派生作品。此文件完整记录其来源
脉络。README 首屏聚焦产品体验，来源细节收在此文件与 README 文末「来源与许可」段落——降位不抹除。

## 上游来源 Upstream sources

- **鼠须管 Squirrel** —— <https://github.com/rime/squirrel>（GPLv3）
  Owltype 的 macOS IMK 前端复用并精简自鼠须管的输入热路径。候选窗 / 设置 / 引导 / 表情符号面板由
  SwiftUI 重做，运行时身份、数据根与安装位置全部改为 Owltype（见下方「与鼠须管并存」）。
- **librime** —— <https://github.com/rime/librime>（BSD-3 / 组件各自许可）
  输入引擎。Owltype 不重写 librime，将其与数据自包含进 `Owltype.app`。
- **RIME / 中州韻输入法引擎** —— <https://rime.im>
- **水杉输入法 Metasequoia IME (`msime`)** —— <https://github.com/metasequoiaime/msime>（GPLv3）
  Rust 输入引擎与运行时 crate（`rust/crates/`，经窄 C-ABI 静态链接入 `Owltype.app`），以及配套语言模型库
  `chinese-ime-lm`（<https://github.com/metasequoiaime/chinese-ime-lm>，GPLv3）。

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
  许可证原文逐字保留在 [`licenses/wubi86-jidian.LICENSE`](licenses/wubi86-jidian.LICENSE)。
- OpenCC 简繁转换等

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
