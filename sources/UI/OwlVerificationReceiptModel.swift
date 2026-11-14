//
//  OwlVerificationReceiptModel.swift
//  法墨输入法 (Owltype) — 核验回执卡状态模型 (issue #135, 方案三「朱印」)
//
//  回执卡的全部可测逻辑：锚点准入（案号闸）、单锚点核验状态机（待核→核验中→绿/橙/红）、
//  批量动作、跳库路由打开 + 剪贴板纪律 + 逐字 toast、键盘焦点、回执文本拼装。
//  渲染归 OwlVerificationReceiptCard.swift；本文件不建窗口。
//
//  铁律（对齐 Responsay，见 docs/owl-responsay-alignment-spec.md）：
//    · 搜不到 ≠ 不存在 —— 联网核验搜不到只标橙/红，永不自动判驳；
//    · 跳库一律 NSWorkspace.open 用户默认浏览器，先 open 后复制；
//    · 只有打开的 URL 无 query 参数时才写剪贴板（OwlSelectionVerifyClipboard）。
//

import AppKit
import SwiftUI

/// 单锚点核验进度（回执卡行状态）。
enum OwlAnchorVerifyState: Equatable {
  case idle                                // [待核]
  case loading                             // 正在联网核验…
  case success(OwlVerifiedAnchorSource)   // 绿卡：已找到可核来源（等用户确认[已核]）
  case confirmed(OwlVerifiedAnchorSource) // [已核]（用户确认）
  case notFound                            // 法条→红「疑似杜撰 · 待核」；案例/文献→橙「未能通过联网核实」
  case error(String)                       // 联网核验暂不可用

  var isPending: Bool {
    let kind: String
    switch self {
    case .idle: kind = "idle"
    case .loading: kind = "loading"
    case .success: kind = "success"
    case .confirmed: kind = "confirmed"
    case .notFound: kind = "notFound"
    case .error: kind = "error"
    }
    return OwlAIBusinessCore.call("receiptPending", ["kind": kind])
  }

  var isVerified: Bool {
    switch self {
    case .success, .confirmed: return true
    default: return false
    }
  }
}

@MainActor
final class OwlVerificationReceiptModel: ObservableObject {
  private let core: OwlAITextSession
  private var projection: Projection
  let selectedText: String
  let anchors: [OwlVerificationAnchor]
  /// 是否配好了豆包搜索（来源核验的检索层）；false 时只留跳库深链路（对齐 Responsay LegalBrain off）。
  let onlineVerifyAvailable: Bool

  @Published private(set) var states: [String: OwlAnchorVerifyState] = [:]
  /// 折叠详情展开态：绿卡默认展开、橙/红卡默认收起（对齐原型）。
  @Published var expanded: [String: Bool] = [:]
  @Published var focusedIndex: Int = 0
  @Published var copiedAnchorID: String?
  @Published var toastText: String?
  @Published private(set) var completedAt: Date?

  var onClose: (() -> Void)?

  private var tasks: [String: Task<Void, Never>] = [:]
  private let verifier: (String) async throws -> OwlSourceVerificationOutcome
  private let openURL: (URL) -> Void
  private let writePasteboard: (String) -> Void
  private let now: () -> Date

  init(
    selectedText: String,
    anchors: [OwlVerificationAnchor],
    onlineVerifyAvailable: Bool,
    verifier: @escaping (String) async throws -> OwlSourceVerificationOutcome,
    openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
    writePasteboard: @escaping (String) -> Void = {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString($0, forType: .string)
    },
    now: @escaping () -> Date = Date.init
  ) {
    core = try! OwlAITextSession("verificationReceipt", args: ["anchors": OwlAIBusinessCore.json(anchors),
      "text": selectedText, "available": onlineVerifyAvailable])
    projection = core.call("snapshot")
    self.selectedText = selectedText
    self.anchors = anchors
    self.onlineVerifyAvailable = onlineVerifyAvailable
    self.verifier = verifier
    self.openURL = openURL
    self.writePasteboard = writePasteboard
    self.now = now
  }

  // MARK: - 锚点准入（案号闸）

  static func admittedAnchors(from text: String, currentYear: Int) -> [OwlVerificationAnchor] {
    OwlAIBusinessCore.call("admittedAnchors", ["text": text, "currentYear": currentYear])
  }

  // MARK: - 状态读数

  func state(for anchor: OwlVerificationAnchor) -> OwlAnchorVerifyState {
    states[anchor.id] ?? .idle
  }

  var isBusy: Bool { projection.busy }
  var hasOutcome: Bool { projection.hasOutcome }
  var verifiedCount: Int { projection.verifiedCount }
  var suspectedCount: Int { projection.suspectedCount }
  var pendingCount: Int { projection.pendingCount }

