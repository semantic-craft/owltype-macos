//
//  OwlSelectionMenuCoordinator.swift
//  猫头鹰输入法 (Owltype) — 划词工具箱 (selection toolbox)
//
//  2026-07-26 工具箱重设计：「选中即自动弹出小菜单」整条管线已删（0.30s 停留、每次划选后的
//  AX 读、dismissedText/代数计数那套消失状态机都是它的陪葬）。现在唯一的打开方式是明确手势——
//  选中文字后双击 ⌥（或录制的召唤热键）→ 读一次选区 → 打开 OwlAIWindow 工具箱（技能按钮行 +
//  任意提问输入框）。本文件保留：动作集、快照/替换类型、AX 选区读取、双击 ⌥ 判定器、技能分发
//  与三个破坏性技能的执行体。
//

import AppKit
import ApplicationServices
import SwiftUI

/// 2026-07-26 技能精简：公文排版 / 润色·多版本挑选 / 润色·仿我的范例已删——个性化的加工需求由
/// 「任意提问」对选区直接下指令兜底；「结构化·加标签」并入「提示词优化」（优化+加标签一次做完）。
enum OwlSelectionMenuAction: String, Codable, CaseIterable, Sendable {
  case ask
  case jevReply
  case polish
  case sourceVerification
  case researchAssist
  case translate
  case promptOptimize
  case goalBrief
  case publishFormatting

  var title: String {
    switch self {
    case .jevReply: return "Kotone 回复建议"
    case .ask: return "任意提问"
    case .polish: return "润色"
    case .sourceVerification: return "来源核验"
    case .researchAssist: return "辅助检索"
    case .translate: return "翻译"
    // 优化的是「提示词」本身而非普通文字，名字要和「润色」区分开。
    case .promptOptimize: return "提示词优化"
    // 按「目标七问」把模糊需求整理成 Agent 可独立执行的目标任务书。
    case .goalBrief: return "任务书"
    // 规范排版：只修中文排版（多余换行/引号/全半角/空格）、内容一字不改。
    case .publishFormatting: return "规范排版"
    }
  }

  var symbol: String {
    switch self {
    case .jevReply: return "bubble.left.and.bubble.right"
    case .ask: return "text.bubble"
    case .polish: return "wand.and.stars"
    case .sourceVerification: return "checkmark.seal"
    case .researchAssist: return "magnifyingglass"
    case .translate: return "globe"
    case .promptOptimize: return "sparkles"
    case .goalBrief: return "checklist"
    case .publishFormatting: return "text.justify"
    }
  }

  // menuGroups / menuHint（方案三「朱印」纵向菜单的分组与行尾提示）已随小菜单面板一并删除
  // （2026-07-26 工具箱重设计）：工具箱按钮行按 enabledActions() 顺序平铺。

  static func enabledActions(cloudEnabled: Bool = OwlCloudPreferences.isEnabled) -> [OwlSelectionMenuAction] {
    OwlAIBusinessCore.call("enabledActions", ["cloud": cloudEnabled, "enabled": [
      "jevReply": OwlSelectionMenuPreferences.jevReplyEnabled,
      "ask": OwlSelectionMenuPreferences.askEnabled, "polish": OwlSelectionMenuPreferences.polishEnabled,
      "sourceVerification": OwlSelectionMenuPreferences.sourceVerificationEnabled,
      "researchAssist": OwlSelectionMenuPreferences.researchAssistEnabled,
      "publishFormatting": OwlSelectionMenuPreferences.publishFormattingEnabled,
      "translate": OwlSelectionMenuPreferences.translationEnabled,
      "promptOptimize": OwlSelectionMenuPreferences.promptOptimizeEnabled,
      "goalBrief": OwlSelectionMenuPreferences.goalBriefEnabled]])
  }
}

struct OwlSelectionMenuSnapshot: Equatable {
  let text: String
  let bounds: NSRect?
  let replacementTarget: OwlSelectionReplacementTarget?
  /// 目标 App 的 bundleID（回填插入的 Vulcan 缓存键），`readCurrentSelection` 从前台 App 捕获。
  var bundleID: String?

  static func == (lhs: OwlSelectionMenuSnapshot, rhs: OwlSelectionMenuSnapshot) -> Bool {
    lhs.text == rhs.text && lhs.bounds == rhs.bounds
  }
}

