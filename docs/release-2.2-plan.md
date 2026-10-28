# 2.2 发版实施计划：清掉 Rime、接上 Agent

> 状态：2026-10-29 起草，基线 main `c4fdf85`。本文是计划，不是验收记录；各阶段的完成状态以对应工单为准。
> 用户决定（2026-10-29）：2.1.1 不单独发布，Rime 清理和扩展接口做完后合成 2.2 一起发；扩展方向优先 Agent / MCP 接入；快捷片段（#160–#173）与改名（#148、#149）工单按已交付处理。

## 1. 目标

2.2 交付一个只依赖 Rust 引擎、可以被本机 Agent 安全调用的猫头鹰：

1. **引擎只有一条路**：运行时、构建、脚本和命名里不再有 Rime；拼音、五笔与固定版水杉的对照仍是 0 差异。
2. **上游跟得动**：词库与引擎重钉成为一条命令加一份文档，版本号只在一处维护。
3. **Agent 接得进**：外部 Agent 通过 MCP 读到猫头鹰的脱敏状态和用户开放的模板，并能把一段文本交给猫头鹰，由用户在原生预览里确认后写入当前输入框。
4. **不变慢**：端到端输入延迟有实测数据，MCP 开或关都不影响打字热路径。

代价：2.1.0 用户在 2.2 发布前仍会遇到 2.1.1 已修好的问题，如 `tadefangjian` 首选「塔德房间」。

## 2. 现状（截至 `c4fdf85`）

| 项 | 事实 |
| --- | --- |
| 线上版本 | appcast 为 2.1.0。2.1.1 第一次正式出包因 Sparkle 权限缺陷作废（#293），缺陷已由 #320 修复，之后没有重新出包。 |
| 仓库版本 | `MARKETING_VERSION = 2.1.1`，CHANGELOG 已有 2.1.1 段。git tag 停在 2.0.14。 |
| 对齐 | 拼音 2,134 事件、五笔 397 事件对照 0 差异（作废的出包上测得；#292 要求在新包上重跑）。 |
| Rime 残留 | `librime`、`librime-lua`、`plum` 子模块；约 12 个脚本；`sources/` 有 90 个文件提到 Rime，其中仍在用的命名有 `RimeSession`、`RimeSeam`、`OwlRimePatchBuilder`、`+RimeUpdate`、`+RimeOptions`、`OwlConfigWriter`。`usesRustEngine` 分支已经删干净。 |
| Rust 层 | 照搬上游的 crate：`engine`、`input-runtime`、`path-trust`，以及 `client-core` 的选取部分，附 11 项本地适配（`rust/msime-source.json`）。猫头鹰自有的只有 `owl-msime-ffi`（C ABI，每键传 JSON）和 `rust/shared/contracts/punctuation`。 |
| Agent 接入 | 没有对外 MCP 服务。可复用的部分：`OwlTemplateHostDelivery`（原宿主校验与交付）、模板存储、`scripts/check-ai-off-hot-path.sh`。`Main.swift` 的分布式通知 CLI 只能广播、拿不到应答，也不做认证，不适合作为接入通道。本机已装 Grok Build（`~/.grok/bin/grok`）和 AGY（`~/.local/bin/agy`）。 |

## 3. 架构决定：Agent 接入放在哪一层

猫头鹰是由系统拉起的 IMK 进程，MCP 客户端没法把它当作 stdio 子进程启动。因此分成三段：

```
Agent 客户端 ──stdio/MCP──▶ owltype-mcp（Rust，随 App 分发的辅助程序）
                              │  Owl Agent Bridge 协议（版本化 JSON-RPC）
                              ▼
                     Unix 域套接字（用户私有目录，0700 / 0600）
                              │
                              ▼
               Owltype.app 内的 OwlAgentBridge（Swift，后台队列）
                 ├─ 只读：状态、诊断（脱敏）、开放给 Agent 的模板
                 └─ 动作：文本交付 → 原生预览 → 用户确认 → OwlTemplateHostDelivery
```

- **`owltype-mcp` 用 Rust 写，作为新的猫头鹰自有 crate**，放在 `rust/crates/owl-agent-mcp`，编出 `Contents/Helpers/owltype-mcp`。它只负责 MCP 协议、工具 schema 和转发，不持有任何输入状态。这样 Windows 版以后可以把套接字换成命名管道，直接复用。MCP SDK 在开工时选官方 Rust SDK 的固定版本，并在 PROVENANCE 和对应源码里写明许可。
- **通道用 Unix 域套接字，不用 XPC，也不用分布式通知。** XPC 的 Mach 服务要靠 launchd 注册，IMK 进程没有这个条件；分布式通知无法认证，也没有应答。套接字两端各做一道检查：用 `getpeereid` 确认是同一用户，再用对端 PID 取代码签名，确认是同一个 Team ID 的猫头鹰组件。
- **协议合同放在 `rust/shared/contracts/agent-bridge/`**（JSON Schema 加样例），Rust 和 Swift 两侧的测试都跑同一套样例，做法与现有的 punctuation 合同一致。
- **App 侧的 `OwlAgentBridge` 不进 IMK 按键路径**：I/O 在后台队列处理，需要动 UI 时才切到主线程。`check-ai-off-hot-path.sh` 把这个模块也纳入检查。
- **分层规则**：照搬上游的 crate 只接受 `msime-source.json` 里登记过的适配，新功能一律写进猫头鹰自有的 crate，避免 #314 的重钉流程越来越难重放。

