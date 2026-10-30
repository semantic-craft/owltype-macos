import Foundation

/// Built only after a successful library/configuration change. No storage or context capture.
struct OwlAutomaticExpansionIndex {
  enum ValidationError: Error, Equatable, LocalizedError {
    case invalidTrigger, duplicateTrigger, immediatePrefixConflict
    case invalidTemplate(String)

    var errorDescription: String? {
      switch self {
      case .invalidTrigger: return "自动触发词须为双分号后接字母、数字、下划线或连字符。"
      case .duplicateTrigger: return "生效的自动触发词重复，请修改后保存。"
      case .immediatePrefixConflict: return "立即展开词不能是另一自动触发词的前缀。"
      case .invalidTemplate(let message): return message
      }
    }
  }

  private struct Node: Decodable {
    var children: [UInt8: Int] = [:]
    var entry: OwlTemplateEntry?
    init() {}
    enum CodingKeys: String, CodingKey { case children, entry }
    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      let raw = try values.decode([String: Int].self, forKey: .children)
      children = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in UInt8(key).map { ($0, value) } })
      entry = try values.decodeIfPresent(OwlTemplateEntry.self, forKey: .entry)
    }
  }
  private var nodes: [Node] = [Node()]
  var isEmpty: Bool { nodes.count == 1 }
  static let empty = OwlAutomaticExpansionIndex()
  private init() {}
  init(entries: [OwlTemplateEntry]) throws {
    nodes = try OwlStorageHost(dataDir: URL(fileURLWithPath: "/")).call("automatic_index", ["entries": OwlAppCore.payload(entries)])
  }

  static func validTrigger(_ text: String) -> Bool {
    OwlTemplateStore.core("automatic_valid", ["text": text])
  }

  static func isSuffixByte(_ byte: UInt8) -> Bool {
    (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95 || byte == 45
  }

  func next(after node: Int, byte: UInt8) -> Int? { nodes[node].children[byte] }
  func entry(at node: Int) -> OwlTemplateEntry? { nodes[node].entry }
}

/// Only the reserved prefix buffer belongs here; Rime continues to own Chinese conversion.
final class OwlAutomaticExpansionRecognizer {
  enum Input: Equatable { case text(String), backspace, escape, interrupt }
  enum Step: Equatable {
    case passThrough
    case mark(String)
    case clear
    case restore(String, replaySemicolon: Bool, consumeKey: Bool)
    case invoke(OwlTemplateEntry, trigger: String, delimiter: String? = nil)

    /// Kept separately from the entry body so preview, delivery and explicit copy share it.
    /// The original delimiter remains on the step even in drop mode for future cancellation.
    var trailingText: String {
      guard case .invoke(let entry, _, let delimiter) = self,
            entry.expansionMode == .delimiterKeep else { return "" }
      return delimiter ?? ""
    }
  }

  private(set) var buffer = ""
  private var path = [0]
  var isRecognizing: Bool { !buffer.isEmpty }

  /// Taking the pending text consumes it before any client callback can re-enter finalization.
  func takePending() -> String? {
    guard !buffer.isEmpty else { return nil }
    let text = buffer
    buffer = ""
    path = [0]
    return text
  }

  func consume(_ input: Input, index: OwlAutomaticExpansionIndex, canStart: Bool = false) -> Step {
    if !isRecognizing {
      guard canStart, !index.isEmpty, case .text(";") = input,
            let node = index.next(after: 0, byte: 59) else { return .passThrough }
      buffer = ";"
      path.append(node)
      return .mark(buffer)
    }
    switch input {
    case .backspace:
      buffer.removeLast()
      path.removeLast()
      return buffer.isEmpty ? .clear : .mark(buffer)
    case .escape:
      return restore(consumeKey: true)
    case .interrupt:
      return restore(consumeKey: false)
    case .text(let text):
      if Self.isDelimiter(text) {
        guard let entry = index.entry(at: path.last ?? 0), entry.expansionMode != .immediate else {
          return restore(consumeKey: false)
        }
        let trigger = takePending() ?? ""
        return .invoke(entry, trigger: trigger, delimiter: text)
      }
      let bytes = Array(text.utf8)
      guard bytes.count == 1 else { return restore(consumeKey: false) }
      let byte = bytes[0]
      if buffer == ";", byte != 59 { return restore(consumeKey: false) }
      guard buffer == ";" || OwlAutomaticExpansionIndex.isSuffixByte(byte) else {
        return restore(consumeKey: false)
      }
      guard let next = index.next(after: path.last ?? 0, byte: byte) else {
        let literal = buffer + text
        _ = takePending()
        return .restore(literal, replaySemicolon: false, consumeKey: true)
      }
      buffer += text
      path.append(next)
      if let entry = index.entry(at: next), entry.expansionMode == .immediate {
        let trigger = takePending() ?? ""
        return .invoke(entry, trigger: trigger)
      }
      return .mark(buffer)
    }
  }