enum OwlSelectionReplacementResult: Equatable {
  case success
  case failed(String)
}

struct OwlSelectionReplacementTarget {
  let replace: @MainActor (String) -> OwlSelectionReplacementResult
}

enum OwlSelectionReplacementFlow {
  /// 回填改写：AX 写回 → 模拟 ⌘V 粘贴 → 仅剪贴板（Vulcan 梯子，见 OwlTextInserter）。
  @MainActor
  static func write(
    _ replacement: String,
    target: OwlSelectionReplacementTarget?,
    bundleID: String? = nil
  ) -> OwlInsertOutcome {
    let failure: String = OwlAIBusinessCore.call("replacementAdmission", ["text": replacement, "hasTarget": target != nil])
    guard failure.isEmpty, let target else { return .failed(failure) }
    return OwlTextInserter.shared.insert(
      replacement,
      bundleID: bundleID,
      axSet: { if case .success = target.replace(replacement) { return true } else { return false } },
      paste: { OwlPasteInserter.paste($0) },
      copyOnly: { OwlPasteInserter.copyOnly($0) }
    )
  }
}

// OwlSelectionMenuPanel / OwlSelectionMenuView / OwlSelectionMenuItem（选区旁的非激活小菜单
// 浮窗）已删（2026-07-26 工具箱重设计）：技能入口改为 OwlAIWindow 工具箱的按钮行——标准窗口
// 语义（Esc 关、焦点可预测），不再需要「点外部消失 / 召唤键自消抑制」那套全局监视器状态机。

/// 双击 ⌥ 手势判定（2026-07-26 工具箱重设计）。纯状态机：事件与时间戳全由调用方注入，可单测。
///
/// 判定表：一「击」= ⌥ 单独按下（四大修饰键里只有 .option）→ 在 tapMaxHold 内完全松开；两击
/// 的间隔（第一击松开 → 第二击按下）≤ tapMaxGap 时，在第二击松开的瞬间触发。任何键盘/鼠标
/// 事件（经 invalidate()）、其他修饰键出现、或超时都会把状态清零——⌥+字母组合键、⌥+点击、
/// 长按 ⌥ 都绝不误触发。触发即回到 idle，第三击从头数。
struct OwlOptionDoubleTapDetector {
  /// 单击最长按住时长：超过就是「按住 ⌥ 用组合键/拖选」，不是轻击。
  static let tapMaxHold: TimeInterval = 0.5
  /// 两击最大间隔（第一击松开 → 第二击按下）。
  static let tapMaxGap: TimeInterval = 0.45

  private let core = try! OwlAppSession("selectionGesture")
  mutating func invalidate() { let _: Bool = core.call("invalidate") }
  mutating func processFlagsChanged(_ flags: NSEvent.ModifierFlags, at now: Date) -> Bool {
    let mods = flags.intersection([.shift, .control, .option, .command])
    return core.call("flags", ["modifiers": mods == .option ? "option" : (mods.isEmpty ? "empty" : "other"),
      "time": now.timeIntervalSince1970])
  }

}

final class OwlSelectionMenuCoordinator {
  /// 双击 ⌥ 监视器（工具箱重设计后仅存的常驻监听）。flagsChanged 喂判定器；keyDown / mouseDown
  /// 只做一件事——作废进行中的双击手势（⌥ 正被当真修饰键用）。回调是纯内存状态机，零 AX、零计时器。
  private var tapMonitor: Any?
  private var doubleTap = OwlOptionDoubleTapDetector()

  // 「选中即自动弹出」管线（0.30s 停留、每次划选后的后台 AX 读、面板维护计时器、dismissedText/
  // readGeneration/lastSummon 消失状态机）已删（2026-07-26 工具箱重设计）：打开工具箱只剩明确
  // 手势，AX 只在手势后读一次。2026-07-21 卡顿实锤的 150ms 轮询教训（别在打字期间碰 AX）依然
  // 成立——现在打字期间连事件解析都只剩双击判定的纯内存操作。

