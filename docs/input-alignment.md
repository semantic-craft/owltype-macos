# 水杉输入对齐与共享工作入口

普通拼音以 [#280](https://github.com/semantic-craft/owltype-macos/issues/280)、普通五笔以
[#294](https://github.com/semantic-craft/owltype-macos/issues/294) 为产品目标：同版源码、资源、有效配置、学习状态和事件轨迹下，候选及提交行为对齐水杉。Owltype 保留原生界面和已有 AI/模板。
当前已使用 Rust 引擎；规格发布不表示全部输入体验已经对齐。

## 一处状态，两个展示入口

- [项目进度 HTML](../progress/index.html) 与 [绑定数据](../progress/progress.json) 由 GitHub 当前事实生成，展示 13 张拼音票和 10 张五笔票、负责人及未关闭前置。观察时间之后的变化需要刷新。
- TeslaHub 既有生成器采集同一仓库。本项目的同步适配复用其渲染器，将同一次 GitHub 原生依赖和指派快照投影成 Waiting/Doing，生成 board.json 和 HTML。其 `/board` 页面须由已配对服务提供；本地生成文件不表示已部署公网。公网入口：[TeslaHub](https://hub.xwzhang.com/board)。
- GitHub 原生依赖是阻塞真源。父规格不可领取，`ready-for-agent` 不代表前置已完成。关闭数不是实现、发布或用户验收比例。
- 不再维护历史阶段计划作为第二套执行清单。源码导航见 [domain](agents/domain.md)，安装/发布约束仍由 [installation](operations/installation.md) 和 [CI](operations/ci.md) 拥有。

```sh
python3 progress/sync.py
python3 progress/progress.py check --live
# 可同时刷新 TeslaHub；使用当前维护的 checkout 和明确输出目录：
python3 progress/sync.py --teslahub "$TESLAHUB_HOME" --hub-out "$OWLTYPE_BOARD_OUTPUT"
```

刷新命令只读 GitHub，不指派、不派工、不改标签。生成页面须随绑定数据提交；TeslaHub 派生输出放证据目录，不复制到 Git。

## 拼音与五笔的共享边界

| 五笔票 | 直接复用的拼音前置 | 交付 |
| --- | --- | --- |
| W01 #295 | #281 | 五笔基线和双端差异样例 |
| W02 #296 | 经 W01 | 五笔 86 正式资源与候选 |
| W03 #297 | 无新增跨线前置 | 连打、四码与第五码上屏 |
| W04 #298 | #283（含 #282） | 五笔拼音混输及剩余输入 |
| W05 #299 | #282 | z 模式、反查和提示 |
| W06 #300 | 无新增跨线前置 | 五笔 98 完整输入 |
| W07 #301 | #289 | 五笔学习、造词和重启恢复 |
| W08 #302 | #290 | AI/模板与普通五笔边界 |
| W09 #303 | #291 | 五笔资源更新与回退 |
| W10 #304 | 复用各切片；与 #292/#293 协调 | 差异收口及交付组合 |

表格仅说明分工；精确依赖读工单原生边。共同的参考端、资源事务、模型/拼音配置、学习日志和增强入口由拼音已有票负责，五笔票只补方案接线及差异。共享 Rust 会话、FFI、Swift 引擎文件要先核对当前执行者与开放 PR，在独立 worktree 工作；文件重叠串行集成，不通过覆盖另一会话改动解决。

## Agent 领取与回报

复用 TeslaHub 已有 `board/claims.mjs`，不另造锁或网页派发服务。所有 Owltype agent 必须使用同一个明确的 `TESLAHUB_DATA_DIR`，本地 Hub 服务也用它；禁止按 agent/worktree 分开建账本。`TESLAHUB_HOME` 指向包含该入口的维护 checkout。跨机器由同一协调节点执行领取，不复制 task-state 数据库。

协调者用 TeslaHub `grant-scope` 给本轮五笔 #295–#304 建立白名单，base 为已核实的集成分支，最大编码槽 2；全局 `dispatch=false` 和不重放历史“做”评论保持。拼音现有活跃会话不在本轮领取白名单，不强行接管；它们仍以已有工单负责人、PR 和当前会话为准。共享文件开始改动前须与拼音已有占用核对。

1. 查看最新原生前置、负责人、开工评论与开放 PR。只将真正无阻塞且未占用的票置为 `status:next`；不要批量把 ready-for-agent 变成 Next。
2. 在最新集成 head 创建独立 worktree，用真实分支、SHA、通道和文件范围调用 `scripts/input-claims.sh reserve`，沿用 TeslaHub CLI 参数。它重新核实 GitHub 并做原子互斥（API 不可用时拒绝领取）；只有首次 `ok:true,deduplicated:false` 才允许启动一次执行器。
3. 启动后 `bind` 真实会话 ID；交付用 `in-review` 写真实 PR/head 和验证边界；阻塞用 `stuck`，返工沿用 `rework`。已合入且核验 SHA 后才 `integrate`，释放锁。入口参数详见 [TeslaHub 领取协议](https://github.com/semantic-craft/TeslaHub/blob/main/docs/coordinator-claims.md)。
4. 每次状态变化写回 GitHub 后运行上面的同步命令。状态未知先核实原会话，不换幂等键重复派工。看板“执行”评论只代表请求，不代表成功领取。

静态项目 HTML 是共享进度与工单入口；真正领取在同一协调账本完成。本轮准备入口与 scope，不自行启动实施 agent，也不把本地服务接线说成公网部署。

## 验证范围

复用现有高层会话测试，只为实际差异、已知故障和隐蔽的资源/竞态风险补回归。普通打字、点击和切换不另建人工矩阵。共享变更检查受影响的另一输入方案；正式交付只补资源与已验证版本不一致的风险。拼音侧已取消旧用户迁移专项，不把它重新列作跨线阻塞；五笔保留现有数据，复用已有迁移能力。

同步适配读取有界 GraphQL 快照；任一连接被截断会明确失败并保留旧页面，不用部分结果更新看板。完整项目或更大历史范围由 TeslaHub 原采集器处理。
