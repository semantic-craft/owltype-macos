//
//  OwlTextInserter.swift
//  猫头鹰输入法 (Owltype) — 技能输出回填插入（Vulcan 多策略兜底）
//
//  技能输出（划词润色/公文排版改写）回填目标 App 时，AX 写回失败（微信/部分 Chromium 选区只读）就自动兜底：
//    梯子：AX 写回 → 模拟 ⌘V 粘贴 → 仅剪贴板。按 App(bundleID) 记忆上次成功策略（Vulcan 缓存）。
//
//  不采用「CGEvent 逐字」策略：键码逐字打不出中文（你/好无键码）；unicode-string 版会被
//  Owltype 自身 IMKInputController 二次合成（IME 再入）。模拟 ⌘V 粘贴已覆盖「AX 进不去」的通用兜底，且中文完美。
//

import AppKit
import ApplicationServices

enum OwlInsertStrategy: String, Equatable, Sendable {
  case axSelectedText   // AX 写回选区（首选，无副作用）
  case paste            // 剪贴板 + 模拟 ⌘V（通用，微信可用，中文完美）
  case clipboardOnly    // 仅写剪贴板（终态兜底，用户手动粘）
}

enum OwlInsertOutcome: Equatable, Sendable {
  case inserted(OwlInsertStrategy)   // 自动落入目标（AX 或 ⌘V）
  case copiedToClipboard              // 终态兜底：文本在剪贴板，提示用户手动粘
  case failed(String)                 // 守卫失败（空文本/无选区）
}

/// 策略排序（纯函数）：默认序，cached 提到最前，优先复用上次成功的回填方式。
enum OwlInsertLadder {
  static let order: [OwlInsertStrategy] = [.axSelectedText, .paste, .clipboardOnly]

  static func sequence(cached: OwlInsertStrategy?) -> [OwlInsertStrategy] {
    guard let cached, order.contains(cached) else { return order }
    return [cached] + order.filter { $0 != cached }
  }
}

/// 编排 + 按 App 缓存成功策略。原语（axSet/paste/copyOnly）注入 → 编排与缓存可单测（无 AX/CGEvent）。
@MainActor
final class OwlTextInserter {
  static let shared = OwlTextInserter()

  /// bundleID → 上次成功策略。内存态（跨会话不持久，够用）。
  private var cache: [String: OwlInsertStrategy] = [:]

  /// 按梯子逐策略试，首个成功即缓存并返回。`axSet`/`paste` 返回是否成功；`clipboardOnly` 是终态。
  func insert(
    _ text: String,
    bundleID: String?,
    axSet: () -> Bool,
    paste: (String) -> Bool,
    copyOnly: (String) -> Void
  ) -> OwlInsertOutcome {
    let key = bundleID ?? ""
    for strategy in OwlInsertLadder.sequence(cached: cache[key]) {
      switch strategy {
      case .axSelectedText:
        if axSet() { cache[key] = .axSelectedText; return .inserted(.axSelectedText) }
      case .paste:
        if paste(text) { cache[key] = .paste; return .inserted(.paste) }
      case .clipboardOnly:
        copyOnly(text); cache[key] = .clipboardOnly; return .copiedToClipboard
      }
    }
    return .failed("插入失败。")
  }
}

/// 剪贴板 + CGEvent 粘贴 glue。
enum OwlPasteInserter {
  /// 存当前剪贴板 → 写 text → 模拟 ⌘V → 0.5s 后恢复剪贴板。返回是否成功 post 事件。
  /// ponytail: CGEvent 无法验证 ⌘V 是否真落地——post 成功即视作 paste 成功，这是已知天花板。
  @MainActor
  static func paste(_ text: String) -> Bool {
    let pasteboard = NSPasteboard.general
    let saved = pasteboard.string(forType: .string)
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    guard postCommandV() else { return false }   // 没 post 出去 → 保留 text 在剪贴板，让上层降级
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      guard let saved else { return }
      pasteboard.clearContents()
      pasteboard.setString(saved, forType: .string)
    }
    return true
  }

  /// 终态兜底：只写剪贴板、不恢复（保证用户手上一定有这段文本可粘）。
  @MainActor
  static func copyOnly(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  private static func postCommandV() -> Bool {
    guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
    let vKey = CGKeyCode(9)   // kVK_ANSI_V
    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
      return false
    }
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    return true
  }
}
