# 「设为系统默认输入法」实现方案

> 状态：已评审定稿（2026-08-20 拟，同日评审通过并按评审意见修订，决议见 §8）。
> 起因：用户报告「一重启，默认输入法就变成鼠须管」，并要求增加"设为系统默认输入法"功能。
> 本文先把机制查清、把伪因排除，再给最小实现。

---

## 1. 已验证的事实

### 1.1 macOS 没有「默认输入法」这个 API

`TextInputSources.h`（MacOSX.sdk）里能**修改**状态的公开函数只有五个：

```
TISRegisterInputSource      注册 bundle
TISEnableInputSource        加入输入源列表
TISDisableInputSource       移出列表
TISSelectInputSource        切到它（此刻）
TISDeselectInputSource      切走
TISSetInputMethodKeyboardLayoutOverride   （只管 ASCII 布局层）
```

没有 set-default，**也没有任何排序 API**。所有输入法的"设为默认"都是在这几条原语上拼出来的效果。

顺带排除一个流传很广的误区：网上大量教程让写 `AppleDefaultAsciiInputSource`。该键是 **ASCII 兜底键盘布局**（密码框、Spotlight 用），与中文 IME 无关。

### 1.2 状态存在哪里（macOS 26 实测）

| 存储 | 键 | 作用 |
|---|---|---|
| `~/Library/Preferences/com.apple.HIToolbox.plist` | `AppleSelectedInputSources` | **登录时恢复的目标** |
| 同上 | `AppleEnabledInputSources` | 仅 Apple 自带；第三方永远不在这里 |
| 同上 | `AppleInputSourceHistory` | MRU |
| `~/Library/Preferences/com.apple.inputsources.plist` | `AppleEnabledThirdPartyInputSources` | 第三方列表，顺序 = 菜单顺序 |
| `/Library/Preferences/com.apple.HIToolbox.plist` | — | 登录窗口/访客，**只管键盘布局** |

macOS 26 把第三方 IME 拆到了独立的 `com.apple.inputsources.plist`，菜单栏 agent 读两个 plist 合并。写验收脚本时读 `AppleEnabledThirdPartyInputSources`，读 `AppleEnabledInputSources` 会把正常安装误判为"未启用"。

### 1.3 对照实验：真凶是 LaunchServices 遮蔽，不是"默认"机制

2026-08-20 在本机做了一次清理 → 重启对照。

| 项 | 清理前 | 清理后重启 |
|---|---|---|
| LS 认领 `im.famo.inputmethod.Famo` | 5 条（4 条未签名 ad-hoc 构建 + 1 条装机版） | **1 条**，teamID `LQAVR62TK2` |
| 重启后恢复的输入源 | 鼠须管 | **法墨** ✓ |
| 第三方列表第一位 | 鼠须管 | 鼠须管（**未变**） |

**结论 A —— 真凶确认。** 未签名开发构建抢同一个 bundle id，登录时 macOS 解析到 ad-hoc 构建，IMK 服务拉不起来，切过去又飘走，落到下一个输入源（鼠须管）。清掉遮蔽后恢复正常。

**结论 B —— "排序决定默认"被证伪。** 鼠须管在第三方列表里**仍然排第一**，法墨照样被正确恢复。决定登录恢复的是 `AppleSelectedInputSources`，**不是列表顺序**。

**结论 C —— 污染会再生。** 清理后 7 小时内，另一会话跑 gate/测试构建又灌回 4 条未签名认领。这不是一次性事故。

**结论 D —— 这是开发机特有问题。** 真实用户机器上不会有一堆 ad-hoc 构建抢 bundle id。因此本功能**不应以"修这个 bug"为设计理由**，而应按用户价值设计：用户装了法墨 + 其它输入法，希望开机默认是法墨。

> 证据强度声明：结论 A/B 各基于**一次**重启对照。机制解释与观测一致，但样本为 1。结论 C/D 是机制推论，不依赖该次实验。

---

## 2. 业界做法（读源码，非二手资料）

| 做法 | 代表 | 关键代码 |
|---|---|---|
| **A. 安装时 enable + select** | mozc / Google 日本語入力、Squirrel、hallelujahIM、Jyutping | `TISEnableInputSource(); TISSelectInputSource();` |
| **B. 只 enable，绝不 select** | fcitx5-macos 安装器、LeftIO、typing-chao | 只有 `TISEnableInputSource` |
| **C. 直接写 plist 改顺序** | nix-darwin、各类 dotfiles | `CFPreferencesSetAppValue` 写两个 domain |
| **D. 登录期 LaunchAgent 回切** | 搜狗/教程派、各种 im-keeper | `RunAtLoad` + `TISSelectInputSource` |
| **E. 运行期观察 + 按上下文回切** | herdr ime-keeper、macism | 焦点事件驱动 |

