# 不注销安装与更新：实施和验收记录

## 当前状态

分支：`codex/no-logout-install-update`。核实基线：`7f24eac8fe379ec58e5fa5e1ae666d9e116a03b0`。
已实现探针、原子交换、暂存 pkg、共享会话自检、GUI 复用及失败才提示注销；尚未安装修改后的产物。
已验签并安装线上 2.0.13 更新包；旧、新 TextEdit 五笔上屏成功，但稍后出现注销提示。
安装基线失败项已复现；用户已执行回滚，当前 App 为 2.0.12，安装收据保留 2.0.13。
回滚进程 PID 37873、路径/磁盘/LS 版本一致、inode 检查通过；用户确认旧、新宿主打字恢复。
回滚后也延迟出现“已更新到 2.0.12”注销提示，截图已保存；A1 同样影响降级。
用户已批准并完成本机 B4、发布包安装/回滚和 macl 实验；修改后产物的真机安装仍需按原限制交给用户执行或确认，管理员认证由用户接管。
已完成真机只读基线和 B4 同版本对照：用户用五笔确认旧、新 TextEdit 都能提交“你好”。
同版本和跨版本 B4 在本机均未复现“旧 TextEdit 必须重开”；不能外推其他系统。
macl 真机 spike 已通过；3e323f3 干净分支头完整 gate 通过（1310 项产品测试）。
两种未签名 product pkg 的实际展开结构检查通过；draft PR #203 已创建，尚未合并。
用户已允许隔离测试副本 ad-hoc 签名；未使用 Developer ID、私钥、公证或发布。
这不能替代 GUI 发行验签或真实 Sparkle 验收，且签名身份变化是本次实验的潜在混杂因素。
Sparkle 的仅下载接管尚未实现，当前仍使用其既有 pkg 安装器；真实 Sparkle 入口不计通过。
**最新真机结果：修改版 b8ad566 的直接 pkg 更新失败。** 用户已授权隔离副本 ad-hoc 签名并执行安装。
installer 返回 0；安装完成后约 1 秒内，版本/path/inode 三证通过，微信选中态保留。
但用户随后报告输入菜单只有微信、没有猫头鹰，必须手动删除并重新添加；不得计为成功。
用户操作期间父源曾读为 disabled、随后 enabled；准确干预时刻未知，不能据此断言自动禁用。
此时新/旧 TextEdit 上屏、60 秒人工证据和无注销提示均未确认。用户已执行回滚：发行签名 2.0.12/PID86006/inode88269622 一致，失败 App 严格验签通过并保留；用户确认菜单恢复且旧 TextEdit 可五笔上屏。收据仍2.0.13。
下一步回到此失败步骤，隔离注册刷新、签名身份变化、重复 LS claims；暂不叠加安装补丁。

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
| S1 GUI 首装 | 未测 | 未采集 | 未测 | 未测 | 未测 | 首装选中待测 | 无 |
| S2 pkg 首装 | 未测 | 未采集 | 未测 | 未测 | 未测 | 首装选中待测 | 无 |
| S3 Sparkle/pkg 更新，原选猫头鹰 | 未测 | 未采集 | 未测 | 未测 | 未测 | 未测 | 无 |
| S3 直接 pkg 更新，原选其他源（b8ad566 ad-hoc 测试副本） | 通过：安装后约1秒内，PID70931，版本2.0.13、inode88254884；非发行签名 | **失败：用户报告无猫头鹰；未采集截图** | 未确认 | 未确认，新宿主70951 | 未确认 | 初次探针微信保持；人工干预后不计 | native-b8ad566-imqzppmw/session.log、after.txt、user-acceptance.json |
| S3 真实 Sparkle 更新，原选其他源 | 未测 | 未采集 | 未测 | 未测 | 未测 | 未测 | 无 |
| S4 GUI 更新，原选猫头鹰 | 未测 | 未采集 | 未测 | 未测 | 未测 | 未测 | 无 |
| S4 GUI 更新，原选其他源 | 未测 | 未采集 | 未测 | 未测 | 未测 | 未测 | 无 |

S3 的直接 pkg 安装与 Sparkle 下载/安装入口分别记录，不能互相替代。
此次安装使用 Apple Installer GUI 打开已验签的更新 pkg，未执行原计划的 sudo installer CLI，
因此不能声称已复现指定 CLI 入口，也未覆盖真实 Sparkle 或 Owltype GUI 安装器。
失败的基线不是修改后 S3 验收。安装成功页截图为 `pkg-2.0.13-baseline/installer-result.png`。

## 自动验证与未验证项

- 探针自测 19 项通过；旧 inode 检查自测通过；verify runner 自测 8 项通过；shell 语法通过。
- 自测已接入 gate 的 portable_scripts 及 verify.py distribution。
- 五组相关 Swift 测试 96/96 通过（20261010T032914Z-swift-zhm__izf）：OwlBundleSwapTests、OwlSessionRestartTests、InstallerActivationPolicyTests、OwlUpdateLogoutPromptTests、ActivationPolicyTests。
- check-release.selftest 17/17、release-cohort-selftest 33/33 通过；GUI 无签名构建通过。
- cfaba60 的干净分支头 gate 在 release_checks 失败：identity selftest 仍把夹具放到旧的 live payload 路径；此前所有阶段（含产品测试与构建）通过。修正夹具后 identity selftest 16/16；3e323f3 完整 gate 通过，证据 20261010T034015Z-full-hzs73vjg。失败证据：20261010T033505Z-full-ceatwrfb。
- 实际 product pkg 结构证据：no-logout-20261010/product-pkgs-_9_8c099，含命令、pkgutil payload 原始输出、两个展开目录及 result.json。PASS_STRUCTURE_ONLY，不是安装验收或可发布 cohort。
- 未验证：修改后 S1–S4、无 ABC、Intel、macOS 14/15、真实 Sparkle 入口、指定 sudo installer CLI 基线入口。
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

## 菜单缺失：下一步隔离实验

先保持代码和版本均为 2.0.12，以相同的共享文件交换、用户进程重启和 TextInput 服务刷新流程做
signed 控制，再做 ad-hoc 对照。第一组失败就停止，不继续第二组；每组退出时都恢复发行签名 2.0.12。
候选目录为本地证据根下 `signature-control-un78ig0b`。`code-section-proof.json` 证明两架构主程序
`__TEXT,__text` 以及 Info.plist 一致；`preflight.json` 保留严格验签及比对命令；尚未运行装机实验。
驱动为同目录 `run-control.sh signed|adhoc`，只允许普通登录用户执行，内部 sudo 仅调用既有文件提交 helper。
不运行 pkg、不改收据、不删除词典、不注册/启用输入源来修补现场。人工确认之后自动换回已验签副本。

待区分的假设：

1. 若同代码同流程只在 ad-hoc 组丢菜单，签名变化是该序列中的关键变量；这仍不覆盖所有 PackageKit 场景。
2. 若 signed 组也丢菜单，优先定位交换/会话刷新顺序，不能归咎签名。
3. 若两组均通过，回到修改版代码、pkg 执行上下文或重复 LS claims 的差异继续隔离，不能宣布原失败消失。

菜单 AX 查询超时，不能仅靠 TIS 布尔值自动确认实际菜单。每组人工 PASS 必须同时满足菜单可见和旧宿主上屏；
任何手工删加输入源都使该组失败。统一日志未提供可归因的 Owltype 拒收原因；CharacterPaletteIM 的错误不作为 Owltype 根因。
