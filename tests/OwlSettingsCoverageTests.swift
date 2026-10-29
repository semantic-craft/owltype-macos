//
//  OwlSettingsCoverageTests.swift
//  OwltypeTests
//
//  Source-level guard for the settings coverage manifest. Action/e2e tests prove behavior;
//  this test makes new user-facing settings controls fail until the manifest is updated.
//

import Foundation
import XCTest

final class OwlSettingsCoverageTests: XCTestCase {
  func testEverySettingsControlLabelIsTrackedByCoverageManifest() throws {
    let source = try Self.combinedSource()
    let foundLabels = Self.extractLabels(from: source)
    let unexpectedLabels = foundLabels.subtracting(Self.expectedControlLabels).sorted()
    let missingLabels = Self.expectedControlLabels.subtracting(foundLabels).sorted()

    XCTAssertEqual(unexpectedLabels, [], "New settings controls need action/e2e coverage and manifest review.")
    XCTAssertEqual(missingLabels, [], "Expected settings controls disappeared; update tests and docs deliberately.")

    for marker in Self.expectedSourceMarkers {
      XCTAssertTrue(source.contains(marker), "Missing settings marker: \(marker)")
    }
  }

  private static let settingsFiles = [
    "sources/Settings/OwlSettingsView.swift",
    "sources/Settings/OwlKeyboardPage.swift",
    "sources/Settings/OwlKeyboardPage+SmartPunctuation.swift",
    "sources/Settings/OwlWubiCommitSettings.swift",
    "sources/Settings/OwlWubiLookupSettings.swift",
    "sources/Settings/OwlInputHabitsSettings.swift",
    "sources/Settings/OwlKeyboardPreferences.swift",
    "sources/Settings/OwlSettingsPages.swift",
    "sources/Settings/OwlSkinPage.swift",
    "sources/Settings/OwlQuickSendPage.swift",
    "sources/Settings/OwlClipboardPage.swift",
    "sources/Settings/OwlSkillsPage.swift",
    "sources/Settings/OwlAIPage.swift",
    "sources/Settings/OwlPromptPage.swift",
    "sources/Settings/OwlEmojiPreferences.swift",
    "sources/Settings/OwlFuzzySheet.swift",
    "sources/Settings/OwlAppEnglishSheet.swift",
    "sources/Settings/OwlWritePreviewSheet.swift",
  ]

