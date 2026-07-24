# 来源与许可 · Provenance

法墨输入法 Famo 是自由软件，以 **GPLv3** 许可，是以下上游项目的派生作品。此文件完整记录其来源
脉络。README 首屏聚焦产品体验，来源细节收在此文件与 README 文末「来源与许可」段落——降位不抹除。

## 上游来源 Upstream sources

- **鼠须管 Squirrel** —— <https://github.com/rime/squirrel>（GPLv3）
  Famo 的 macOS IMK 前端复用并精简自鼠须管的输入热路径。候选窗 / 设置 / 引导 / 表情符号面板由
  SwiftUI 重做，运行时身份、数据根与安装位置全部改为 Famo（见下方「与鼠须管并存」）。
- **librime** —— <https://github.com/rime/librime>（BSD-3 / 组件各自许可）
  输入引擎。Famo 不重写 librime，将其与数据自包含进 `Famo.app`。
- **RIME / 中州韻输入法引擎** —— <https://rime.im>

## 内置数据与方案 Bundled data & schemas

- 雾凇拼音 rime-ice —— <https://github.com/iDvel/rime-ice>
- 极点五笔 86 —— <https://github.com/KyleBing/rime-wubi86-jidian>
- OpenCC 简繁转换等

各组件的完整许可条款见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## 与鼠须管并存 Coexistence

Famo 使用独立身份，与已安装的鼠须管互不干扰；对鼠须管的任何文件与配置**只读**，绝不修改。

| 项 | 鼠须管 Squirrel | 法墨 Famo |
| --- | --- | --- |
| Bundle ID | `im.rime.inputmethod.Squirrel` | `im.famo.inputmethod.Famo` |
| 安装位置 | `/Library/Input Methods/Squirrel.app` | `/Library/Input Methods/Famo.app` |
| 数据根 | `~/Library/Rime` | `~/Library/Application Support/Famo` |

## 许可 License

GPLv3（见 [`LICENSE.txt`](LICENSE.txt)）。分发基于本项目的二进制时，必须一并提供对应的修改源码、
GPLv3 许可证文本与版权声明，不得作为闭源制品分发。