  /// 回执标题区副标题（对齐原型三态文案）。
  var subtitle: String {
    if isBusy { return "正在联网核验…" }
    if hasOutcome {
      return "核验完成 · \(Self.timestamp(completedAt ?? now())) · 已核 \(verifiedCount) / 待核 \(pendingCount)"
    }
    return "已抽取 \(anchors.count) 个待核锚点 · 右键更多源"
  }

  var sealHint: String {
    hasOutcome && !isBusy ? "点击印章复制核验回执" : "核验完成后印章生效"
  }

  // MARK: - 联网核验（复用 OwlSourceVerificationService，结果进卡不进 AI 窗口）

  func verify(_ anchor: OwlVerificationAnchor) {
    transition("begin", ["id": anchor.id])
    guard projection.accepted else { return }
    let generation = projection.generation
    tasks[anchor.id]?.cancel()
    tasks[anchor.id] = Task { [weak self] in
      guard let self else { return }
      let result: Result<OwlSourceVerificationOutcome, Error>
      do { result = .success(try await self.verifier(anchor.query)) }
      catch { result = .failure(error) }
      guard !Task.isCancelled else { return }
      var args = Self.resultFacts(result, at: self.now())
      args["id"] = anchor.id
      args["generation"] = generation
      self.transition("complete", args)
      guard self.projection.accepted else { return }
      let state = self.state(for: anchor)
      if case .success = state { self.expanded[anchor.id] = true }
      else if state == .notFound { self.expanded[anchor.id] = false }
      self.tasks[anchor.id] = nil
    }
  }

  func verifyAll() {
    let ids: [String] = core.call("eligible")
    for id in ids { if let anchor = anchors.first(where: { $0.id == id }) { verify(anchor) } }
  }

  func cancel(_ anchor: OwlVerificationAnchor) {
    tasks[anchor.id]?.cancel()
    tasks[anchor.id] = nil
    transition("cancel", ["id": anchor.id])
  }

  func cancelAll() {
    for anchor in anchors { cancel(anchor) }
  }

  func confirm(_ anchor: OwlVerificationAnchor) {
    transition("confirm", ["id": anchor.id])
  }

  /// 「不对，手动查」：回到待核 + 复制检索词 + 打开该 kind 的默认库（对齐 Responsay dismissAndFallback）。
  func manualFallback(_ anchor: OwlVerificationAnchor) {
    tasks[anchor.id]?.cancel()
    tasks[anchor.id] = nil
    transition("fallback", ["id": anchor.id])
    copyQuery(anchor)
    open(OwlVerificationQueryRouter.route(
      query: anchor.query,
      source: OwlVerificationQueryRouter.defaultSource(for: anchor.kind)))
  }

  // MARK: - 跳库（先 open 后复制；剪贴板纪律 + 逐字 toast）

  func jumpGroups(for anchor: OwlVerificationAnchor?) -> [OwlVerifyMenuGroup] {
    OwlSelectionVerifyMenu.build(
      selectedText: selectedText,
      anchors: anchor.map { [$0] } ?? anchors)
  }

  /// 手动查验源 chips（橙/红卡 + 绿卡跳库复核）：与锚点 kind 相关的组 + 兜底必应。
  func manualChipItems(for anchor: OwlVerificationAnchor) -> [OwlVerifyMenuItem] {
    let groups = jumpGroups(for: anchor)
    let related = groups.first { group in
      group.items.contains { $0.route.query == anchor.query }
    } ?? groups.first
    var items = related?.items ?? []
    if let fallback = groups.last(where: { $0.title == "兜底" })?.items.first {
      items.append(fallback)
    }
    return items
  }

  func open(_ route: OwlVerificationRoute) {
    switch route.kind {
    case .deepLink:
      guard let url = route.url else { return }
      openURL(url)  // 先开
      if let paste = OwlSelectionVerifyClipboard.pasteQuery(openedRoutes: [route]) {
        writePasteboard(paste)  // 后复制
        showToast(route.source == .cnki
          ? "知网检索式已复制，切到「专业检索」粘贴即可"
          : "检索式已复制，粘贴到该站检索框即可")
      }
    case .copyOnly:
      writePasteboard(route.query)
      showToast("检索式已复制，粘贴到该站检索框即可")
    case .modelSearch:
      break  // 模型内搜索不开 URL；卡内联网核验即该路径
    }
  }

