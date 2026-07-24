# 法墨 去 Squirrel 化 · 真机 smoke 交接清单

> **这是交付物，不是自动步骤。** Agent 不做真机 GUI；本清单交由**人工**在一台
> **装了公证包、已授辅助功能、有 GUI 登录会话**的真机上跑，逐项勾选并归档证据。
> 覆盖父任务 `07-04-famo-macos-de-squirrelization` 全部标注「真机=是」的验证项。
>
> 执行基准：仓库根 `Famo_macOS_de_Squirrelization_Plan_v2.html`（§7 八门 / §3 W1.x）。
> 自动化脚本：`scripts/smoke-live.sh`（W1.5 §7 Gate 7）。诊断入口：`Famo.app/Contents/MacOS/Famo --diagnose-tis`（W1.4）。

## 0. 前置（所有场景共用）

| 项 | 要求 |
|---|---|
| 构建物 | **公证 + staple** 的 DMG/pkg（`scripts/release.sh` 产出）。ad-hoc/未签名本地拷贝会被 Tahoe 弹回上一个输入法（坑 10），**不是合法 smoke 目标**。 |
| 权限 | 给跑 `smoke-live.sh` 的终端 / osascript 授「辅助功能」（TextEdit 实输回读需要）。 |
| 会话 | 真实 GUI 登录会话（非 SSH/无头）。 |
| 证据目录 | `EV=/tmp/famo-smoke && mkdir -p "$EV"`。全程产物落这里，随发布决策一起归档。 |

打印人工序列（脚本自带，照抄即可）：

```
bash scripts/smoke-live.sh checklist first-install
bash scripts/smoke-live.sh checklist update
```

---

## 1. W1.5 §7 Gate 7 — Live 首装 smoke（干净账户）

- **前置**：干净 macOS 账户；旧法墨未装。
- **操作**：
  1. `bash scripts/smoke-live.sh snapshot "$EV/before"`
  2. 装公证 DMG → 跑 GUI 安装器 → 授「允许启用输入法」→ 菜单出现「法墨」。**首装免注销激活**（1.3.32）。
  3. 从输入菜单选中「法墨」。
  4. `bash scripts/smoke-live.sh snapshot "$EV/after" && bash scripts/smoke-live.sh verify "$EV/before" "$EV/after"`
  5. `bash scripts/smoke-live.sh check`（已装 app 只读门）
  6. `bash scripts/smoke-live.sh input textedit`（真按键 nihao→你好）
- **期望**：装完无需注销即出现并可选中；`verify` 全 PASS；`input` 打出「你好」。若半激活，`--diagnose-tis` 给出失败层 + `FAMO-*` 码，而非「重启/注销」。
- **证据**：`$EV/before`、`$EV/after`（含 `diagnose-tis.json`）；`verify`/`check`/`input` 的 PASS 输出；安装器授权截图。

## 2. W1.5 §7 Gate 7 — Live 更新免注销 smoke（闭合 1.3.32 开环）

> 1.3.32「更新免注销」是**待自然验证**项——跑一次本场景闭环即完成验证。

- **前置**：旧法墨已装且**已选中**；预开 TextEdit、Chrome、WeChat。
- **操作**：
  1. `bash scripts/smoke-live.sh snapshot "$EV/before"`
  2. 触发 Sparkle 更新（`Famo-update.pkg`）。更新路径 = **切 ABC → 原地换 → 切回**，**禁止重 register/enable/select**（二次 enable 会造幽灵 TIS 记录）。
  3. 逐个预开 app 如实记录：能否立刻打字，还是需重开 app。已开 app 不接新 IMKServer 是**系统天花板**（含 WeChat），「需重开」**不算失败**，记录即可。
  4. `bash scripts/smoke-live.sh snapshot "$EV/after" && bash scripts/smoke-live.sh verify "$EV/before" "$EV/after"`
  5. `bash scripts/smoke-live.sh check` —— 断言**单一 Hans 源**；非法重 enable 会显示为重复行。
  6. 重开 TextEdit → `bash scripts/smoke-live.sh input textedit`（真按键 nihao→你好）
  7. 菜单栏图标 = 法墨；输入菜单「法墨」恰好一条（无重复/幽灵）。
- **期望**：更新全程不强制注销；`--diagnose-tis` 仍显示单一干净 Hans 源、无重复/幽灵行；`check` 单源；`input` 打出「你好」。
- **证据**：`$EV/before`、`$EV/after`；`verify`/`check` 输出；六层 JSON（无重复行）；各 app「立刻可打字 / 需重开」记录；菜单栏截图。

## 3. W1.5 §7 Gate 7 — Squirrel 并存（只读）

