import Foundation

/// Built only after a successful library/configuration change. No storage or context capture.
struct OwlAutomaticExpansionIndex {
  enum ValidationError: Error, Equatable, LocalizedError {
    case invalidTrigger, duplicateTrigger, immediatePrefixConflict
    case invalidTemplate(String)

    init?(coreCode: String) {
      switch coreCode {
      case "automatic_invalid": self = .invalidTrigger
      case "automatic_duplicate": self = .duplicateTrigger
      case "automatic_prefix": self = .immediatePrefixConflict
      default:
        guard coreCode.hasPrefix("automatic_template:") else { return nil }
        self = .invalidTemplate(String(coreCode.dropFirst("automatic_template:".count)))
      }
    }

    var errorDescription: String? {
      switch self {
      case .invalidTrigger: return "自动触发词须为双分号后接字母、数字、下划线或连字符。"
      case .duplicateTrigger: return "生效的自动触发词重复，请修改后保存。"
      case .immediatePrefixConflict: return "立即展开词不能是另一自动触发词的前缀。"
      case .invalidTemplate(let message): return message
      }
    }
  }

  fileprivate let core: OwlAppSession
  var isEmpty: Bool { core.call("empty") }
  static let empty = try! OwlAutomaticExpansionIndex(entries: [])
  init(entries: [OwlTemplateEntry]) throws {
    do { core = try OwlAppSession("index", args: OwlAppCore.payload(entries)) }
    catch let error as OwlAppCore.Failure { throw ValidationError(coreCode: error.code) ?? error }
  }
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
      guard case .invoke(let entry, _, let delimiter) = self else { return "" }
      return OwlAutomaticExpansionScope.rule("trailing", ["mode": entry.expansionMode.rawValue,
        "delimiter": delimiter as Any? ?? NSNull()])
    }
  }

  private let core = try! OwlAppSession("recognizer")
  var buffer: String { core.call("buffer") }
  var isRecognizing: Bool { !buffer.isEmpty }
  func takePending() -> String? {
    let text: String = core.call("take")
    return text.isEmpty ? nil : text
  }
  private struct WireStep: Decodable {
    let kind: String
    let text: String?
    let replay: Bool?
    let consume: Bool?
    let entry: OwlTemplateEntry?
    let trigger: String?
    let delimiter: String?
  }
  func consume(_ input: Input, index: OwlAutomaticExpansionIndex, canStart: Bool = false) -> Step {
    var args: [String: Any] = ["canStart": canStart]
    switch input {
    case .text(let text): args["input"] = "text"; args["text"] = text
    case .backspace: args["input"] = "backspace"
    case .escape: args["input"] = "escape"
    case .interrupt: args["input"] = "interrupt"
    }
    let result: WireStep = core.call("consume", args, index: index.core)
    switch result.kind {
    case "mark": return .mark(result.text!)
    case "clear": return .clear
    case "restore": return .restore(result.text!, replaySemicolon: result.replay!, consumeKey: result.consume!)
    case "invoke": return .invoke(result.entry!, trigger: result.trigger!, delimiter: result.delimiter)
    default: return .passThrough
    }
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
    guard case .invoke(let entry, let trigger, let delimiter) = step else { return nil }
    struct Source: Decodable { let valid: Bool; let original: String?; let trailing: String? }
    let source: Source = OwlAutomaticExpansionScope.rule("source", ["pending": entry.isPendingReview, "invocation": entry.invocationMode.rawValue,
      "entryTrigger": entry.trigger as Any? ?? NSNull(), "mode": entry.expansionMode.rawValue, "trigger": trigger, "delimiter": delimiter as Any? ?? NSNull(), "start": start, "marked": markedText])
    guard source.valid else { return nil }
    self.entry = entry
    originalInput = source.original!
    self.markedText = markedText
    markedRange = NSRange(location: start, length: markedText.utf16.count)
    trailingText = source.trailing!

  }
}