  private static func isDelimiter(_ text: String) -> Bool {
    // Exact product set; other Unicode whitespace and multi-character input are not confirmations.
    switch text {
    case " ", "\t", "\n", ",", ".", "?", "!", ":", "，", "。", "？", "！", "：": return true
    default: return false
    }
  }

  private func restore(consumeKey: Bool) -> Step {
    let text = takePending() ?? ""
    return .restore(text, replaySemicolon: text == ";", consumeKey: consumeKey)
  }
}

/// Immutable handoff from the recognizer to the shared invocation/host delivery. This carries
/// original input, not rendered template text; parsing, context capture and replacement stay there.
struct OwlAutomaticExpansionInvocationSource {
  let entry: OwlTemplateEntry
  let originalInput: String
  let markedText: String
  let markedRange: NSRange
  let trailingText: String

  init?(step: OwlAutomaticExpansionRecognizer.Step, start: Int, markedText: String) {
    guard case .invoke(let entry, let trigger, let delimiter) = step,
          !entry.isPendingReview, entry.invocationMode == .automatic,
          entry.trigger == trigger, OwlAutomaticExpansionIndex.validTrigger(trigger) else { return nil }
    // The terminal immediate character has not been marked. Delimiter mode has marked the
    // full trigger, but the consumed delimiter has not reached the host as text or a key action.
    let expectedMarked = entry.expansionMode == .immediate ? String(trigger.dropLast()) : trigger
    guard markedText == expectedMarked,
          (entry.expansionMode == .immediate) == (delimiter == nil) else { return nil }
    let range = NSRange(location: start, length: markedText.utf16.count)
    guard OwlAutomaticExpansionScope.valid(range) else { return nil }
    self.entry = entry
    originalInput = trigger + (delimiter ?? "")
    self.markedText = markedText
    markedRange = range
    trailingText = step.trailingText
  }
}

/// Once an invocation observes a changed session/mode/configuration it cannot revive when those
/// values later change back. The host delivery separately owns field/focus invalidation.
final class OwlAutomaticExpansionInvocationValidity {
  private let isCurrent: () -> Bool
  private var valid = true

  init(isCurrent: @escaping () -> Bool) { self.isCurrent = isCurrent }

  func isValid() -> Bool {
    guard valid else { return false }
    valid = isCurrent()
    return valid
  }
}

/// Readback checks are values so tests can exercise invalid/stale ranges without a real IMK host.
enum OwlAutomaticExpansionScope {
  static func canStart(selection: NSRange, marked: NSRange, preceding: String?) -> Bool {
    guard valid(selection), selection.length == 0,
          marked.location == NSNotFound || marked.length == 0 else { return false }
    if selection.location == 0 { return true }
    guard let preceding, preceding.utf16.count == 1, let char = preceding.first else { return false }
    return char.isWhitespace || ",.?!:，。？！：".contains(char)
  }

  static func owns(start: Int, text: String, marked: NSRange, selection: NSRange, substring: String?) -> Bool {
    let expected = NSRange(location: start, length: text.utf16.count)
    guard valid(expected), valid(marked), valid(selection), marked == expected,
          selection.length == 0, selection.location == start + expected.length else { return false }
    return substring == text
  }

  static func valid(_ range: NSRange) -> Bool {
    range.location >= 0 && range.location != NSNotFound && range.length >= 0
      && range.length != NSNotFound && range.location <= Int.max - range.length
  }
}

/// Production controller entry seam. Tests drive the same Rime reads and host-opening branch
/// that handleAutomaticExpansion uses, without constructing an IMK server in the test process.
enum OwlAutomaticExpansionControllerEntry {
  static func start(input: OwlAutomaticExpansionRecognizer.Input, bundleID: @autoclosure () -> String?,
                    runtime: OwlAutomaticExpansionRuntime, engineSession: EngineSession?, openHost: () -> Bool) -> Bool {
    guard case .text(";") = input, runtime.enabled, !runtime.index.isEmpty,
          runtime.allows(bundleID: bundleID()),
          let engineSession, engineSession.isValid, let raw = engineSession.input(), raw.isEmpty,
          let context = engineSession.composition(), context.preedit.isEmpty,
          context.candidates.isEmpty, (context.commitTextPreview ?? "").isEmpty else { return false }
    return openHost()
  }

  /// The first semicolon belongs to the OLD punctuation mode, before Shift changes ascii_mode.
  static func processModifiers(pending: String, finishSemicolon: () -> Void, process: () -> Void) {
    if pending == ";" { finishSemicolon() }
    process()
  }

  static func replaySemicolon(keycode: UInt32, modifiers: UInt32, process: (UInt32, UInt32) -> Bool,
                              update: () -> Void, isCurrent: () -> Bool, insertLiteral: () -> Void) {
    guard isCurrent() else { return }
    let handled = process(keycode, modifiers)
    update()
    if !handled && isCurrent() { insertLiteral() }
  }
}