### 2.2 的 MCP 工具（首版切片）

| 工具 | 类型 | 说明 |
| --- | --- | --- |
| `owltype_status` | 只读 | 版本、引擎资源代次、当前方案、中英状态、接入开关。不含任何输入文本。 |
| `templates_list` / `template_get` | 只读 | 只返回用户在设置里标为「开放给 Agent」的模板。每个模板单独开放，默认都不开放。 |
| `template_render` | 只读 | 按参数渲染模板，只返回预览文本，不写入任何输入框。 |
| `deliver_text` | 需确认的动作 | Agent 提交一段文本，猫头鹰在当前焦点处弹出原生预览，用户确认后才通过 `OwlTemplateHostDelivery` 写入。请求绑定目标身份并有超时；焦点变了、选区失效或结果迟到都不写入；不自动按 Return；同一请求重复提交只写一次。返回 `delivered`、`cancelled`、`target_changed` 或 `expired`。 |

设置里新增「Agent 接入」页：总开关（默认关）、逐个模板的开放勾选、复制给 Grok Build / AGY 的配置片段、最近调用记录（脱敏，不含正文）。

**不在 2.2 做**（写回 #208 作为后续）：第二个真实客户端的闭环验收、由应用主动委托 Agent 的链路、内置聊天窗口的迁移、白名单配置写入工具。

## 4. 阶段

阶段 1 和阶段 2 都改 `Makefile` 与 `scripts/`，按顺序做。阶段 3 和阶段 4 与它们互不依赖，可以并行开会话。

### 阶段 0 · 定基线与收尾旧账（本周）

- ✅ 2026-10-29 已关闭快捷片段 #160–#173 和改名 #148、#149，每张票都写明了核对的 commit 和证据。2026-10-11 真机复核中实测失败的两项转入 **#331**：面板确认后回填原宿主失败（`focusNotRestored`），以及 `{cursor}` 定位不对。#149 里删除 famo 分发文件属于线上操作，不在这次关票范围内。
- 把 #293 的核对对象从作废的 2.1.1 出包改为 2.2 RC，并解除它对 #317 的阻塞（**需你确认**）。
- 把 #208 收窄为第 3 节定义的 2.2 切片，其余拆成后续票。
- 新开工单：「2.2 版本与发版收口」，见阶段 6。

### 阶段 1 · 清掉 Rime（#317）

做什么：
1. 先确认正式构建不再加载任何 Rime 内容（看链接库、包内文件和启动路径），再移除三个子模块，以及 `Makefile` 和约 12 个脚本里的引用，删掉只为 Rime 产物设的白名单。
2. `sources/` 中提到 Rime 的地方按四类处理并出清单：
   - 死代码：删除。
   - 仍在用的命名：改名。例如 `RimeSession` → `EngineSession`，`RimeSeam` → `EngineSeam`，`OwlRimePatchBuilder` / `OwlConfigWriter` 改为 Rust 配置写入的名字，`+RimeUpdate` / `+RimeOptions` 并入 Session。
   - 旧数据导入（`sources/UserMigration/`）：保留。
   - 已存的偏好键：键名不变。
3. 退役 CLI 的 exit 64 桩保留（domain.md 有约定）。`rust/crates/engine/src/lattice/octagram.rs` 中出现的 Rime 是移植来源和许可声明，保留。

怎么算完成：`git grep -i -e librime -e plum` 只剩注明理由的条目；拼音、五笔对照仍为 0 差异（仍用 dict-v2.0.24，确保这一阶段只动了命名和构建）；交付包自检脚本已更新；完整门禁通过。

### 阶段 2 · 词库升级与重钉流程（#314）

做什么：升到开工时最新的 `dict-v*`（目前是 2.0.39）；查清五笔库为什么从 14.5 MB 涨到 95 MB；重跑全部对照并更新基线；做成一条只读的「与上游差多少」命令，再写一份重钉文档；版本号收拢到 `rust/msime-source.json`，其他位置由检查脚本核对一致。

怎么算完成：按 #314 的验收清单逐项完成。另需一份对比数据：安装包体积、首次启动耗时、常驻内存，分别列出升级前后的数字。

