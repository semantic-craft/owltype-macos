<div align="center">

<img src="Assets.xcassets/Owltype.appiconset/icon_128x128@2x.png" width="96" alt="猫头鹰输入法图标">

# 猫头鹰输入法 · Owltype

**好看、好打、好用。为日常输入与 AI 工作流打磨的开源 macOS Rust 输入法。**

水杉 Rust 输入引擎 · 全拼 / 双拼 / 五笔 86·98 / 中英混输 · 云端语音输入 · AI 联想与 Jev 选词 · 提示词快捷片段 · 四合一安装维护向导

[![Latest Release: 2.5.0](https://img.shields.io/badge/release-2.5.0-brightgreen)](https://downloads.responsay.com/owltype/releases/2.5.0/Owltype-2.5.0.dmg)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)](https://responsay.com/owltype/)
[![Apple Silicon + Intel](https://img.shields.io/badge/Apple_Silicon_%2B_Intel-Universal-grey)](#立即下载与安装)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE.txt)

### [📥 下载最新版 2.5.0 安装镜像（Owltype-2.5.0.dmg）](https://downloads.responsay.com/owltype/releases/2.5.0/Owltype-2.5.0.dmg)

[立即下载与安装](#立即下载与安装) · [为 AI 工作流设计](#为-ai-工作流设计) · [核心功能](#核心功能) · [安装与故障修复](#安装与故障修复) · [测试反馈](#项目与反馈) · [English](README.en.md)

</div>

---

## 立即下载与安装

> **系统要求**：macOS 14.0（Sonoma）及以上 · 原生支持 Apple Silicon（M 系列）与 Intel（Universal 双架构） · 已通过 Apple Developer ID 签名与公证（Notarized）。

| 下载项 | 适用场景 | 2.5.0 不可变直链 | 稳定最新别名 |
| --- | --- | --- | --- |
| **📥 猫头鹰安装器 DMG（推荐）** | 首次安装、版本升级、故障修复、彻底卸载（内置四合一图形化安装维护向导 `OwltypeInstaller.app`） | [**Owltype-2.5.0.dmg**](https://downloads.responsay.com/owltype/releases/2.5.0/Owltype-2.5.0.dmg) | [responsay.com/owltype/Owltype.dmg](https://responsay.com/owltype/Owltype.dmg) |
| **📦 标准安装包 PKG** | 系统标准安装器或批量部署 | [Owltype.pkg](https://downloads.responsay.com/owltype/releases/2.5.0/Owltype.pkg) | [responsay.com/owltype/Owltype.pkg](https://responsay.com/owltype/Owltype.pkg) |
| **🔄 覆盖更新包 PKG** | 已安装旧版时直接覆盖升级（保留词库与配置） | [Owltype-update.pkg](https://downloads.responsay.com/owltype/releases/2.5.0/Owltype-update.pkg) | [responsay.com/owltype/Owltype-update.pkg](https://responsay.com/owltype/Owltype-update.pkg) |

- **校验与构建溯源**：[SHA-256 校验清单](https://downloads.responsay.com/owltype/releases/2.5.0/OWLTYPE-FILE-MANIFEST.sha256) · [SPDX SBOM](https://downloads.responsay.com/owltype/releases/2.5.0/OWLTYPE-SBOM.spdx.json) · [构建溯源 Provenance](https://downloads.responsay.com/owltype/releases/2.5.0/OWLTYPE-APP-PROVENANCE.txt) · [最新发布元数据 `latest.json`](https://downloads.responsay.com/owltype/latest.json)
- **应用内自动更新**：已安装 `2.0.10` 及以上版本的用户，可直接在输入法菜单「关于 → 检查更新」升级（Sparkle 更新源：`https://downloads.responsay.com/owltype/v3/appcast.xml`）。

### 三步上手测试

1. 下载并打开 [**Owltype-2.5.0.dmg**](https://downloads.responsay.com/owltype/releases/2.5.0/Owltype-2.5.0.dmg)，双击运行「**猫头鹰安装器**」，点击「**安装输入法**」并完成 macOS 管理员授权。
2. 安装器会自动将输入法落盘至 `/Library/Input Methods/Owltype.app` 并在当前登录会话直接完成注册与激活。若系统提示启用，按安装器向导第 2 步点击「打开系统设置 → 键盘 → 输入法」勾选「**猫头鹰**」，向导检测到启用后会自动跳转完成页。
3. 打开猫头鹰设置页：在「**键盘输入**」选择拼音、双拼或五笔方案并确认准备随包内置的完整词库；日常打字完全在本机运行，需要语音转写或 AI 辅助时再到「**AI**」页面配置任一供应商密钥即可。

![猫头鹰候选窗](docs/screenshots/candidates.png)

---

## 项目缘起与定位

猫头鹰（Owltype）是一个围绕个人日常打字与 AI 协作习惯打磨的业余开源项目。

项目最初基于 **[RIME / 鼠须管（Squirrel）](https://github.com/rime/squirrel)** 起步；后来看到 **[水杉输入法（Metasequoia IME / `msime`）](https://github.com/metasequoiaime/msime)** 用纯 Rust 重构中文输入引擎与词库体系的设计，深受启发，因此自 `2.1.0` 起在核心输入引擎、SQLite 词库与重排模型上直接复用了水杉的成果，同时在 macOS 前端交互、快捷键与细节手感上保留了自己早期基于 RIME 开发和日常使用中养成的个人习惯，并顺手把平时高频用到的 `/` 命令上屏、提示词片段、云端语音转写和选区润色整合了进来。

> 💡 **如果你想要一款功能更完整、多语种与跨平台支持更全面的主力输入法，非常推荐直接前往下载上游的 [水杉输入法（Metasequoia IME / MSIME-Apple）](https://github.com/metasequoiaime/MSIME-Apple)**；如果你偏爱完整的 RIME 方案定制生态，也推荐直接使用经典的 **[鼠须管（Squirrel）](https://github.com/rime/squirrel)**。猫头鹰更多是服务于作者自身偏好与 AI 工作流习惯的个人探索项目，欢迎感兴趣的朋友下载把玩与交流。

---

## 为 AI 工作流设计

在 Codex、Claude Code、终端、编辑器与日常文档之间切换时，输入法针对高频细节做了专门优化：

| 你正在做的事 | 猫头鹰的设计 |
| --- | --- |
| 中文聊完需求，接着输入 `/` 命令 | 默认按 `/` 提交当前中文候选、切到英文并输出半角 `/`，直接继续输入命令；也可在设置中改回符号选单。 |
| 在终端或 Agent 中输入 `$` 名称 | `Shift + 4` 的货币候选把半角 `$` 放在首位，人民币符号 `¥` 仍可选。 |
| 在空组字下快速呼出 AI 写作面板 | 连续键入 `/ai` 或按 `⇧K` 直接呼出 AI 写作与对话面板，而连续输入 `//` 会原样保留斜杠，不误吞路径或注释。 |
| 在编辑器、终端和聊天窗口之间切换 | 按应用记忆中英文状态，支持配置指定应用默认英文、中文模式下使用英文标点，以及可选的中英自动间距。 |
| 反复给 Agent 发送同一套提示词结构 | 把长提示词保存为快捷片段，支持参数填空 `{argument}`、默认值、剪贴板 `{clipboard}`、日期时间与光标定位 `{cursor}`，先预览再插入。 |
| 希望不打开面板直接展开模板 | 开启自动展开后，输入 `;;` 开头的触发词立即展开（或输入大写 `K` + 触发词通过候选确认插入），支持按应用禁用。 |
| 已经在 Raycast 积累了 Snippets | 支持导入 Raycast JSON，逐项预览、自动转换动态字段并处理重复项与触发词冲突。 |
| 让本地 Agent 安全调用输入法能力 | 内置受控本地 Agent 桥接与 `owl-agent-mcp`（默认关闭），开启后校验对端签名并提供模板查询与文本预览投递。 |

![提示词快捷片段与 Raycast 导入](docs/screenshots/prompt-snippets.jpg)

### 把提示词变成随手可用的参数模板

在「快捷片段」中新建模板，将触发词设为 `;;review` 并开启自动展开：

```text
请审阅以下改动，重点关注 {argument name="关注点" default="正确性与边界条件"}。
先列出可复现的问题，再给出最小修复建议。

{clipboard}
```

复制待审阅代码后，在输入框键入 `;;review`，确认或修改参数即可预览并插入。模板也支持仅搜索或通过大写 `K` 前缀（如 `Kreview`）候选确认调用，普通拼音输入不会混入模板候选。

---

## 核心功能

### 1. 水杉 Rust 输入引擎与随包完整词库

- **多方案与混输支持**：内置全拼、小鹤双拼等双拼方案、极点五笔 86、五笔 98、拼音五笔混输、英文输入与中英混输，支持简入繁出。
- **随包完整 SQLite 词库与语义重排**：App 随包内置固定版本（`dict-v2.1.2`）的完整 SQLite 词库资源（拼音、五笔 86/98、英文、Emoji 与颜文字）以及双端语义重排模型（`keyboard-model.bin` 键盘同步重排与 `settled-model.bin` 停顿重排）。在首次引导或设置中确认后即可在本机事务化准备启用，跨版本升级自动回放保留个人学习词频与置顶词（默认 `⌃⇧P` 置顶）。
- **横向四标签键盘设置与候选定制**：「键盘输入」设置采用顶部横向四标签栏（`方案与状态` / `拼音设置` / `五笔设置` / `标点与习惯`）；默认竖排 4 候选、默认关闭五笔编码提示（可在「五笔设置」一键开启），候选方向、数量、字体与配色即时生效。

### 2. 云端语音输入（Voice ASR）与非激活语音胶囊

- **水杉单键语音手势与非激活胶囊 HUD**：对齐上游水杉 `msime` 单键手势（按住右 Option 键说话、松手即上屏，录音中按空格锁为免提模式，按 `Option + 其他键` 组合键自动退让），16kHz 单声道内存 WAV 直传云端识别接口；悬浮非激活语音胶囊实时展示声波振幅与转写状态，全程不抢占当前输入框焦点。
- **3 套云端 ASR 通道与热词自动注入**：内置 **OpenAI（`gpt-transcribe`）、Google Gemini（`gemini-3.5-transcribe`）与 OpenAI 账号登录（Codex CLI ChatGPT 听写）** 三套通道；录音时自动从用户置顶词、自定义短语与高频自学习词中提取个人热词（UTF-8 800B 预算），连同组字前上文注入识别提示，提升专有名词与中英混输识别准确率。
- **DeepSeek 语音后处理润色**：转写完成后可选经过 DeepSeek 非思考模式自动去除口水词、修正同音错字并补全标点；设有 4.0 秒硬超时与按录音代次隔离机制，网络异常或超时时无感降级直接上屏原始转写文本。

### 3. AI 联想、Jev 选词与 AI 写作辅助

- **云端生成式「AI 联想」**：单独开启后，打字停顿（300ms）时结合宿主组字前有界 UTF-16 上文与当前输入码，在候选窗首页末位异步追加带 `[AI]` 徽标的云端联想词条，继续打字时自动取消陈旧请求。
- **判别式「Jev 选词」**：打字停顿后基于上文语义，从当前本地候选列表中智能挑选最匹配词条提权至首位并挂载 `[Jev]` 徽标；严格限定在本地词表集合内选择，零词表外幻觉。
- **AI 写作面板与双候选多风格润色**：支持通过 `⇧K`、状态菜单或 `/ai` 呼出；内置「润色」（保持原意、更正式、更精简、扩写润色 4 种风格双候选对照，含字数变化徽标与 `[1]`/`[2]` 快捷键一键上屏）与 6 类场景「快捷回复」模板，通过「IMK 直插 → AX 选区写回 → 剪贴板粘贴回退」三级链路可靠写回宿主应用。
- **Kotone 选区回复建议（v1 契约）**：可选接入本地 Kotone 服务（见 [接入说明](docs/operations/jev-replies.md)），围绕选中文本给出判断与多条风格回复候选，支持非阻塞单调截止取消、生成中修改要求与显式复制，仅展示不自动填充或发送。

### 4. 选中文字就地处理（划词工具箱）

开启云端 AI 并授予辅助功能选区读取权限后，「划词工具箱」提供 8 项可独立开关的选区动作：

| 功能 | 用途 |
| --- | --- |
| **任意提问** | 围绕选中文字下指令或追问；开启联网搜索后先检索网页再带引用作答。 |
| **润色** | 改善选中文本表达，预览确认后替换原文。 |
| **翻译** | 翻译选中的中外文段落。 |
| **来源核验** | 提取选区中的法条、案例、文献线索，提供国家法律法规数据库、北大法宝、裁判文书网、人民法院案例库、知网等分组检索入口，并支持火山方舟 / DeepSeek 联网核验。 |
| **辅助检索** | 整理检索思路、关键词组合与查询线索。 |
| **提示词优化** | 将草稿提示词整理为目标、约束与输出结构清晰的提示词。 |
| **任务书** | 将模糊需求拆解为可执行任务书，标出缺失前提。 |
| **规范排版** | 整理中文空格、标点与段落格式，预览后确认替换。 |

### 5. 三卡片 AI 设置与供应商密钥复用

「AI」设置页收敛为三张清晰卡片，只用普通打字时无需配置任何密钥：

1. **模型供应商（配一个就行）**：内置 **通义千问（Qwen）、豆包（Doubao）、OpenAI、Google Gemini、DeepSeek** 五大核心预设（每行标注 `LLM · 语音识别`、`LLM · 联网搜索 · 语音润色` 等能力徽标），同时保留自定义 OpenAI 兼容端点接入与连通性测试。
2. **语音输入 · 云端语音识别**：支持 OpenAI、Google Gemini 与 OpenAI 账号登录（ChatGPT 听写）；当上方已配置 Gemini 或 OpenAI 模型供应商密钥时**自动联动复用**（显示「已复用供应商密钥」），也支持单独保存或清除语音专属 API Key；DeepSeek 语音润色同样自动回退复用已配置的 DeepSeek 供应商密钥。
3. **AI 能力与联网搜索**：集中管理候选词智能辅助（AI 联想 / 英文 AI 候选 / Jev 选词）、选区与写作工具（划词工具栏 / 自动朗读 / Kotone 回复建议）以及联网搜索与来源核验策略。

### 6. 九套学院配色与浮动状态栏

内置九套学院风主题配色，支持浅色、深色与跟随系统外观；提供与当前候选窗皮肤一致的浮动输入状态栏（中英、全半角、繁简与方案指示），以及剪贴板历史、表情与符号面板。

| 皮肤外观 | 键盘输入设置 |
| --- | --- |
| ![皮肤外观](docs/screenshots/skins.jpg) | ![键盘输入设置](docs/screenshots/keyboard-settings.jpg) |

<details>
<summary>查看香槟橙（燃橙）配色候选窗预览</summary>

![香槟橙（燃橙）皮肤下的候选窗](docs/screenshots/candidates-flame.png)

</details>

---

## 安装与故障修复

`Owltype-2.5.0.dmg` 内置独立的图形化安装维护器 **「猫头鹰安装器」（`OwltypeInstaller.app`）**。除了首次安装与版本升级外，打开安装器底部的「**故障修复与彻底卸载**」抽屉即可随时执行维护操作：

| 模式 | 作用与适用场景 | 用户数据（词库与配置） |
| --- | --- | --- |
| **安装 / 更新输入法** | 将随包 `Owltype.app` 提权安装至 `/Library/Input Methods/Owltype.app`，非阻塞收敛当前 IMK/TIS 会话并按状态引导启用。 | 完整保留 |
| **修复安装（保留词库与配置）** | 覆盖更新后遇到系统输入法列表未刷新、候选不显示或进程卡死时，重装应用并重新注册 LaunchServices / InputMethodKit 会话。 | 完整保留 |
| **清空修复（备份数据后重建）** | 先将个人词库、Rime/水杉用户目录与偏好设置完整备份至 `~/Library/Application Support/Owltype-Backups/<时间戳>/`，再清空运行态目录并全新重装。 | 自动备份至 `Owltype-Backups` 后重置 |
| **彻底卸载** | 从系统移除 `/Library/Input Methods/Owltype.app`、终止残留进程并注销输入源；可选择保留用户数据、备份后清理或直接彻底清理。 | 可选保留 / 备份后清理 / 彻底删除 |

**安装或升级后暂时打不出字？**
1. 先确认系统菜单栏输入法图标已切换为「猫头鹰」，并重新打开一次当前打字的目标应用窗口。
2. 若仍未响应，打开 `Owltype-2.5.0.dmg` 中的「猫头鹰安装器」，展开底部抽屉点击「**修复安装**」；仅在 macOS `imklaunchagent` 仍持有旧进程句柄未释放时，按提示注销并重新登录一次即可恢复。

---

## 最近更新（2.5.0）

完整变更历史见 [CHANGELOG.md](CHANGELOG.md)。

### 2.5.0（2026-11-10）
- **水杉引擎 `macos-v0.59.1` 与词库 `dict-v2.1.2` 升级**：同步上游水杉 Rust 引擎至 `macos-v0.59.1`、官方 SQLite 词库至 `dict-v2.1.2`；全部 Rust 业务与引擎接口合并为单一 `lib/libowl_msime_ffi.a` 通用静态库并直接读取随包 `Contents/SharedSupport/msime` SQLite 词库，彻底移除旧 Rime YAML/Lua/dict 种子管线，并在发布门禁直接校验主可执行文件的 Rust 符号。
- **设置交互整行热区、后台加载与非激活浮动面板**：统一 `.owlPlain` 整行点击热区（由 SwiftLint 强制守护），模板库、供应商密钥状态与诊断报告移至后台读取且不打断当前草稿，支持从菜单直接恢复已最小化的设置窗口；候选窗、状态栏、语音胶囊（鼠标穿透）与 Agent 投递面板统一继承 `OwlFloatingPanel` 非激活策略，永不抢占宿主输入框焦点。

### 2.4.3（2026-11-08）
- **水杉单键语音手势与三通道云端语音识别**：语音输入改为按住右 Option 键说话、松手即上屏（录音中按空格锁为免提，组合键自动退让），移除复杂组合键录制器；云端语音识别收敛为 OpenAI（`gpt-transcribe`）、Google Gemini（`gemini-3.5-transcribe`）与 OpenAI 账号登录（ChatGPT 听写）三套通道，并支持自动跟随已配密钥的 Gemini / OpenAI 供应商档案。
- **移除 Grok / xAI 预设与错误文案残留**：清理模型供应商与语音设置中的 Grok / xAI 预设，语音报错文案按当前激活语音通道动态展示。

### 2.4.2（2026-11-08）
- **四合一安装与维护向导（`OwltypeInstaller.app`）**：重构为仿微信输入法两步极简向导 + 底部维护抽屉，集成「安装 / 更新输入法」「修复安装（保留词库与配置）」「清空修复（备份用户数据后重建）」「彻底卸载」四项能力，并按 TIS 注册与启用状态精准分流引导文案。（#411）
- **非阻塞式安装落盘与 IMK 会话收敛**：移除覆盖安装前的 45 秒 `lsof` 阻塞式自检门禁，避免已落盘文件因后台句柄占用误报「安装失败」；补充 TIS 父级输入源递归注册与 macOS 14+ `TISSelectInputSource` 焦点窗口辅助激活。（#411）
- **键盘设置横向四标签栏与默认体验对齐**：五笔编码提示关闭语义对齐水杉 `#10790` 并默认关闭；候选窗默认改为竖排 4 候选；键盘设置页底部折叠「高级」手风琴升级为顶部横向四标签栏（`方案与状态` / `拼音设置` / `五笔设置` / `标点与习惯`）。（#410）
- **Kotone 回复决策契约校验**：对含 `contract` 字段的响应严格校验场景、整数版本、请求/来源与构建字段，兼容旧服务并冻结 12 组回归样例。（#409）

### 2.4.1（2026-11-03）
- **三卡片 AI 设置与云端语音识别（ASR）**：整合三卡片 AI 设置与多通道云端 ASR 预设，支持语音识别与润色自动复用同厂商模型密钥。（#404）
- **语音代次隔离、上文边界与 `/ai` 指令修复**：按录音代次隔离已取消的陈旧语音回调，修复连续 `//` 斜杠保留、组合键缓冲刷新及 AI 候选有界 UTF-16 上文计算。（#401, #402）

### 2.4.0（2026-11-03）
- **AI 联想与 Jev 选词**：新增停顿触发的云端生成式 `[AI]` 联想候选与本地词表内判别式 `[Jev]` 语义提权。（#392, #395）
- **语音输入与个人热词注入**：新增非激活语音胶囊 HUD、个人词库热词自动提取注入与 DeepSeek 语音后处理润色。（#393, #396, #398）
- **AI 写作面板与双候选多风格润色**：新增 `/ai` 与 `⇧K` 呼出、4 种风格双候选对照润色、6 类快捷回复模板与一键上屏写回链路。（#394, #397）

---

## 隐私边界

- **日常打字完全留在本机**：按键、组字、候选排序、词库管理与快捷片段展开均在本机完成，不自动上传任何输入内容。
- **云端 AI 与语音默认关闭**：仅在你主动开启并触发语音录音、划词工具、AI 写作面板，或单独勾选可选的「AI 候选（AI 联想 / Jev 选词）」时，才会向你所配置的供应商发起请求。
- **严格的上下文边界**：划词与写作请求仅包含你主动提交的指令、明确选中的文本及当前面板对话记录；开启「AI 候选」或「语音热词」时仅附带当前组字编码、组字前有界上文（UTF-16 预算截断）与本地高频热词，绝不采集屏幕截图、无关窗口或浏览器历史。
- **密钥存入系统 Keychain**：所有供应商与语音 API Key 均存储在 macOS Keychain 中，不写入明文配置文件。

详见 [PRIVACY.md](PRIVACY.md)。如发现安全问题，请按 [SECURITY.md](SECURITY.md) 指引报告。

---

## 项目与反馈

- **安装包下载**：[项目主页与下载中心](https://responsay.com/owltype/) · [直接下载 Owltype-2.5.0.dmg](https://downloads.responsay.com/owltype/releases/2.5.0/Owltype-2.5.0.dmg) · [直接下载 Owltype.pkg](https://downloads.responsay.com/owltype/releases/2.5.0/Owltype.pkg)
- **问题反馈与功能建议**：[GitHub Issues](https://github.com/semantic-craft/owltype-macos/issues)。提交测试反馈时，请注明 **猫头鹰版本号（如 2.5.0）**、**macOS 版本与芯片型号**、**出现问题的宿主应用** 以及 **复现步骤**。
- **项目进度看板**：[输入对齐与交付进度页](progress/index.html)
- **Windows 版**：[semantic-craft/owltype-win](https://github.com/semantic-craft/owltype-win)（独立仓库维护，版本号与发布资产不与 macOS 版自动同步）。

---

## 来源、致谢与许可

本项目遵循 **GPL-3.0** 许可证，全文见 [LICENSE.txt](LICENSE.txt)。

猫头鹰站在众多优秀的开源输入法、词库与工具项目的肩膀上才得以完成。前端早期派生自 [鼠须管（Squirrel）](https://github.com/rime/squirrel) 与 [librime](https://github.com/rime/librime)；自 `2.1.0` 起输入引擎切换为 [水杉输入法（Metasequoia IME）](https://github.com/metasequoiaime/msime) Rust 引擎（当前固定上游引擎基线 `macos-v0.59.1`、词库基线 `dict-v2.1.2`），公开分发的 App 不再打包或链接 `librime`。完整来源脉络与提取边界见 [PROVENANCE.md](PROVENANCE.md)，第三方组件与词库逐项授权说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

在此向以下全部上游项目、词库维护者与开源社区致以诚挚感谢：

### 1. 输入引擎与前端基座

- **[水杉输入法（Metasequoia IME / `msime`）](https://github.com/metasequoiaime/msime) & [MSIME-Apple](https://github.com/metasequoiaime/MSIME-Apple)**（GPL-3.0）：直接启发了本项目向 Rust 架构的演进，并提供核心 Rust 输入引擎、整句解码器与运行时底座。想要体验原汁原味且功能更全面的版本，请直接访问并下载 [水杉输入法](https://github.com/metasequoiaime/MSIME-Apple)。
- **[chinese-ime-lm](https://github.com/metasequoiaime/chinese-ime-lm)**（Apache-2.0）：水杉中文输入法神经网络重排语言模型与参考库，以及基于 C4 中文语料（ODC-BY）与 LCCC 语料（MIT）训练的逐键与停顿重排模型权重（`model-v1`）。
- **[鼠须管（Squirrel）](https://github.com/rime/squirrel)**（GPL-3.0）：本项目 macOS InputMethodKit 前端的起点与派生基座。
- **[RIME / 中州韻输入法引擎（librime）](https://github.com/rime/librime)**（[rime.im](https://rime.im)，BSD-3-Clause）：项目早期的输入引擎基座，塑造了本项目一直延续至今的输入方案设计和操作手感。

### 2. 词库、码表与语言数据

- **[水杉词库（msime-dictionary）](https://github.com/metasequoiaime/msime-dictionary)**（`dict-v2.1.2`）：提供随包内置的拼音、五笔 86/98、英文、Emoji 与颜文字 SQLite 词库及上下文统计表构建。
- **[雾凇拼音（rime-ice，iDvel）](https://github.com/iDvel/rime-ice)**（GPL-3.0）：现代拼音词库、单字与长词词频、英文补充词表、Emoji 映射与 Lua 方案生态的核心上游来源。
- **[极点五笔 86（KyleBing/rime-wubi86-jidian）](https://github.com/KyleBing/rime-wubi86-jidian)**（Apache-2.0）：86 版五笔基础单字与词组码表来源。
- **[98 五笔码表（yanhuacuo/98wubi-tables · 98五笔小组）](https://github.com/yanhuacuo/98wubi-tables)**（Unlicense）与 **[fcitx5-table-extra](https://github.com/fcitx/fcitx5-table-extra)**（GPL-3.0-or-later）：98 版五笔基础与补充码表来源。
- **小鹤双拼 / 小鹤音形**：双拼键位布局与形码辅助规则参考。
- **[OpenCC（开放中文转换，BYVoid）](https://github.com/BYVoid/OpenCC)**（Apache-2.0）：简繁转换词表与配置。
- **[结巴分词（fxsjy/jieba）](https://github.com/fxsjy/jieba)**（MIT）、**[mozillazg/pinyin-data](https://github.com/mozillazg/pinyin-data)**（MIT）、**[mozillazg/phrase-pinyin-data](https://github.com/mozillazg/phrase-pinyin-data)**（MIT）与 **[mozillazg/python-pinyin](https://github.com/mozillazg/python-pinyin)**（MIT）：清洁室基础种子词频、汉字读音校正与多音词注音数据。
- **[SCOWL（Kevin Atkinson, en-wl/wordlist）](https://github.com/en-wl/wordlist)**、**[Google 词频表（Peter Norvig）](https://www.norvig.com/ngrams/count_1w.txt)** 与 **[ECDICT（skywind3000）](https://github.com/skywind3000/ECDICT)**（MIT）：英文拼写词典、词频与候选释义来源。
- **[aoguai/rime_kaomoji_dict](https://github.com/aoguai/rime_kaomoji_dict)**（MIT）与 **[Unicode Emoji / CLDR](https://unicode.org/Public/emoji/17.0/)**（Unicode-3.0）：颜文字词典与 Emoji 英文名称标注来源。
- **[modood/Administrative-divisions-of-China](https://github.com/modood/Administrative-divisions-of-China)**（WTFPL）：中国行政区划全称与简称补充词条。
- **[中文维基百科（zhwiki dump）](https://dumps.wikimedia.org/zhwiki/)**（CC-BY-SA 4.0）：整句输入二元/三元（`bigram`/`trigram`）上下文统计语料来源。

### 3. 框架与协议组件

- **[Sparkle](https://github.com/sparkle-project/Sparkle)**（MIT）：macOS 应用内自动更新与签名校验框架。
- **[rmcp（Model Context Protocol 官方 Rust SDK）](https://github.com/modelcontextprotocol/rust-sdk)**（Apache-2.0）及 Rust 开源社区依赖（详见 [`THIRD-PARTY-CRATES.md`](rust/crates/owl-agent-mcp/THIRD-PARTY-CRATES.md)）：本地 Agent MCP 桥接辅助实现。