  private static let expectedControlLabels: Set<String> = [
    // OwlSegmentedControl option labels (replaced the old `Picker(.segmented)` titles).
    // 浅色/深色 dropped: 外观模式 + 皮肤预览 removed from 候选窗设置 (明暗 lives on 皮肤外观, uses 亮/暗).
    "跟随系统",
    // Input habits: persistence, forget/unpin and native practice are covered by OwlInputHabitsTests.
    "记住每个应用的中英文状态", "管理记忆…", "忘记", "管理置顶词…", "取消置顶",
    // 候选窗尺寸：2026-08-06 由三档「候选字号」升为四档，`特大`(base 27) 是纯增补，小/中/大
    // 三档的点数与 rawValue 都没动（老用户零迁移）。这一档拨的是整块面板——候选字与留白同步
    // 缩放。生命周期覆盖在 OwlCandidatePanelDisplayLifecycleTests；点数阶梯与留白换算表在
    // OwlPanelSizeTests。
    "小", "中", "大", "特大",
    // 排列方向；多行在翻页后显示前后页候选。
    "自动", "横排", "竖排", "多行",
    "默认", "衬线", "圆体", "Noto Serif SC", "Maple Mono",
    "亮", "暗",
    // 06-26 batch: 7 new Rime/Squirrel config controls.
    // 简入繁出 toggle 已并入「默认状态」组的「简繁体」下拉（`defaultStatePickerRow` helper，
    // 不被本清单的 SettingsToggleRow 正则提取）。
    "Caps Lock 切换西文",             // Feature 2 good_old_caps_lock
    "内嵌候选预览",                   // Feature 3
    "候选条翻页箭头",                 // Feature 4
    // 多行的后页行数分段（只在排列方向 = 多行时露出；2026-07-28 上限放宽到 4）。
    // 生命周期覆盖在 OwlCandidatePanelDisplayLifecycleTests；纯逻辑（取数门控/切页）在
    // OwlScrollRowsPlanTests。
    "跟 1 页", "跟 2 页", "跟 3 页", "跟 4 页",
    "始终", "智能", "从不",           // Feature 5 切换提示通知
    "标准", "隐藏注释", "仅候选",     // Feature 7 候选格式
    "OwlInputMenuTitles.deploy",
    "OwlInputMenuTitles.logs",
    "OwlInputMenuTitles.onboarding",
    "OwlInputMenuTitles.configFolder",
    // 重置用户词典…（#37）：备份+删除+还原全链路覆盖在 OwlUserDictResetTests，
    // 确认弹窗默认按钮同处断言。
    "OwlInputMenuTitles.resetUserDict",
    "OwlInputMenuTitles.migrateLegacyUserData",
    "https 端点",
    // 辅助功能权限：状态即入口的单一按钮，accessibilityLabel 随授权态切换。
    "辅助功能已授权，点此打开权限设置",
    "辅助功能未授权，点此前往授权",
    "删除供应商",
    "模型，如 gpt-4o / deepseek-chat",
    "拉取最新",                       // AI 配置：拉取供应商 /models 模型列表
    // AI 配置：拿「端点 + 这个型号 + Key」真发一次最小请求。补的正是「拉取最新」证明不了的那一段——
    // `/models` 通不代表你选的型号能用（实盘撞过：同一把 Key 拉 /models 正常，型号打错端点是 400
    // url error）。action coverage 在 ProviderProfileStoreTests 的 OwlProviderConnectivityCheckTests。
    "验证连通性",
    "选择模型",                       // AI 配置：从 curated + 拉取结果里选模型
    // Qwen Responses 的 Workspace 设置：供应商表单与独立百炼检索共用。规范化、非法 Host 拒绝、
    // 偏好持久化及既有 Qwen profile 端点同步，覆盖在 ProviderProfileStoreTests。
    "Workspace ID 或 API Host",
    "新 Workspace 的 API Key（换空间时必填）",
    "保存空间",
    // 已配供应商的原地编辑（换模型不必删了重加）：入口按钮 + 编辑态的两个 footer 按钮。
    // action coverage 在 OwlProviderRegistryTests 与 ProviderProfileStoreTests 的 replaceEndpoint 断言。
    "修改模型：\\(profile.displayName)",
    "保存修改",
    "取消",
    "刷新",                           // 诊断页 (OwlDiagnosticsPage)：重跑 buildReport()
    "导出诊断包",                     // 诊断页：NSSavePanel 写脱敏支持包（报告 JSON + 统一日志）
    // 诊断页「当前系统输入源」行下方：enable + select，系统随即写 AppleSelectedInputSources，
    // 下次登录恢复猫头鹰（docs/default-input-method-plan.md §4）。这是全仓唯一允许调用
    // makeDefault() 的路径——安装/更新/启动路径复用即破坏 no-steal。action coverage 在
    // ActivationPolicyTests 的 makeDefaultPlan / makeDefaultResult / makeDefaultStatusText 断言。
    "设为系统默认输入法",
    "添加并设为默认",
    // 供应商行改单选 radio（1.4.19 / 624ce54）：整行 Button 的 accessibilityLabel 随 isDefault 三元切换，
    // 两支都插值 provider 名，正则按「源码字面量」提取故含 `\(…)` 文本（Swift 侧需 `\\(` 转义），
    // 与上方 辅助功能 三元 a11y 标签同策略登记两支。旧的静态「设为默认」按钮已随 radio 改造移除。
    "设为默认：\\(profile.displayName)",
    "\\(profile.displayName)（当前默认）",
    "选择供应商预设",
    "自定义（OpenAI 兼容）",
    "an = ang",
    "ch = c（翘舌）",
    "en = eng",
    "f = h",
    "in = ing",
    "n = l",
    "r = l",
    "sh = s（翘舌）",
    "zh = z（翘舌）",
    "中文与英文间加入空格",
    "智能标点",
    "重复标点改为中文",
    "标点后空格改为英文",
    "成对输入",                       // task 07-02 本地便捷输入：commit 层配对补全（默认关；07-21 由「自动配对括号」改名）
    // 本地模型重排（#257/#258）：默认关；模型资源、许可、SHA 与运行状态同卡展示。
    "逐键候选重排",
    "停顿候选重排",
    "中文下使用英文标点",
    "使用 Shift 切换中英文",
    "下载 Noto Serif SC 字体",
    "下载 Maple Mono CN 字体包",
    "保存修改",
    "我已了解：写入会修改 ~/Library/Application Support/Owltype（需真机；备份+manifest 已就绪，可回滚）",
    "候选条动画",
    "候选窗显示输入串",
    // Actual runtime toggles are covered by the existing Wubi commit and hint/wildcard tests.
    "候选剩余编码提示",
    "四码唯一候选自动上屏",
    "第五码将首选上屏",
    "z 通配",
    // 候选个数 is now a OwlSegmentedControl (was a Stepper); its option labels are 3…9.
    "3", "4", "5", "6", "7", "8", "9",
    "关闭",
    "写入并应用配置（需真机）",
    "减号等号翻页",
    // 场景词库/术语规则设置 UI 已在 ccda902「audit privacy and remove dead code」中移除；
    // 其全部标签与源码标记于 2026-07-24 单仓合并时确认出册（deliberate ack）。
    "双拼方案",
    "五笔方案",
    "z 临时拼音反查",
    "启用云端 AI",
    "联网搜索",                        // 任意提问专属：开启后交给可联网供应商作答
    "启用划词工具箱",                  // 2026-07-26 重设计：自动弹出改双击 ⌥ 召唤，开关随之改名
    "启用剪贴板面板",
    "在候选中显示 emoji",
    // Real settings toggle → persisted preference → queued live engine ON/OFF is covered by
    // OwlRustEngineTests.testNativeQuickPhrasePreferencePreservesLiveComposition.
    "普通候选中显示快捷短语",
    "回滚最近写入",
    "完成",
    "左右中括号翻页",
    "捕获当前剪贴板",
    "检查更新",
    "添加短语",
    "添加…",                          // App 默认英文 管理弹窗：选应用
    "管理…",                          // App 默认英文：打开管理弹窗
    "移除",                           // App 默认英文 管理弹窗：删一项

    "清空",
    "清空记录",
    "来源核验",
    "规范排版",
    "划词翻译",
    // 2026-07-26 技能精简：公文排版 / 润色·多版本挑选 / 润色·仿我的范例 / 结构化·加标签 四行
    // 出册（个性化加工由「任意提问」兜底，加标签并入「提示词优化」）；「润色·直接替换」独苗后
    // 简名「润色」；「任意提问」置顶成真开关行。
    "任意提问",
    "润色",
    "提示词优化",
    "任务书",                          // 目标七问：模糊需求整理成 Agent 可执行的目标任务书
    "记住我常用的词（个性化）",
    "短语",
    "空码自动清码",
    "编码，如 mty 或 mtycs",
    "输入中文时 “/” 弹出符号选单",
    // 「<」与「/」符号选单的 patch coverage 在 OwlKeyboardPatchBuilderTests。
    "输入中文时 “<” 弹出符号选单",
    // N3 ` 临时英文（键盘页 五笔 卡，2026-07-21）：patch coverage 在 OwlKeyboardPatchBuilderTests
    // 的 wubiEnglishChannel 断言。
    "` 临时英文",
    "逗号句号翻页",
    "设置模糊拼音",
    "保存并重新应用", "重新应用",
    // 完整词库卡（方案B dict-pack）：Rust 后端先把 generation 准备成候选，用户再显式启用或回退；
    // legacy Rime 后端仍走下载后 deploy。事务与不自动切换由 OwlRustResourceTransactionTests、
    // OwlRustEngineTests 和 OwlDictPackTests 的中心层门控覆盖。
    "立即下载（约 90 MB）",
    "重试",
    "启用",
    "回退到 v\\(target)",
    "辅助检索",
    "分号引号选 2/3 位",
    // 「唤起热键」不再列入：快捷短语面板与划词菜单都改用 UI 层的 OwlHotKeyRecorderRow 录制器，
    // 标签随之离开 settings- 源文件（与录制器其余文案同一策略）。
    "粘贴",
    // 提示词管理面板 (OwlPromptPage)：master-detail 控件标签。
    // 方案 A（07-21）：三个字段改常驻标签 + 描述性 placeholder，两组都会被提取、都登记。
    "提示词",
    "触发码",
    "标题",
    "分类",
    "如 docs",
    "显示在候选条上的名字",
    "可空；用于左列分组",
    "正文",
    "新建",
    "删除",
    "保存并应用",
    "搜索",
    "变量",
    // 来源核验 · 豆包搜索：Key 存取在 OwlSettingsActions.saveDoubaoSearchKey / clearDoubaoSearchKey，
    // 行为由 OwlDoubaoSearchWireTests 的 key store 用例与 OwlSourceVerificationServiceTests 覆盖。
    "豆包搜索 API Key（写入 Keychain）",
    "已设置 ●●●●●●（输入新 Key 可覆盖）",
    "保存",
    "清除",
  ]