- **前置**：同机装有 Squirrel（鼠须管）。
- **操作**：包含在场景 1/2 的 `snapshot`→`verify` 里（脚本自动断言）。
- **期望**：全流程 `Squirrel.app` bundle 的文件 mtime **不变**（法墨对 Squirrel 严格只读，从不改写）。
- **证据**：`verify` 输出中「Squirrel.app unchanged across the flow (coexistence read-only)」PASS 行。

## 4. W1.5 §7 Gate 7 — 数据哨兵（§8.4）

- **前置**：用户现有 `~/Library/Rime`。
- **操作**：包含在 `snapshot`→`verify`（脚本自动断言）。
- **期望**：全流程 `~/Library/Rime` **无法墨写入**（法墨数据隔离在 `~/Library/Application Support/Famo`）。
- **证据**：`verify` 输出中「~/Library/Rime unchanged across the flow (data sentinel clean)」PASS 行。

---

## 5. W1.2 真机目视 — 输入源列表 + 菜单栏图标

- **前置**：法墨已装并选中。
- **操作**：打开「系统设置 → 键盘 → 输入法」；观察菜单栏输入法图标。
- **期望**：
  - 输入源列表出现「法墨」（Hans），**无 rime 旧图标 / 无「鼠须管」误认**；不出现无方案可选的裸繁体条目。
  - 菜单栏图标渲染为法墨图标（`FamoMenuIcon.pdf`），非 rime 旧图标。
- **证据**：系统设置输入源列表截图；菜单栏图标截图。

## 6. W1.4 真机 — `--diagnose-tis` 六层健康 JSON

- **前置**：法墨已装并选中（用**当前构建**的 app；旧安装可能无此 flag）。
- **操作**：`"/Library/Input Methods/Famo.app/Contents/MacOS/Famo" --diagnose-tis | tee "$EV/diagnose-tis.json"`
- **期望**：六层（**register / enumerate / enable / select / menu / client-attach**）健康；`summary.code` 为 null（健康时 JSONEncoder 略去该键 ⇒ 键缺失）。异常时给出对应 `FAMO-*` 码（`FAMO-TIS-001..006` / `FAMO-INSTALL-001` / `FAMO-SIGN-001/002` / `FAMO-DATA-001/002` / `FAMO-UPDATE-001`）+ §5 用户向文案。TIS 读取在 **fresh 进程**（定律 4）。
- **证据**：`$EV/diagnose-tis.json`（healthy：无 `summary.code`）。

---

## 7. 本轮新增 UI 项（第二波 M2.4）

### 7a. 诊断设置页渲染六层 / FAMO-* 码

- **前置**：法墨已装并选中；打开法墨设置窗 → 「诊断」页（`FamoDiagnosticsPage`）。
- **操作**：查看「诊断概要」「六层激活诊断」两张卡；点「刷新」重取。
- **期望**：概要显示 summary（健康/失败层 + 码）；六层卡逐层列 register…client-attach 的 ok/码/detail + 安装身份（install-location / bundle id）+ 数据根；渲染与 `--diagnose-tis` JSON 一致。
- **证据**：诊断页截图；与第 6 项 JSON 交叉核对一致。

### 7b. 「导出诊断包」写出脱敏文件

- **前置**：诊断页。
- **操作**：点「导出诊断包」→ NSSavePanel「导出法墨诊断支持包」→ 存盘。
- **期望**：写出 markdown 支持包，含 版本/OS 头 + TIS 六层 JSON + 近 30 分钟 unified logs（子系统 `im.famo.inputmethod.Famo`）；**脱敏**：所有主目录路径（含用户名）收敛成 `~`，无 PII 泄漏。
- **证据**：导出的 `.md` 文件（打开确认无真实用户名/主目录绝对路径）。

### 7c. 卸载器「当前源是法墨先切 ABC」

- **前置**：法墨为**当前**输入源。
- **操作**：跑 DMG 内 `卸载法墨.command`（或 `scripts/uninstall-famo.sh`）。
- **期望**：卸载前若当前源是法墨，先 `--select-input-source com.apple.keylayout.ABC` 切到系统 ABC 再停用/删除（避免停用后留在无激活源坏态）；**若当前用的是搜狗/Squirrel 则绝不粗暴拽到 ABC**；卸载遵守严格白名单（不碰 `~/Library/Rime` / Squirrel）。
- **证据**：卸载脚本终端输出（含「当前输入源是法墨，先切到 ABC 再停用」行）；卸载后输入源列表截图（法墨已移除、其余源不变）。

---

## 8. 发布决策标记

把 `$EV` 全部证据 + 手工见证项（Terminal/Chrome 实输、WeChat 见证截图、菜单栏图标）附到发布决策。
`check-release.sh` 在其手工 smoke 文档里门控这一行：

```
Status: PASS
```

> 手工见证项（osascript 回读不可靠，只能人工）：Terminal + Chrome 实输 nihao→你好（尽力而为）；WeChat 打 nihao→你好 + 截图；菜单栏图标目视。