  func copyQuery(_ anchor: OwlVerificationAnchor) {
    writePasteboard(anchor.query)
    copiedAnchorID = anchor.id
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      await MainActor.run {
        guard let self, self.copiedAnchorID == anchor.id else { return }
        self.copiedAnchorID = nil
      }
    }
  }

  /// 「一键打开核验（百度学术 + 北大法宝）」：逐锚点 ①复制检索词 ②开百度学术 ③开法宝 site:（spec §1.7）。
  func openAllForManualVerify() {
    for anchor in anchors {
      copyQuery(anchor)
      open(OwlVerificationQueryRouter.route(query: anchor.query, source: .baiduScholar))
      open(OwlVerificationQueryRouter.route(query: anchor.query, source: .pkulaw))
    }
  }

  // MARK: - 键盘（↑↓ 选锚点 / ⏎ 核验 / ⌘C 复制回执 / esc 关闭）

  func moveFocus(_ delta: Int) {
    guard !anchors.isEmpty else { return }
    focusedIndex = min(max(focusedIndex + delta, 0), anchors.count - 1)
  }

  func verifyFocused() {
    guard anchors.indices.contains(focusedIndex) else { return }
    verify(anchors[focusedIndex])
  }

  func requestClose() {
    cancelAll()
    onClose?()
  }

  // MARK: - 回执文本（⌘C / 点击印章 / 复制核验摘要）

  func copyReceipt() {
    writePasteboard(receiptText())
    showToast("已复制核验回执")
  }

  func receiptText() -> String {
    core.call("receipt", ["timestamp": Self.timestamp(completedAt ?? now())])
  }

  private struct Row: Decodable {
    let kind: String
    let source: OwlVerifiedAnchorSource?
    let message: String?
    var native: OwlAnchorVerifyState {
      switch kind {
      case "loading": return .loading
      case "success": return .success(source!)
      case "confirmed": return .confirmed(source!)
      case "notFound": return .notFound
      case "error": return .error(message ?? "")
      default: return .idle
      }
    }
  }
  private struct Projection: Decodable {
    let accepted: Bool
    let generation: UInt64
    let states: [String: Row]
    let busy: Bool
    let hasOutcome: Bool
    let verifiedCount: Int
    let pendingCount: Int
    let suspectedCount: Int
    let completedAt: Double?
  }
  private func transition(_ event: String, _ args: [String: Any]) {
    projection = core.call(event, args)
    states = projection.states.mapValues(\.native)
    completedAt = projection.completedAt.map(Date.init(timeIntervalSince1970:))
  }
  nonisolated private static func resultFacts(_ result: Result<OwlSourceVerificationOutcome, Error>, at date: Date) -> [String: Any] {
    var facts: [String: Any] = ["timestamp": timestamp(date), "time": date.timeIntervalSince1970]
    switch result {
    case let .success(outcome):
      facts["sources"] = OwlAIBusinessCore.json(outcome.sources)
      facts["content"] = outcome.content
    case let .failure(error):
      if case OwlSourceVerificationError.emptyResponse = error { facts["error"] = "empty" }
      else { facts["error"] = "failure"; facts["message"] = OwlSourceVerificationService.message(for: error) }
    }
    return facts
  }

  // MARK: - Toast

  private var toastGeneration = 0

  func showToast(_ text: String) {
    toastGeneration += 1
    let generation = toastGeneration
    toastText = text
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 2_500_000_000)
      await MainActor.run {
        guard let self, self.toastGeneration == generation else { return }
        self.toastText = nil
      }
    }
  }

  nonisolated static func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
  }
}

/// 分组源菜单的原生 NSMenu 渲染（1:1 对齐 Responsay SelectionVerifyMenuController）：
/// 组题 disabled header，条目前缀两空格；popUp 模态跟踪、点选同步回调。
@MainActor
final class OwlVerifyJumpMenuController: NSObject {
  private var onPick: ((OwlVerifyMenuItem) -> Void)?

  func present(groups: [OwlVerifyMenuGroup], at screenPoint: CGPoint,
               onPick: @escaping (OwlVerifyMenuItem) -> Void) {
    guard !groups.isEmpty else { return }
    self.onPick = onPick

    let menu = NSMenu()
    menu.autoenablesItems = false
    for (index, group) in groups.enumerated() {
      if index > 0 { menu.addItem(.separator()) }
      let header = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
      header.isEnabled = false
      menu.addItem(header)
      for item in group.items {
        let entry = NSMenuItem(title: "  \(item.title)", action: #selector(didPick(_:)), keyEquivalent: "")
        entry.target = self
        entry.representedObject = OwlVerifyJumpMenuBox(item: item)
        menu.addItem(entry)
      }
    }
    menu.popUp(positioning: nil, at: screenPoint, in: nil)
  }

  @objc private func didPick(_ sender: NSMenuItem) {
    guard let box = sender.representedObject as? OwlVerifyJumpMenuBox else { return }
    onPick?(box.item)
  }
}

/// `representedObject` 需要 AnyObject；OwlVerifyMenuItem 是值类型，装箱携带。
private final class OwlVerifyJumpMenuBox: NSObject {
  let item: OwlVerifyMenuItem
  init(item: OwlVerifyMenuItem) { self.item = item }
}