  private static let expectedSourceMarkers = [
    "title: method.displayName",
    ".accessibilityLabel(skin.displayName)",
    "case .singleFirst: return \"单字优先\"",
    "case .singleOnly: return \"纯单字\"",
    "(\"竖排\", .vertical)",
    "ForEach(OwlLLMProviderCatalog.presets)",
    "providerID: providerID",
    "registry.applyQwenWorkspace(",
    // Key 字段的提示语按「新增 / 编辑」两态分叉：编辑态留空＝保持现有 Key，不是稍后再填。
    // 这个区别是原地改模型不用重贴 Key 的用户可见凭据，两支都钉住。
    "API Key（\\(hint)写入 Keychain，可留空稍后再填）",
    "API Key（\\(hint)留空＝保持现有 Key 不变）",
    "OwlSettingsActions.saveDoubaoSearchKey(",
    "OwlSettingsActions.clearDoubaoSearchKey(",
    "toggle(.quickPhraseCandidates)",
    "OwlExperimentalPreferences.keyboardRerankEnabled",
    "OwlExperimentalPreferences.settledRerankEnabled",
  ]

  private static let labelPatterns = [
    LabelPattern(#"Settings(?:ToggleRow|CheckRow|RadioRow)\s*\(\s*title:\s*"([^"]+)""#),
    LabelPattern(#"row\("([^"]+)""#),
    LabelPattern(#"Picker\("([^"]+)""#),
    LabelPattern(#"TextField\("([^"]+)""#),
    LabelPattern(#"SecureField\("([^"]+)""#),
    LabelPattern(#"SecureField\s*\(\s*[^?\n]+\?\s*"([^"]+)"\s*:\s*"([^"]+)""#, captures: [1, 2]),
    LabelPattern(#"Button\("([^"]+)""#),
    LabelPattern(#"smallButton\("([^"]+)""#),
    LabelPattern(#"Label\("([^"]+)""#),
    LabelPattern(#"Label\s*\(\s*[^?\n]+\?\s*"([^"]+)"\s*:\s*"([^"]+)""#, captures: [1, 2]),
    LabelPattern(#"accessibilityLabel\("([^"]+)""#),
    LabelPattern(#"accessibilityLabel\s*\(\s*[^?\n]+\?\s*"([^"]+)"\s*:\s*"([^"]+)""#, captures: [1, 2]),
    LabelPattern(#"actionButton\(title:\s*OwlInputMenuTitles\.([A-Za-z0-9]+)"#) {
      ["OwlInputMenuTitles.\($0[0])"]
    },
    LabelPattern(#"Toggle\s*\([^)]*\)\s*\{\s*Text\("([^"]+)""#),
    LabelPattern(#"Stepper\s*\([^)]*\)\s*\{\s*Text\("([^"]+)""#),
    LabelPattern(#"Text\("([^"]+)"\)\s*\.font\([^)]*\)\s*\.foregroundStyle\(palette\.ink2\)"#),
    LabelPattern(#"options:\s*\[(.+?)\]"#) { captures in
      guard let body = captures.first else { return [] }
      let quoted = try! NSRegularExpression(pattern: #""([^"]+)""#)
      let range = NSRange(body.startIndex..<body.endIndex, in: body)
      return quoted.matches(in: body, range: range).compactMap {
        Range($0.range(at: 1), in: body).map { String(body[$0]) }
      }
    },
  ]

  private static func combinedSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try settingsFiles
      .map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
      .joined(separator: "\n")
  }

  private static func extractLabels(from source: String) -> Set<String> {
    var labels: Set<String> = []
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    for pattern in labelPatterns {
      for match in pattern.regex.matches(in: source, range: range) {
        let captures = pattern.captureIndexes.compactMap { capture(match, at: $0, in: source) }
        labels.formUnion(pattern.transform(captures))
      }
    }
    return labels
  }

  private static func capture(_ match: NSTextCheckingResult, at index: Int, in source: String) -> String? {
    guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: source) else {
      return nil
    }
    return String(source[range])
  }

  private struct LabelPattern {
    let regex: NSRegularExpression
    let captureIndexes: [Int]
    let transform: ([String]) -> [String]

    init(
      _ pattern: String,
      captures: [Int] = [1],
      transform: @escaping ([String]) -> [String] = { $0 }
    ) {
      regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
      captureIndexes = captures
      self.transform = transform
    }
  }
}
