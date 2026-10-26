# 水杉输入对齐与共享工作入口

普通拼音以 [#280](https://github.com/semantic-craft/owltype-macos/issues/280)、普通五笔以
[#294](https://github.com/semantic-craft/owltype-macos/issues/294) 为产品目标：同版源码、资源、有效配置、学习状态和事件轨迹下，候选及提交行为对齐水杉。Owltype 保留原生界面和已有 AI/模板。规格、实现、验证、合并和发布分别记录；当前状态以已核实的工单、PR 及进度快照为准。

## 一处状态，两个展示入口

- [项目进度 HTML](../progress/index.html) 与 [绑定数据](../progress/progress.json) 从 GitHub 当前事实生成，展示所跟踪工单的依赖、负责人和证据边界。观察时间之后的变化需要刷新，不在本文另存票数或阶段状态。
- TeslaHub 既有生成器采集同一仓库。本项目的同步适配复用其渲染器，将同一次 GitHub 原生依赖和指派快照投影成 Waiting/Doing，生成 board.json 和 HTML。其 `/board` 页面须由已配对服务提供；本地生成文件不表示已部署公网。公网入口：[TeslaHub](https://hub.xwzhang.com/board)。
- GitHub 原生依赖是阻塞真源。父规格不可领取，`ready-for-agent` 不代表前置已完成。关闭数不是实现、发布或用户验收比例。
- 不维护历史阶段计划作为第二套执行清单。源码导航见 [domain](agents/domain.md)，安装/发布约束由 [installation](operations/installation.md) 和 [CI](operations/ci.md) 拥有。

```sh
python3 progress/sync.py
python3 progress/progress.py check --live
# 可同时刷新 TeslaHub；使用当前维护的 checkout 和明确输出目录：
python3 progress/sync.py --teslahub "$TESLAHUB_HOME" --hub-out "$OWLTYPE_BOARD_OUTPUT"
```

刷新命令只读 GitHub，不指派、不派工、不改标签。生成页面须随绑定数据提交；TeslaHub 派生输出放证据目录，不复制到 Git。静态 HTML 提供共享进度与工单入口，真正领取仍由同一协调账本完成。

## 拼音与五笔的共享架构

- 普通输入共用固定导入的 Rust 引擎、input-runtime、FFI 和 Swift 会话适配，不另建五笔算法或第二套拼音引擎。上游来源与必要适配见 [源码基线记录](../rust/msime-source.json)；具体代码入口见 [domain](agents/domain.md)。
- 正式资源使用官方拆分的 `msime-pinyin.db` 与 `msime-wubi.db`，后者包含完整 86/98 码表；混输、反查及英文等依赖随同版完整资源组合交付。兼容组合、摘要和许可由现有资源设施核对，准备代次时组装可写工作词库并回放共享学习日志，更新和回滚复用同一事务链路。实现入口见 [完整资源与代次](../sources/DictPack/OwlRustDictPackResource.swift)。
- 候选生成、排序、分页、选择和提交遵循固定水杉链路。AI、模板及宿主短语使用明确入口；普通快捷短语偏好与原生语义一致，显式 K 浏览独立保留。不能等价映射的个性化能力不干扰默认对齐路径，不静默删除既有用户内容或偏好。
- 双端驱动复用真实 `OwlRustEngine/RimeSession` 接缝，参考端使用固定水杉 Host API；运行方法及证据边界见 [双端对照指南](operations/pinyin-parity.md)，不可变源码、资源摘要和基线约束见 [对照基线](../tests/fixtures/pinyin-parity/baseline.json)。

共享 Rust 会话、FFI、Swift 引擎文件开始改动前须核对当前执行者、工单和开放 PR；各 agent 在独立 worktree 工作，重叠改动串行集成，不覆盖另一会话的工作。

## Agent 领取与回报

复用 TeslaHub 已有 `board/claims.mjs`，不另造锁或网页派发服务。所有 Owltype agent 必须使用同一个明确的 `TESLAHUB_DATA_DIR`，本地 Hub 服务也用它；禁止按 agent/worktree 分开建账本。`TESLAHUB_HOME` 指向包含该入口的维护 checkout。跨机器由同一协调节点执行领取，不复制 task-state 数据库。

每轮由协调者用 `grant-scope` 只登记用户明确授权的工单，并核实本轮有效的 base 与不可变 minSHA；并发额度和文件范围也由本轮 scope 明确限定。保持默认 `dispatch=false`，不自动派工、不重放历史“做”评论，也不接管其他活跃会话。改动合入 main 后，下轮须重新获取并核实 fresh main，再建立本轮 base/minSHA；不得沿用已删除的集成分支、过期 scope 或旧 checkout 的 head。

1. 查看最新原生前置、负责人、开工评论与开放 PR。只将真正无阻塞且未占用的票置为 `status:next`；不要批量把 ready-for-agent 变成 Next。
2. 在本轮已核实、包含 minSHA 的最新 base 上创建独立 worktree，用真实分支、SHA、通道和文件范围调用 `scripts/input-claims.sh reserve`，沿用 TeslaHub CLI 参数。它重新核实 GitHub 并做原子互斥（API 不可用时拒绝领取）；只有首次 `ok:true,deduplicated:false` 才允许启动一次执行器。
3. 启动后 `bind` 真实会话 ID；交付用 `in-review` 写真实 PR/head 和验证边界；阻塞用 `stuck`，返工沿用 `rework`。已合入且核验 SHA 后才 `integrate`，释放锁。入口参数详见 [TeslaHub 领取协议](https://github.com/semantic-craft/TeslaHub/blob/main/docs/coordinator-claims.md)。
4. 每次状态变化写回 GitHub 后运行上面的同步命令。状态未知先核实原会话，不换幂等键重复派工。看板“执行”评论只代表请求，不代表成功领取。

## 验证与交付边界

复用现有高层会话测试，只为实际差异、已知故障和隐蔽的资源/竞态风险补回归。普通打字、点击和切换不另建人工矩阵。共享变更检查受影响的另一输入方案；正式交付核对实际资源、配置和源码是否对应已验证组合。拼音侧已取消的旧用户迁移专项不作为跨线阻塞；五笔保留现有数据，复用已有迁移能力。

源码修改、自动测试、真实宿主检查、合并、正式产物验证、发布和用户验收分层报告。测试通过或 PR 合并不替代发布及用户验收证据；尚未完成的门禁或交付步骤保留在当前工单与进度记录，不预称通过。

同步适配读取有界 GraphQL 快照；任一连接被截断会明确失败并保留旧页面，不用部分结果更新看板。完整项目或更大历史范围由 TeslaHub 原采集器处理。
