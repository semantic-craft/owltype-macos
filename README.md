<div align="center">

<img src="Assets.xcassets/Owltype.appiconset/icon_128x128@2x.png" width="96" alt="猫头鹰输入法图标">

# 猫头鹰输入法 · Owltype

**好看、好打、好用。为 AI 工作流打磨的开源 Rime 输入法。**

macOS 原生界面 · 拼音 / 双拼 / 五笔 · 提示词快捷片段 · Raycast 导入

**深圳大学法律人工智能实训实验室**

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)](https://responsay.com/owltype/)
[![Apple Silicon + Intel](https://img.shields.io/badge/Apple_Silicon_%2B_Intel-Universal-grey)](#快速开始)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE.txt)

[下载与安装](#快速开始) · [AI 工作流](#为-ai-工作流设计) · [功能](#功能) · [界面](#界面) · [项目与反馈](#项目与反馈)

[项目主页](https://responsay.com/owltype/) · [English](README.en.md)

</div>

猫头鹰（Owltype）是一款基于 **Rime** 的开源 macOS 中文输入法。用中文向 agent 描述任务，接着输入 `/` 命令、`$` skill 名称，再插入一段常用提示词——我们把这些每天反复发生的小动作，做进了输入法。

原生 SwiftUI 候选窗与九套学院配色，让输入看起来舒服；拼音、双拼、五笔和中英混输，让熟悉的输入习惯继续顺手。日常输入与快捷片段在本机处理，可选云端 AI 由你配置并明确触发。

我们已经实际使用了两三个月，并经过小范围内测，现在开放的是可以日常稳定使用的版本。**安装完成后需要注销并重新登录一次**，让 macOS 正确加载输入法。

> 🦉 **开发仓库为私有，安装包与已发布版本的对应源码仍公开提供。** [下载安装](https://responsay.com/owltype/) · [获取版本源码](https://responsay.com/owltype/source.tar.gz)

![猫头鹰候选窗](docs/screenshots/candidates.png)

## 为 AI 工作流设计

在 Codex、Claude Code 等 agent 与日常写作之间切换，输入法也应该懂这些小习惯。

| 你正在做的事 | 猫头鹰的小设计 |
| --- | --- |
| 中文聊完需求，接着输入 `/` 命令 | 默认按 `/` 提交当前中文候选、切到英文并输出半角 `/`，继续输入命令；也可在设置中改回符号选单。 |
| 在 Codex 中输入 `$` skill 名称 | `Shift + 4` 的货币候选把半角 `$` 放在第一位，人民币符号 `¥` 仍可选。 |
| 在编辑器、终端和聊天窗口之间切换 | 按应用记忆中英文状态，也可指定应用默认英文；支持中文下使用英文标点与可选的中英间距。 |
| 反复给 agent 写同一套要求 | 把长提示词保存为快捷片段，按标题、正文、标签或触发词搜索，或通过候选确认插入。 |
| 同一提示词，每次换任务、语言和材料 | 动态模板支持参数填空、默认值、选项、剪贴板、日期时间及光标位置；先预览，再插入。 |
| 希望少开一次面板 | 开启自动展开后，用 `;;` 开头的触发词立即展开，或在分隔符后展开；可按应用禁用。 |
| 已经在 Raycast 积累了 Snippets | 导入 Raycast 基础 JSON，逐项预览、处理重复项和触发词冲突，把现有片段带进输入法。 |
| 需求还没想清楚就准备发给 AI | 划词调用「提示词优化」或「任务书」，整理目标、约束与缺失信息，再决定如何使用。 |

![提示词快捷片段与 Raycast 导入](docs/screenshots/prompt-snippets.jpg)

### 把提示词变成随手可用的模板

例如，在「快捷片段」新建一个模板，把触发词设为 `;;review`，选择自动展开，并开启「自动展开设置」：

```text
请审阅以下改动，重点关注 {argument name="关注点" default="正确性与边界条件"}。
先列出可复现的问题，再给出最小修复建议。

{clipboard}
```

复制待审阅内容后，在支持的输入框中输入 `;;review`，填写或确认参数，预览后插入。模板也可保存为仅搜索或候选确认调用；`{cursor}` 可指定插入后的光标位置，宿主无法安全定位时会提供降级提示。

**与 Raycast 配合：** 在「快捷片段 → 导入 Raycast JSON…」选择导出文件。支持的动态字段会按模板解析，不支持或有歧义的字段保留待处理，可修正后启用，或明确转为普通文本。这是本地导入，不是双向同步；两个工具中相同的自动触发词应只交给一方处理。自动展开仅在猫头鹰激活时工作，不会替你发送聊天消息。

## 功能

### ⌨️ 用熟悉的方式输入

全拼、小鹤双拼、极点五笔 86，以及简入繁出。候选数量、字体、横竖排、中英文初始状态和应用初始英文规则，都能在「键盘输入」与「候选窗设置」中调整。Rime 在本机维护用户词频与学习数据。

App 内置可独立启动的引擎与基础种子词库；完整词库通过应用从上游下载。首次下载需要网络，下载后的日常输入在本地运行。

### ✨ 选中文字，就地处理

「划词工具箱」提供八项功能，可分别启用。需要先开启云端 AI、配置供应商，并为读取选区授予所需的系统权限。

| 功能 | 用途 |
| --- | --- |
| 任意提问 | 围绕选中文字下指令、追问；配置搜索后可先检索再作答。 |
| 润色 | 改善表达，在预览后决定是否替换原文。 |
| 翻译 | 翻译选中的文本。 |
| 来源核验 | 从选区提取法条、案例、文献等线索，提供来源与检索入口。 |
| 辅助检索 | 整理检索思路、关键词与查询线索。 |
| 提示词优化 | 将提示词整理成更清楚的目标、约束与结构。 |
| 任务书 | 将模糊需求整理为可执行任务，标出缺失信息。 |
| 规范排版 | 整理中文空格、标点与段落，在预览后确认替换。 |

来源核验提供法规、案例、文献等分组入口，包括国家法律法规数据库、北大法宝、裁判文书网、人民法院案例库、知网等。联网核验用豆包搜索和 DeepSeek 内置联网搜索取回网页，对照判断并标注来源；需要在 设置 → AI 填写豆包搜索的 API Key，或配置 DeepSeek 供应商。检索入口与 AI 回答供你查阅原文，不等于已经取得数据库全文或完成事实核验。

### 🔌 模型与搜索分别配置

内置阿里云百炼、豆包、DeepSeek、MiniMax 等供应商预设，也可配置 OpenAI 兼容服务。按账户填写端点、模型与密钥，并通过连通性测试检查配置。

任意提问的联网搜索只走 DeepSeek 内置搜索（固定用 `deepseek-v4-pro`，Flash 不会真的搜索）：配好 DeepSeek 供应商即可，作答模型可以是别家。MiniMax 使用国内站（api.minimax.cn）的 M3.1-Flash 正式版，思考深度可调、不能关闭。

### 📋 常用内容随手可取

快捷片段把普通短语与长提示词放在同一处，提供「全部／提示词」筛选。剪贴板、表情与符号面板补齐日常输入；常用入口的快捷键集中在「快捷键设置」，不必修改配置文件。

### 🎨 原生设置与学院配色

九套学院风配色，支持浅色、深色与跟随系统。字体、布局、候选样式和动画可调整；皮肤选择即时生效。设置中还提供词库管理、同步目录、诊断与维护入口。

## 快速开始

**macOS 14 及以上 · Apple Silicon / Intel**

1. 从[官网下载安装器 DMG](https://responsay.com/owltype/Owltype.dmg)，打开其中的「猫头鹰安装器」，点击「安装」。macOS 可能请求管理员授权。
2. **安装完成后注销并重新登录一次。** 若系统询问是否允许启用输入法，选择允许；随后在系统输入法菜单中选择「猫头鹰」。若未出现，检查「系统设置 → 键盘 → 输入法」。
3. 在猫头鹰设置的「键盘输入」中选择方案，按引导准备词库，然后在新打开的文本应用中试打。
4. 需要 AI 时，再到「AI 配置」添加供应商，在「划词工具箱」启用所需功能。只用普通输入法无需配置模型。

**安装后打不出字？** 确认已注销并重新登录，再重新打开宿主应用，并检查系统输入法菜单是否选中了「猫头鹰」。

**更新：** 2.0.10 起在「关于 → 检查更新」获取后续版本，更新源为 `https://downloads.responsay.com/owltype/v3/appcast.xml`。旧版需先手动安装一次 2.0.10 或更新版本。[直接下载更新包](https://responsay.com/owltype/Owltype-update.pkg)。

**卸载：** 打开「猫头鹰安装器」选择「卸载」。卸载会清理猫头鹰的用户数据；需要保留个人词库或配置时先备份。

## 界面

设置截图来自 2.0.12 的隔离演示窗口，使用示例数据；候选窗为实际输入截图。具体控件以安装版本为准。

| 皮肤外观 | 键盘输入 |
| --- | --- |
| ![皮肤外观](docs/screenshots/skins.jpg) | ![键盘输入设置](docs/screenshots/keyboard-settings.jpg) |

<details>
<summary>查看另一套候选窗配色</summary>

![香槟橙（燃橙）皮肤下的候选窗](docs/screenshots/candidates-flame.png)

</details>

## 最近更新

**2.0.12 · 本仓库版本**

- **设置生效流程**：集中保存、编译与会话刷新，保留输入中的组字。
- **划词改写**：统一确认、取消和回填流程，取消后的结果不会继续预览或回填。
- **快捷片段筛选**：改用主题适配的中性底色与选中块，保留「全部／提示词」切换。

**2.0.11**

- **拼音中英混输**：修复完整词库下载或升级后，英文及中英混合候选通道没有接入的问题。
- **按应用记忆中英文**：返回应用时恢复上次选择，可管理和清除单个应用的记忆。
- **候选词置顶**：完整全拼候选支持置顶与取消，默认快捷键为 Control Shift P，并提供右键入口。
- **引导真实试打**：在原生输入框中完成「你好，猫头鹰」，核验组字与提交；粘贴不计入。
- **安装与介绍**：安装器选择本机实际可用的系统英文键盘；关于页只保留实验室署名，更新中英文项目介绍。

<details>
<summary>验收范围与上一版更新</summary>

中英混输及快捷置顶已有 TextEdit 实测；右键菜单、跨应用 Shift 切换和完整引导试打尚未完成实机验收。功能逻辑通过原生控制器与真实 Rime 集成测试，详见[设计与验收记录](docs/input-habits-design.md)。

**2.0.10（2026-10-01）** 新增 MiniMax M3.1 档案与国内站订阅搜索，并恢复更新通道。2.0.9 及更早版本需要手动安装一次 2.0.10 或更新版本，之后使用 App 内更新。

</details>

## 隐私边界

- **输入留在本机**：按键、组字、候选生成与词库处理不自动上传。
- **云端 AI 默认关闭**：开启后，也只在你明确触发功能时请求模型或搜索服务。
- **只处理明确提交的内容**：请求可包含主动提交的问题、明确选中的文本及当前对话历史；不自动附带屏幕、窗口、浏览器信息、选区之外的正文或光标前后文本。
- **密钥保存在 Keychain**：不写入普通配置文件。更新与词库下载属于网络请求，不携带输入内容。

详见 [PRIVACY.md](PRIVACY.md)。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## 项目与反馈

**深圳大学法律人工智能实训实验室**。

- [项目主页与公开下载](https://responsay.com/owltype/) · [每版对应源码](https://responsay.com/owltype/source.tar.gz)
- [维护者工单](https://github.com/semantic-craft/owltype-macos/issues)：仅已获仓库访问权限的协作者可使用 Issue 和 Pull Request。反馈请说明应用版本、macOS 版本、宿主应用与复现步骤。目前未配置面向未授权用户的公开反馈入口。
- [Windows 版](https://github.com/semantic-craft/owltype-win)：独立维护，版本、功能与发布资产不与 macOS 版自动同步。

GitHub 是 macOS 版的私有开发仓库，供获授权的协作者管理产品、工单与代码评审；安装包、更新源与对应源码由官网公开分发。仓库访问权限不改变已分发版本的 GPL-3.0 许可。仓库历史从 1.4.22 源码快照开始，1.4.21 及更早公开版本已停止分发与支持。

## 从源码构建

需要 Xcode 26+ 与 macOS 14+。没有仓库访问权限时，从[版本源码下载入口](https://responsay.com/owltype/source.tar.gz)获取已发布版本，解压后按包内构建说明操作。以下克隆与 Git hook 命令仅供获授权的仓库协作者使用：

```sh
git clone https://github.com/semantic-craft/owltype-macos.git
cd owltype-macos
git submodule update --init --recursive
make setup-dev
make deps
make release
```

`make setup-dev` 为当前 checkout 启用仓库自带的 pre-push 门禁。推送前会阻止密钥文件、
个人主目录绝对路径、已废弃的私有仓 remote、非 GitHub noreply 提交身份与 secret scanner 命中。
请把本仓库的 Git email 配置为 GitHub 提供的 noreply 地址；本地密钥使用 Keychain 或
被 `.gitignore` 排除的环境文件保存，不要把 AI 会话、调试日志或本机配置加入 Git。

公开构建使用清洁室词库种子（`scripts/owl-seed.sh`）：只包含授权链可审计的输入，
生成的词表限定在《通用规范汉字表》8105 字内。完整词库由 App 首启时从上游原仓库拉取，
猫头鹰自身不再分发那批数据。种子的逐项来源见构建产物里的 `OWLTYPE-SEED-SOURCES.md`。

签名、公证与打包由 `scripts/release.sh` 处理；验证完成后由
`scripts/owl_distribution.py --publish` 将完整 cohort 发布到 responsay.com。本项目没有托管
CI：合并前的门禁由开发机上的 `scripts/gate.sh` 执行，详见
[docs/operations/ci.md](docs/operations/ci.md)。

## 来源与许可

本项目以 **GPL-3.0** 发布，许可证全文见 [LICENSE.txt](LICENSE.txt)。猫头鹰是
[RIME 鼠须管（Squirrel）](https://github.com/rime/squirrel) 与
[librime](https://github.com/rime/librime) 的派生作品。基于本项目分发二进制时，必须同时提供
对应的修改源码、GPL-3.0 许可证文本与版权声明，不得作为闭源制品分发。
每个二进制版本的完整对应源码可从[官网固定入口](https://responsay.com/owltype/source.tar.gz)取得；
欢迎依 GPL 使用、修改和再分发源码；开发分支与已发布二进制可能处于不同版本。

完整来源脉络见 [PROVENANCE.md](PROVENANCE.md)，第三方组件许可见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 致谢

- [RIME / 中州韻输入法引擎](https://rime.im)——librime 与 Squirrel
- [雾凇拼音 rime-ice](https://github.com/iDvel/rime-ice)
- [极点五笔 86](https://github.com/KyleBing/rime-wubi86-jidian)
