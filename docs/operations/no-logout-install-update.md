# 不注销安装与更新：实施和验收记录

## 当前状态

分支：`codex/no-logout-install-update`。核实基线：`7f24eac8fe379ec58e5fa5e1ae666d9e116a03b0`。
**最新Sparkle实验：原选猫头鹰的计时输入、选中态和延迟观察通过；应用管理通知的触发原因已定位，产品修复待完成。** 官方Sparkle祖先进程93816实际启动installer93915，14:13:23包安装结束；三证约1.13秒通过，Owltype PID94004/inode90964582。菜单有猫头鹰并勾选，原旧PID86600在20.79秒、新PID94180在13.84秒保存，人工26秒PASS。
截图同时出现macOS“Updater被阻止修改App”的提示；TCC日志在14:13:24记录SystemPolicyAppBundles拒绝，后续不安装探针确认是旧openURL申请目标App读写沙盒扩展被拒，不是换入或输入失败。三分钟进程观察仅有稳定PID94004，用户随后确认延迟观察PASS、无注销提示且输入正常。通知直接触发链已闭环，产品修复及发行签名验证未完成，#204保持开放；未回滚、未追加安装。

**最新验收：直接归档 pkg 更新、原选微信的场景通过。** 用户于2026-10-11 12:33运行绑定宿主的正式安装；版本三证约1.1秒通过，菜单截图显示猫头鹰且微信仍勾选。
真正旧TextEdit PID86600/窗口21126在24.83秒保存新增你好；安装后新PID76113在17.85秒保存；两侧观察均为原绑定窗口聚焦且Hans选中。用户32秒确认实际五笔、菜单和无提示，随后再次确认没有迟到提示。
证据位于`native-bound-host-ma6tlcf0`；保留测试版2.0.13，无需重做本场景。此结果支持本机旧宿主无需重开，不推广为所有系统保证。
这是隔离ad-hoc App的直接pkg入口，尚不代表Sparkle、GUI、首装、原选猫头鹰或旧live-bundle收据迁移通过。

此前宿主误绑、采样竞态、保存后失焦误判及各轮失败均保留在结果矩阵、决策日志和本地原始证据；没有将回放或不安装演练计为安装通过。

实现与验证状态：
- 已实现只读探针、Contents原子交换、归档pkg、共享会话自检、GUI复用、失败才提示注销及去RequireLogout。
- B4同版本和跨版本在本机均未复现旧TextEdit必须重开；发布版2.0.13及回滚2.0.12都曾延迟弹出注销建议。
- 暂存App方案b8ad566曾失败：版本自检通过但菜单缺失；日志证明PackageKit在postinstall之后注册暂存App。签名控制和绕过PackageKit的生产会话控制人工通过；改成ZIP归档后功能人工通过。历史失败保留在下表和决策日志。
- 代码提交18755cd的干净分支完整gate通过：1310项产品测试、宿主自测17项及所有14阶段，353.498秒；收据`20261011T042438Z-full-t3aqmbyb`。本次仅追加验收文档，不冒称文档新提交已跑完整gate。相关Swift96/96记录保留。
- draft PR #203已推送，未合并。S1/S2/S4、原选猫头鹰更新和真实Sparkle入口仍未通过。
- #204路线已获用户调整：保留官方Sparkle下载、验签和pkg调用，验证并修正与包内会话流程的配合；不再要求定制只下载接口。GUI发行验签未放宽；隔离ad-hoc副本不替代发行签名GUI验收。
- 用户允许本机隔离副本ad-hoc签名；未使用Developer ID、私钥、公证或发布。原收据仍2.0.13，App回滚不撤销收据。

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

### 已核实产物（2026-10-10）

用户指定当前装机 2.0.12 为旧版，线上已发布 2.0.13 更新 pkg 为目标；仅在下载失败时
才从两个 tag 打包。下载成功，因此未走本地打包，也没有签名、公证或读取私钥。

