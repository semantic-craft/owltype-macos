# 不注销安装与更新：实施和验收记录

## 当前状态

分支：`codex/no-logout-install-update`。核实基线：`7f24eac8fe379ec58e5fa5e1ae666d9e116a03b0`。
已完成只读版本探针和离线自测；产品安装、更新、提示行为尚未修改。
下一步由用户执行基线及 B4 隔离实验，保留原始输出后再实施。
不得把下面的源码核实、探针自测或微信静态分析记成真机验收通过。

顺序：探针 → 基线/B4 → OwlBundleSwap 单测 → 用户 macl spike → 会话重启 →
暂存更新包 → GUI 共用交换原语 → 失败才提示注销/去 RequireLogout → 文档 → S1–S4。
某一步验证失败先修该步；连续两次修不好停下报告。

## A1–B4 核实

以下行号均对应上述基线提交，不随后续修改滚动。

| 项 | 结论 | 源码证据及边界 |
| --- | --- | --- |
| A1 | 部分属实，需要精确表述 | `sources/Controller/OwlApplicationDelegate.swift:170–172` 传入的是 **CFBundleShortVersionString**；`sources/Controller/OwlUpdateLogoutPrompt.swift:30–68` 在已有非空历史版本且营销版本变化时安排提示。首启不弹，单独改变 CFBundleVersion 不触发；调度器等待输入安全时机，非立即弹窗。 |
| A2 | 属实 | `package/Distribution:28` 声明 RequireLogout；`scripts/check-release.sh:224–239` 要求首装带、更新不带。 |
| A3 | 属实，非终态 | `installer/Sources/InstallerActivationVerifier.swift:44–47` 默认 30/300 秒；`InstallerActivationPolicy.swift:72–84` 软超时进入 needsLogout(stillTrying: true)，但仍可迟到成功。 |
| A4 | 属实 | `sources/Controller/OwlInputController+Menu.swift:48–66` 无条件添加菜单项；标题在 `OwlInputMenuTitles.swift:22`。 |
| B1 | 原地覆盖和延迟任务属实；时序因果待复现 | `package/make_package:10,45–60,65–84` 两个 pkg 共用直接安装到 /Library/Input Methods 的组件；`package/Owltype-component.plist:14–20` 使用 upgrade。`scripts/postinstall:55–81,82–211` 描述并实施跨收据边界任务。最终 LS 注册晚于 postinstall 是既有注释中的历史观察，本次尚无安装时间线证据。 |
| B2 | 属实 | `scripts/preinstall:48–63` 只记录既有 bundle/选中态，不停止进程；`scripts/postinstall:287–288` 在 payload 已落盘后才 killall Owltype。Sparkle 可能先退出宿主，不能保证安装途中无旧进程复活。 |
| B3 | 属实，权限需区分 | `installer/Sources/Installer.swift:484–485` 用两次 mv 换整个 app；`:492–494` 在特权命令中 killall SystemUIServer；`:380–388` 则在用户会话中 -9 结束 pboard 和两个 TextInput 服务，并非 root 杀 pboard。`:483,489` 另有 macl 历史注释及 best-effort 删除。 |
| B4 | 未核实，不能称为平台必然限制，也不能证明历史上从未复现 | `OwlUpdateLogoutPrompt.swift:12–13` 将 squirrel#68 写成“系统天花板”；`InstallerActivationPolicy.swift:129`、`InstallerTISProbe.swift:3–5`、`InstallerActivationVerifier.swift:5–8` 有旧宿主失败/新宿主成功的 QA 描述。未找到对应的控制变量实验及原始输出。当前必须独立复现。 |

