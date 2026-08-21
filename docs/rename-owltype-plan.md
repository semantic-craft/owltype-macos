# 改名方案：法墨输入法 → 猫头鹰输入法（Owltype）

> 状态：方案定稿；08 外壳改名已完成，09 分发上线尚未执行，后续 10–11 待执行。GitHub #140–#149 是当前规格与依赖源；本地票文件保留对应阶段的详细操作编舞。
> 原则：一次性彻底改名，不保留兼容层、不留旧标识残留（全局工程原则：不做向后兼容）。
> 撰写日期：2026-08-20。当前版本 1.6.3，改名后首个版本定为 **2.0.0**。

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

**不变项（明确不要动）**：
- Sparkle EdDSA 密钥对（`SUPublicEDKey = 3Ze0A+sHbvkQ8CLlDUIcYvm7BJS4IJLU1rNEX66F9R4=`）——密钥与名字无关，轮换才是风险。
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
- `resources/Info.plist` 全量身份替换：`TISInputSourceID`、`CFBundleExecutable`、`CFBundleIconFile`（Owltype.icns）、`CFBundleName = 猫头鹰输入法`、`tsInputModeListKey` 两个模式 ID 及 `tsVisibleInputModeOrderedArrayKey`、`InputMethodConnectionName = Owltype_Connection`、`InputMethodServerControllerClass/DelegateClass = Owltype.OwlInputController`、`NSAppleEventsUsageDescription` 文案（法墨→猫头鹰）、`SUFeedURL = https://responsay.com/owltype/appcast.xml`。
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
5. Metis 侧若有检出（08-19 清理记录称两机残留已清，预期没有），有则同法处理。famotype 不在 fleet manifest，无 manifest 改动。
6. `.claude/` 内残留的 worktree 配置、launch.json 等若引用旧路径，同步清理。

---

## 4. 阶段 P3：分发面切换（responsay.com R2）

> **铁律：当前发布器通过 `wrangler r2 object get/put` 逐对象读写，不是整站快照部署。共享桶与公共路由仍有误覆盖风险：发布前必须对 Owltype、旧 Famo、Responsay 三个面留存现网快照，其中旧 `famo/` 对象逐个记录字节数与哈希；发布只允许写 `owltype/` 键；发布后按同一组三面快照复验。**

1. 发布前读取并留存三面基线：当前 `owltype/` 对象（首次发布时允许不存在）、整个旧 `famo/` 对象集合的字节数与哈希、Responsay 自己的 appcast 正文与版本号。旧 `famo/` 快照既是冻结证明，也是误写时的恢复依据。
2. 新增 `owltype/` 路径：`appcast.xml`（2.0.0 条目，enclosure 指向 `owltype/releases/2.0.0/Owltype-update.pkg`）、`Owltype.pkg`、`Owltype.dmg`、`release-cohort` 端点、`source.tar.gz`。
3. **暂时保留 `famo/` 原样不动**（冻结，不再更新）。旧装机的 Sparkle 还在查旧 feed，留着可避免报错噪音；等 P5 全部机器切换且 2.0.x 新更新链证明完成后，第二次对象级部署再删除整个 `famo/` 路径。
4. 发布走改名后的 `owl_distribution.py --publish`；该脚本按发布计划对明确的 `owltype/` 键执行对象级 R2 put/get 与公开 URL readback（wrangler 4.123.0；R2 put 后 readback 短暂不一致属正常，直接重跑不删对象）。
5. 部署后复验三面：`curl https://responsay.com/owltype/appcast.xml` 内容正确且下载对象可读；旧 `famo/` 的对象集合、字节数与哈希和发布前完全一致；**Responsay 自己的 appcast 正文与版本号未回退**。

**关于老用户桥接的决策**：不做旧 feed 桥接更新（即不在 famo appcast 上发「自动迁移到猫头鹰」的最终版本）。理由：装机面就是自己的几台机器，手动干净切换（P5）比维护一条只跑一次的自动迁移链更「没有隐患」；bundle id 变更后 Sparkle 跨身份迁移本身就是新风险面。若未来发现有真实外部用户，再考虑在冻结的旧 feed 上发一条纯提示性条目。

---

## 5. 阶段 P4：用户数据迁移（装在 pkg postinstall / 首启迁移逻辑里，二选一，定为**首启迁移**）

新 app 首次启动时检测并执行一次性迁移（迁移完成写标记，幂等）：