- Feed：[线上 v3 appcast](https://downloads.responsay.com/owltype/v3/appcast.xml)。
- 包：[2.0.13 Owltype-update.pkg](https://downloads.responsay.com/owltype/releases/2.0.13/Owltype-update.pkg)。
- 长度：15,151,841 字节，与 appcast 完全一致。
- SHA-256：`72494e3bfcb7efb9f0e75f7ec163a003835e4207197ee9c23b6dc59ba60e726f`，与 appcast 一致。
- 用装机 2.0.12 内的 SUPublicEDKey 和仓库 `scripts/verify-sparkle-eddsa.swift` 验证
  appcast Ed25519 签名，通过；未调用需要私钥的 sign_update。
- `pkgutil --check-signature` 确认 Apple Developer ID Installer 签名、公证信任；
  `spctl --assess --type install` 接受；包内 App `codesign --verify --deep --strict` 通过。
- pkg、包内 App、装机备份的签名团队一致。包内 build/营销版本均为 2.0.13，
  bundle ID、InputMethodConnectionName、公钥、完整 ComponentInputModeDict 与装机 2.0.12 一致。
- `pkgutil --payload-files` 显示 316 条 `./Owltype.app/Contents/` 路径，PackageInfo
  的安装根是 `/Library/Input Methods`；更新包无 RequireLogout。
  解包得到的 preinstall/postinstall 与当前分支脚本逐字节一致。
- 当前装机 App 已用 ditto 归档成 `Owltype-installed-2.0.12.zip`；解包后的版本仍为
  2.0.12，完整 plist 一致，深度严格签名验证通过。这是 App 文件备份，不是用户数据或收据备份。

本地证据子目录：`no-logout-20261010/published-2.0.13-wkcqsfhx`，位于前述 verification 根下。
保留 `appcast.xml`、下载响应头、`selected-item.json`、`validation.json`、
`content-checks.json`、签名/公证输出、完整 payload 列表、解包内容、2.0.12 备份。
`validation.json` 记录校验命令及退出码；`content-checks.json` 另存 feed、验证器和备份哈希。

### 基线安装与跨版本 B4（2026-10-10 已执行）

下面是针对上述已核实包的安装命令，目的仅为记录原有 2.0.12 → 2.0.13 更新行为。
**不要在完成 B4 同版本控制、保留旧 TextEdit 并准备好计时之前执行。**

```sh
artifact_dir="$HOME/Projects/_shared-work/owltype/verification/no-logout-20261010/published-2.0.13-wkcqsfhx"
sudo /usr/sbin/installer -pkg "$artifact_dir/Owltype-update.pkg" -target /
```

用户执行时应将安装 stdout/stderr、退出码、安装起止 epoch 保存到独立实验目录，
而不是仅运行上面两行后回忆时刻。密码由用户在原生终端/系统授权框输入。
用户已在本对话明确批准上述实验和安装；密码/生物识别仍由用户本人输入。

安装前保持 O 运行并能提交“你好”，记录其 PID、选中态、版本探针、开始时间；
装完立即记完成时间，先记录无干预的探针/菜单/O/N 打字（N 必须是另一个 PID），
之后才允许做服务重启对照。基线有 RequireLogout 或更新提示时记录失败，不接受注销。
本次回滚来源为已验签的装机 2.0.12 备份：用户先切到系统键盘，停止猫头鹰；
将 `rollback/Owltype.app` 暂存到 `/Library/Input Methods/.Owltype.rollback-2.0.12`，
核验签名并恢复 root:staff 所有权，再把失败的 live App 移到带时间戳的保留目录，
将暂存 App 移回 `/Library/Input Methods/Owltype.app`。若第二次移动失败，立即移回保留目录中的
失败 App，避免留下空安装路径。最后在用户会话重新启动并选择猫头鹰，运行版本/inode 探针和打字检查。
这些恢复步骤同样需要用户执行或明确批准；不删除词典、不重写系统输入源文件。
App 回滚不会撤销 pkg 收据或运行期间发生的用户数据变化；若出现数据格式不兼容，停止并另行确认恢复范围。
首装场景的“无 bundle/未启用”前提不能靠删除用户词典或手改 HIToolbox 制造；
当前主账号已有安装，清理范围/测试账号需用户另行选定后提供具体命令。

## 结果表（空缺和失败都保留）

| 场景 | 版本三证/60 秒 | 菜单截图 | 旧 TextEdit 上屏 | 新 TextEdit 上屏 | 无注销提示 | 选中态保留 | 原始输出 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| B4 同版本控制 | 重启后 2.0.12 路径/inode/LS 版本通过，新 PID 20422 | 输入菜单未采集；打字基线截图已存 | 用户确认五笔“你好”上屏 | 用户确认五笔“你好”上屏 | 无版本变化提示被观察到；非完整 UI 扫描 | 猫头鹰保持选中 | b4-live-gtbydw85/b4-control-result.json、b4-1-after-retry.txt |
| B4 跨版本基线 | 完成后 5/30 秒版本三证通过；人工打字时刻不满足计时证明 | 未采集；Installer 成功页已存 | 用户确认五笔“你好”上屏，旧 PID 86600 保留 | 用户确认新 PID 22804 上屏；文件未保存 | **失败：135 秒后弹出，用户选稍后** | 0 秒为 US，5/30 秒恢复 Hans | pkg-2.0.13-baseline 下 probe-*.txt、timeline.jsonl、user-acceptance.json、logout-prompt-final-log.txt |
| 同版本原发行签名控制 | 2.0.12，恢复PID3908，inode88291319；非完整60秒验收 | 用户以pass确认菜单可见；未采集 | 用户以pass确认五笔上屏 | 本组不覆盖 | 本组不覆盖；原版延迟提示另有截图 | 最终读回Hans；CLI曾打印选择失败 | signature-control-un78ig0b/signed-run/session.log、restored.txt、interpretation.json |
| S1 GUI 首装 | 未测 | 未采集 | 未测 | 未测 | 未测 | 首装选中待测 | 无 |
| S2 pkg 首装 | 未测 | 未采集 | 未测 | 未测 | 未测 | 首装选中待测 | 无 |
| S3 Sparkle/pkg 更新，原选猫头鹰 | 未测 | 未采集 | 未测 | 未测 | 未测 | 未测 | 无 |
| S3 直接 pkg 更新，原选其他源（b8ad566 ad-hoc 测试副本） | 通过：安装后约1秒内，PID70931，版本2.0.13、inode88254884；非发行签名 | **失败：用户报告无猫头鹰；未采集截图** | 未确认 | 未确认，新宿主70951 | 未确认 | 初次探针微信保持；人工干预后不计 | native-b8ad566-imqzppmw/session.log、after.txt、user-acceptance.json |
| S3 直接归档pkg更新，原选微信（2844297脚本，同一b8ad566 App） | 约1秒三证通过：PID30891/inode88685200；**完整60秒未证明** | **缺失：Ghostty无截图权限**；用户PASS确认菜单 | 用户PASS；文档含你好，保存于完成后100秒 | 用户PASS；archive-update-new-host.txt含你好，保存于完成后100秒 | 用户提交PASS时未见；更晚未覆盖 | 初次探针微信保持；之后用户选择Hans打字 | native-archive-1p8g5o1e/session.log、after.txt、user-acceptance.json、packagekit-install-archive.txt |
| S3 同归档pkg复测，原选微信 | 三证通过：PID15690/inode88861134；26秒人工PASS，但新宿主计时未证实 | input-menu.png：约9秒，猫头鹰可见、微信勾选 | 文档约24秒保存你好，用户PASS | 首次打在其他窗口；指定文件约114秒保存你好，补查PASS，**不计60秒** | 用户补查仍无提示；非无限期证明 | 自动完成后微信保持，随后人工选择Hans | native-archive-recheck-gwmw77gz/after.txt、manual-probe.txt、user-acceptance.json、input-menu.png |
| S3 指定新窗口复测（同包） | 三证通过：PID30889/inode88878518；20秒PASS | **约9.5秒截图只有微信与U.S.，无猫头鹰** | 46秒保存你好，输入法归属未确认 | 18秒保存你好，输入法归属未确认 | PASS含无提示，但整体人工结果待澄清 | 自动/人工后探针仍为微信；更晚Hans不能倒推 | native-window-check-0n2jrwny/user-acceptance.json、input-menu.png、after.txt、manual-probe.txt；用户无印象，**不计通过** |
| S3 输入法身份采样复测（同包） | 三证通过：PID43020/inode88900974；32秒PASS | input-menu.png：猫头鹰可见，微信勾选 | **未验证旧宿主**：旧文件29秒保存、Hans，但前台为新PID43694 | 21秒保存你好，Hans，新PID43694；typing-new-1.png | 人工32秒PASS未见提示 | 自动完成微信保持，之后人工Hans | native-identity-check-_5q9z_gs/user-acceptance.json、typing-observations.jsonl、window-ownership.txt；**不计完整S3** |
| S3 绑定宿主直接归档pkg，原选微信 | **通过**：约1.1秒，PID76011/inode89596300，三版本2.0.13；人工32秒PASS | input-menu.png：猫头鹰可见、微信勾选 | **通过**：原PID86600/窗口21126，24.83秒，Hans；old-save.png | **通过**：新PID76113，17.85秒，Hans；new-save.png | 用户PASS及随后追问均无提示 | 自动完成保持微信，之后人工选择Hans | native-bound-host-ma6tlcf0：after.txt、new-save.json、old-save.json、user-acceptance.json；本机ad-hoc副本 |
| S3 官方Sparkle，本地隔离feed，原选Hans | 三证约1.13秒通过：PID94004/inode90964582；26秒人工PASS | input-menu.png：猫头鹰可见且勾选 | 原PID86600/窗口21126，20.79秒Hans保存；old-save.png | 新PID94180，13.84秒Hans保存；new-save.png | 当场与延迟观察PASS；另有Updater应用管理拒绝通知待诊断 | 自动完成后Hans保持 | sparkle-official-5d03p3jc：祖先进程/HTTP/PackageKit、after.txt、new/old-save.json、user-acceptance.json；**计时输入及延迟观察通过，通知原因未闭环** |
| S3 真实 Sparkle 更新，原选其他源 | 未测 | 未采集 | 未测 | 未测 | 未测 | 未测 | 无 |
| S4 GUI 更新，原选猫头鹰 | 未测 | 未采集 | 未测 | 未测 | 未测 | 未测 | 无 |
| S4 GUI 更新，原选其他源 | 未测 | 未采集 | 未测 | 未测 | 未测 | 未测 | 无 |

S3 的直接 pkg 安装与 Sparkle 下载/安装入口分别记录，不能互相替代。
历史基线安装使用 Apple Installer GUI 打开已验签的更新 pkg，未执行原计划的 sudo installer CLI，
该历史基线不能声称已复现指定 CLI 入口，也未覆盖真实 Sparkle 或 Owltype GUI 安装器。
失败的基线不是修改后 S3 验收。安装成功页截图为 `pkg-2.0.13-baseline/installer-result.png`。

## 自动验证与未验证项

- 探针自测 19 项通过；旧 inode 检查自测通过；verify runner 自测 8 项通过；shell 语法通过。
- 自测已接入 gate 的 portable_scripts 及 verify.py distribution。
- 五组相关 Swift 测试 96/96 通过（20261010T032914Z-swift-zhm__izf）：OwlBundleSwapTests、OwlSessionRestartTests、InstallerActivationPolicyTests、OwlUpdateLogoutPromptTests、ActivationPolicyTests。
- check-release.selftest 17/17、release-cohort-selftest 33/33 通过；GUI 无签名构建通过。
- cfaba60 的干净分支头 gate 在 release_checks 失败：identity selftest 仍把夹具放到旧的 live payload 路径；此前所有阶段（含产品测试与构建）通过。修正夹具后 identity selftest 16/16；3e323f3 完整 gate 通过，证据 20261010T034015Z-full-hzs73vjg。失败证据：20261010T033505Z-full-ceatwrfb。
- 实际 product pkg 结构证据：no-logout-20261010/product-pkgs-_9_8c099，含命令、pkgutil payload 原始输出、两个展开目录及 result.json。PASS_STRUCTURE_ONLY，不是安装验收或可发布 cohort。
- 未验证：S1/S2/S4、S3原选猫头鹰、真实Sparkle入口、旧live-bundle收据迁移、无ABC、Intel、macOS14/15。直接sudo installer归档pkg、原选微信已通过；发布版CLI基线未补做。
- 真机：arm64、macOS 27.0.1 (26A434)。2.0.13 的 PID 22162 于安装期间启动；
  路径正确，inode 87910446 映射检查通过，磁盘/lsappinfo/目标均为 2.0.13。
- 未注销、未退出旧 TextEdit；已重启 Owltype 并安装发布包。没有签名、公证、修改 feed 或发布。

2026-10-10 08:56 补充真机前置观察：完整只读快照通过，PID 830 映射装机 inode 18743969，
磁盘/lsappinfo 版本均为 2.0.12。初始选中微信输入法；实验已选择并读回 Owltype.Hans。
旧 TextEdit PID 86600 保持运行，新增独立 `b4-old-host.rtf`，没有修改原有用户文档。
工具逐键发送 n/i/h/a/o 后出现英文，未确认中文候选；单独 Shift_L 被 CUA 拒绝，
输入菜单宿主 AX 查询超时。该结果不足以判断 Owltype 失效或 B4 成立。
已请求用户用实体键盘建立装前上屏基线；在此之前没有重启服务、结束进程或安装。
原始探针、观察记录和空白测试窗口准备态截图在 verification 根下的
`no-logout-20261010/b4-live-gtbydw85/`。安装包哈希和回滚备份签名复核仍通过。

## macl 交换实验（2026-10-10 11:06 已通过）

当前真实 App 外壳存在 72 字节 `com.apple.macl`；Contents 只有 provenance 属性。
`installer/Shared/OwlBundleSwap.swift` 保持外壳不变，调用 `renamex_np(RENAME_SWAP)`；
首装用 `RENAME_EXCL` 拒绝覆盖现有目标。原语只负责文件，不验签、不重启、不删除。
调用方必须串行化安装，保护暂存路径，在交换前验证身份/签名，在验收后决定旧内容保留策略。

普通用户目录中的签名副本预检发现：在 App 根目录保留 `.Contents.update` 时，
`codesign --verify --deep --strict` 报 `unsealed contents present in the bundle root`。
修正为交换后先把旧 Contents 移出 App，再验签，副本预检已通过；换回原 Contents 并移走
测试副本后验签也通过。因此后续实现必须在重启新进程前完成这一步，不能留下隐藏目录。
原始失败与修正记录：`no-logout-20261010/macl-spike-kz23tpby/preflight{,-corrected}.json`。

已用系统 swiftc 编译独立 helper（未调用 Developer ID 签名或公证），源码为
`scripts/owl-bundle-swap.swift` + 同一个 OwlBundleSwap。真实实验脚本为
`scripts/spike-bundle-swap-macl.sh`。用户已执行以下命令：

```sh
bash "$HOME/Projects/_shared-work/owltype/verification/no-logout-20261010/macl-spike-kz23tpby/run-macl-spike.sh"
```

实测结果：root 阶段 `RESULT=0`；外壳 inode 87976695 不变，Contents 从 87976696
交换为 88060372，再恢复 87976696；macl 哈希前/中/后相同。严格验签通过，
`.Contents.update` 已移出 live App。前后 PID 均为 37873、版本 2.0.12、inode 映射通过，
前后均选中微信输入法。这只证明这次交换没有改选中态，不是 S3/S4 更新的 no-steal 验收。
详见同目录 `result.json`、`post-spike-signature.txt` 和原始两份日志。

目的：将装机 2.0.12 的 Contents 复制为 `.Contents.update`，交换一次、把旧 Contents
临时保留到证据目录、核验签名和外壳 inode/macl 哈希，再交换回原 Contents inode。
不运行安装包、不重启服务器或输入服务、不改输入源和词典、不修改安装收据。
这只验证 macl/交换/签名，不能当作一次更新重连验收。实验期间请暂不打字或启动其他安装。

恢复：EXIT handler 在已知两侧 inode 对应时换回原 Contents，将测试副本保留到
证据目录 `retained-Contents`。它不会删任何一个 Contents；若 inode 非预期或换回失败，
保留原始/新目录并输出 STOP，停止后人工核验，禁止继续叠加安装。
`macl-spike.log` 保存 root 文件阶段，`macl-session.log` 保存执行前后用户会话只读探针。

## 决策日志（北京时间，逐步追加）

| 时间 | 做了什么 | 原因 | 证据 | 结果 |
| --- | --- | --- | --- | --- |
| 2026-10-10 08:10 +0800 | 从 freshly fetched main 建指定分支，核对 A1–B4 | 先确认实际代码，避免把旧注释当平台规律 | 基线 7f24eac；上表源码定位及 squirrel#68 正文 | A1/A3/B3 口径收窄；B1 因果和 B4 保留待测 |
| 2026-10-10 08:13 +0800 | 添加只读探针、19 项自测，接入 gate/distribution | 同时核对路径/启动时间、inode、三份版本，并拒绝不完整证据 | 探针自测 19/19、inode 自测、runner 8/8、bash -n | 离线通过；真实安装/打字未验证，停在用户实验前 |
| 2026-10-10 08:45 +0800 | 下载线上 2.0.13 更新包，验证签名/身份/payload，归档并验签装机 2.0.12 | 用户指定已发布包为复现目标，实际安装前备好基线和回滚来源 | 长度/SHA 一致；Ed25519、pkgutil、spctl、App codesign 全通过；本地 validation.json/content-checks.json | 下载成功，无需 tag 打包；仍未安装，等待用户真机实验 |
| 2026-10-10 08:56 +0800 | 接受本机实验/安装授权，采集完整只读快照并建立独立旧 TextEdit 文档 | B4 必须先证明装前可以真实上屏，不能用失效或未确认基线推断更新行为 | b4-0-before.txt、baseline-observations.json；CUA 单独 Shift 不受支持 | 版本映射基线通过；等待实体键盘打字结果，尚未重启或安装 |
| 2026-10-10 09:04 +0800 | 完成 2.0.12 同版本服务器重启对照 | 单独检验旧 TextEdit 是否必须重开 | PID 830→20422；旧宿主 86600 保留，新宿主 20527；用户确认两者均可五笔输入“你好”；b4-control-result.json | 同版本对照通过；首次 open 返回 -600，确认旧进程退出后一次重试成功；尚不能代替跨版本结论 |
| 2026-10-10 09:14 +0800 | 完成跨版本基线并记录延迟注销提示；准备 App 回滚脚本 | 用户确认两代宿主都能输入，随后提示证明 A1 与实际重连状态脱钩 | 收据09:05:30；日志09:07:45 presenting alert、09:07:48 later；5/30秒探针通过；user-acceptance.json | B4 本机未复现必须重开；无提示验收失败；sudo需密码，CUA禁止控制Terminal，回滚尚未执行 |
| 2026-10-10 09:17 +0800 | 核验用户执行的 App 回滚 | 按失败恢复约定保留现场，不撤销收据或删除词典 | rollback-output.txt；PID 37873、inode 87976705、磁盘/LS 2.0.12；恢复及保留 App 的深度严格签名均通过 | 旧 TextEdit 86600 保留；收据仍2.0.13；实际打字待确认 |
| 2026-10-10 09:20 +0800 | 新增 OwlBundleSwap 和 11 项真实文件系统单测 | 保持 App 外壳，以 RENAME_SWAP 交换 Contents，失败不走两次移动；首装使用 RENAME_EXCL | verify.py swift --test OwlBundleSwapTests 11/11；证据 20261010T011853Z-swift-d1tphz1c；SDK sys/stdio.h 定义交换 API | 临时目录通过；实际 App 外壳存在 macl，尚未验证其影响，也未接入安装流程 |
| 2026-10-10 09:22 +0800 | 记录回滚后实际打字与随后再次弹窗 | 不把暂未出现弹窗当成最终无提示验收 | 用户先确认两边正常，再提供2.0.12注销提示截图；rollback-user-acceptance.json、rollback-logout-prompt-log.txt | App与打字恢复；无提示项仍失败，版本变化策略也触发降级提示 |
| 2026-10-10 09:24 +0800 | 准备 macl 实验 driver/恢复脚本并完成签名副本预检 | 在真实安装前验证交换期间签名边界，避免隐藏暂存目录影响新进程启动 | 初次严格验签失败 unsealed contents；将旧 Contents 移出 App 后交换/换回验签均通过；shell语法通过 | 修正一次后预检通过；真实 /Library 交换尚未执行，等待用户 |
| 2026-10-10 11:06 +0800 | 核验用户执行的真实 macl spike | 在接入安装调用链前确认保留外壳的 Contents 交换可用 | macl-spike.log RESULT=0；外壳87976695不变；Contents87976696→88060372→87976696；macl哈希一致；严格验签0 | 本机macl不阻碍交换；进程37873及微信选中态保持；尚非更新重连验收 |
| 2026-10-10 11:15 +0800 | 实现用户会话重启序列、fresh TIS/进程探针与 --finish-install CLI | 替换后有界结束旧进程；首装注册启用；选择读回后只刷两个TextInput服务；版本/path/inode共同自检 | 新增11项会话测试，连同四个指定组共113/113；证据20261010T031407Z-swift-01iq58j7；真实只读探针正确，开发目录重启入口被拒绝 | 尚未接入pkg/GUI或真机重启；第一次集成编译漏括号，修正一次后全通过 |
| 2026-10-10 11:24 +0800 | pkg改为隐藏暂存payload、root文件提交与用户会话收尾；新增校验失败恢复测试 | 消除PackageKit原地覆盖live和收据边界延迟任务，交换后移出旧Contents再验签 | Swift交换/会话26/26；release selftest15/15；真实未签名组件pkgutil payload无live路径，PackageInfo无bundle注册；证据staged-pkg-9uoglhmo | 离线通过，未安装；结构检查初次把系统/var软链误判，限定到payload边界后修正通过；两产品pkg仍待最终构建 |
| 2026-10-10 11:26 +0800 | GUI复用 --commit-install 与 --finish-install，删除旧Verifier及旧整包替换/服务清理 | 两个入口使用相同原语和自检，避免30秒软超时直接建议注销 | GUI无签名构建通过；相关Swift组通过，证据20261010T032538Z-swift-_5dfrr0m；release-cohort-selftest33/33 | 未安装GUI；首次测试编译有两处旧参数，修正一次后通过 |
| 2026-10-10 11:31 +0800 | 删除版本变化触发和常驻注销菜单，只在自检失败时提供恢复；两个pkg去RequireLogout并更新发版断言/文档 | 基线升级及降级都在成功上屏后延迟弹窗，版本差异不能证明会话坏了 | 五组Swift96/96；release selftest17/17；证据20261010T032914Z-swift-zhm__izf | 离线通过，正式S1–S4待测；Sparkle仅下载接管仍未实现 |
| 2026-10-10 11:40 +0800 | 修正 identity 自测夹具的 pkg 暂存路径 | 完整 gate 检出旧夹具路径导致毒化 payload 未被扫描，不能放宽断言 | cfaba60 gate 的 release_checks 失败；修正后 identity selftest16/16 | 单次修正通过；即将重跑干净分支头 gate |

| 2026-10-10 11:46 +0800 | 完成两产品pkg结构验证及完整gate，推送分支并建draft PR #203；清理旧注销标题和打包注释 | 交付可审阅修改，保留失败与真机证据边界 | 3e323f3 gate 全阶段通过、产品1310/1310；product-pkgs-_9_8c099 两包无live payload/RequireLogout | 未合并/发布；签名约束待用户答复，S1–S4及Sparkle仅下载仍未完成；本次收尾提交后重跑分支头验证 |

| 2026-10-10 11:57 +0800 | 读取用户执行的修改版直接pkg更新，记录菜单缺失及手动删加，提供回滚 | 不能将版本自检通过当成菜单/实际输入成功，也不能把人工修复当自动生效 | installer退出0；PASS_VERSION_ONLY、inode通过；用户报告无猫头鹰；manual-removal-readd-diagnostics.json | 本次失败；保留失败现场并等待用户回滚；父源两次读数受人工操作混杂，根因未定；未叠加补丁 |

| 2026-10-10 12:44 +0800 | 核验用户回滚及打字恢复，准备同代码不同签名对照 | 上次同时改变代码和签名，人工删加使后续状态不可归因；先控制变量 | rollback-verification.json、rollback-user-acceptance.json；signed/adhoc严格验签通过，两架构代码段和Info一致 | 2.0.12恢复且用户确认旧宿主可打字；控制实验待用户执行，未改装机状态、未叠加产品补丁 |

| 2026-10-10 12:53 +0800 | 核验signed控制及自动恢复，修正交互脚本仅识别大写PASS的缺陷 | 用户小写pass不应被当成输入法失败，选中CLI错误也需区分随后读回 | signed-run原始日志、interpretation.json；大小写/空白等10项自测；恢复严格验签及inode通过 | 人工菜单/旧宿主控制通过，误判原文保留；不要求重做；ad-hoc待用户执行，未叠加产品补丁 |

| 2026-10-10 13:03 +0800 | 核验 ad-hoc 控制通过和自动恢复；提取 PackageKit 晚注册证据并准备生产会话控制 | 排除单纯签名假设，纠正空组件列表能阻止注册的错误保证；先隔离再改产品 | adhoc-run/interpretation.json；PID10550/inode88299480严格验签通过；packagekit-finalization.txt；控制脚本 bash -n 通过 | 两个同版本控制人工通过；原修改pkg仍失败；暂存App晚注册已证实，菜单因果待测；未叠加产品补丁 |

| 2026-10-10 20:13 +0800 | 核验生产会话无PackageKit控制及恢复 | 同一失败App隔离包安装上下文，保留初始选中态差异 | session-control-r6pwto8y/interpretation.json；用户17秒内PASS；恢复严格验签/版本/inode通过、收据一致 | 新版会话控制通过；不计S3/S4；下一步修暂存App晚注册，未再次安装 |

| 2026-10-10 20:20 +0800 | 暂存payload改成ZIP，私有解包交换后移除临时App，所有内容门禁先解包 | 实际日志证明空组件列表不足以阻止暂存App晚注册；回归先拒绝旧失败布局再修复 | 旧布局回归先红后绿；6项归档检查、release17/17、identity16/16、secret16/16；两个真实包解包diff/严格验签通过，native-archive-1p8g5o1e | 离线通过，未安装；secret夹具第一次重复install-location，修正一次后通过；归档包真机和旧收据迁移效果仍待验证 |

| 2026-10-10 20:57 +0800 | 核验归档包安装功能与回滚，前移Ghostty截图权限预检 | 用户PASS但112秒后才提交，截图权限缺失使验收不完整；不把人机交互延迟当成激活失败 | 三证约1秒通过；文档保存100秒；无PNG；本轮安装日志无暂存App Touched/Registered；恢复严格签名/映射通过 | 功能通过但不计完整S3；只改外部验收driver，同包复测待用户；3项预检失败/成功分支检查通过 |

| 2026-10-10 21:31 +0800 | 核验同包复测截图、26秒PASS与新宿主澄清 | pass不能替代指定新宿主的实际结果；用户确认首次打在其他窗口 | 菜单PNG可见且微信勾选，三证通过，旧文档24秒保存；指定新文档114秒补查保存你好，无提示 | 功能通过，完整60秒仍缺新宿主项；保留测试版，未改产品或再次安装 |

| 2026-10-10 21:39 +0800 | 核验新窗口复测，记录人工PASS与菜单/输入源证据不一致 | 你好文本和版本通过不能证明猫头鹰实际参与输入 | 新18秒/旧46秒保存；菜单无猫头鹰；20秒PASS后仍微信，后续Hans；用户无印象要求再测 | 不计通过，保留测试版；同包driver增加保存截图及输入源/前台PID只读采样，隔离自测通过，未再次安装或改产品 |

| 2026-10-10 21:43 +0800 | 核验身份采样并查窗口所属进程，暂停重复装机 | 新TextEdit自动恢复旧文档，使文件名不足以区分安装前宿主；不把采样部分成功扩大为完整通过 | 菜单有猫头鹰，Hans下21/29秒保存；两次前台PID43694；CGWindow所有权确认新旧PID都有同名旧文档 | 新宿主通过，旧宿主未验证；保留测试版和证据，不再给无绑定的重装命令，不叠加产品补丁 |

| 2026-10-11 12:11 +0800 | 修正验收宿主绑定与保存判定，准备不安装演练 | TextEdit恢复同名旧文档导致旧宿主误认；先验证验收工具再请用户安装 | 原旧PID86600/窗口21126精确聚焦；新50212与旧86600两轮切换；4项本机错误绑定、14项离线回放通过；distribution全步骤通过 | 未安装、未重启输入法；只准备rehearse.sh，真实五笔演练与后续安装仍未计通过；完整分支头gate待最终阶段 |

| 2026-10-11 12:18 +0800 | 修正保存采样顺序竞态 | 文件读到旧状态后保存、AX读取已晚于保存13毫秒，原循环丢掉正确下界 | 原始new-save.json，interpretation.json；真实顺序回放先红后绿，15项自测通过 | 不放宽60秒，不把演练算安装结果；保留失败脚本/校验和，未安装或回滚；同一不安装演练待复验 |

| 2026-10-11 12:20 +0800 | 核验第二次演练并停止后续修补/重试 | 新宿主通过；旧宿主正确保存后0.41秒焦点已回Ghostty，触发双侧焦点门槛 | old-save.json：原PID86600/窗口21126、Hans、窗口18→19、15.81秒保存；后置PID49177经ps确认Ghostty | 保留原始STOP，不计整体演练通过；旧宿主有新增上屏/保存观察，非产品输入失败；遵守两次限制停下，未改代码或装机 |

| 2026-10-11 12:24 +0800 | 用户授权继续后修正保存后焦点判定并回放原始记录 | 已聚焦的原窗口有新增文字且保存一致时，切回终端不能抹去先前输入证据 | 真实new/old-save原文回放均无错误；新增回归先红后绿，17项自测通过；原始STOP保留 | 不要求重做已有焦点演练；未补造旧图，未计S3或执行安装；完整分支验证随后运行 |
| 2026-10-11 12:37 +0800 | 核验绑定宿主正式pkg更新并保留测试版 | 用真实旧进程身份排除同名文档恢复混淆，不重复已通过场景 | 三证1.1秒、菜单微信保持、旧24.83秒/新17.85秒Hans保存、人工32秒PASS及迟到提示追问无；18755cd完整gate通过 | 直接pkg原选微信通过；本机B4旧宿主无需重开；其余入口/选中态/平台仍未验证 |
| 2026-10-11 13:58 +0800 | 核对#204实际Sparkle接口与验签时序 | 微信报告中的接管接口并非官方2.6.2 API，不能把下载回调当作可信包交接 | 固定子模块41847a5及链接框架2.6.2；通知无路径/接管返回值，包验签在安装器内；禁止重启委托会中止推进 | 两种路线及成本已交用户选择；未改产品/依赖、未安装，保留#204开放 |
| 2026-10-11 14:10 +0800 | 按用户决定保留官方Sparkle，准备隔离真实入口实验 | 无需维护定制框架；源码尚未证明重复启动故障，先补可归属的端到端证据 | 固定版本源码、同包哈希/临时公钥验签、loopback检查、原旧窗口绑定及日志反例回放；审阅修复互斥和来源验证 | 未改产品、未安装；#204仍待用户真机执行，不新增无收益单测 |
| 2026-10-11 14:16 +0800 | 核对官方Sparkle原选Hans实验 | 不能只凭pkg成功或人工PASS覆盖更新器收尾异常 | 下载请求、Autoupdate→installer来源、三证和菜单/两宿主截图通过；26秒PASS；TCC出现Updater应用管理拒绝 | 计时输入与Hans保持通过；延迟观察及通知原因未闭环，保留现场，不重装或自动回滚 |
| 2026-10-11 15:34 +0800 | 增加并构建Sparkle应用重开源码补丁 | 官方无可替代收尾接口，避免临时插桩进入产品 | 双架构构建通过；实际编译Updater无TCC拒绝；release自测17/17 | 保留官方下载验签安装流程；产品补丁完成，完整gate/审阅/真机待完成 |
| 2026-10-11 15:42 +0800 | 修复审阅发现的无Git源码包构建回归 | 对应源码归档必须能独立构建，不能依赖仓库元数据 | Gitless真实源树补丁自测通过；隔离归档make sparkle双架构构建通过；Standards复核零遗留、Spec零缺陷 | 不安装、不改系统权限；完整新分支头gate随后运行 |
| 2026-10-11 16:34 +0800 | 核验补丁后的真实Sparkle更新及延迟观察 | 以完整安装确认隔离探针修复，避免只凭人工PASS结案 | 02a24b4三证、菜单Hans、新17.83秒/原旧22.18秒保存、27秒人工PASS、三分钟延迟PASS；Updater退出且捕获日志无其AppBundles拒绝 | 本机原选猫头鹰分支通过；其他选中态及平台仍未验证，不重复安装、不合并 |
| 2026-10-11 16:49 +0800 | 按用户新授权squash合并#203并准备2.0.14发布 | 剩余验收移交#204/#205，不重复通过场景；发布授权覆盖必要签名公证和分发 | 当前头21cedc8完整gate14阶段通过；#203合并为fb88c69，线上仍2.0.13 | 准备独立版本提交，走唯一release入口；尚未发布，不自动安装 |
| 2026-10-11 14:57 +0800 | 定位Updater拒绝并完成旧/新API交叉对照 | 系统跟踪避免把目录删除fallback误作通知原因 | 精确读写扩展参数、EPERM调用栈、同PID的A/B/A/B与TCC对照 | 直接原因已证；无再安装、无权限改动；官方依赖下产品修复待完成 |
| 2026-10-11 14:29 +0800 | 收录用户延迟PASS并只读追查Updater通知 | 避免重复安装或用权限放宽掩盖问题 | TCC PID93817拒绝时间、LaunchServices请求、固定2.6.2源码及签名对照 | 功能与延迟观察通过；拒绝操作路径未知，签名因素仍是假设；不改产品、不改权限 |
| 2026-10-11 14:47 +0800 | 建立不安装的Updater拒绝复现 | 避免为诊断重复完整安装；控制TCC责任进程归因 | launchd副本PID10783/11609的AppBundles拒绝，原Owltype94004保持 | 已能独立复现；准备30秒系统调用跟踪，因sudo限制待用户执行，无产品补丁 |

## 菜单缺失：控制结果与后续隔离

先保持代码和版本均为 2.0.12，以相同的共享文件交换、用户进程重启和 TextInput 服务刷新流程做
signed 控制，再做 ad-hoc 对照。第一组失败就停止，不继续第二组；每组退出时都恢复发行签名 2.0.12。
候选目录为本地证据根下 `signature-control-un78ig0b`。`code-section-proof.json` 证明两架构主程序
`__TEXT,__text` 以及 Info.plist 一致；`preflight.json` 保留严格验签及比对命令。signed 与 ad-hoc 控制均已运行并通过人工菜单/旧宿主打字检查。
驱动为同目录 `run-control.sh signed|adhoc`，只允许普通登录用户执行，内部 sudo 仅调用既有文件提交 helper。
不运行 pkg、不改收据、不删除词典、不注册/启用输入源来修补现场。人工确认之后自动换回已验签副本。

待区分的假设：

1. 若同代码同流程只在 ad-hoc 组丢菜单，签名变化是该序列中的关键变量；这仍不覆盖所有 PackageKit 场景。
2. 若 signed 组也丢菜单，优先定位交换/会话刷新顺序，不能归咎签名。
3. 若两组均通过，回到修改版代码、pkg 执行上下文或重复 LS claims 的差异继续隔离，不能宣布原失败消失。

菜单 AX 查询超时，不能仅靠 TIS 布尔值自动确认实际菜单。每组人工 PASS 必须同时满足菜单可见和旧宿主上屏；
任何手工删加输入源都使该组失败。统一日志未提供可归因的 Owltype 拒收原因；CharacterPaletteIM 的错误不作为 Owltype 根因。


### PackageKit 最终注册的直接证据

本地 `native-b8ad566-imqzppmw/packagekit-finalization.txt` 保留 `/var/log/install.log` 的
本次安装原始片段；`packagekit-finalization-analysis.json` 区分观察与推断。
组件 PackageInfo 的 bundle-version/relocate 均为空，但系统仍记录：

```text
11:56:08 postinstall: INSTALL_SESSION_OK pid=70931 version=2.0.13
11:56:08 installd: Writing receipt for im.owltype.inputmethod.Owltype
11:56:08 installd: Touched bundle /Library/Input Methods/.Owltype.pkg-staging/Owltype.app
11:56:08 installer: Registered bundle file:///Library/Input%20Methods/.Owltype.pkg-staging/Owltype.app/ for uid 0
```

这确认 B1 的“最终注册晚于 postinstall”仍存在于新暂存方案，不能再声称空组件列表会阻止注册。
日志还声明 receipt-based obsoleting，但没有直接文件删除证据，不据此断言旧 live Contents 被删。
当前优先级：晚到的暂存 App 注册 > 生产会话收尾与控制脚本差异 > 多份 App 注册记录干扰。
同版本两签名控制已降低“单纯换签名”的解释力，但没有排除其与 PackageKit 的组合影响。

下一控制保留失败产物 b8ad566 的字节、签名和 `--finish-install`，绕过 PackageKit，使用既有文件 helper。
若仍缺菜单，则晚到的 PackageKit 注册不是该失败的必要条件；若通过，则优先缩小 PackageKit/启动上下文的差异，
仍不能直接归因于某一条注册。控制脚本为本地 `session-control-r6pwto8y/run-control.sh`，严格验签/hash/旧宿主守卫、
原选中态读回、版本探针和自动恢复均已准备；bash 语法检查通过，尚未真机执行。
起始选中态按现场记录（当前 Hans，上次失败时微信），差异必须保留，不作同条件因果证明。
控制通过也不算 S3/S4；下一轮产品修复需避免把可注册的暂存 App 交给 PackageKit，并重新验证完整安装边界。

2026-10-10 20:13 更新：上述生产会话控制已运行通过；新版PID21222，用户17秒内确认菜单和旧新宿主五笔上屏，未出现提示。恢复PID21480、inode88385964、发行签名2.0.12、Hans选中及收据不变均核验通过。未留输入菜单截图，未覆盖迟到提示，也不抹去起始选中源差异。

归档payload修订：`native-archive-1p8g5o1e`保留两个pkg、pkgutil列表、原始命令、解包后严格验签和逐文件diff；App仍是已通过控制的b8ad566 ad-hoc字节，没有重新签名。新的完整gate在本次提交后运行，结果保存在verification收据与PR，不能用之前b8ad566结果代替新分支头。


### 归档包原生结果与截图权限阻塞

`native-archive-1p8g5o1e/user-acceptance.json` 区分功能结果、计时证据和回滚。
20:50:57安装完成；约1秒后探针通过，原选微信保留。用户确认菜单及旧新五笔上屏，文档也均含“你好”。
Ghostty截图报 `could not create image from display`，用户随后说明刚授予权限。没有生成菜单PNG；
文档保存时间约100秒，提交PASS为112秒。不能从提交时间反推输入法实际何时可用，60秒标准仍保留。
脚本依原策略自动恢复签名2.0.12，PID37072、inode88691493、微信选中；收据保留新安装时间。
本次安装日志未再记录暂存App的Touched/Registered；旧暂存收据的obsoleting因preinstall已移走目录而报路径缺失。
这不是从旧发行live-bundle收据迁移的验证，仍不代表所有LaunchServices活动都已观测。

外部复测driver为 `native-archive-recheck-gwmw77gz/run-update.sh`，复用同一个pkg字节。
它先在执行它的Ghostty进程环境实际截图，验证成功再等用户准备，并在sudo认证后才启动安装计时。
预检失败则不切输入源、不sudo、不安装；失败/空图/成功三种预检分支已在隔离夹具运行。
原始112秒与缺图记录不覆盖、不改写。复测已运行，见下文；新证据不补记为上一轮证据。


### 同包复测：菜单及功能通过，指定新宿主计时未完整

`native-archive-recheck-gwmw77gz`保存完整探针、菜单PNG、两个宿主PID列表、人工原文和`user-acceptance.json`。
21:28:20安装完成；PID15690于安装期间启动，live路径、inode88861134及磁盘/LS/目标2.0.13全部一致。
约9秒时截图清楚显示猫头鹰条目及微信选中勾；约24秒旧文档保存你好，26秒收到PASS。
人工后置读回Hans，表示用户可选择猫头鹰；不改变自动收尾保持微信的证据。
指定新文件最初0字节，用户确认输入在其他窗口。打开指定`archive-check-new-host.txt`后，用户确认五笔你好上屏并保存、无提示；文件13字节且含你好，mtime为安装完成后113.65秒。
因此该轮功能通过，指定新宿主在60秒内上屏仍未证明。测试版2.0.13保留，未因证据缺口擅自回滚。

下一轮外部驱动为`native-window-check-0n2jrwny/start.sh`，仍是同字节pkg。用户执行后先截图预检、恢复已验签2.0.12，再进入更新计时；菜单截图完成后自动将唯一命名的新文档`OWLTYPE-NEW-HOST.txt`调到前台，先验新宿主再验保留的旧宿主。三个脚本bash语法及前台打开顺序检查通过，尚未执行；失败保留内容并恢复发行版，不改词典或撤销收据。


### 指定新窗口复测：人工结果与身份观察不一致

`native-window-check-0n2jrwny/user-acceptance.json`保存解释，原始PASS不改写。
21:34:48安装完成，版本三证通过；约9.5秒菜单截图仅有微信与U.S.，TIS父源及Hans仍enabled。
新文件约18秒保存、人工20秒PASS、旧文件约46秒保存，均含你好；不能只凭文本认定使用了猫头鹰。
用户表示不记得当时是否切换，要求重测。后续只读快照为Hans；该安装日志窗口无暂存App的Touched/Registered，仍不能解释菜单当时缺项。
新驱动`native-identity-check-_5q9z_gs`只改本地验收采集，同pkg同App；保存指定测试文档时截主屏幕，最多每份3张，仅本地保存，持续采样前台PID/输入源到60秒。
记录不把瞬时输入源当作字符归属的绝对证明，最终仍需人工确认；三个bash语法检查、Python语法及隔离模拟的保存/输入源切换/PID解析/时限检查通过。
用户执行前未安装、回滚或更改产品。原两次不完整证据及本轮矛盾保留，不继续无证据产品补丁。


### 输入法身份采样：发现旧文档恢复到新宿主

`native-identity-check-_5q9z_gs/user-acceptance.json`汇总原始探针、`typing-observations.jsonl`及三张本地截图。
21:40:55安装完成，43020进程启动时间晚于安装开始；约21秒新文档和约29秒旧文档保存时，采样均为Hans，前台PID43694。
截图确认输入菜单猫头鹰存在、微信原选中态保持，两份文档可见你好；人工32秒PASS包含当时无提示。
只读CGWindowList查询`window-ownership.txt`进一步确认：43694同时拥有`OWLTYPE-IDENTITY-NEW.txt`和`b4-old-host.rtf`，86600仍拥有另一个`b4-old-host.rtf`。
因此本次新宿主通过，但安装前旧宿主未测到。open -n启动TextEdit会恢复旧文档，按标题找窗口不能保证对应原进程。
此前基线B4/生产控制/归档复测的旧宿主人工确认属于历史报告；没有窗口所属进程证据的部分不能独立排除同样混淆。
暂停重复真机安装，先修正验收宿主绑定；不把此缺口解释为必须重开App，也不改产品、放宽60秒标准或再次自动回滚。


### 旧窗口绑定修复与无安装演练

版本化工具：`scripts/ime-acceptance-host.swift`和`scripts/check-ime-host-evidence.py`，自测接入gate及distribution。
helper只操作指定TextEdit窗口，不安装、输入字符、改输入源或关闭窗口。PID重用、启动时间变化、窗口重建、同名新进程都拒绝；新宿主使用单次启动参数忽略恢复状态，不改系统偏好。
最初观察器要求保存前后均聚焦；现已修正：保存后可失焦，但保存前必须已在Hans聚焦的原窗口观察到与保存一致的新增文字；身份、计数及60秒限制保持。子进程有超时，截图缺失不能记通过。
本地`host-binding-repair`保存old-host.json、原生焦点往返记录、native-negative-checks.json、driver-audit.json及Codex预检日志。全部不涉及系统安装；新建空白演练文档保留，没有自动关闭任何已有窗口。
离线14项测试覆盖原生观察到的同文档新PID误认、PID复用、窗口重建、非猫头鹰输入源、焦点变化、已有文字、晚保存、安装期间新起进程及其他进程保存同路径。
聚焦distribution收据`20261010T135043Z-distribution-bp1il6y4`通过（当时工作区有本修复）；最后的超时约束另以同组自测验证，不冒称分支头完整gate通过。
`native-bound-host-ma6tlcf0/preflight.sh`在执行终端检查AX/窗口身份和截图；不抢焦点，不调用sudo。`rehearse.sh`在确认准备后创建唯一新文档，自动先切新窗口、采集保存，再切真正旧窗口、采集保存。该入口没有安装/回滚调用，结果标签为REHEARSAL_EVIDENCE_READY，不能替代S3。
实际安装入口随后由用户执行并通过，详见当前状态和结果矩阵；准备阶段记录与原始演练失败保留。


### #204：Sparkle 交接接口核对（2026-10-11）

核对对象为实际链接框架2.6.2及同版本子模块提交`41847a58cdef7506b257591fcca6f9495df591d4`，不是当前上游最新版。
微信逆向报告里的`shouldExtractUpdate:downloadedFilePath:clanerBlock:`不在该版本公开头文件或源码中；该报告不能直接作为官方API接入方案，尚未证明微信如何提供这个扩展。

| 证据（Sparkle子模块内） | 结论 |
| --- | --- |
| `Sparkle/SPUUpdaterDelegate.h:291–296` | didDownloadUpdate只给appcast item，不给本地下载路径，也无接管返回值。 |
| `Sparkle/SPUCoreBasedUpdateDriver.m:178–183,216–250` | 通知后直接进入内部extractUpdate并启动安装器；公开willExtractUpdate也只是通知。 |
| `Autoupdate/AppInstaller.m:194–201` | 包的下载签名预校验在安装器里执行；下载通知不等于验签通过。 |
| `Sparkle/SPUInstallerDriver.m:504–520` | updaterShouldRelaunchApplication返回false会中止本次安装推进，不是仅关闭安装后的重启。不能以此方法作为完成接管。 |
| `Autoupdate/SUGuidedPackageInstaller.m:41–48` | 标准package最终仍调用系统installer安装pkg；PR中的包内文件/会话逻辑继续适用，但真正Sparkle生命周期尚未验收。 |

官方[安装流程文档](https://github.com/sparkle-project/Sparkle/blob/41847a58cdef7506b257591fcca6f9495df591d4/Documentation/Installation.md)说明目标进程退出后才进行最终安装，并可在安装后重启。直接pkg通过不能证明该退出/重启配合通过。

实现选择待用户确认：保留官方下载、验签、pkg调用并验证会话配合（调整只下载要求）；或者维护定制Sparkle，新增安全交接边界及依赖构建/更新维护。未使用私有API、扫描下载缓存、跳过验签或改依赖。尚未修改产品代码或执行安装；不把接口调查记为#204完成。


### #204：保留官方流程，准备真实入口验收

用户已选择保留官方Sparkle，并明确不做没有边界收益的过度单元测试。此前“只下载”要求已调整，#204验收正文同步。仅在出现可复现问题后改产品，不凭两个启动调用推断重复进程。
源码补查：Sparkle的InstallerProgress在pkg完成后通过普通NSWorkspace openURL打开同一路径，未要求新实例；包内已执行open -g和版本/单PID自检。需要真实入口验证最终PID稳定、选中态及宿主输入，不能只看postinstall成功。

本地证据`sparkle-official-5d03p3jc`包含：同字节已通过归档pkg、只改本地feed/临时公钥/版本标记的ad-hoc测试基线、绑定宿主与回滚脚本。基线代码仍为此前通过的b8ad566，不冒充原发行2.0.12代码；其显示版本2.0.12用于触发对2.0.13的真实检查更新。
临时Ed25519密钥只在内存生成，不落私钥、不读钥匙串；用仓库公钥验签器复验包签名。HTTP只绑定loopback，目标包恢复正常产品feed与公钥。未运行安装，尚不算Sparkle验签/授权/更新链通过。

执行驱动先验证原旧PID86600/窗口21126及截图权限；用户执行文件准备后，从真实“检查更新”走Sparkle。观察器关联本地feed/下载、installer的Sparkle祖先进程及相同PID的PackageKit事务；只有postinstall自检与事务结束同时记录后才开始60秒宿主步骤，缺证据即停。保留3分钟进程观察和人工迟到提示确认。
脚本审阅修正：准备/回滚共用操作锁；授权后和提交前核查安装进程及PackageKit结束边界，状态不明不回滚；禁止安装未结束时自动交换备份。失败现场保留，由用户确认安全结束后恢复已验签发行版2.0.12，不删词典、不改收据。
准备检查：公钥验签、loopback feed和pkg字节一致、安装日志边界回放与无Sparkle祖先/无会话成功/其他包反例、shell/Python语法通过。原旧窗口只读身份仍一致。没有新增产品单测，也没有把这些检查计为原生验收。


### #204：Updater应用管理通知的只读诊断

本轮用户确认延迟观察PASS，无注销提示、输入正常。证据目录仍为`sparkle-official-5d03p3jc`；原始`notification-window.json`、精确摘录`notification-focused.json`、签名对照`notification-signatures.txt`与`user-acceptance.json`保存在本地。

- 已确认：14:13:23安装和会话恢复完成。14:13:24.292488，Updater PID93817记录LaunchServices.launchViaCSUA；14:13:24.299076，TCC将AppBundles请求归因到同一Updater；14:13:24.312402因unentitled binary无法提示授权而拒绝。提示不是包安装失败，也不是注销提示。
- 推断：最接近的调用是安装后的NSWorkspace openURL（固定Sparkle 2.6.2源码InstallerProgressAppController.m:373–405）。随后源码延迟0.3秒才删除自己的缓存App；进程14:13:24.680920退出，缓存副本已不存在。因此优先怀疑重新打开App时的系统操作，缓存清理假设较弱；日志没有调用栈和被拒绝路径，不能定为具体系统调用。
- 签名对照：实验的基线/目标App及嵌套Updater均Signature=adhoc、TeamIdentifier=not set；保存的发行版2.0.12及其Updater均为Developer ID、TeamIdentifier=LQAVR62TK2。测试签名无法证明发行签名下是否发生同样通知；没有Team ID是候选影响因素，尚无对照实验证明因果。
- 不符合的已知问题：[Sparkle #2591](https://github.com/sparkle-project/Sparkle/issues/2591)及[#2593](https://github.com/sparkle-project/Sparkle/pull/2593)针对自定义NSUpdateSecurityPolicy与Sparkle整App原子交换。本轮App没有该键，文件交换由包内root步骤较早完成，拒绝主体是后续Updater，因此不能直接套用其修复或认定升级Sparkle能解决。
- 上游维护者说明默认更新策略使用同Team ID，且此类通知有时不妨碍安装；见[讨论2881](https://github.com/sparkle-project/Sparkle/discussions/2881)（讨论正文2026-06-03维护者回复；不借用其他报告的根因）。

本次未重装、未修改TCC/权限/签名，也未加入猜测性产品补丁。尚缺被拒操作/路径，以及正常同Team ID发行签名的对照，故保留通知问题为未验证项；无需用户重复已通过的打字验收。


### #204：不安装复现Updater拒绝（2026-10-11续查）

本地`.../sparkle-official-5d03p3jc/open-probe`保留源码、调用记录、进程证据和TCC日志。未执行sudo或安装，Owltype始终为原PID94004。

1. 普通NSWorkspace openURL探针成功，没有重现AppBundles拒绝。真实Updater副本通过命令行运行收尾也成功，但TCC归因到Codex，因此该阴性结果不能排除Updater权限问题。
2. 改为临时`gui/501` launchd任务，使用原ad-hoc Updater二进制副本；诊断dylib只将applicationDidFinishLaunching改为设置既有目标并调用原relaunchApplication，跳过安装器连接。原来的重新打开和副本自清理逻辑仍执行，任务结束后bootout。
3. 独立归因的PID10783再次触发SystemPolicyAppBundles拒绝（421.30093，14:44:31.227168，authValue=0/authReason=2）。补充元数据调用跟踪的PID11609也触发同类拒绝（421.30100，14:46:26.794891）；进程仍为94004。因此已经存在无需安装的拒绝复现，不需要重跑Sparkle更新或人工打字。
4. `setxattr/removexattr/setattrlist/fsetattrlist/fsctl/access/faccessat/open`的用户态插桩未定位具体拒绝调用；不能由“没有捕获”推断没有系统写操作。中间sandbox_check变参插桩没有完整转发契约，已移除，该轮不作为因果证据。
5. 准备`.../sparkle-denial-trace-4d6shq92/start-no-install.sh`：sudo只运行系统fs_usage，限定Updater/CoreServicesUIAgent、最长30秒；先通过预检进程读取专用marker，确实记录路径才运行同一隔离复现。脚本/二进制SHA256、shell语法、预检读文件通过；root跟踪尚未运行。安装草案已删除，本次不包含安装/回滚动作。

下一步由用户执行上述取证脚本（sudo限制）。不用关闭旧窗口、无需再次安装或打字；现有App、词典、收据均保持。精确被拒操作仍待系统层捕获，不把本轮诊断标为修复完成。


### #204：精确触发链及A/B/A/B验证（2026-10-11）

**结论：Sparkle 2.6.2的旧式NSWorkspace openURL收尾路径，让LaunchServices为已安装App申请读写沙盒扩展，触发App Management拒绝。** 不需要交换文件即可复现。

证据根目录`sparkle-official-5d03p3jc/open-probe`：`extension.log`中PID17073在1791701697.964930调用`sandbox_extension_issue_file`，目标`/Library/Input Methods/Owltype.app`，class=`com.apple.app-sandbox.read-write`，flags=`0x10`，返回NULL/errno=1（EPERM）。完整栈为Updater收尾block→NSWorkspace openURL→LSOpenFromURLSpec→_LSRemoteOpenCall invokeWithError→沙盒扩展申请；对应TCC明确拒绝SystemPolicyAppBundles。`macsyscall.log`进一步记录Sandbox syscall 5的EPERM。接口声明核对[Apple WebKit SandboxSPI.h](https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/spi/darwin/SandboxSPI.h)；私有接口仅用于诊断插桩，不能进入产品。

用户执行的`kerneltrace`系统调用记录在`sparkle-denial-trace-4d6shq92/filesystem-trace.log`。14:50:07.386的TCC拒绝早于14:50:07.741开始的副本删除；后者unlink目录的EPERM随后由rmdir成功处理，不能误认成通知原因。

| 隔离探针 | AppBundles拒绝 | 读写扩展申请 | 最终输入法PID |
| --- | --- | --- | --- |
| 原API extension/PID17073 | 1次 | NULL/EPERM | 94004 |
| 专用openApplicationAtURL modern/PID17379 | 0次 | 未观察到 | 94004（回调error=none） |
| 恢复原API legacyconfirm/PID18102 | 1次 | NULL/EPERM | 94004 |
| 专用API，activates=true modernmatched/PID18412 | 0次 | 未观察到 | 94004（回调error=none） |

`causal-comparison.json`汇总原始日志；`diagnosis.md`说明边界，`final-probe.sha256`固定最终探针版本。所有探针使用同一已安装App、同类ad-hoc Updater副本，均未安装/重启输入法；临时launchd任务已bootout。原命令行对照归因于Codex的差异另留记录，不纳入上述独立归因对照。

产品修复尚未实施：官方当前2.x文件blob`fb73bd28bc9609a081b4da800e86715c13dbee52`第399行仍用openURL（原文保留为`upstream-2x-controller.m`），不能把升级依赖当作已验证修复。可行方向是上游采用专用打开应用API；遵守保留官方Sparkle的决定，不把临时方法替换或私有API带进产品。此结论证明本机ad-hoc实验的直接触发链；原发行Developer ID同Team信任下是否拒绝仍未验证，不把缺少Team ID单独写成充分根因。


### #204：持久源码修复，待完整真机更新

用户要求继续修复、尽量保留官方Sparkle且不加临时绕过。官方2.x仍使用旧openURL，公开回调也不能单独接管收尾。因此保留固定官方2.6.2提交及其下载/验签/pkg调用，新增`patches/sparkle/application-relaunch.patch`；在隔离源码目录构建，不改子模块或使用运行时插桩。APPL使用专用API，等待异步回调、错误以失败退出、成功后保留0.3秒退出延时；插件/旧系统保留上游兼容行为。

构建接入bootstrap与make依赖，最终包和发行检查核验patch/builder摘要、双架构Updater UUID及新API。SBOM标记本地补丁，签名变化不影响UUID检查。未改输入法标识、生产feed或密钥，没有Developer ID签名、公证或安装。

独立编译的实际Updater副本`open-probe/builtpatch`无读写扩展申请、无AppBundles拒绝，继续使用PID94004；原有插桩只用于启动收尾与观察，未替换编译后的relaunch方法。发行脚本17/17自测通过。编译首次因上游10.13部署目标不被当前SDK支持而失败，改为与Owltype一致的14.0后通过；未修改输入法最低系统要求。完整gate及代码审阅另记后续结果。

迁移边界：从旧版开始的第一轮更新仍运行旧版Updater，目标包不能替换已经在运行的辅助进程；这轮可能仍有旧通知。后续更新才使用修复后的辅助进程。下一轮完整真机实验必须将修复放入起始基线，不能只换目标pkg。

源码归档兼容性审阅发现并修复：`make sparkle`仅在Git工作区初始化子模块；归档路径复制随包源码，两条路径均核验固定上游树摘要。实际无Git目录`sparkle-gitless-build-7hywnmu0/build.log`的`make sparkle`通过；自测覆盖真实源码及未知修改拒绝。标准轴原1项已解决，需求轴0项；真机更新仍单独验收。


### #204：补丁完整 Sparkle 更新通过（原选猫头鹰）

测试代码提交 `02a24b4044187f239efa68845cd20ea13bd26747`，完整干净 gate 14阶段/1310项产品测试通过（366.353秒，收据 `20261011T074108Z-full-4zof5r73`）。本节仅记录后续人工验收，不将其文档提交冒称为该次完整 gate 的提交。

本地证据目录 `sparkle-patched-qcz2s_rj`。起始测试App与目标包均含源码补丁；本机ad-hoc签名、localhost feed、内存生成测试密钥，真实检查更新入口。`sparkle-installer-ancestry.jsonl`证明Autoupdate76158调用installer76312；payload为归档，下载字节和验签配置已在准备时绑定。

| 项目 | 结果 | 原始证据 |
| --- | --- | --- |
| 版本三证 | PID76429，系统安装路径；磁盘/LS/目标2.0.13；inode91173429一致；进程晚于安装开始 | after.txt |
| 菜单/选中态 | 猫头鹰可见且选中Hans，更新前后保持 | input-menu.png、update-source-before.txt |
| 新宿主 | PID76516；17.83秒保存新增“你好”；前后选中Hans | new-save.json、new-save.png |
| 原旧宿主 | PID86600/window21126保持；22.18秒保存新增“你好”；前后选中Hans | old-save.json、old-save.png |
| 人工与延迟 | 27秒PASS；三分钟观察后用户PASS，无注销或Updater被阻止通知 | manual-result.txt、delayed-result.txt、late-runtime.jsonl |
| Updater收尾 | PID76159于16:30:11.653退出；捕获日志未发现其AppBundles拒绝 | interim-updater-log.json、updater-system-log.json、diagnostic-status.json |

中途日志451条、最终查询223条：系统统一日志后续查询保留的条目减少，两份均保留。其他系统进程有AppBundles预检，不能宣称所有TCC事件为零；结论限定本轮Updater未观察到拒绝，并有用户无通知确认。收尾查询exit0，操作锁已释放；保留测试版，不再重装或回滚。`review.json`汇总完整审阅。

本轮解决本机已复现的Updater拒绝。#204仍缺原选其他输入源的真实Sparkle分支等验收；#205剩余GUI/pkg矩阵、Intel、macOS14/15和原发行Developer ID信任路径未验证。首次从旧发行版更新仍运行旧Updater的迁移限制不变。