  func start() {
    guard tapMonitor == nil else { return }
    tapMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
    ) { [weak self] event in
      guard let self else { return }
      guard event.type == .flagsChanged else {
        self.doubleTap.invalidate()
        return
      }
      guard self.doubleTap.processFlagsChanged(event.modifierFlags, at: Date()) else { return }
      // 双击 ⌥ 成立。总开关只管这个手势（录制热键是平行开关，走 hotKeyTap，不经这里）。
      guard OwlSelectionMenuPreferences.isEnabled else {
        OwlHotKeyMatcher.log.notice("double-tap option dropped: toolbox disabled")
        return
      }
      self.summonForCurrentSelection()
    }
  }

  func stop() {
    if let tapMonitor {
      NSEvent.removeMonitor(tapMonitor)
      self.tapMonitor = nil
    }
  }

  /// 召唤入口（双击 ⌥ / 录制热键共用）：读一次当前选区，打开工具箱窗口。
  ///
  /// 平行开关语义延续（产品决策 2026-07-19，2026-07-26 重设计后仍然成立）：录制热键**不受**
  /// 总开关约束（按下热键本身就是明确意图）；总开关只管双击 ⌥ 手势（闸在监视器回调里）。
  /// 剩余闸门（授权 / 输入源 / 选区 / 技能）逐一落盘记 drop 原因——#118 的教训是静默闸门
  /// 让人以为热键坏了。
  func summonForCurrentSelection() {
    guard OwlInstaller.currentInputSourceID()?.hasPrefix(OwlInstaller.inputSourcePrefix) == true else {
      OwlHotKeyMatcher.log.notice("summon dropped: Owltype not current input source")
      return
    }
    guard AXIsProcessTrusted() else {
      OwlHotKeyMatcher.log.notice("summon dropped: accessibility not trusted")
      return
    }
    guard let snapshot = readCurrentSelection(), isAllowedSelection(snapshot.text) else {
      OwlHotKeyMatcher.log.notice("summon dropped: no usable selection")
      return
    }
    guard !OwlSelectionMenuAction.enabledActions().isEmpty else {
      OwlHotKeyMatcher.log.notice("summon dropped: no enabled skills")
      return
    }
    openToolbox(snapshot: snapshot)
  }

  /// 打开（或刷新）工具箱窗口：技能按钮行 + 任意提问输入框，选区随窗捕获。
  /// `question` 非空 = 带指令自动送出（翻译 / 辅助检索按钮走这条，窗口原地刷新、按钮行保留）。
  private func openToolbox(
    snapshot: OwlSelectionMenuSnapshot,
    question: String? = nil,
    display: String? = nil
  ) {
    let actions = OwlSelectionMenuAction.enabledActions()
    let toolbox = OwlAIToolboxContext(
      actions: actions.filter { $0 != .ask },
      askEnabled: actions.contains(.ask),
      onSkill: { [weak self] action in self?.toolboxPick(action, snapshot: snapshot) }
    )
    Task { @MainActor in
      OwlAIWindow.shared.show(
        selectedText: snapshot.text,
        initialQuestion: question ?? "",
        initialDisplayQuestion: display,
        autoSubmit: question != nil,
        toolbox: toolbox
      )
    }
  }

  /// 工具箱按钮行的分发。窗口内技能（翻译 / 辅助检索）原地刷新窗口并保留按钮行；出窗技能
  /// （核验回执卡、三个替换原文的技能）先关窗（把焦点还给宿主，替换流与小菜单时代同构）再执行。
  private func toolboxPick(_ action: OwlSelectionMenuAction, snapshot: OwlSelectionMenuSnapshot) {
    struct Route: Decodable { let effect: String; let prompt: String; let display: String }
    let route: Route = OwlAIBusinessCore.call("toolboxRoute", ["action": action.rawValue])
    switch route.effect {
    case "question":
      let question: String = OwlAIBusinessCore.call("prompt", ["id": route.prompt])
      openToolbox(snapshot: snapshot, question: question, display: route.display)
    case "verify":
      Task { @MainActor in
        OwlAIWindow.shared.close()
        OwlVerificationReceiptController.shared.show(selectedText: snapshot.text, anchorBounds: snapshot.bounds)
      }
    case "jevReply":
      Task { @MainActor in
        OwlAIWindow.shared.close()
        JEVReplyPanel.shared.show(text: snapshot.text, source: "owltype-selection")
      }
    case "rewrite":
      Task { @MainActor in
        OwlAIWindow.shared.close()
        await self.handleRewrite(action, snapshot: snapshot)
      }
    default: break
    }
  }

  /// 同步读当前前台 App 的选区（仅召唤用）。在主线程等待，但有 50ms AX 消息超时，最坏
  /// ~0.25s 的一次性等待，换召唤即时响应。
  func readCurrentSelection() -> OwlSelectionMenuSnapshot? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
    return readSelection(from: app)
  }

  /// 对 `app` 做一轮 AX 选区读取（4–5 次同步查询）。同步 AX 由目标 App 主线程应答，宿主忙时会
  /// 阻塞调用线程；50ms 消息超时保证单次查询有界。
  private func readSelection(from app: NSRunningApplication) -> OwlSelectionMenuSnapshot? {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(axApp, 0.05)
    var focusedRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
          let focused = focusedRef else {
      return nil
    }
    let element = focused as! AXUIElement
    AXUIElementSetMessagingTimeout(element, 0.05)
    let role = copyString(element, kAXRoleAttribute)
    let description = copyString(element, kAXDescriptionAttribute) ?? ""
    let capabilities = OwlClientCapabilityPolicy().evaluate(
      OwlClientCapabilityInput(
        host: OwlClientHostIdentity(
          bundleID: app.bundleIdentifier,
          appName: app.localizedName,
          fieldRole: role,
          fieldIdentifierSignal: description,
          // Electron 宿主的通用判定（详见 OwlElectronHostDetector）；这里已握有
          // NSRunningApplication，直接用它的 bundleURL，免去按 bundleID 反查。
          linksElectronFramework: OwlElectronHostDetector.shared.linksElectron(
            bundleURL: app.bundleURL, cacheKey: app.bundleIdentifier
          )
        ),
        privacy: .current(isPasswordLike: role?.localizedCaseInsensitiveContains("password") == true ||
                          description.localizedCaseInsensitiveContains("password"))
      )
    )
    guard capabilities.contextMenu.allowed else { return nil }

    var textRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &textRef) == .success,
          let text = textRef as? String else {
      return nil
    }
    let selectedRange = capabilities.selectedRange.allowed ? selectedRange(for: element) : nil
    return OwlSelectionMenuSnapshot(
      text: text,
      bounds: selectedBounds(for: element, selectedRange: selectedRange),
      replacementTarget: capabilities.replacementRange.allowed
        ? replacementTarget(for: element, selectedRange: selectedRange)
        : nil,
      bundleID: app.bundleIdentifier
    )
  }

  private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
      return nil
    }
    return ref as? String
  }

  private func selectedRange(for element: AXUIElement) -> CFTypeRef? {
    var rangeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
          let rangeValue = rangeRef else {
      return nil
    }
    return rangeValue
  }

  private func selectedBounds(for element: AXUIElement, selectedRange: CFTypeRef?) -> NSRect? {
    guard let rangeValue = selectedRange else { return nil }
    var boundsRef: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
      element,
      kAXBoundsForRangeParameterizedAttribute as CFString,
      rangeValue,
      &boundsRef
    ) == .success,
      let boundsRef else {
      return nil
    }
    let boundsValue = boundsRef as! AXValue
    var rect = CGRect.zero
    guard AXValueGetValue(boundsValue, .cgRect, &rect), !rect.isEmpty else { return nil }
    return appKitBounds(fromAccessibilityBounds: rect)
  }

  private func replacementTarget(for element: AXUIElement, selectedRange: CFTypeRef?) -> OwlSelectionReplacementTarget? {
    guard let selectedRange else { return nil }
    return OwlSelectionReplacementTarget { replacement in
      let rangeStatus = AXUIElementSetAttributeValue(
        element,
        kAXSelectedTextRangeAttribute as CFString,
        selectedRange
      )
      guard rangeStatus == .success else {
        return .failed("无法恢复原选区，请重新选择文字后再试。")
      }
      let textStatus = AXUIElementSetAttributeValue(
        element,
        kAXSelectedTextAttribute as CFString,
        replacement as CFString
      )
      guard textStatus == .success else {
        return .failed("无法写回选区；目标应用可能不支持辅助功能替换。")
      }
      return .success
    }
  }

  private func appKitBounds(fromAccessibilityBounds rect: CGRect) -> NSRect? {
    guard let screen = NSScreen.screens.first(where: { screen in
      guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
        return false
      }
      return CGDisplayBounds(displayID).intersects(rect)
    }) ?? NSScreen.main else {
      return nil
    }
    guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
      return nil
    }
    let displayBounds = CGDisplayBounds(displayID)
    return NSRect(
      x: rect.origin.x,
      y: screen.frame.maxY - (rect.origin.y - displayBounds.origin.y) - rect.height,
      width: rect.width,
      height: rect.height
    )
  }

  private func isAllowedSelection(_ text: String) -> Bool {
    let admission: OwlAIAdmission = OwlAIBusinessCore.call("admission", ["text": text, "trimCount": true])
    return admission.error.isEmpty
  }

  // 「润色」：选中文本送云端改写，预览确认后原地替换。选中文本离设备是用户显式
  // 触发的、对 CodeOnly 边界的既定例外（承接旧 requestSelectionPolish 的隐私注释）。原地
  // 替换不可用（部分 Chromium/Electron 选区只读不可写）时退回剪贴板，保住润色仍可用。
  @MainActor
  private func handleRewrite(_ action: OwlSelectionMenuAction, snapshot: OwlSelectionMenuSnapshot) async {
    await OwlSelectionRewrite(
      generate: OwlSelectionRewrite.generate,
      confirm: { self.confirmReplacement($0, resultNoun: $1) },
      deliver: { OwlSelectionReplacementFlow.write(
        $0, target: snapshot.replacementTarget, bundleID: snapshot.bundleID) },
      clarify: { OwlAIWindow.shared.show(selectedText: $0, composerTask: $1) },
      notify: { OwlApplicationDelegate.showMessage(msgText: $0) }
    ).run(action, text: snapshot.text)
  }

  @MainActor
  private func confirmReplacement(_ replacement: String, resultNoun: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = "替换选中文本？"
    alert.informativeText = "将把原选区替换为下方\(resultNoun)结果。"
    alert.addButton(withTitle: "替换")
    alert.addButton(withTitle: "取消")

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    let textView = NSTextView(frame: scrollView.bounds)
    textView.isEditable = false
    textView.isSelectable = true
    textView.font = NSFont.systemFont(ofSize: 13)
    textView.string = replacement
    textView.textContainerInset = NSSize(width: 8, height: 8)
    scrollView.documentView = textView
    alert.accessoryView = scrollView

    return alert.runModal() == .alertFirstButtonReturn
  }
}

