# AIME 与 Owltype 拼音体验比较（2026-10-02）

> 当前状态（2026-10-02）：中英混输修复、按应用记忆中英状态、真实试打与快捷置顶已合入并发布于 2.0.11。本文保留研究时的对照基线，文中的“尚未发布”和功能差距均指当时状态；最终实现、真实宿主验收及未覆盖项见 [输入体验设计与验收记录](input-habits-design.md)。

## 结论与证据范围

**AIME 最值得借鉴的是首用验证、中英状态记忆、术语订阅和迁移入口；目前没有证据证明它的拼音排序、整句准确率或响应速度整体优于 Owltype。** 两者默认都建立在雾凇拼音与 librime 上，许多“智能输入”来自同一套上游配置。“80 余项设置”主要证明设置覆盖面，不等于输入质量领先。

AIME 基线固定为 [`90e9e431d112e2407ce7c34375bd288b2401db17`](https://github.com/zoolapp/aime/tree/90e9e431d112e2407ce7c34375bd288b2401db17)。Owltype 对照为本仓 `3be472b25d18427ccde759f93071f02babcf4f4a` 加本次查看时的工作区；本次已完成 #181 英文混输接线的本地修复，66 项测试及真实 librime 引擎回归通过；尚未发布，本文不把旧缺陷当作长期竞品差距。本文仅写研究文档，不修改产品代码，不安装 AIME，也不操作真实输入源。

以下“已核实”指存在可追踪的源码路径；“收益”是工程与体验推断；质量和兼容性差异仍需同环境实测。Owltype 文件使用仓库相对链接，后续改动可能改变对应内容；AIME 链接固定提交和行号。

## 建议优先参考的五项

| 顺序 | 建议 | 已核实差异与预期收益 | 主要代价与边界 |
| --- | --- | --- | --- |
| 1 | 首用结束前提供可跳过的真实试打 | AIME 会检查用户是否打出目标短语；Owltype 完成页只有提示。可在交付前让用户发现“已启用但不能用”“词库没生效”“英文不出现”。 | 中等：处理当前输入源、词包未装、部署中与无障碍焦点。我们的测试应覆盖中文、英文与混合输入；AIME 现有试打主要是示例短语和快捷菜单，并未覆盖所有这些场景。 |
| 2 | 中英状态按应用记住最近选择 | AIME 将“首次默认英文”和“之后记忆用户选择”分开；Owltype 已有 App 默认英文，但未见等价的 App 状态表及共享范围设置。可以减少在编辑器注释和聊天窗口间切换时的反复按 Shift。 | 中等：新会话、多个窗口、快速设置应用与 CLI 切换必须一致。建议先做按应用记忆，再决定是否需要 global/app/window 三种用户开关；不应未经体验验证改默认。 |
| 3 | 独立维护可选的领域术语订阅 | AIME 在线词表可按日/周更新、校验、空闲部署，和主词库分离；Owltype 当前为随应用 manifest 固定版本的完整词包。适合 AI 产品、开发和法学领域新词，无需等应用发版。 | 中高：来源和版本维护、用户订阅选择、重复编码排序、可回滚更新。先做一个维护得住的词表，不必先建通用方案市场；保留当前知情下载和源边界。 |
| 4 | 提供鼠须管只读迁移预览 | AIME 已有方案、custom 配置、短语和 sync 词频快照导入；Owltype 当前没有找到等价向导。老 Rime 用户可保留已有输入习惯，减少重新调教。 | 中高：配置兼容、冲突报告、缺失词频快照、回退及用户文件保护。不能照抄成“自动完整迁移”；其词频迁移依赖用户先做同步快照。 |
| 5 | 给常用词增加低成本的置顶入口 | AIME 从高频词列表一键写入短语表；Owltype 已有高优先级候选模板，但主要靠手工编辑触发码。可减少重复选择人名、项目名和专业词。 | 小到中：复用现有候选模板或短语机制，新增快速入口；不必为此引入全量输入统计。自动拼音对多音字并不可靠，允许用户修正编码。 |

以上是建议，不是已实施清单。若当前用户主要是非 Rime 新用户，第 4 项优先级可下调；若反馈集中在特定 App 的中英文切换，第 2 项可以提前。

## 逐项对照

### 候选排序与常用词

**共有能力。** AIME 默认沿用雾凇 `pin_cand_filter`、`long_word_filter`、主翻译器权重 1.2，以及长词补全。Owltype 的种子同样复制雾凇 Lua 并保留这些过滤器；上游固定版本虽然不同，但上述机制都存在。不能把“长词优先”“简拼可用”“有错音提示”单列为 AIME 优势。[AIME 使用的雾凇配置](https://github.com/iDvel/rime-ice/blob/6810e8916d160498620a16fef2135956fecbd485/rime_ice.schema.yaml#L74-L85)、[Owltype 固定雾凇配置](https://github.com/iDvel/rime-ice/blob/b681a34f788795034b3b288830f4861980bc8b0d/rime_ice.schema.yaml#L74-L85)、[种子装配](../scripts/owl-seed.sh)

**真实差异在操作入口。** AIME 高频词页有图钉，调用 `pinUsageWord` 将词及自动生成的全拼 / 受支持双拼编码加入短语表；可取消置顶。Owltype 已有候选模板表，`initial_quality: 99`，也有模板“置顶”设置；但模板列表置顶与把任意普通词提升为拼音首选不是同一操作。此次未找到“普通候选 / 高频词 → 自动编码 → 首选”的同等便捷入口。[AIME 置顶实现:633–659](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Apps/AIMESettings/Model/SettingsModel.swift#L633-L659)、[AIME 高频词界面:140–165](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Apps/AIMESettings/Views/UsageStatsView.swift#L140-L165)、[Owltype 候选模板](../sources/Settings/OwlTemplateStore.swift)、[模板编辑](../sources/Settings/OwlTemplatePage.swift)

收益推断是更容易固定少数个人常用词，不代表通用排序算法更好。这里置顶是将明确词条写入自定义短语表，不是动态学习算法；我们的模板 `isPinned` 用于管理排序，不能冒充普通拼音候选置顶。AIME 高频统计默认关闭、仅本机保存，用户主动开启后才有高频列表；不建议为了快捷置顶自动启用统计。AIME 自动标音也没有证明多音人名总能得到正确编码。[AIME 统计开关说明](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Apps/AIMESettings/Views/UsageStatsView.swift#L237-L242)

### 整句、语言模型与准确率

AIME 可视化暴露 `translator/contextual_suggestions` 与模型名称，并提供万象、白霜等方案包入口；这些是**配置和选择能力**。其说明自己就要求已有 `.gram` 与相应 schema 接线，默认开关为 false；不能因为带 octagram 插件、提供万象卡片，就认定默认雾凇已经启用强整句模型。[AIME 模型设置:204–224](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Packages/AIMEKit/Sources/AIMECore/Resources/catalog.json#L204-L224)、[方案目录](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Packages/AIMEKit/Sources/AIMECore/Resources/registry.json#L54-L138)

Owltype 完整词包 manifest 已含八股文 `.gram`；当前默认 `rime_ice.custom.yaml` 是空 patch，下载到模型不等于每个用户环境都已启用。也不能反向用“我们也有模型文件”宣称质量等价。[Owltype manifest](../sources/DictPack/OwlDictPackManifestData.swift)、[当前默认补丁](../rime/rime_ice.custom.yaml)

**待实测：** 同版本雾凇、相同词库与空用户词频下比较首选命中率、整句需改字数；再单独比较不同方案 / 语言模型。分开看普通聊天、法学长句、专名和中英混合。没有这些数据前，不建议仅凭方案目录迁移默认引擎。

### 纠错、简拼与模糊音

AIME 将简拼、`v/u` 容错、常见误拼修正包装为独立设置；这些规则来自雾凇。Owltype 固定的雾凇 schema 已有对应拼写派生，且设置页有九组模糊音（包括 `r/l`、`in/ing`）。AIME 的可见模糊音列表拆开部分方向，Owltype 则以成对开关表达；不能从设置行数判断谁覆盖更全。[AIME 简拼与纠错设置:544–593](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Packages/AIMEKit/Sources/AIMECore/Resources/catalog.json#L544-L593)、[Owltype 上游拼写规则](https://github.com/iDvel/rime-ice/blob/b681a34f788795034b3b288830f4861980bc8b0d/rime_ice.schema.yaml#L360-L407)、[Owltype 模糊音](../sources/Settings/OwlFuzzyPreferences.swift)、[schema 补丁生成](../sources/Settings/OwlRimePatchBuilder.swift)

值得借鉴的是用具体例子解释开关并允许关闭误纠正；优先级低于解决真实输入反馈。不能把一个开关描述为“新纠错算法”，也不应将规则纠错与我们的 AI / 退格纠错混为同一层能力。

### 英文混输

AIME 默认完整带雾凇 `melt_eng` 和 `cn_en`，中文模式即可出现英文候选，同时用大小写派生和短英文降频减少干扰。详细来源、权重和许可见[先前核实报告](aime-input-method-research-2026-10-02.md)。

Owltype 已有相同家族的英文词表，#181 已在本地修复精简种子与完整词包之间的 translator 接线；工作区 `OwlPinyinMixedInput` 实现“文件齐备后恢复、尊重自定义 schema / translator 列表”。66 项测试及真实 librime 引擎回归通过，但尚未发布。因此这项主要是回归保障和首用验证问题，不能持续作为 AIME 独有能力。[Owltype 混输补丁](../sources/DictPack/OwlDictPack.swift)、[完整词包清单](../sources/DictPack/OwlDictPackManifestData.swift)

两者的这个通道都是中文模式中的词表混输，不是 Shift 切入纯 ASCII 后的智能英文预测。

### 词库与方案更新

AIME 有两个层次：固定版本方案包（雾凇、万象、白霜等）；独立在线术语订阅。订阅按日 / 周 / 手动更新，校验官方目录的 SHA-256，发生词条变化后在输入空闲时重新部署。在线表权重为 6，但关闭补全，主要是精确编码术语。[订阅更新](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Packages/AIMEKit/Sources/AIMECore/VocabularySubscriptions.swift#L228-L284)、[在线表挂载](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Packages/AIMEKit/Sources/AIMECore/VocabularySubscriptions.swift#L353-L380)、[空闲部署调度](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Apps/AIME/InputEngine.swift#L171-L192)

Owltype 并非没有词库管理：已具备固定源版本、逐文件 hash、断点续传、下载源切换、自动部署、用户修改保护。AIME 同样按固定版本校验方案包；它的差异主要是更广的方案目录与持续更新的可选术语订阅，而不是“有校验、有升级”。[Owltype 下载器](../sources/DictPack/OwlDictPackFetcher.swift)、[词库状态与记录](../sources/DictPack/OwlDictPack.swift)、[词包编排](../sources/DictPack/OwlDictPackCenter.swift)

用户文件保护甚至采取不同取舍：Owltype 对无归属记录或用户改过的文件直接跳过；AIME 安装包管理会先备份再替换。因此不能把 AIME 管理器整体称为更安全，借鉴订阅能力即可。[AIME 覆盖备份:203–230](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Packages/AIMEKit/Sources/AIMECore/PackageManager.swift#L203-L230)、[Owltype 下载器](../sources/DictPack/OwlDictPackFetcher.swift)

### 首用验证与迁移

AIME 引导包含真实文本框和任务完成检查，逐项检查示例短语是否上屏、快捷菜单是否打开；Owltype 已有五步引导、启用检测、词包进度和方案选择，但完成页明确不提供真实试打。这是最直接可借鉴的体验闭环。[AIME PracticeStep:621–650](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Apps/AIMESettings/Views/OnboardingView.swift#L621-L650)、[Owltype 引导](../sources/Settings/OwlOnboardingView.swift)

AIME 的鼠须管导入器跳过编译产物和安装身份，将 `*.custom.yaml` 放入 imported 层，将 `sync/*/*.userdb.txt` 作为词频迁移材料；无快照时明确警告，不直接拷运行中的 LevelDB。默认、导入、设置生成三层合成配置。Owltype 现有隔离数据目录、模板迁移和 Raycast 导入不能等同于整个 Rime 用户目录迁移；此次检索未找到等价入口。[AIME 导入计划:58–105](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Packages/AIMEKit/Sources/AIMECore/SquirrelImporter.swift#L58-L105)、[缺失快照警告:154–165](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Packages/AIMEKit/Sources/AIMECore/SquirrelImporter.swift#L154-L165)、[配置层](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Packages/AIMEKit/Sources/AIMECore/ConfigLayers.swift#L4-L20)、[Owltype 数据边界](../sources/Main.swift)、[现有模板迁移](../sources/Settings/OwlTemplateMigrationView.swift)

收益推断是更低迁移成本；未知是各类自定义 Lua、方案和模型实际迁移成功率。

### 按应用的中英状态

AIME 有明确的 `AsciiStatePolicy`：global、app、window 三种范围；配置了默认状态的应用即使在 global 模式也独立记忆。App 的初始默认只用于首次进入，之后取最近记忆状态；该表存在进程内，不能称为跨应用重启永久记忆。它还能扫描已安装应用，提出初始模式建议，并跳过已有配置。[状态策略:3–63](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Packages/AIMEKit/Sources/AIMECore/AsciiStatePolicy.swift#L3-L63)、[应用推荐:82–96](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Packages/AIMEKit/Sources/AIMECore/AppRecommendations.swift#L82-L96)

Owltype 已有系统应用选择器和默认英文 App 列表；创建会话时先设全局默认，再应用 `app_options`，进入不同 App 时也更新其选项。此次未找到与 AIME 相同的 `perApp` 最近状态表或可选共享范围。不能说我们“完全不记忆”：活着的 Rime session 自身仍有状态；具体切换体验需多窗口实测。[App 默认英文 UI](../sources/Settings/OwlAppEnglishSheet.swift)、[会话初始化与 App 选项](../sources/Controller/OwlInputController+Session.swift)、[App 变化检测](../sources/Controller/OwlInputController.swift)

### 候选窗与前端体验

两者都有原生候选窗、横竖布局、字体字号、亮暗样式与预览。Owltype 还提供多行滚动、候选格式、页码提示和预编辑等设置；因此 AIME 的“原生自绘”“实时预览”不构成独有优势。AIME 明确在用户自定义配色下显示最低文字对比度提示（阈值 3）；这是可小步参考的设置反馈，不能据此判定完整无障碍体验更好。[AIME 外观:13–57](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Apps/AIMESettings/Views/AppearanceView.swift#L13-L57)、[Owltype 候选窗设置](../sources/Settings/OwlCandidatePanelSettings.swift)、[Owltype 候选呈现](../sources/UI/OwlCandidatePanelView.swift)、[主题](../sources/Theme/OwlThemes.swift)

**待实测：** 长候选可读性、屏幕边缘、多显示器、Electron / VS Code / 微信宿主、连续快速输入、失焦与切源时的文本完整性。AIME README 中开发机 p99 数值没有同机同词库同宿主的 Owltype 对照，不能直接当作性能领先证据。

## 建议验收方式

在 #181 已完成的本地回归基础上，再用相同配置的短语集对照中文、英文和中英混合候选；为首用验证提供同样的可跳过试打。状态记忆用“聊天中文 → 编辑器英文 → 编辑器注释切中文 → 切走返回”以及同 App 两窗口场景检查。排序与长句需记录首选命中、改选次数和候选延迟，分别报告空用户词频和经过学习后的结果。

本次完成的是源码比较与优先级建议；没有运行 AIME，也没有把任何推断收益标为已验证效果。
