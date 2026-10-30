# 第三方组件与许可证（猫头鹰输入法 macOS）

猫头鹰输入法 macOS 版的前端历史上派生自 **rime/squirrel（鼠须管）**。自 2.1.0 起，
输入核心改为 **Metasequoia IME（msime）Rust 引擎**；公开 App 不再打包或动态链接 librime、
librime Lua 插件或 plum。本文件按当前二进制实际携带的内容汇总许可证归属。

## 直接派生 / 上游基座

| 组件 | 角色 | 许可证 | 上游 |
|---|---|---|---|
| **Squirrel（鼠须管）** | 本项目 fork 的基座（IMK 输入法 app、候选窗、Rime 部署） | **GPL-3.0**（见 `LICENSE.txt`） | https://github.com/rime/squirrel |
| **librime（中州韵）** | 历史输入引擎基座；2.1.0 起不在公开 App 运行时中 | **BSD-3-Clause**（"Copyright (c) 2014, RIME Developers"） | https://github.com/rime/librime |
| **水杉输入法（Metasequoia IME / msime）** | Rust 输入引擎核心与运行时（`rust/crates/`，pin `208c10e848bbed99373ca8b609fd2142b6b0b4e2`） | **GPL-3.0** | https://github.com/metasequoiaime/msime |
| **chinese-ime-lm reference crate** | 中文输入法语言模型参考库（`rust/crates/chinese-ime-lm`；仅 vendored 上游 `reference/`，pin `15caab4fdeb59c11f452b91884371cf30e2e5608`） | **Apache-2.0**；许可证原文见 [`rust/crates/chinese-ime-lm/LICENSE`](rust/crates/chinese-ime-lm/LICENSE)，SHA-256 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` | https://github.com/metasequoiaime/chinese-ime-lm |

> 因基座为 GPL-3.0：**分发本 fork 的二进制时，必须提供对应修改源码、GPL-3.0 许可证文本、版权声明与构建说明，
> 不得作为闭源制品分发。**

## 打包进 app 的运行时与数据组件

| 组件 | 角色 | 许可证（以上游为准） | 上游 |
|---|---|---|---|
| **OpenCC 数据** | 简繁转换表与配置（`SharedSupport/opencc`；不链接 libopencc） | **Apache-2.0** | https://github.com/BYVoid/OpenCC |
| **Sparkle** | 更新检查与签名 package 安装框架；基于固定官方版本构建，应用重开补丁见 `patches/sparkle/` | **MIT**（含其依赖各自许可） | https://github.com/sparkle-project/Sparkle |
| **rime-ice（雾凇拼音）** | Owltype 自包含 seed（`data/owl-rime` → `SharedSupport`）的方案配置底座：rime_ice schema / Lua 辅助脚本 / OpenCC 配置 / default.yaml；公开 seed 不含其 cn_dicts 或 en_dicts | **GPL-3.0**（打包保留 `rime-ice.LICENSE` 与 Credits） | https://github.com/iDvel/rime-ice |
| **jieba（结巴分词）** | 公开种子词库 `cn_dicts/owltype_base.dict.yaml` 的词表与词频来源（`jieba/dict.txt`，pin tag `v0.42.1`） | **MIT**（打包保留 `jieba.LICENSE`） | https://github.com/fxsjy/jieba |
| **phrase-pinyin-data** | owltype_base 的词语注音来源（**仅用 MIT 的 `pinyin.txt`**；`large_pinyin.txt` / `cc_cedict.txt` / `zdic_*` 因 CC BY-SA / 爬取来源明确排除） | **MIT**（打包保留 `phrase-pinyin-data.LICENSE`） | https://github.com/mozillazg/phrase-pinyin-data |
| **rime-wubi86-jidian（极点五笔86）** | 水杉官方 `msime-wubi.db:wubi86` 的基础码表来源；正式资源保留水杉补充词组与词频 | **Apache-2.0**；许可证原文随 seed 以 `wubi86-jidian.LICENSE` 保留并校验 SHA-256 | https://github.com/KyleBing/rime-wubi86-jidian |
| **msime-dictionary 完整拼音、五笔与英文、上下文统计** | `dict-v2.0.39`；完整拼音、独立五笔 86/98 与英文表、bigram/trigram 均原样随产品可用。固定 manifest、每个文件的大小/摘要和源 notice 见 [`data/msime-resources-NOTICE.md`](data/msime-resources-NOTICE.md) | GPL-3.0、MIT、SCOWL、CC-BY-SA-4.0 等逐项许可，原文随 seed 保留；不据源代码 GPL 推导数据许可 | https://github.com/metasequoiaime/msime-dictionary/releases/tag/dict-v2.0.39 |
| **LaTeX 符号码表** | 固定 msime 源码 `plugins/phrase_table/latex-symbols/symbols.tsv`，编入引擎 | MIT，版权与许可证原文随 seed 保留 | https://github.com/metasequoiaime/msime |
| **msime-others.db：emoji / emoji_pinyin / kaomoji / kaomoji_catalog** | 由固定 msime release 派生的 emoji 与颜文字目录；中文关键词来自固定 rime-ice 提交的 emoji map，英文名使用 Unicode Emoji 17.0、CLDR 标注与 Emoji 1.0 名称；多音词读音覆盖表由 python-pinyin 0.55.0 `lazy_pinyin` 生成 | **GPL-3.0-only**（rime-ice）、**Unicode-3.0**（Unicode 数据）与 **MIT**（python-pinyin，打包保留 `python-pinyin.LICENSE`）；颜文字来自 aoguai/rime_kaomoji_dict（MIT，保留 `rime-kaomoji.LICENSE`）；不包含 PiliApp 符号表 | https://github.com/iDvel/rime-ice/tree/9e66b0729083b37d217312294f6d516c8d7234be ； https://unicode.org/Public/emoji/17.0/ ； https://github.com/mozillazg/python-pinyin/tree/v0.55.0 ； https://github.com/aoguai/rime_kaomoji_dict |
| **rmcp（MCP 官方 Rust SDK）及其依赖** | `Contents/Helpers/owltype-mcp`：供本机 Agent 以 stdio MCP 连接猫头鹰的辅助程序；rmcp 固定 `=3.8.0`，其余 crates.io 依赖逐项见 `rust/crates/owl-agent-mcp/THIRD-PARTY-CRATES.md` | **Apache-2.0**（rmcp）；依赖为 MIT 或 Apache-2.0 可选许可，原文见 `SharedSupport/licenses` | https://github.com/modelcontextprotocol/rust-sdk |
| **chinese-ime-lm 模型权重（keyboard / settled）** | `model-v1` 发布的两个固定 safetensors：逐键候选重排与输入停顿后的候选重排。权重许可与项目代码许可分开；文件内保留 C4（ODC-BY）与 LCCC（MIT）的训练语料署名 | **Apache-2.0**（见 [`resources/licenses/chinese-ime-lm-model-Apache-2.0.txt`](resources/licenses/chinese-ime-lm-model-Apache-2.0.txt) 与 [`NOTICE`](resources/licenses/chinese-ime-lm-model-NOTICE.txt)） | https://github.com/metasequoiaime/chinese-ime-lm/releases/tag/model-v1 |

## 说明

- 上表中标「以上游为准」处，未在本文件内逐字复制许可证，避免转述失真；分发前请核对各上游 LICENSE 原文并随附。
- `msime-others.db` 是 Owltype 从固定 release 派生的 emoji 与颜文字目录，只含 `emoji`、`emoji_pinyin`、`kaomoji` 与 `kaomoji_catalog`。上游整包仍标记 `NOASSERTION`，但其 PiliApp `symbol_catalog` 和其他表不进入交付物；不得把上游整包的授权状态或内容写成已随 Owltype 发布。实际构建阶段、输入文件摘要与发布 manifest 位置记录在 `msime-others-NOTICE.txt`。
- 公开 App 不包含 librime 插件、plum 配方或 rime-octagram-data 的 `.gram` 文件；可选完整词包由
  App 首启后从固定上游下载，相关来源与许可由 dict-pack 清单另行记录。
- 本 fork 对 Squirrel 的修改清单见本仓 `README.md` 与 git 历史。
- 猫头鹰自有部分（`sources/Owl*.swift`、`scripts/*`、深大红配色）随本项目许可；与上游 GPL-3.0 基座一并分发时，
  整体须满足 GPL-3.0 的传染性要求。

`owl-app-core` 模板语义复用锁文件中的 `unicode-segmentation`（MIT OR Apache-2.0，
https://github.com/unicode-rs/unicode-segmentation）与 ICU4X `icu_normalizer`
（Unicode-3.0，https://github.com/unicode-org/icu4x）；随 Rust 依赖许可集合分发。
