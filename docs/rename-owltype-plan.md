# 改名方案：法墨输入法 → 猫头鹰输入法（Owltype）

> 状态（2026-10-02 核对）：本文保留改名时的设计决策和迁移依据，以下阶段步骤是历史方案，不作为当前操作清单。现行实现已发布至 2.0.11；GitHub [#148](https://github.com/semantic-craft/owltype-macos/issues/148)、[#149](https://github.com/semantic-craft/owltype-macos/issues/149) 仍开放，未完成验收与旧分发面的处置以这两项工单为准。当前发布流程见 [发布检查清单](PUBLISHING_CHECKLIST.md)。
> 原则：一次性彻底改名，不保留兼容层、不留旧标识残留（全局工程原则：不做向后兼容）。
> 撰写日期：2026-08-20。方案制定时版本为 1.6.3；改名后首个版本 **2.0.0** 已于 2026-08-21 发布。

---

## 0. 命名定论

| 维度 | 旧 | 新 |
|---|---|---|
| 中文名（显示名） | 法墨输入法 | **猫头鹰输入法** |
| 中文简称 | 法墨 | 猫头鹰 |
| 英文名（品牌） | Famo / Famotype | **Owltype** |
| 代码符号前缀 | `Famo` | **`Owl`**（如 `FamoInputController` → `OwlInputController`） |
| 常量/环境变量前缀 | `FAMO_` | `OWL_` |
| Bundle ID | `im.famo.inputmethod.Famo` | **`im.owltype.inputmethod.Owltype`** |
| 输入模式 ID | `….Famo.Hans` / `….Famo.Hant` | `im.owltype.inputmethod.Owltype.Hans` / `.Hant` |
| App 名 | Famo.app | **Owltype.app** |
| 连接名 | `Famo_Connection` | `Owltype_Connection` |
| GitHub 仓库 | `semantic-craft/famotype-macos` | **`semantic-craft/owltype-macos`** |
| 本地目录 | `~/Projects/famotype-macos` | `~/Projects/owltype-macos` |
| 分发路径 | `responsay.com/famo/` | **`responsay.com/owltype/`** |
| 用户数据目录 | `~/Library/Application Support/Famo` | `~/Library/Application Support/Owltype` |

命名理由：Owltype 与 Famotype 结构平行（品牌+type），无知名 macOS 应用重名（注意 **不要** 用 NightOwl，已有知名 macOS 深色模式工具占用）。备选（不采用，仅备档）：Strix、Bubo。

可选加固（非阻塞）：注册 `owltype.im` 域名以坐实 bundle id 反向域名。不注册也可执行；若用户明确不想用未持有的域名，退路是 `com.semanticcraft.inputmethod.Owltype`（semantic-craft 为 GitHub org），执行前问一次即可，默认用 `im.owltype.*`。

**签名边界与不变项**：
- Developer ID 与公证身份不因改名轮换。Sparkle EdDSA 必须切到 Owltype 独立信任域：2.0.1 内嵌 `SUPublicEDKey = dWrr6gck5aoy5F7V00SizqQM6w9MHmZzeeQFSqYTlfM=`，但它的更新包仅为让已安装 2.0.0 升级而用旧钥签署一次；2.0.2 起只用 Owltype 新钥。否则冻结的旧 Famo 包及其公开有效签名可被 Owltype 重放并以 root 装回旧身份。
- Developer ID 签名身份、notary profile `xw-notary`、Apple 团队。
- rime-ice 主方案与 `rime_ice.userdb`（用户主词库，schema id 是 `rime_ice` 不含 famo，天然免迁移）。
- librime / plum / Sparkle 子模块。

---

## 1. 阶段 P0：前置清场（改名提交之前必须完成）

1. **核对基线**：`git status --short --branch` 干净；`git log origin/main..main` 为空（历史教训：main 有过本地领先未推的堆积）。不干净先处理，不得在脏树上开工。
2. **拆除残留 worktree**（现存两个：`.claude/worktrees/famotype-macos-cleanup-workflows-eb52c0`、`.claude/worktrees/ime-default-system-setting-d068ba`）。已知 `git worktree remove` 必失败，配方：先 `lsof +D <worktree>` 确认无活跃会话 → `rm -rf <目录>` → `git worktree prune` → 删除对应分支（`claude/clean-dev-script` 若已合并/无价值则删，未合并内容先确认）。
3. **收尾未决事项**：1.6.1 的「升级后输入源还原」修复（PR#134 机制）至今未经真机验证。改名会更换全部输入源 ID，该链路必须在 2.0.0 真机验收中一并闭环（见 P6），此处只需知悉，不阻塞开工。
4. 跑一次 `scripts/gate.sh` 确认改名前基线全绿，留存输出。

---

## 2. 阶段 P1：代码与工程改名（一个分支内完成，原子合入）

> 策略：先改「身份单一来源」，再机械替换，最后用身份残留扫描器兜底。

### 2.1 身份单一来源
- `scripts/famo-identity.sh` → 重命名为 `scripts/owl-identity.sh`，其中三个常量改为新 ID：
  `OWL_BUNDLE_ID="im.owltype.inputmethod.Owltype"`、`OWL_SOURCE_ID_HANS/.HANT` 同步。
  函数与变量前缀 `famo_`/`FAMO_` 全部改 `owl_`/`OWL_`。
- `scripts/check-identity-residual.sh`（及其 selftest）：把「禁止出现的旧标识」清单换成 famo/Famo/法墨/famotype 全家桶，改完后它就是本次改名的**验收扫描器**。`OWL_IDENTITY_STRICT=1` 跑到零告警为止。

### 2.2 Xcode 工程与打包身份
- `Famo.xcodeproj` → `Owltype.xcodeproj`；target、scheme、`PRODUCT_NAME`（Famo → Owltype）、三个 `PRODUCT_BUNDLE_IDENTIFIER`（主 app + `OwltypeTests` + `OwltypeUITests`）、`INFOPLIST_KEY_CFBundleDisplayName = 猫头鹰输入法`、`MARKETING_VERSION = 2.0.0`。
- `resources/Info.plist` 全量身份替换：`TISInputSourceID`、`CFBundleExecutable`、`CFBundleIconFile`（Owltype.icns）、`CFBundleName = 猫头鹰输入法`、`tsInputModeListKey` 两个模式 ID 及 `tsVisibleInputModeOrderedArrayKey`、`InputMethodConnectionName = Owltype_Connection`、`InputMethodServerControllerClass/DelegateClass = Owltype.OwlInputController`、`NSAppleEventsUsageDescription` 文案（法墨→猫头鹰）。2.0.1 起 `SUFeedURL = https://downloads.responsay.com/owltype/v2/appcast.xml`，旧 `responsay.com/owltype/appcast.xml` 固定为 2.0.0 客户端跨钥匙桥。
- `resources/Famo.entitlements` → `Owltype.entitlements`（内容不变，pbxproj 引用同步）。
- `resources/FamoMenuIcon.pdf` → `OwlMenuIcon.pdf`；**菜单栏图标与 icns 需要换成猫头鹰视觉**——这是设计工作，代码侧先原图改名保证可编译，图标重绘列为独立后续任务，不阻塞改名合入。
- `installer/`：`FamoInstaller.xcodeproj`、project.yml、其 Info.plist 同套替换。
- `package/`：`Famo-component.plist` → `Owltype-component.plist`；pkg 标识符（`im.famo.*` → `im.owltype.*`）；`make_package`/`make_dmg`/`make_archive`/`sign_app`/`sign_update`/`bump_version`/`common.sh` 中的产物名（Owltype.pkg、Owltype-update.pkg、Owltype-2.0.0.dmg）；welcome/conclusion html 文案；`卸载法墨.command` → `卸载猫头鹰.command`（内容中的路径与 ID 同步）；appcast 模板（`xmlns:famo` 命名空间 → `xmlns:owl`，指向 `responsay.com/owltype/release-cohort`，`<famo:releaseCohort>` 等元素同改——**注意 app 内解析这些自定义元素的代码要同步**，全局搜 `releaseCohort`）。
- 删除仓内旧产物：`package/Famo-1.6.3.dmg`、`Famo.pkg`、`Famo-update.pkg`、旧 `appcast.xml`/`debug-appcast.xml`/`testing-appcast.xml` 内容重生成。

### 2.3 Swift 源码与测试
- `sources/`、`tests/` 全量符号改名：类型前缀 `Famo*` → `Owl*`（约 4000+ 处，机械替换 + 编译驱动修正）；`Famo-Bridging-Header.h` → `Owltype-Bridging-Header.h`（pbxproj 的 `SWIFT_OBJC_BRIDGING_HEADER` 同步）。
- 文件名 `Famo*.swift` → `Owl*.swift`，用 `git mv` 保留历史。
- 通知名 / defaults 键：`com.famo.selection-menu.ax` → `com.owltype.selection-menu.ax`、`com.famo.test.roundtrip` → `com.owltype.test.roundtrip`、`im.famo.inputmethod.Famo.deepseek/.providers/.tests/.selftest/.deferred-update-select.log` 等派生标识全部换前缀（以 `rg 'im\.famo|com\.famo'` 扫尽为准）。
- 面向用户的字符串：`resources/Localizable.xcstrings`、`InfoPlist.xcstrings` 中所有「法墨」→「猫头鹰」，英文串 Famo → Owltype；逐条人工过一遍语感，不要纯替换出「猫头鹰在更新后…」这种不通的句子（该句式恰好通顺，但要检查全部条目）。
- 用户数据路径常量：`Application Support/Famo` → `Application Support/Owltype`；`Library/Preferences/im.famo.inputmethod.Famo.plist` 引用同改。
- Rime 配置命名：`data/famo.yaml` → `data/owltype.yaml`、`rime/famo.custom.yaml` → `rime/owltype.custom.yaml`、`data/famo-rime/` → `data/owl-rime/`，源码中 26+16 处引用同步；`FamoPromptStore`/`FamoQuickSendPage` 中 `user_dict: famo_prompts` → `owl_prompts`、`famo_quick_send` → `owl_quick_send`（用户数据迁移见 P4）。
- `tools/famo-rime-probe.cc` → `owl-rime-probe.cc`。

### 2.4 脚本、Makefile 与文档
- `scripts/` 下所有 `famo*` 文件改名（`famo_distribution.py` → `owl_distribution.py`、`famo-seed.sh`/`famo-seed-full.sh`、`uninstall-famo.sh` → `uninstall-owltype.sh`、`build-famotype-base.py` 等），内部引用、`gate.sh` 调用、Makefile 目标（`famo-seed` → `owl-seed`）全部同步。**历史教训：公开/全量两个 seed 脚本曾两次失同步，这次两个一起改并核对 check-release 断言。**
- `check-release.sh` 里所有对产物名、bundle id、feed URL 的断言换新值。
- 根目录文档：README.md / README.en.md / CHANGELOG.md / PRIVACY.md / PROVENANCE.md / SECURITY.md / CONTRIBUTING.md / THIRD_PARTY_NOTICES.md / install-signed.sh / cliff.toml / AGENTS.md / docs/ 全量改名。CHANGELOG 顶部加 2.0.0 条目声明改名。
- 开发约定文件：`~/.famo-test-key`、`~/.famo-test-key-doubao`、`~/.famo-test-model`、`~/.famo-test-workspace` → 对应 `~/.owl-test-*`；代码里读取这些路径的地方同改；**本机文件由执行者当场 `mv`**（这是机器状态，不在 git 里）。

### 2.5 P1 验收（合入前）
1. `rg -i 'famo|法墨'` 全仓（排除 CHANGELOG 历史条目、本方案文档、identity 扫描器自身的模式串）零命中。
2. `OWL_IDENTITY_STRICT=1 scripts/check-identity-residual.sh` 通过。
3. `scripts/gate.sh` 全绿（含全部 selftest；注意 worktree 构建依赖：submodule/Sparkle/librime 生成物）。
4. librime 候选级探针（`owl-rime-probe`）验证候选正常。

---

## 3. 阶段 P2：仓库与目录改名（P1 合入 main 之后）

顺序敏感，按序执行：

1. **GitHub**：`gh repo rename owltype-macos -R semantic-craft/famotype-macos`。GitHub 对旧名自动 301 重定向，clone/push 不断，但仍要显式更新引用。
2. **本地 remote**：`git remote set-url github git@github.com:semantic-craft/owltype-macos.git`。`origin`（origin.cursor.com 镜像）：Cursor 侧镜像若无法改名则新建 `owltype-macos` 镜像并 set-url；若不再需要该镜像，直接 `git remote remove origin`（默认动作：问用户一次，用户不管则移除）。
3. **本地目录**：确认无其他会话占用（`lsof +D`）后 `mv ~/Projects/famotype-macos ~/Projects/owltype-macos`。
4. **Claude/engram 记忆随迁**：目录名是记忆的 key。
   `mv ~/.claude/projects/-Users-xianweizhang-Projects-famotype-macos ~/.claude/projects/-Users-xianweizhang-Projects-owltype-macos`；engram 若按 cwd 归档项目，确认新路径能接上旧项目（接不上则在 engram 里做一次 handoff 说明）。**漏掉这步 = 全部项目记忆静默丢失，这是最容易被忽略的隐患。**
5. 原计划中的 Metis 跨机迁移步骤已取消：该机器已退役，不再执行同步、部署或验收。
6. `.claude/` 内残留的 worktree 配置、launch.json 等若引用旧路径，同步清理。

---

## 4. 阶段 P3：分发面切换（responsay.com R2）

> **铁律：当前发布器通过 `wrangler r2 object get/put` 逐对象读写，不是整站快照部署。共享桶与公共路由仍有误覆盖风险：发布前必须对 Owltype、旧 Famo、Responsay 三个面留存现网快照，其中旧 `famo/` 对象逐个记录字节数与哈希；发布只允许写 `owltype/` 键；发布后按同一组三面快照复验。**

1. 发布前读取并留存三面基线：当前 `owltype/` 对象（首次发布时允许不存在）、整个旧 `famo/` 对象集合的字节数与哈希、Responsay 自己的 appcast 正文与版本号。旧 `famo/` 快照既是冻结证明，也是误写时的恢复依据。
2. 新增 `owltype/` 路径：`appcast.xml`（2.0.0 条目，enclosure 指向 `owltype/releases/2.0.0/Owltype-update.pkg`）、`Owltype.pkg`、`Owltype.dmg`、`release-cohort` 端点、`source.tar.gz`。
3. **暂时保留 `famo/` 原样不动**（冻结，不再更新）。旧装机的 Sparkle 还在查旧 feed，留着可避免报错噪音；等 P5 全部机器切换且 2.0.x 新更新链证明完成后，第二次对象级部署再删除整个 `famo/` 路径。
4. 发布走改名后的 `owl_distribution.py --publish`；该脚本按发布计划对明确的 `owltype/` 键执行对象级 R2 put/get 与公开 URL readback（wrangler 4.123.0；R2 put 后 readback 短暂不一致属正常，直接重跑不删对象）。
5. 部署后复验三面：`curl https://responsay.com/owltype/appcast.xml` 内容正确且下载对象可读；旧 `famo/` 的对象集合、字节数与哈希和发布前完全一致；**Responsay 自己的 appcast 正文与版本号未回退**。

> **执行记录（票 09，2026-08-21）** —— Owltype 2.0.0 已从源码提交 `f63a4b5` 构建、签名、公证并发布；稳定 appcast 按计划最后写入。发布后重新读取全部 Owltype 对象与四个下载别名，均与 release cohort 一致；旧 `famo/` 的 12 个对象仍为 69,807,317 字节且逐对象哈希不变；Responsay 根 appcast 仍为 1.9.2（build 157）。脱敏证据已随清理移出工作树，见 Git 历史中的 `docs/rename-owltype-evidence/09-distribution-cutover-2026-08-21.md`；原始 HTTP/appcast 留档仅保存在执行机的 `.scratch/rename-owltype/`。GitHub #143 已关闭。旧 `famo/` 仍按本节第 3 条冻结，删除归票 11。

> **2.0.1 更新信任桥修订（2026-08-22）** —— 2.0.0 与 Famo 共用 Sparkle 公钥会让旧 Famo 已签包在 feed 被改写时仍可被 Owltype 接受并以 root 安装。2.0.1 因此采用两段式桥：App 内嵌 Owltype 新公钥并改读 `downloads.responsay.com/owltype/v2/appcast.xml`，但 2.0.1 的 update.pkg 仍用旧钥签一次；发布器按“10 个不可变对象 → `owltype/latest.json` → 四个下载别名验证 → `owltype/v2/appcast.xml` → 旧 `owltype/appcast.xml`”执行，最后一步只在 2.0.1 固定桥接 feed。2.0.2 起只用新钥、只更新 v2 feed，旧 feed 不再写入；`famo/*` 在两次桥接发布中始终不属于写入计划。该桥只处理 Sparkle 信任连续性，不读取或迁移任何 Famo 用户数据。

**关于老用户桥接的决策**：不做旧 feed 桥接更新（即不在 famo appcast 上发「自动迁移到猫头鹰」的最终版本）。理由：装机面就是自己的几台机器，手动干净切换（P5）比维护一条只跑一次的自动迁移链更「没有隐患」；bundle id 变更后 Sparkle 跨身份迁移本身就是新风险面。若未来发现有真实外部用户，再考虑在冻结的旧 feed 上发一条纯提示性条目。

---

## 5. 阶段 P4：数据边界（修订为**不迁移**）

> 2026-08-21 用户重新确认：改名的目的不是保存旧输入数据，而是让 Owltype 成为没有旧身份冲突的全新 App。

1. Owltype 不读取、复制、改写或删除 `Application Support/Famo`、旧 defaults 域或旧 Keychain service。
2. 删除一次性 `OwlLegacyDataMigration` 及其测试、启动入口和扫描豁免；不保留完成标记、staging 或回落读取路径。
3. Owltype 只使用自己的数据目录、defaults 域、Keychain service、Rime 前端配置和更新源。
4. 旧数据由旧 Famo 卸载器随旧 App 一并删除；这是明确接受的数据放弃，不是迁移失败。

原先的迁移实现已经证明复杂且风险集中：它需要复制整个目录、重命名 Rime/JSON 文件、改写 YAML、导入 defaults，任一局部失败都会制造两套身份混合状态。既然没有需要保留的数据，删除这条运行时兼容链比继续修补更符合项目“不做向后兼容”的原则。

---

## 6. 阶段 P5：装机切换（每台装有法墨的机器，人工按序执行）

> 每台机器一次过，按“旧身份彻底卸载、会话清理、新身份首装”执行；不备份、不恢复、不迁移旧数据。

1. 退出 Karabiner-Elements。
2. 从改名前最后提交取回旧卸载器并先 dry-run：`git show 470d8f5:scripts/uninstall-famo.sh > /tmp/uninstall-famo.sh`；确认后执行。它必须删除旧 App、旧数据目录、旧 defaults/caches 等 Famo 自有路径。
3. 删除旧 Famo 的两个 Keychain service（`im.famo.inputmethod.Famo.providers`、`im.famo.inputmethod.Famo.deepseek`），忘记旧 PackageKit receipt，并 reset 旧 bundle id 的 Accessibility / AppleEvents TCC；旧 AI key 已明确放弃。
4. 确认系统输入法列表里已移除法墨，注销并重新登录；随后清理旧 bundle id 和开发构建的 LaunchServices 认领。
5. 安装已修复的 Owltype 2.0.x 签名公证包，以全新身份首次启动并在系统设置加入猫头鹰输入法。
6. 重新授予辅助功能与 Apple 事件权限；出现 csreq 失配时删条目重加。
7. 验证基础输入、设置写入、Rime 独立目录、默认输入法按钮、三处图标及诊断中无旧身份；AI profile 从空状态重新配置，不读取旧 key。

已完成 2.0.0 更新前验收的主测试机曾把旧数据复制进 Owltype 目录。先发布包含本轮修复的 2.0.x，并在该机证明新 feed 更新、输入源还原和 no-steal；证明留档后，必须完整卸载 2.0.x、删除 Owltype 与旧身份两套运行状态，注销清会话，再重装同一 2.0.x 作干净身份验收。第二台目标机直接使用以上干净路线；不安装输入法的机器明确 N/A。两台目标机通过后才删除旧分发路径。

---

## 7. 总验收清单（全部勾完才算改名完成）

> 前四项由票 07 在集成分支上验完并合入 main（合并提交 `3c6ac8f`）；余下各项归 08–11。

- [x] `rg -i 'famo|法墨'` 全仓零残留（白名单外）
- [x] `check-identity-residual.sh` 严格模式通过（对产物 .app/.pkg 也扫）
- [x] `gate.sh` 全绿；全部 selftest 通过
- [x] librime 探针候选验证通过
- [x] GitHub 仓库、本地目录、remote、Claude 记忆目录四者一致为 owltype（08 已完成）
- [x] `responsay.com/owltype/appcast.xml` 在线且正确；首次发布后三面验证通过，`famo/` 当前冻结待最终删除
- [ ] 每台装机：完整卸载旧身份→注销→清 LS→全新安装→TCC 重授，逐机记录
- [ ] Sparkle 新 feed 真机更新一次成功（含输入源还原）
- [ ] 图标重绘任务已立项（不阻塞）

## 8. 已知风险与对策速查

| 风险 | 对策 |
|---|---|
| 共享 R2 桶中对象级发布误写旧产品或公共路由 | 发布前留存三面基线与旧 `famo/` 逐对象字节/哈希快照，只写 `owltype/` 键，发布后按同一快照复验（P3 铁律） |
| 目录改名丢 Claude/engram 记忆 | P2 第 4 步随迁 |
| 迁移逻辑把两套身份混在一起 | 不迁移；旧 Famo 完整卸载，Owltype 只创建自己的新数据 |
| 输入源会话层污染 | 卸载后强制注销（P5.4） |
| TCC 旧授权失效/ csreq 失配 | P5.8 预期化处理 |
| Karabiner 析构 bug | P5.1 先退 Karabiner |
| 双 seed 脚本失同步 | P1.4 成对修改 + check-release 断言 |
| CI 只覆盖到 package | archive/appcast/签名链路全部本地真机验（本次全链都动了） |
| appcast 自定义 `famo:` 命名空间 | 改名与 app 内解析代码同步（P2.2） |
