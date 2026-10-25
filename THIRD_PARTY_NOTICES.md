# 第三方组件与许可证（猫头鹰输入法 macOS）

猫头鹰输入法 macOS 版是 **rime/squirrel（鼠须管）** 的派生作品（fork）。它打包并依赖以下第三方组件。
本文件汇总许可证归属；各组件的完整许可证文本以其上游仓库为准。

## 直接派生 / 上游基座

| 组件 | 角色 | 许可证 | 上游 |
|---|---|---|---|
| **Squirrel（鼠须管）** | 本项目 fork 的基座（IMK 输入法 app、候选窗、Rime 部署） | **GPL-3.0**（见 `LICENSE.txt`） | https://github.com/rime/squirrel |
| **librime（中州韵）** | 输入引擎核心（C++，预编译 universal dylib + 头文件子模块） | **BSD-3-Clause**（"Copyright (c) 2014, RIME Developers"） | https://github.com/rime/librime |
| **水杉输入法（Metasequoia IME / msime）** | Rust 输入引擎核心与运行时（`rust/crates/`，pin `09e3d53c16eb11420bef708c35d425c31eff41e2`） | **GPL-3.0** | https://github.com/metasequoiaime/msime |
| **chinese-ime-lm reference crate** | 中文输入法语言模型参考库（`rust/crates/chinese-ime-lm`；仅 vendored 上游 `reference/`，pin `15caab4fdeb59c11f452b91884371cf30e2e5608`） | **Apache-2.0**；许可证原文见 [`rust/crates/chinese-ime-lm/LICENSE`](rust/crates/chinese-ime-lm/LICENSE)，SHA-256 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` | https://github.com/metasequoiaime/chinese-ime-lm |

> 因基座为 GPL-3.0：**分发本 fork 的二进制时，必须提供对应修改源码、GPL-3.0 许可证文本、版权声明与构建说明，
> 不得作为闭源制品分发。**

## 打包进 app 的运行时组件

| 组件 | 角色 | 许可证（以上游为准） | 上游 |
|---|---|---|---|
| **librime 插件**：librime-lua / librime-octagram / librime-predict | 雾凇拼音 rime_ice 等方案的 Lua / 语言模型 / 预测能力 | **BSD-3-Clause**（三者上游 `LICENSE`） | [librime-lua](https://github.com/hchunhui/librime-lua) / [librime-octagram](https://github.com/lotem/librime-octagram) / [librime-predict](https://github.com/rime/librime-predict) |
| **rime-octagram-data（八股文 gram）** | 雾凇拼音 `rime_ice` 启用的简体语法模型数据 `zh-hans-t-essay-bgw.gram`（octagram 插件加载，整句加权） | **LGPL-3.0**（见上游 `LICENSE`） | https://github.com/lotem/rime-octagram-data |
| **OpenCC** | 简繁转换数据与库（`SharedSupport/opencc`） | **Apache-2.0** | https://github.com/BYVoid/OpenCC |
| **Sparkle** | 更新检查与签名 package 安装框架；基于固定官方版本构建，应用重开补丁见 `patches/sparkle/` | **MIT**（含其依赖各自许可） | https://github.com/sparkle-project/Sparkle |
| **plum 配方 / 预置方案与词库** | `SharedSupport` 中的 base 配置与词典 | 各方案/词库上游许可（多为 GPL-3.0 / LGPL / CC，以来源为准） | https://github.com/rime/plum |
| **rime-ice（雾凇拼音）** | Owltype 自包含 seed（`data/owl-rime` → `SharedSupport`）的**拼音底座**：rime_ice 全拼方案 / cn_dicts / en_dicts / Lua / OpenCC / default.yaml | **GPL-3.0**（打包保留 `rime-ice.LICENSE`） | https://github.com/iDvel/rime-ice |
| **jieba（结巴分词）** | 公开种子词库 `cn_dicts/owltype_base.dict.yaml` 的词表与词频来源（`jieba/dict.txt`，pin tag `v0.42.1`） | **MIT**（打包保留 `jieba.LICENSE`） | https://github.com/fxsjy/jieba |
| **phrase-pinyin-data** | owltype_base 的词语注音来源（**仅用 MIT 的 `pinyin.txt`**；`large_pinyin.txt` / `cc_cedict.txt` / `zdic_*` 因 CC BY-SA / 爬取来源明确排除） | **MIT**（打包保留 `phrase-pinyin-data.LICENSE`） | https://github.com/mozillazg/phrase-pinyin-data |
| **rime-wubi86-jidian（极点五笔86）** | Owltype seed 的**五笔全套** overlay：`wubi86_jidian` / `_pinyin` / `_trad` / `_trad_pinyin` 方案、反查依赖 `pinyin_simp`、`numbers` 与 Lua；生产 `msime-pinyin.db:wubi86` 也直接导入该项目的 `wubi86_jidian.dict.yaml`（固定 commit `a194fb8b…`，词典 SHA-256 `8ccf1358…`） | **Apache-2.0**；许可证原文见 [`licenses/wubi86-jidian.LICENSE`](licenses/wubi86-jidian.LICENSE)，生成 seed 时校验 SHA 并保留 `wubi86-jidian.LICENSE` | https://github.com/KyleBing/rime-wubi86-jidian |
| **chinese-ime-lm 模型权重（keyboard / settled）** | `model-v1` 发布的两个固定 safetensors：逐键候选重排与输入停顿后的候选重排。权重许可与项目代码许可分开；文件内保留 C4（ODC-BY）与 LCCC（MIT）的训练语料署名 | **Apache-2.0**（见 [`resources/licenses/chinese-ime-lm-model-Apache-2.0.txt`](resources/licenses/chinese-ime-lm-model-Apache-2.0.txt) 与 [`NOTICE`](resources/licenses/chinese-ime-lm-model-NOTICE.txt)） | https://github.com/metasequoiaime/chinese-ime-lm/releases/tag/model-v1 |

## 说明

- 上表中标「以上游为准」处，未在本文件内逐字复制许可证，避免转述失真；分发前请核对各上游 LICENSE 原文并随附。
- 本 fork 对 Squirrel 的修改清单见本仓 `README.md` 与 git 历史。
- 猫头鹰自有部分（`sources/Owl*.swift`、`scripts/*`、深大红配色）随本项目许可；与上游 GPL-3.0 基座一并分发时，
  整体须满足 GPL-3.0 的传染性要求。