/// Once an invocation observes a changed session/mode/configuration it cannot revive when those
/// values later change back. The host delivery separately owns field/focus invalidation.
final class OwlAutomaticExpansionInvocationValidity {
  private let core: OwlAppSession
  private let current: () -> [String: String]
  init(binding: [String: String], current: @escaping () -> [String: String]) {
    core = try! OwlAppSession("binding", args: binding)
    self.current = current
  }
  func isValid() -> Bool {
    let needsFacts: Bool = core.call("valid")
    return needsFacts ? core.call("binding", current()) : false
  }
}

/// Readback checks are values so tests can exercise invalid/stale ranges without a real IMK host.
enum OwlAutomaticExpansionScope {
  static func rule<T: Decodable>(_ rule: String, _ args: [String: Any]) -> T {
    OwlAppCore.required(["operation": "template_session_rule", "rule": rule, "args": args])
  }
  static func canStart(selection: NSRange, marked: NSRange, preceding: String?) -> Bool {
    rule("can_start", ["selection": [selection.location, selection.length], "marked": [marked.location, marked.length],
      "preceding": preceding as Any? ?? NSNull()])
  }
  static func owns(start: Int, text: String, marked: NSRange, selection: NSRange, substring: String?) -> Bool {
    rule("owns", ["start": start, "text": text, "marked": [marked.location, marked.length],
      "selection": [selection.location, selection.length], "substring": substring as Any? ?? NSNull()])
  }
  static func valid(_ range: NSRange) -> Bool {
    rule("valid_range", ["range": [range.location, range.length]])
  }
}

/// Production controller entry seam. Tests drive the same Rime reads and host-opening branch
/// that handleAutomaticExpansion uses, without constructing an IMK server in the test process.
enum OwlAutomaticExpansionControllerEntry {
  static func start(input: OwlAutomaticExpansionRecognizer.Input, bundleID: @autoclosure () -> String?,
                    runtime: OwlAutomaticExpansionRuntime, engineSession: OwlRustSession?, openHost: () -> Bool) -> Bool {
    guard case .text(";") = input, runtime.enabled, !runtime.index.isEmpty,
          runtime.allows(bundleID: bundleID()),
          let engineSession, engineSession.isValid, let raw = engineSession.input(),
          let context = engineSession.composition() else { return false }
    let idle: Bool = OwlAutomaticExpansionScope.rule("engine_idle", ["valid": engineSession.isValid,
      "input": raw, "preedit": context.preedit, "candidates": context.candidates.count,
      "preview": context.commitTextPreview ?? ""])
    guard idle else { return false }
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

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.selection == rhs.selection
      && lhs.marked == rhs.marked
      && lhs.documentLength == rhs.documentLength
      && lhs.nearbyText == rhs.nearbyText
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
  private let core = try! OwlAppSession("runtime")
  var revision: UInt64 { core.call("revision") }
  var policyRevision: UInt64 { core.call("policy_revision") }
  var enabled: Bool { core.call("enabled") }
  var disabledBundleIDs: Set<String> { Set(core.call("disabled") as [String]) }
  func binding(for entry: OwlTemplateEntry) -> [String: String] {
    core.call("entry_binding", ["id": entry.id.uuidString, "entry": OwlAppCore.payload(entry)])
  }
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
    OwlAutomaticExpansionScope.rule("allows", ["enabled": enabled, "empty": index.isEmpty,
      "bundle": bundleID as Any? ?? NSNull(), "disabled": Array(disabledBundleIDs)])
  }

  /// Validation failure leaves both the previous snapshot and any active composition intact.
  func publish(entries: [OwlTemplateEntry], enabled: Bool, disabledBundleIDs: Set<String>) throws {
    let next = try OwlAutomaticExpansionIndex(entries: entries)
    NotificationCenter.default.post(name: Self.willChange, object: self)
    index = next
    let _: Bool = core.call("publish", ["entries": OwlAppCore.payload(entries), "enabled": enabled,
      "disabled": Array(disabledBundleIDs)])
  }
}