1. 若 `~/Library/Application Support/Owltype` 不存在且 `…/Famo` 存在 → 整目录 **复制**（不是移动）到新路径。
2. 复制后在新目录内改名：`famo.custom.yaml` → `owltype.custom.yaml`；`famo_prompts.userdb` → `owl_prompts.userdb`、`famo_quick_send.userdb` → `owl_quick_send.userdb`（Rime userdb 目录随 user_dict 名寻址，目录改名即接上；`rime_ice.userdb`、`wubi86_jidian.userdb` 原名保留）。**用户短语和提示词库是真用户数据，丢了无法再生，这步必须有并且先复制后改名。**
3. UserDefaults：从 `im.famo.inputmethod.Famo` 域读取旧偏好导入新域（`defaults export` 级别的整域拷贝即可），失败则接受回落出厂默认，不视为阻塞。
4. 旧的 `~/Library/Application Support/Famo` 保留原样。**注意：不能指望 P5 的卸载脚本「在迁移之后」删它**——
   旧卸载器（`470d8f5:scripts/uninstall-famo.sh:29`）的 TARGETS 里直接列着这个目录，且没有任何 `--keep-data`
   开关（只有 `--dry-run` / `--yes`，一次 y/N 覆盖全部路径），而 P5 的卸载排在装新版之前。所以 P5 改成
   **第 0 步先整目录备份、首启前恢复、验证通过后才删**（见 §6）。迁移逻辑侧的对应要求：**旧目录不存在时
   绝不写「迁移完成」标记**，否则一次跑空就把自己永久锁死，用户恢复备份后也不会再迁移。
5. 迁移逻辑写单测覆盖：目录存在/不存在、半迁移中断重入、userdb 改名。

> **落地修订（票 06 交付时，2026-08-21）** —— 实现见 `sources/Engine/OwlLegacyDataMigration.swift`：
>
> - 第 2 条列的三个文件**不够**。快捷短语 / 提示词的 source of truth 是 `famo_quick_send.json` /
>   `famo_prompts.json`（`.txt` 是派生表，`.userdb` 是 Rime 运行期的 stabledb）；只改 `.userdb` 的话新 app
>   读不到那两个 JSON，等于短语库和提示词库全丢。完整映射以 `OwlLegacyDataMigration.renameMap` 为准，
>   另含 `.famo-seed-v2`、`.famo-dictpack.json`、`.famo-dictpack-staging`、`.famo-backup`、`famo/`
>   （rollback manifest 目录）与两个 dict-pack 法学词库。
> - 复制后还要改写根目录每个 `*.custom.yaml` 里的托管块标识（`FAMO MANAGED` / `FAMO_CUSTOM` /
>   `famo_quick_send` / `famo_prompts`）。不改的话新 app 认不出旧 marker，会在同一个 `patch:` 里另起一套
>   `OWL MANAGED` 块 —— YAML 重复键，且旧块指着已改名的表。
> - 原子性：复制 + 改名 + 标识改写都在同卷 staging 目录里完成，最后一步 `moveItem` 挂成正式目录。
>   磁盘上不存在「半个正式目录」，中断重入直接丢弃残骸重跑。
> - **Keychain 不随迁**：API Key 存在旧 service `im.famo.inputmethod.Famo.providers` / `….deepseek` 下，
>   `providers.json` 里的 `secretName` 也是旧前缀。装机后需要重新填 API Key —— 见下面 P5 第 2、9 步。
> - **一次性迁移实现的删除门**：在所有 Mac 完成逐机切换、且随后发布的 2.0.x 已经从新 feed 完成一次真机更新证明之前，
>   不得删除迁移实现、迁移测试或残留扫描器中的迁移期例外。更新链证明完成后再在收尾票中一并移除，避免尚未切换的机器失去唯一迁移入口。

---

## 6. 阶段 P5：装机切换（每台装有法墨的机器，人工按序执行）

> 每台机器一次过，顺序不能乱。**本节必须与 2026-08-21 重写后的 10 号票配套使用；10 号票的 0–9 九步编舞、逐步等用户确认和四条红线是权威版本，禁止用更早的七步或八步口径覆盖。**