enum OwlSelectionSkillPrompts {
  static let sourceVerificationQuestion: String = OwlAIBusinessCore.call("prompt", ["id": "sourceVerificationQuestion"])

  static let researchAssistQuestion: String = OwlAIBusinessCore.call("prompt", ["id": "researchAssistQuestion"])

  /// 规范排版的「段落重排」系统提示。AI 只做一件事——把被硬换行拆断的行拼回完整段落；引号 / 全半角 /
  /// 空格等规范化全交给确定性规则（OwlChineseTypesetting.finalize），故这里严令「一字不改、连标点都别动」。
  /// 内容不变式由指纹护栏兜底（见 OwlSelectionPublishFormatter）。
  static let publishReflowSystemPrompt: String = OwlAIBusinessCore.call("prompt", ["id": "publishReflowSystemPrompt"])

  // 划词翻译：改造自 GitHub andrewyng/translation-agent（反思式翻译 translate→reflect→improve），
  // 折叠为单次调用、只输出意译；反思四维（准确/流畅/风格文化/术语惯用）照搬其原文。目标语言自动中↔英。
  static let translationQuestion: String = OwlAIBusinessCore.call("prompt", ["id": "translationQuestion"])

  /// 提示词优化的澄清脚手架（issue #138）。作为任务卡的隐藏 scaffold（问题另在卡上逐条显示；
  /// 这里仍串进 scaffold，让模型能把用户补答对回问题）；脚手架自带优化指令，让用户补答后经
  /// 通用对话也能产出「四要素 + XML 标签分区」的提示词（真多轮循环待 #137）。
  static func promptOptimizeClarificationScaffold(_ questions: [String]) -> String {
    OwlAIBusinessCore.call("clarificationScaffold", ["questions": questions, "goal": false])
  }

