# AIME 安装注销与英文词库核实（2026-10-02）

> 当前状态（2026-10-02）：中英混输修复、按应用记忆中英状态、真实试打与快捷置顶已合入并发布于 2.0.11。本文保留研究时的对照基线，文中的“尚未发布”和功能差距均指当时状态；最终实现、真实宿主验收及未覆盖项见 [输入体验设计与验收记录](input-habits-design.md)。

核实对象是 Zool 的 **AIME / 艾么输入法**，官网 https://aime.zool.app，官方仓库 `zoolapp/aime`。本次读取公开源码与上游词库，未安装或运行 AIME；没有用宣传或代码存在替代端到端验收。

源码基线：AIME [`90e9e431d112e2407ce7c34375bd288b2401db17`](https://github.com/zoolapp/aime/tree/90e9e431d112e2407ce7c34375bd288b2401db17)；雾凇 `2026.06.30` 对应 [`6810e8916d160498620a16fef2135956fecbd485`](https://github.com/iDvel/rime-ice/tree/6810e8916d160498620a16fef2135956fecbd485)；librime 1.17.0 对应 [`33e78140250125871856cdc5b42ddc6a5fcd3cd4`](https://github.com/rime/librime/tree/33e78140250125871856cdc5b42ddc6a5fcd3cd4)。

## 可实施结论

1. **AIME 没有彻底解决首次安装需要注销的问题。** 它不强制安装器注销，尝试自动注册、启用、选中；失败时仍让用户手动添加输入源，必要时注销。README 和发布清单都明确说明这一点。[README:76](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/README.md#L76)、[发布清单:84–86](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/docs/release-checklist.md#L84-L86)
2. **升级走普通 pkg 替换及重新注册，没有找到特殊免注销技术。** 安装器没有强制注销要求；源码不能证明所有升级情形均无需注销，也不能证明旧进程退出和新实例接管全部成功。[打包脚本:22–40](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/scripts/package.sh#L22-L40)
3. **基础英文能力直接来自雾凇 `melt_eng`，不是 AIME 自研英文词库或 AI 英文补全。** 默认完整携带雾凇方案、英文主词库、扩充词库与 Lua；此外提供自己维护的 AI / 品牌术语订阅。[词库装配脚本](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/scripts/fetch-dicts.sh#L15-L51)、[雾凇英文词典](https://github.com/iDvel/rime-ice/blob/6810e8916d160498620a16fef2135956fecbd485/melt_eng.dict.yaml#L7-L13)

## 1. 安装、升级及注销

### 实际流程

- `preinstall` 用 `pkill -f` 停止 `/Library/Input Methods/AIME.app/Contents/MacOS/AIME`。[preinstall:1–4](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/scripts/pkg/scripts/preinstall#L1-L4)
- pkg 将输入法装到 `/Library/Input Methods`，设置应用装到 `/Applications`；安装结束声明 `onConclusion="none"`。同一脚本没有首次安装与升级的独立分支。[package.sh:13–40](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/scripts/package.sh#L13-L40)
- `postinstall` 获取 `/dev/console` 所属用户，以该用户运行输入法自身的 `AIME --install`；注册是按用户的，不以 root 做 TIS 操作。命令失败被 `|| true` 忽略，安装脚本仍成功退出。[postinstall:1–9](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/scripts/pkg/scripts/postinstall#L1-L9)
- 输入法自身执行 `TISRegisterInputSource` → 枚举本 bundle 的输入源 → `TISEnableInputSource` → 找到 `app.zool.inputmethod.aime.hans` → `TISSelectInputSource`。代码注释强调由输入法自己的 bundle 选择其模式；找不到 mode 时直接提示注销重登，没有恢复算法。[Installer.swift:4–38](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Apps/AIME/Installer.swift#L4-L38)
- `--install` 分支执行后立即退出，不继续创建 IMKServer；普通启动才建立 IMKServer。[main.swift:7–22](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Apps/AIME/main.swift#L7-L22)
- 应用内更新下载并校验包后，用 `NSWorkspace.shared.open(package)` 打开系统 Installer，仍由用户完成 pkg 安装。[SettingsModel.swift:780–797](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Apps/AIMESettings/Model/SettingsModel.swift#L780-L797)

### 能确定与不能确定的事

AIME 的选择是“尽量当场注册，失败给恢复说明”。其发布清单记录 macOS 首次安装可能 `TISSelectInputSource == -50`；因此“安装器不强制注销”不能解读为“首次安装必定不用注销”。开发安装脚本也保留第一次安装注销提示，并警告系统目录与用户目录两个相同 bundle ID 副本会造成启动目标和图标缓存混淆。[发布清单:84–86](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/docs/release-checklist.md#L84-L86)、[install-dev.sh:18–27](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/scripts/install-dev.sh#L18-L27)

本次查看的安装路径没有切换到备用输入源、等待旧进程完整退出、刷新菜单服务、重试选择或核对新进程接管的流程。不能仅凭简短实现认定其比 Owltype 的升级流程更可靠。

## 2. 英文词库与补全

### 基础词库来源与大小

构建脚本下载雾凇 `2026.06.30/full.zip`，核对 SHA-256，解压到应用的只读 `SharedSupport`。只移除鼠须管 / 小狼毫前端配置等文件，保留英文方案和词库。AIME 默认 `rime_ice` 补丁为空，没有另建英文引擎。[fetch-dicts.sh:15–47](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/scripts/fetch-dicts.sh#L15-L47)、[默认补丁](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/SharedSupport/aime/defaults/rime_ice.yaml#L1-L7)

`melt_eng.dict.yaml` 按顺序导入 `en_dicts/en_ext`、`en_dicts/en`；扩充库先导入，是因为少量重复条目带有额外权重。[melt_eng.dict.yaml:10–12](https://github.com/iDvel/rime-ice/blob/6810e8916d160498620a16fef2135956fecbd485/melt_eng.dict.yaml#L10-L12)

- `en.dict.yaml` 词头声明来源是 google-10000-english 的常见两万词，并合并 rime-melt 一千余不重复词；移除了单字母、大量双字母和冷僻缩写，并修正大小写。本次从被 AIME 固定 SHA-256 的 zip 统计到 **21,225 条非注释制表符记录**。[en.dict.yaml:1–22](https://github.com/iDvel/rime-ice/blob/6810e8916d160498620a16fef2135956fecbd485/en_dicts/en.dict.yaml#L1-L22)
- `en_ext.dict.yaml` 主要是缩写、互联网和产品词，统计 **2,594 条记录**。两库有重复，不能将总和当作独立单词数。[en_ext.dict.yaml:1–15](https://github.com/iDvel/rime-ice/blob/6810e8916d160498620a16fef2135956fecbd485/en_dicts/en_ext.dict.yaml#L1-L15)
- `en_dicts/cn_en.txt` 另外提供中英混合词表，本次统计 **1,001 条非注释制表符记录**；通过 `stabledb` 挂载，允许补全，初始权重 0.5。[cn_en 配置](https://github.com/iDvel/rime-ice/blob/6810e8916d160498620a16fef2135956fecbd485/rime_ice.schema.yaml#L197-L206)

### 挂载、排序和大小写

雾凇在中文方案中同时挂载中文 `script_translator`、英文 `table_translator@melt_eng`、混合词 `table_translator@cn_en`，所以英文候选可以随中文拼音候选一起出现。[引擎配置:60–85](https://github.com/iDvel/rime-ice/blob/6810e8916d160498620a16fef2135956fecbd485/rime_ice.schema.yaml#L60-L85)

| 机制 | 已核实的实现 |
| --- | --- |
| 中英基础权重 | 中文 `initial_quality: 1.2`，英文 1.1；英文关闭造句和用户词典，因此这个通道没有用户词频学习。 |
| 前缀补全 | 英文配置未覆盖 `enable_completion`；固定 librime 的 `TranslatorOptions` 默认 `true`。这是源码配置推断，未做实际候选测试。 |
| 避免短英文抢首位 | `reduce_english_filter` 使用 `custom` 列表，把指定编码的英文候选下移，`idx: 2`；例如配置注释用 `rug / 如果` 说明目的。 |
| 大小写及带符号产品名 | `melt_eng.schema.yaml` 有大小写、数字、符号拼写派生；`autocap_filter.lua` 根据首字母或前两位大写转换英文候选。 |

证据：[中文和英文参数:165–194](https://github.com/iDvel/rime-ice/blob/6810e8916d160498620a16fef2135956fecbd485/rime_ice.schema.yaml#L165-L194)、[librime 默认补全:176](https://github.com/rime/librime/blob/33e78140250125871856cdc5b42ddc6a5fcd3cd4/src/rime/gear/translator_commons.h#L176)、[短词降频配置:118–152](https://github.com/iDvel/rime-ice/blob/6810e8916d160498620a16fef2135956fecbd485/rime_ice.schema.yaml#L118-L152)、[拼写派生:75–138](https://github.com/iDvel/rime-ice/blob/6810e8916d160498620a16fef2135956fecbd485/melt_eng.schema.yaml#L75-L138)、[自动大写过滤器](https://github.com/iDvel/rime-ice/blob/6810e8916d160498620a16fef2135956fecbd485/lua/autocap_filter.lua#L1-L62)。

这些是**中文模式中的英文词表混输 / 补全**，不等于按 Shift 切入 `ascii_mode` 后还有独立英文预测功能。源码中普通英文透传走 librime 未处理按键的分支，没有找到 AIME 自研的 ASCII 模式英文预测器。[AIMEInputController.swift:228–247](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Apps/AIME/AIMEInputController.swift#L228-L247)

### 更新：基础词包与在线术语是两条路径

基础雾凇的完整方案和“仅词库”包都在 registry 中固定为 `2026.06.30`、对应 release 文件和 SHA-256。“仅词库”条目明示仅更新 `cn_dicts / en_dicts`，不动配置。下载器校验 hash 后安装，覆盖用户自行修改的文件前保留备份。不能把在线词库的每日更新宣传理解为自动追踪雾凇最新英文主词库。[registry:6–58](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/dicts/registry.json#L6-L58)、[PackageManager.swift:157–230](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Packages/AIMEKit/Sources/AIMECore/PackageManager.swift#L157-L230)

在线术语订阅是 AIME 额外提供的产品层：随应用的目录有 AI 公司产品、AI 与开发术语、互联网品牌热词三组，每组声明 160 条；可包含保留正确大小写的英文品牌，声明 CC BY 4.0。[vocabulary-catalog.json](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/SharedSupport/aime/vocabulary-catalog.json#L1-L54)

订阅支持每天、每周、手动，默认每天；定时器每小时检查，真正下载遵守各订阅周期。官方 feed 跟随远端目录的 URL 和 SHA-256，先校验再保存；更新后在用户空闲时部署。源码定时器附近“每 12 小时”的注释已过时，实际间隔以 `UpdateInterval` 的 24 小时 / 7 天为准。[更新周期:79–99](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Packages/AIMEKit/Sources/AIMECore/VocabularySubscriptions.swift#L79-L99)、[下载校验:228–284](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Packages/AIMEKit/Sources/AIMECore/VocabularySubscriptions.swift#L228-L284)、[调度和部署:150–192](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Apps/AIME/InputEngine.swift#L150-L192)

订阅内容生成独立的 `aime_online` 表，按文字和编码去重、取最高权重；适配全拼和支持的双拼，拉丁编码原样保留。其 translator 是 `stabledb`、`initial_quality: 6`、**关闭补全与造句**；因此主要是高优先级精确编码术语补充，不应当作通用英文预测词库。[生成与挂载:308–380](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/Packages/AIMEKit/Sources/AIMECore/VocabularySubscriptions.swift#L308-L380)

### 许可边界

AIME 原创代码是 MIT；项目自己的第三方声明把雾凇方案、词表和 Lua 标为 GPL-3.0。发布说明声明因包含 GPL 组件，安装包整体按 GPL-3.0 分发，并附对应源码包。不能因 AIME 原创代码 MIT 就把其所有词库当作 MIT。[第三方声明](https://github.com/zoolapp/aime/blob/90e9e431d112e2407ce7c34375bd288b2401db17/THIRD_PARTY_NOTICES.md#L1-L25)、[v0.1.0 发布说明](https://github.com/zoolapp/aime/releases/tag/v0.1.0)

这里核实的是 AIME / 雾凇的许可证声明及词头来源记录，没有独立审计每个英文数据源的完整权利链；不能把上述来源声明扩大为已经完成的数据许可审计。

## 本次验证与限制

- AIME 源码只读 checkout：`/tmp/aime-research-20261002`；未执行其安装、构建、输入法注册或删除脚本。
- 下载并解压雾凇固定 release 的 `full.zip`，SHA-256 为 `675d23b070be00e1b800f9a6db033ef98f4493cd5b568ed8aa3b3541769c46ac`，与 AIME registry 完全一致。
- 词条数是该包文本的静态行记录统计，不代表独立词数、实际可输入候选数或质量评测。
- 未做首次安装、升级或英文输入真机测试；未将发布文档、注释或运行路径的存在当作功能已验收。

## Owltype 对照与英文候选缺失复现

以下是 Owltype 的独立引擎实验，不是 AIME 运行结果。仓库基线为 `3be472b25d18427ccde759f93071f02babcf4f4a`，本机安装版本为 **2.0.10**。使用安装包的 librime、SharedSupport，以及从出厂 `_user_seed` 复制出的隔离用户目录；没有读取个人词频，没有修改已装应用或实际用户配置。

### 安装流程对照

Owltype 已将首装与自动更新分开：[首装 Distribution](../package/Distribution) 仍有 `RequireLogout`，[更新 Distribution](../package/Distribution-update) 没有。更新 [postinstall](../scripts/postinstall) 还包含输入源切换、等待安装收据、刷新菜单及恢复选中态。因此 AIME 没有提供一个我们尚未采用的、已验证的免注销突破；若手动使用首装包更新，仍会受首装包的注销声明影响。本次未运行安装升级验收。

### 已复现的全拼缺陷

| 隔离配置 | 输入 `hello` 的实际结果 |
| --- | --- |
| 出厂种子 | preedit 为 `he l l o`，首候选 `何鲁丽哦`，首页没有英文 `hello` |
| 出厂种子 + 英文词库 | 与上一行一致，仍无 `hello` |
| 同样词库 + 接回 `melt_eng` 依赖及 translator | preedit 为 `hello`，首候选为 `hello` |
| 原始出厂种子输入 `hello{Return}` | `commit=hello`，证明原始英文回车上屏仍可用 |

第二、三组使用本项目 [完整词库清单](../sources/DictPack/OwlDictPackManifestData.swift) 固定的 `b681a34f788795034b3b288830f4861980bc8b0d` 版本，下载 `en_dicts/en.dict.yaml`、`en_dicts/en_ext.dict.yaml`、`melt_eng.dict.yaml`、`melt_eng.schema.yaml`，逐个核对清单 SHA-256。第三组只在隔离目录的 `rime_ice.custom.yaml` 加入：

```yaml
patch:
  "schema/dependencies/+":
    - melt_eng
  "engine/translators/+":
    - table_translator@melt_eng
```

根因在打包种子与下载词库之间的接入缺口：[owl-seed.sh:100–110](../scripts/owl-seed.sh#L100) 为精简种子删掉了 `melt_eng` 依赖、`table_translator@melt_eng` 及 `table_translator@cn_en`。完整词库清单包含英文数据，却没有 `rime_ice.schema.yaml`，也没有恢复全拼英文 translator 的补丁；[Fetcher](../sources/DictPack/OwlDictPackFetcher.swift) 负责落盘，[Center](../sources/DictPack/OwlDictPackCenter.swift) 随后重新部署。因此单纯补数据没有把英文接回候选生成链。

这是**全拼中文模式下英文候选/补全的接入缺陷**；不能扩大成英文字符完全不能输入，也不能直接推广到双拼、用户自定义方案或朋友尚未取得的具体环境。`cn_en` 也被移除是静态事实，本次未单独测试中英混合词。

保留的复现脚本：[scripts/repro-pinyin-english.sh](../scripts/repro-pinyin-english.sh)。运行 `bash scripts/repro-pinyin-english.sh` 检查已装应用的出厂配置；可传入 fixture 用户目录，脚本先复制到临时目录再部署。断言仅检查首页是否有 `hello`，候选通道缺失另由编译后的方案核实。它是诊断脚本，未接入发布门禁。

本次实际运行：

```text
bash scripts/repro-pinyin-english.sh /tmp/owltype-english-diagnosis/dictionary-only
FAIL: hello is absent from the first candidate page  (exit 1)

bash scripts/repro-pinyin-english.sh /tmp/owltype-english-diagnosis/dictionary-and-translator
PASS: hello is available as a candidate              (exit 0)
```

实验目录保留于 `/tmp/owltype-english-diagnosis`。本次只新增研究记录与复现脚本；产品修复、真实宿主应用验收、提交及发布均未执行。

## #181 修复与验证（同日后续授权）

用户随后授权实施，建立 [GitHub #181](https://github.com/semantic-craft/owltype-macos/issues/181)。以上“尚未修改产品”描述是诊断阶段的状态；现在已完成以下本地修改，尚未提交、推送、安装或发布。

- `OwlPinyinMixedInput` 在每次启动/完整部署前检查英文资源；就绪后通过独立托管块恢复 `melt_eng` 及 `cn_en`。命令行 `--build` 也执行同一接入，因此首装下载、已装词库升级和重部署共用逻辑。
- 插入项使用独立的列表插入键，与快捷短语 `engine/translators/+` 共存；重复应用不重复挂载。缺失数据时不挂载对应通道。
- 保留用户自定义的 schema、整个 translator 列表和间接 include；这类配置由用户控制，不自动覆盖。已有英文挂载也不重复添加。
- 配置写入器在追加托管块前展开种子的 `patch: {}`，避免空 flow map 下追加缩进项产生无效 YAML。
- [回归脚本](../scripts/check-pinyin-mixed-input.py) 使用指定 App 和本清单 SHA-256 验证过的五个英文资源，全程只操作临时用户目录。`tools/owl-rime-probe.cc` 新增可选候选数量，能核对后续页而不把“没在首页”误判为“无候选”。

验证基线：`3be472b25d18427ccde759f93071f02babcf4f4a` 加当前未提交修复。

1. Xcode Debug 构建成功；`OwlPinyinMixedInputTests`、`OwlDictPackTests`、`OwlKeyboardPatchBuilderTests`、`OwlTemplateMigrationTests`、`CandidateStoreTests` 共 **66 项通过**。日志 `/tmp/owltype-mixed-input-tests.log`。补充用户 `/=` 和索引覆盖保护后，相关 4 项测试再次通过（`/tmp/owltype-mixed-input-final-tests.log`），实际引擎回归也重新通过。
2. 同一实际引擎回归脚本对已装旧版 2.0.10 为红，对修复构建为绿。覆盖下载前后、已有词库升级、模板共存、用户自定义列表、重复部署；包括 `hello`、`gith → GitHub`、`hell → hello`、`qqqun → QQ群`、`xguang → X光`、`nihao → 你好`、空格和回车提交。日志 `/tmp/owltype-mixed-replay-before.log`、`/tmp/owltype-mixed-replay.log`。
3. 保持雾凇原有排序：前缀或中英混合词不保证首选。例如隔离出厂中文数据中 `hell → hello` 在第 13 项，`xguang → X光` 在第 19 项；均可翻页选择。这次没有另改候选排序策略。
4. 修改文件 SwiftLint 无错误（有既有警告），Python/Bash 语法检查及 `git diff --check` 通过。未跑全量门禁；未进行 TextEdit/微信等实际宿主的界面输入验收，未替换用户正在使用的输入法。

复跑：先运行 `make debug` 和 `make copy-owl-seed`（默认构建目录 `build`），再运行下列命令。之前 `/tmp/owltype-mixed-input-build` 中的临时构建已清理；测试词库仍保留，受 manifest 校验且不包含用户数据。

```bash
python3 scripts/check-pinyin-mixed-input.py \
  --app build/Build/Products/Debug/Owltype.app \
  --dicts /tmp/owltype-mixed-integration/full
```