0. **备份迁移源**（顺序红线，见第 2 步）：`cp -a ~/Library/Application\ Support/Famo ~/Library/Application\ Support/Famo.pre-owltype-backup`。
1. **先退出 Karabiner-Elements**（运行中重装输入法曾触发 Karabiner 析构 bug 致全键盘失灵；本机虽已升 16.1.8 但未实测修复，照旧先退）。
2. **记下各家 API Key**：Keychain Access 按 service `im.famo.inputmethod.Famo.providers` 查找；旧条目此时不得删除。
3. 运行**旧版**卸载脚本移除法墨——**不是仓里那个**：03 号票已把 `scripts/uninstall-famo.sh` 改名并把内部身份全换成 Owltype，在还没装新版的机器上跑它什么都不会删、而你会以为卸干净了。取回旧版：`git show 470d8f5:scripts/uninstall-famo.sh > /tmp/uninstall-famo.sh`，先 `--dry-run` 看清删除清单。**它会连 `~/Library/Application Support/Famo` 一起删掉**（第 0 步的备份就是为这个）。
4. **注销并重新登录**（不是可选项：输入源真存储在 `com.apple.inputsources.plist`，会话层污染只有注销/重启能清；userland 复位全套已被证明无效，别再试）。
5. 清理 LaunchServices 残留：用既有 lsregister 清理配方清掉所有旧 bundle id / 开发构建的认领（装机验收前必清，否则归因不可信）。
6. **首启前确认并恢复迁移源**：先检查 `~/Library/Application Support/Famo`；第 3 步已经把它删掉时，执行 `cp -a ~/Library/Application\ Support/Famo.pre-owltype-backup ~/Library/Application\ Support/Famo`。
   **必须赶在新 app 首次启动之前**——票 06 的迁移只在首启跑一次并写幂等标记，跑空了旧数据就接不过来了。
7. 安装 Owltype 2.0.0（签名 pkg），在系统设置中启用「猫头鹰输入法」，首启一次让票 06 的迁移执行。
8. **重新授予 TCC 权限**（辅助功能、Apple 事件）：bundle id 变了，旧授权全部失效，属预期而非故障；若出现「已勾选仍报未授权」，按已知配方删条目重加（csreq 失配）。
9. **验证并记录**：皮肤/偏好、快捷短语与提示词库、`rime_ice` 词频记忆；逐条重贴 API Key 并实际调用；从「未启用」状态点一次「设为系统默认输入法」并原样记录文案；在 Dock、输入菜单、系统设置三处核对新图标。只有全部机器切换完成且新 Key 实测可用后，旧 Keychain、旧数据目录、备份和 defaults 域才可进入逐机确认删除。

全部机器完成后，先发布一个 2.0.x 小版本，在真机证明 Sparkle 从新 feed 完整更新成功、更新后输入源仍为猫头鹰且无 no-steal 红灯，闭环 1.6.1 遗留项。该证明通过后才允许删除一次性迁移实现；然后执行 P3 第 3 条的第二次对象级部署，删除整个 `responsay.com/famo/`，并逐机让用户确认后删除旧 defaults 域、旧数据目录及备份、旧 Keychain 条目。

---

## 7. 总验收清单（全部勾完才算改名完成）

> 前四项由票 07 在集成分支上验完并合入 main（合并提交 `3c6ac8f`）；余下各项归 08–11。

- [x] `rg -i 'famo|法墨'` 全仓零残留（白名单外）
- [x] `check-identity-residual.sh` 严格模式通过（对产物 .app/.pkg 也扫）
- [x] `gate.sh` 全绿；全部 selftest 通过
- [x] librime 探针候选验证通过
- [x] GitHub 仓库、本地目录、remote、Claude 记忆目录四者一致为 owltype（08 已完成）
- [ ] `responsay.com/owltype/appcast.xml` 在线且正确；`famo/` 路径按计划冻结→删除；Responsay appcast 未被波及
- [ ] 每台装机：卸载→注销→清 LS→装新→TCC 重授→数据迁移验证，逐机记录
- [ ] Sparkle 新 feed 真机更新一次成功（含输入源还原）
- [ ] 图标重绘任务已立项（不阻塞）

## 8. 已知风险与对策速查

| 风险 | 对策 |
|---|---|
| 共享 R2 桶中对象级发布误写旧产品或公共路由 | 发布前留存三面基线与旧 `famo/` 逐对象字节/哈希快照，只写 `owltype/` 键，发布后按同一快照复验（P3 铁律） |
| 目录改名丢 Claude/engram 记忆 | P2 第 4 步随迁 |
| 用户词库/短语库丢失 | P4 先复制后改名 + 幂等标记 + 单测 |
| 输入源会话层污染 | 卸载后强制注销（P5.4） |
| TCC 旧授权失效/ csreq 失配 | P5.8 预期化处理 |
| Karabiner 析构 bug | P5.1 先退 Karabiner |
| 双 seed 脚本失同步 | P1.4 成对修改 + check-release 断言 |
| CI 只覆盖到 package | archive/appcast/签名链路全部本地真机验（本次全链都动了） |
| appcast 自定义 `famo:` 命名空间 | 改名与 app 内解析代码同步（P2.2） |