  /// 任务书的澄清脚手架，与提示词优化同一套 v1 承载（任务卡 + 隐藏 scaffold）：补答后经
  /// 通用对话也能产出按目标七问分节的任务书。
  static func goalBriefClarificationScaffold(_ questions: [String]) -> String {
    OwlAIBusinessCore.call("clarificationScaffold", ["questions": questions, "goal": true])
  }

  static let missingSourceSearchKeyMessage: String = OwlAIBusinessCore.call("prompt", ["id": "missingSourceSearchKeyMessage"])
}

// MARK: - 规范排版（中文出版规范化）

/// 中文规范排版的确定性规则集（大陆出版通行）。全是纯函数：不碰偏好域、不联网，可离线单测。
/// 规则只动「空白 + 标点形态」，永不增删或改写文字（字母 / 数字 / 汉字假名）——排版工具擅改文字最危险，
/// `contentFingerprint` 把这条不变式变成可机械断言的护栏（见 OwlSelectionPublishFormatter）。
enum OwlChineseTypesetting {
  static func preClean(_ text: String) -> String { OwlAIBusinessCore.call("preClean", ["text": text]) }
  static func finalize(_ text: String) -> String { OwlAIBusinessCore.call("typeset", ["text": text]) }
  static func contentFingerprint(_ text: String) -> String { OwlAIBusinessCore.call("fingerprint", ["text": text]) }
  static func normalizeEllipsisAndDash(_ text: String) -> String { OwlAIBusinessCore.call("ellipsis", ["text": text]) }
  static func normalizeQuotes(_ text: String) -> String { OwlAIBusinessCore.call("quotes", ["text": text]) }
  static func normalizePunctuationWidth(_ text: String) -> String { OwlAIBusinessCore.call("punctuationWidth", ["text": text]) }
  static func normalizeSpaces(_ text: String) -> String { OwlAIBusinessCore.call("spaces", ["text": text]) }
}