外部核对：[squirrel#68](https://github.com/rime/squirrel/issues/68) 的可读取 issue 正文是
2015 年对强制注销的用户反馈；本次网页未展示评论，因此没有据此确认任何 IMK 系统限制。
用户提供的微信报告明确限于静态符号、字符串和脚本；真实调用顺序、Sparkle 委托返回值仍有未知。
它支持待测方案，不替代 Owltype 实机证明。

## 只读探针

```sh
bash scripts/check-live-ime-version.sh --self-test
bash scripts/check-live-ime-version.sh --snapshot
bash scripts/check-live-ime-version.sh \
  --target-version "$target_build" \
  --installed-after "$install_started" \
  --completed-at "$install_completed" \
  --expect-selected "$before_source"
```

`target_build` 必须从**目标产物**的 CFBundleVersion 独立取得，不得从装后 live bundle
反推期望值。`install_started=$(date +%s)` 在启动安装前记录；
`install_completed=$(date +%s)` 在 GUI/命令安装完成时记录。ps 时间只有秒精度，
同秒启动不足以证明晚于安装起点，探针保守失败；在开始记录与实际安装间留一秒即可。
`--expect-selected` 是安装前记录的精确 source ID。首装需要验证选中猫头鹰时可传
`im.owltype.inputmethod.Owltype.Hans`；更新另一源时必须传那个源，不能为了探针变绿先切换。

探针只读磁盘和进程，调用系统 pgrep/ps/lsappinfo、既有 inode 检查以及
已安装 Owltype 的 `--current-input-source`。不 register、enable、select、open、kill，
不调用 sudo，不读写 HIToolbox。每个子命令最多五秒，总采集预算 25 秒。
输出保留命令、stdout/stderr、退出码及 JSON；磁盘、PID 前后发生变化时失败，避免混合证据。
探针要求当前用户运行；不能放进 root 安装阶段。

成功只标 `PASS_VERSION_ONLY`；`--snapshot` 最多标 `OBSERVATION`。
输入菜单、旧/新 TextEdit 真实上屏和无注销提示必须另外人工记录，并且都在装完 60 秒内。
未选择猫头鹰的更新场景先取 no-steal 快照，再人工选择猫头鹰完成打字，分别记录时间。
不能把新建一个 TextEdit 窗口当成新进程。

## 用户执行：基线与 B4

实验会短暂中断输入；先提交当前预编辑，保留工作。**以下命令由用户执行或另行明确批准**。
不安装工具、不改系统状态文件、不触碰凭据。所有文件证据留在
`~/Projects/_shared-work/owltype/verification/no-logout-20261010/`；不提交机器原始日志。

### B4 控制实验（同一安装版本，无文件替换）

目的：先隔离“服务器重启”和“文本输入服务重启”，排除包覆盖/版本提示的干扰。
这只能验证当前版本的重连；不能替代后续跨版本 B4 实验。

1. 保持当前 macOS 登录会话。手动打开一个 TextEdit 实例 O，选择猫头鹰，键入
   `nihao` 并用候选提交“你好”；保存只含测试文字的文档。记录 O 的 PID 和输入菜单截图。
2. 在普通用户终端开启不加载配置的 shell，采集初始证据：

   ```sh
   /bin/bash --noprofile --norc
   cd "$HOME/Projects/owltype-macos"
   umask 077
   evidence_dir="$HOME/Projects/_shared-work/owltype/verification/no-logout-20261010"
   mkdir -p "$evidence_dir"
   set -o pipefail
   bash scripts/check-live-ime-version.sh --snapshot 2>&1 | tee "$evidence_dir/b4-0-before.txt"
   /usr/bin/pgrep -lf TextEdit | tee "$evidence_dir/b4-0-hosts.txt"
   ```

   初始打字或版本/映射检查失败则停下，先修基线，不能以坏基线推断 B4。
3. 只重新启动当前用户的 Owltype，保持 O 不退出、不重建文档：

   ```sh
   { date -u; /usr/bin/killall -u "$(id -un)" -TERM Owltype
     /usr/bin/open -g '/Library/Input Methods/Owltype.app'
   } 2>&1 | tee "$evidence_dir/b4-1-restart.txt"
   bash scripts/check-live-ime-version.sh --snapshot 2>&1 | tee "$evidence_dir/b4-1-after.txt"
   /usr/bin/open -n -a TextEdit
   /usr/bin/pgrep -lf TextEdit | tee "$evidence_dir/b4-1-hosts.txt"
   ```

   确認 Owltype 新 PID 且 inode 检查通过；O 的 PID 不变，新 TextEdit N 的 PID 不同。
   在 O 和 N 中分别真实键入并提交“你好”，记录是否有候选、能否上屏、选中态、提示及时间。
   如果出现注销提示只记下并选“稍后”，不注销。
4. 若 O 失败、N 成功，保留两者，**仅**重启当前用户两个服务，再测相同文档：

   ```sh
   { date -u; /usr/bin/killall -u "$(id -un)" -9 TextInputMenuAgent TextInputSwitcher;
   } 2>&1 | tee "$evidence_dir/b4-2-restart.txt"
   bash scripts/check-live-ime-version.sh --snapshot 2>&1 | tee "$evidence_dir/b4-2-services.txt"
   /usr/bin/pgrep -lf TextEdit | tee "$evidence_dir/b4-2-hosts.txt"
   ```

   将服务命令的原始输出一并保存；进程不存在不等于已经成功重启。
   不同时杀 pboard/SystemUIServer，不重新注册，不改输入源 ID。
   再记录输入菜单截图和 O/N 的实际上屏结果。
5. 如果 O 仍失败而 N 成功，停止实验并报告，先由用户确认下一步，不能把“重开 App”改成
   合格标准。如果两者都失败，不能归因为旧宿主限制；先检查版本、进程和选中态。

回滚：实验未改安装文件或用户数据；从输入菜单切到现有系统键盘即可恢复普通输入。
需要恢复猫头鹰时由用户再次 `open -g '/Library/Input Methods/Owltype.app'` 后手动选择；
系统通常会自动重新拉起两个服务。若仍异常停止诊断并交回用户，不擅自注销或重开 O。

### 基线安装与跨版本 B4（等待产物确认）

需要用户指定旧版与目标版的现成 GUI/pkg 产物及已知可回退版本。
不运行发版/签名/公证流程，也不以文件名推断包内版本。
先只读检查产物版本、payload、身份和哈希，随后给出绑定到具体路径的安装及回滚命令，
再由用户执行。pkg 的命令形式为 `sudo /usr/sbin/installer -pkg <已核实的包> -target /`；
GUI 由用户打开已核实安装器并完成管理员授权。本阶段尚未授权 agent 实际安装。

安装前保持 O 运行并能提交“你好”，记录其 PID、选中态、版本探针、开始时间；
装完立即记完成时间，先记录无干预的探针/菜单/O/N 打字（N 必须是另一个 PID），
之后才允许做服务重启对照。基线有 RequireLogout 或更新提示时记录失败，不接受注销。
回退必须使用已核实的旧版安装器且不删除用户数据；如 GUI 拒绝降级，停止并另外确认恢复方案。
首装场景的“无 bundle/未启用”前提不能靠删除用户词典或手改 HIToolbox 制造；
当前主账号已有安装，清理范围/测试账号需用户另行选定后提供具体命令。

## 结果表（空缺和失败都保留）

| 场景 | 版本三证/60 秒 | 菜单截图 | 旧 TextEdit 上屏 | 新 TextEdit 上屏 | 无注销提示 | 选中态保留 | 原始输出 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| B4 同版本控制 | 待用户执行 | 未采集 | 未测 | 未测 | 未测 | 未测 | 无 |
| B4 跨版本基线 | 等待产物/用户执行 | 未采集 | 未测 | 未测 | 未测 | 未测 | 无 |
| S1 GUI 首装 | 未测 | 未采集 | 未测 | 未测 | 未测 | 首装选中待测 | 无 |
| S2 pkg 首装 | 未测 | 未采集 | 未测 | 未测 | 未测 | 首装选中待测 | 无 |
| S3 Sparkle/pkg 更新，原选猫头鹰 | 未测 | 未采集 | 未测 | 未测 | 未测 | 未测 | 无 |
| S3 Sparkle/pkg 更新，原选其他源 | 未测 | 未采集 | 未测 | 未测 | 未测 | 未测 | 无 |
| S4 GUI 更新，原选猫头鹰 | 未测 | 未采集 | 未测 | 未测 | 未测 | 未测 | 无 |
| S4 GUI 更新，原选其他源 | 未测 | 未采集 | 未测 | 未测 | 未测 | 未测 | 无 |

S3 的直接 pkg 安装与 Sparkle 下载/安装入口分别记录，不能互相替代。
尚未执行任一安装场景；不存在可报告的失败格或成功格。

## 自动验证与未验证项

- 探针自测 19 项通过；旧 inode 检查自测通过；verify runner 自测 8 项通过；shell 语法通过。
- 自测已接入 gate 的 portable_scripts 及 verify.py distribution；全 gate 尚未运行。
- Swift 四个指定测试组、check-release.selftest、release-cohort-selftest：产品修改前尚未运行。
- 未验证：B4 两组实验、macl spike、S1–S4、无 ABC、Intel、macOS 14/15、真实 Sparkle 入口。
- 本次只读宿主观察：macOS 27.0.1 (26A434)，装机 CFBundleVersion 和 lsappinfo 都为 2.0.12，
  PID 830 路径正确。尚无启动时间/inode/完整探针数据，**不满足版本三证验收**。
- 本次没有安装、注销、结束任何宿主进程，没有签名、公证、修改 feed 或发布。

## 决策日志（北京时间，逐步追加）

| 时间 | 做了什么 | 原因 | 证据 | 结果 |
| --- | --- | --- | --- | --- |
| 2026-10-10 08:10 +0800 | 从 freshly fetched main 建指定分支，核对 A1–B4 | 先确认实际代码，避免把旧注释当平台规律 | 基线 7f24eac；上表源码定位及 squirrel#68 正文 | A1/A3/B3 口径收窄；B1 因果和 B4 保留待测 |
| 2026-10-10 08:13 +0800 | 添加只读探针、19 项自测，接入 gate/distribution | 同时核对路径/启动时间、inode、三份版本，并拒绝不完整证据 | 探针自测 19/19、inode 自测、runner 8/8、bash -n | 离线通过；真实安装/打字未验证，停在用户实验前 |