B 派的理由（fcitx5-macos / LeftIO / typing-chao 都明写）是**不抢用户当前输入法**——与本项目 no-steal 原则同源。

---

## 3. 砍掉的方案与理由

**砍 C（改写 plist 顺序）** —— §1.3 结论 B 已证伪其前提：顺序不决定登录恢复。且它风险最高（重复条目、设置面板与菜单栏不同步、需注销生效、`killall cfprefsd` 会冲掉状态），并直接违反本仓 `InputSource.swift` 顶部既有约定「Do NOT write `AppleEnabledInputSources` directly」。

**砍 D（LaunchAgent 登录期回切）** —— 实测证明系统恢复本来就是对的，D 是在修一个不存在的问题。代价：多一个常驻 agent、每次登录抢一次输入法（违反 no-steal）、并踩本仓已知的载体坑（root 上下文 `launchctl submit` 返回 0 但永不执行，必须 `bootstrap gui/<uid>`）。

**砍 E** —— per-app 输入法记忆是另一个功能，不在本次范围。

---

## 4. 选定方案：只做 A，用户显式触发

「设为系统默认输入法」= 一个用户主动点击的动作，做两件事：

1. `TISEnableInputSource`（若尚未启用）
2. `TISSelectInputSource`（切到法墨）

系统随即把它写进 `AppleSelectedInputSources`，**下次登录自动恢复法墨**——这就是 macOS 上"默认"能达到的全部含义。不写任何 Apple plist，不常驻进程。

与 no-steal 的关系：no-steal 禁止的是**程序自作主张**切换用户输入法（安装/更新时）。本功能由用户在设置里显式点击触发，是用户意图的直接执行，不冲突。这条边界必须在实现里守住：**只有点击路径能调用，安装/更新路径一律不得复用。**

### 4.1 改动清单（评审后收缩）

评审核对代码后发现：`select(mode:)` 传显式 mode 时**已经是**「未启用则 enable → select → notify」的完整链路，CLI `--select-input-source im.famo.inputmethod.Famo.Hans` 今天就能达成方案 A 的全部效果。因此本功能**不新增任何 TIS 逻辑**，真正的增量只有两块：**结果判定**（现有 `select()` 在「已是当前输入法」时会走进 else 分支打印 "Failed to select"，UI 必须把这一情形判成"已是默认"而非失败）和**模式选择**（不能盲选 `.primary`）。

| 文件 | 改动 |
|---|---|
| `sources/Activation/InputSource.swift` | 新增 `func makeDefault() -> MakeDefaultResult`：**薄结果包装**，内部复用既有 `select(mode:)` 链路，不新增 TIS 封装。模式选择：优先选**已启用的法墨模式**（Hant 已启用而 Hans 未启用则选 Hant），均未启用才 enable + select `.primary`。 |
| 同上 | 新增 `enum MakeDefaultResult { case alreadyDefault, madeDefault, failed(reason:) }` —— 纯值类型，便于单测与 UI 文案分支。判定先于动作：已启用且已选中 → `alreadyDefault`，不触碰 TIS。 |
| `sources/Settings/FamoSettingsPages.swift` | `FamoDiagnosticsPage` 内、"当前系统输入源" 信息行下方加一个按钮 + 结果文案。 |
| `tests/` | 覆盖分支判定（未启用 / 已启用未选中 / 已是默认 / select 失败 / **Hant-only 时选 Hant**），沿用既有纯函数可测风格。 |

**不新增 CLI**（评审决议，见 §8.4）：脚本/验收直接用既有 `--select-input-source im.famo.inputmethod.Famo.Hans`。

### 4.2 明确不做

- 不写 `AppleEnabledInputSources` / `AppleEnabledThirdPartyInputSources` / `AppleSelectedInputSources`
- 不装 LaunchAgent
- 不在安装、更新、启动路径上自动调用 `makeDefault()`
- 不做"取消默认"（macOS 无此语义；用户切到别的输入法即是）

---

## 5. 配套加固（建议纳入，可独立评审）