enum OwlSelectionPublishFormattingError: Error {
  case providerUnavailable
  case emptyResult
}

/// 规范排版技能的执行体：规则优先 + AI 只重排段落。
/// preClean(规则) → reflow(AI，全文直投) → finalize(规则，权威最后一道)。段落重排若被 AI 擅改文字
/// （contentFingerprint 不符），整段丢弃、回退纯规则输出——排版绝不改字；这同时兜住选区里夹带的
/// prompt injection（模型若照做而改内容，指纹护栏即拦下）。
@MainActor
struct OwlSelectionPublishFormatter {
  private let streamer: OwlPlainStreaming

  init(streamer: OwlPlainStreaming? = nil) {
    self.streamer = streamer ?? OwlStreamingChatService.shared
  }

  func generateReplacement(for selectedText: String) async throws -> String {
    struct Result: Decodable { let text: String; let empty: Bool }
    let cleaned = OwlChineseTypesetting.preClean(selectedText)
    let reflowed = try await reflow(cleaned)
    let result: Result = OwlAIBusinessCore.call("formatResult", ["original": cleaned, "reflow": reflowed])
    guard !result.empty else { throw OwlSelectionPublishFormattingError.emptyResult }
    return result.text
  }

  /// 全文直投 AI 做段落重排。刻意不走 OwlAIContextAssembler：它把选区当输入法上下文、截断到 400 字，
  /// 长段 PDF 文本会被切掉。这里把整段放进 user 消息、不截断。
  private func reflow(_ text: String) async throws -> String {
    let messages = [
      OwlDeepSeekMessage(role: "system", content: OwlSelectionSkillPrompts.publishReflowSystemPrompt),
      OwlDeepSeekMessage(role: "user", content: text),
    ]
    switch streamer.stream(messages: messages) {
    case .failure:
      throw OwlSelectionPublishFormattingError.providerUnavailable
    case .success(let stream):
      var out = ""
      for try await chunk in stream { out += chunk }
      return out
    }
  }

  static func message(for error: Error) -> String {
    if let e = error as? OwlSelectionPublishFormattingError {
      switch e {
      case .providerUnavailable: return "尚未配置可用 AI 供应商或 API Key。"
      case .emptyResult: return "未生成可替换文本。"
      }
    }
    return OwlCloudPreferences.message(for: error)
  }
}