/// Bounded, ephemeral readback around our marked write. No host text is persisted or logged.
struct OwlAutomaticExpansionObservation: Equatable {
  let selection: NSRange
  let marked: NSRange
  let documentLength: Int
  let nearbyText: String?

  var isReadable: Bool {
    OwlAutomaticExpansionScope.valid(selection) && documentLength >= 0 && documentLength != NSNotFound && nearbyText != nil
  }
}

enum OwlAutomaticExpansionMarkDelivery {
  enum Outcome: Equatable { case accepted, rejectedWithoutChange, sessionEnded, uncertain }

  /// A synchronously ended composition is never replayed. Only a readable, unchanged host
  /// permits returning the original key to Rime after a rejected setMarkedText call.
  static func perform(before: OwlAutomaticExpansionObservation?, write: () -> Void,
                      isCurrent: () -> Bool, owns: () -> Bool,
                      readAfter: () -> OwlAutomaticExpansionObservation?) -> Outcome {
    guard isCurrent() else { return .sessionEnded }
    write()
    guard isCurrent() else { return .sessionEnded }
    if owns() { return .accepted }
    let after = readAfter()
    guard isCurrent() else { return .sessionEnded }
    if let before, before.isReadable, let after, after.isReadable, before == after {
      return .rejectedWithoutChange
    }
    return .uncertain
  }
}

/// Main input/UI thread only. The owner publishes persisted snapshots off the key path.
/// Shared-store/startup wiring and settings UI are deliberately owned by the integration task.
final class OwlAutomaticExpansionRuntime {
  static let shared = OwlAutomaticExpansionRuntime()
  static let willChange = Notification.Name("OwlAutomaticExpansionWillChange")
  private(set) var index = OwlAutomaticExpansionIndex.empty
  private(set) var revision: UInt64 = 0
  private(set) var enabled = false
  private(set) var disabledBundleIDs: Set<String> = []
  static let enabledKey = "OwlAutomaticExpansionEnabled"
  static let disabledBundleIDsKey = "OwlAutomaticExpansionDisabledBundleIDs"
  private var directory: URL?
  private var defaults: UserDefaults = OwlDefaults.standard
  private var commitObserver: NSObjectProtocol?

  init() {
    commitObserver = NotificationCenter.default.addObserver(forName: OwlTemplateStore.libraryDidCommit,
      object: nil, queue: nil) { [weak self] notification in
      guard let changed = notification.object as? URL else { return }
      // Delayed notifications re-read current committed bytes, never publish a stale value.
      let refresh = { [weak self] in
        guard let self, let directory = self.directory,
              changed.standardizedFileURL == directory else { return }
        try? self.reload(dataDir: directory, defaults: self.defaults)
      }
      if Thread.isMainThread { refresh() } else { DispatchQueue.main.async(execute: refresh) }
    }
  }

  deinit { if let commitObserver { NotificationCenter.default.removeObserver(commitObserver) } }

  /// Startup/settings/successful-transaction path only; ordinary keystrokes never call this.
  func reload(dataDir: URL = OwlApp.userDir, defaults: UserDefaults = OwlDefaults.standard) throws {
    directory = dataDir.standardizedFileURL
    self.defaults = defaults
    do {
      let entries: [OwlTemplateEntry]
      switch OwlTemplateStore.mode(dataDir: dataDir) {
      case .empty: entries = []
      case .unified: entries = try OwlTemplateStore.load(dataDir: dataDir).entries
      case .legacy: throw OwlTemplateError.legacyRequiresMigration
      case .unavailable(let message): throw OwlTemplateError.invalid(message)
      }
      try publish(entries: entries, enabled: defaults.bool(forKey: Self.enabledKey),
                  disabledBundleIDs: Set(defaults.stringArray(forKey: Self.disabledBundleIDsKey) ?? []))
    } catch {
      // A pending recovery or unusable library must never leave an older auto-trigger live.
      try? publish(entries: [], enabled: false, disabledBundleIDs: [])
      throw error
    }
  }

  func allows(bundleID: String?) -> Bool {
    guard enabled, !index.isEmpty, let bundleID, !bundleID.isEmpty else { return false }
    return !disabledBundleIDs.contains(bundleID.lowercased())
  }

  /// Validation failure leaves both the previous snapshot and any active composition intact.
  func publish(entries: [OwlTemplateEntry], enabled: Bool, disabledBundleIDs: Set<String>) throws {
    let next = try OwlAutomaticExpansionIndex(entries: entries)
    NotificationCenter.default.post(name: Self.willChange, object: self)
    index = next
    self.enabled = enabled
    self.disabledBundleIDs = Set(disabledBundleIDs.map { $0.lowercased() })
    revision &+= 1
  }
}