§1.3 结论 A/C 说明：真正让"默认"失效的是 bundle 认领遮蔽，且会持续再生。这不是产品 bug，但值得留一个可观测面。

- **`scripts/ime-check.sh`（本次已落仓）** —— 自动探测装机输入法、不硬编码 bundle id，报告：登录恢复的输入源 / 第三方列表顺序 / 每个 id 的 LS 认领数与 teamID / 输入法进程。改名后无需修改，2.0.0 装机验收可直接复用。
- **六层激活诊断加一行**：报告本 bundle id 的 LS 认领数，>1 或存在无 teamID 条目时给出告警。这次的真凶用现有六层诊断看不出来，加上就能一眼定位。
- **`scripts/gate.sh` 收尾认领数检查**（评审决议：**只告警，不自动删**，见 §8.2）—— gate 结束时报告本 bundle id 的 LS 认领数异常；`clean-dev.sh --apply` 保持手动触发。自动删会误伤并行会话仍在复用的构建产物。

---

## 6. 与改名工程（法墨 → 猫头鹰 / Owltype）的关系

改名会把 bundle id 换成 `im.owltype.inputmethod.Owltype`，输入模式 ID 一并更换（见 `docs/rename-owltype-plan.md`）。

- 本方案**不引入任何新的硬编码 id**，只走 `InputSource.swift` 既有的 `inputSourcePrefix` / `InputMode` 常量。改名扫到那两处，本功能自动跟上，无额外改动。
- `scripts/ime-check.sh` 自动探测，改名后可直接复用。
- **先后顺序（评审决议，见 §8.3）：先落本功能，再改名。** 本功能改动面小且集中在已有常量上；改名是全仓 ID 扫除。反过来做会让本功能的 diff 混进改名的噪声里。
- 改名计划 line 43 记录：PR#134 的「升级后输入源还原」机制至今未经真机验证。本次重启对照已为**法墨时代**留下 baseline（`scripts/ime-check.sh` 输出），P6 验收时可做前后对照。

---

## 7. 验收

1. 单测：`MakeDefaultResult` 五条分支（含 Hant-only 选 Hant）。
2. 真机：装机版下点击按钮 → `scripts/ime-check.sh` 确认 `AppleSelectedInputSources` 变为法墨 → 重启 → 确认恢复为法墨。CLI 侧用 `--select-input-source` 验证同一链路。
3. **验收前置条件**：先跑 `scripts/clean-dev.sh --apply`，确认 LS 认领数为 1 且带 teamID。否则归因不可信（§1.3 结论 C）。
4. 回归：确认安装/更新路径没有调用 `makeDefault()`（no-steal 不被本次改动破坏）。

---

## 8. 评审决议（2026-08-20）

1. **按钮放 `FamoDiagnosticsPage`。** 按结论 D 这是用户价值功能而非诊断功能，语义上略勉强，但另起设置页不符合最小分层原则；以后若做「输入法」设置页再迁。
2. **gate 收尾只告警，不自动删。** `clean-dev.sh --apply` 会删掉并行会话可能还在用的构建产物——多会话并行的开发机上，gate 自动删是给别的会话埋雷。
3. **先功能后改名。** 理由见 §6。
4. **不新增 `--make-default` CLI。** `select(mode:)` 显式传参已是 enable+select 完整链路，与 `--select-input-source` 完全重叠；`makeDefault()` 收缩为 UI 用的结果包装（见 §4.1）。

评审另发现并已修正：`makeDefault()` 原提案会盲选 `.primary`（Hans），Hant 用户点「设为默认」会被切到简体——已改为优先选已启用模式（§4.1）。

---

## 附：一手来源

- SDK `TextInputSources.h`（本机 MacOSX.sdk）—— API 面的权威依据
- mozc `src/mac/ActivatePane/ActivatePane.mm` —— enable + select 范式
- fcitx5-macos-installer `im/enable_im.swift` —— 只 enable 范式
- fcitx5-macos `assets/switch_im.swift` / `assets/get_im.swift`
- rime/squirrel `sources/InputSource.swift` —— 本仓上游
- openvanilla `Packages/InputSourceHelper/…/InputSourceHelper.swift`
- goliajp/inputx `docs/macos-ime-recipe-2026.md` —— macOS 26 三道门与 plist 拆分
- CST-Cat/left-io `docs/leftio-input-method-pitfalls-2026-07-04.md` —— 不写 Apple plist 的理由