**需你决定**：五笔库增大约 80 MB，安装包和更新包都会随之变大。查清原因后，我会给出「全量随包」和「五笔扩展词库改为按需下载」两个方案的数字，由你来选。

### 阶段 3 · Agent / MCP 首版（#208 切片，可并行）

按以下顺序推进，每步都能单独合并：

1. **协议合同**：`contracts/agent-bridge` 的 schema 与样例；Rust、Swift 两侧的样例测试。
2. **`owl-agent-mcp` crate 与辅助程序**：先实现 MCP 握手、工具列表和 `owltype_status`；随 App 打包和签名，纳入 `release.sh` 的清单与 `check-rust-delivery.py`。
3. **`OwlAgentBridge`**：套接字监听、对端校验、超时与取消；默认关闭；纳入 `check-ai-off-hot-path.sh`。
4. **模板工具**：模板增加「开放给 Agent」字段（默认关），实现 `templates_list`、`template_get`、`template_render`。
5. **`deliver_text`**：原生预览，加上目标绑定、去重、过期处理，复用 `OwlTemplateHostDelivery`。**先修 #331**：现在从面板确认后会因焦点没恢复而写不进原宿主，`deliver_text` 走的是同一条路。
6. **「Agent 接入」设置页**。
7. **真实客户端验收**：选 Grok Build 或 AGY 其中一个，完整走一遍「连接 → 发现工具 → 只读调用 → `deliver_text` → 在原生 UI 确认 → 写入 TextEdit 和 Chrome」，记录客户端版本、协商到的协议版本和服务端 commit。异常情况也要覆盖：密码框、目标应用退出、焦点切换、断连、超时和重复调用。

怎么算完成：上述 7 步都已合并；MCP 关闭、辅助程序缺失或 Agent 离线时，打字、候选和模板都正常；不新增任何必须填写的模型 API key。

**需你决定**：首个验收客户端用 Grok Build 还是 AGY。我推荐 Grok Build，它的 MCP 文档同时写明了 stdio 和 Streamable HTTP。

### 阶段 4 · 设置精简（#315，可并行）

先由你确认保留哪些卡片（#315 的建议清单），再动手。删掉自动应用状态卡和持久化说明卡（Rust 下已经没有这一步），删掉自定义 Rime 方案兼容卡，其余移入「高级」。「Agent 接入」页与本阶段都改设置侧栏，两者先后合并即可。

**需你决定**：#315 的卡片去留，可以现在就定，不必等到阶段开始。

### 阶段 5 · 测量与对齐收口（#316、#292）

在 2.2 RC 的正式签名安装上做：
- #316 端到端延迟：TextEdit 和 Chrome，覆盖各输入方案，模型开 / 关，**MCP 开 / 关**。达标条件：P95 不超过一帧（16.7 ms）；超过时指出最慢的一段，并判断是否阻塞发版。
- #292：在 RC 资源上重跑拼音和五笔对照，并在真实宿主上实打确认（拼音、五笔、Chrome 组字与 Esc）。

### 阶段 6 · 发版 2.2.0（#293 与新开的收口票）

1. `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 改为 2.2.0。CHANGELOG 把 2.1.1 段并入 2.2.0，并注明 2.1.1 只出过包、没有发布。appcast 里永远不出现 2.1.1。
2. 用 `scripts/release.sh` 出 cohort，八项门禁全部通过后生成发布授权回执。
3. #293：核对安装包与运行程序的版本和摘要，以及词库、模型、配置；确认没有依赖开发目录。
4. 在本机用更新方式覆盖安装。本机现在装着作废的 2.1.1，运行的是 2.1.0 进程，这正好走一遍真实的跨版本升级：Keychain 里的 AI 密钥要能静默读出，重新授权最多出现一次。
5. 发布到 `downloads.responsay.com` 并更新 appcast（**发布这一步会请你确认一次**）。之后跑 `check-published-release.sh`。
6. 恢复打 tag：从 `2.2.0` 起，每次发布都打 tag。
7. 更新 `progress/progress.json`，关闭 #317、#314、#292、#293 和 2.2 切片票。

## 5. 不进 2.2 的开放工单

保持开放，2.2 不处理：#204、#205（免注销安装与更新）、#207、#247、#269、#278（浮动状态栏已在 #279 合并，留待单独核对后关闭），以及 #208 中切片之外的部分。

## 6. 待你决定的事项

| # | 决定 | 我的推荐 | 卡住哪一步 |
| --- | --- | --- | --- |
| 1 | #293 改为核对 2.2 RC，解除对 #317 的阻塞 | 同意 | 阶段 1 |
| 2 | 首个 MCP 验收客户端 | Grok Build | 阶段 3 第 7 步 |
| 3 | #315 卡片去留 | 按 #315 建议清单 | 阶段 4 |
| 4 | 五笔库 +80 MB 的处理方式 | 等阶段 2 的数字出来再定 | 阶段 2 收尾 |
