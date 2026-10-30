//
//  OwlQuickSendHotKey.swift
//  猫头鹰输入法 (Owltype) — 全局唤起热键（快捷短语面板 PR3 + 划词菜单召唤）
//
//  Both 快捷短语面板 and 划词菜单 use the SAME shape: a user-RECORDED combo inside a restricted range
//  (`OwlRecordedHotKey` + `OwlHotKeySlot` + the shared recorder row below), default OFF — a global
//  hotkey shouldn't claim a key uninvited. 快捷短语面板 used to ship three Space-based presets with
//  ⌃⇧Space as the default; those rawValues are outside the recordable range and deliberately have
//  no legacy decode, so upgrading migrates them to 未设置 (product decision 2026-07-19).
//
//  ⚠️ NO Carbon `RegisterEventHotKey` here — that layer was the #118 root cause and must never
//  come back. In this IMK process, Carbon registration returns noErr and the window server then
//  CONSUMES the combo system-wide, but `kEventHotKeyPressed` is never dispatched to the in-process
//  handler (verified on real machines against both GetApplicationEventTarget and
//  GetEventDispatcherTarget, with persisted register/fire logging). Net effect: the hotkey does
//  nothing AND the combo is stolen from every app — including our own IMK-path matcher below.
//
//  The working design: both features only matter while 猫头鹰 is the ACTIVE input source (panel needs
//  `activeInputController`, 划词召唤 no-ops otherwise) — and in that state every keyDown already
//  flows through `OwlInputController.handle()`. `OwlHotKeyMatcher` matches the combos there;
//  no registration, no extra permissions, no reapply choreography (combos are read live).
//

import AppKit
import Carbon
import Combine
import os
import SwiftUI

/// Hotkey slots share the recorder and conflict checks. Summon shortcuts default to off;
/// candidate pinning defaults to Control Shift P only when that combination is unclaimed.
enum OwlHotKeySlot: CaseIterable, Sendable {
  case quickSendPanel
  case selectionMenu
  /// 提示词助手直达（07-21 机主提案）：同一块面板、初始分段=提示词——五笔用户的专属入口
  /// （提示词表不挂五笔 schema，打字触发只在拼音下存在）。
  case promptAssistant
  /// Local to a live pinyin candidate menu; never intercepted by the global event tap.
  case pinCandidate

  // 任意提问的直达热键槽（askAnything / "OwlAskAnythingHotKey"）已退役（产品决策 2026-07-26）：
  // 任意提问是划词技能的兜底，必须带着选区从划词菜单点进（同日删掉了状态栏那个空选区入口）；
  // 旧偏好键成死数据，不迁移不解码。

  /// UserDefaults key (unchanged from the preset era — the stored values changed, not the keys).
  var defaultsKey: String {
    switch self {
    case .quickSendPanel: return "OwlQuickSendPanelHotKey"
    case .selectionMenu: return "OwlSelectionMenuHotKey"
    case .promptAssistant: return "OwlPromptAssistantHotKey"
    case .pinCandidate: return "OwlPinCandidateHotKey"
    }
  }

  /// Feature name used in the recorder's labels/accessibility strings. Lives here (NOT in a
  /// `settings-` source file) so it stays invisible to `OwlSettingsCoverageTests`.
  var displayName: String {
    switch self {
    case .quickSendPanel: return "快捷片段"
    // 2026-07-26 工具箱重设计：case 名与 defaultsKey 不动（存量组合照常解码），只换用户可见名。
    case .selectionMenu: return "划词工具箱"
    case .promptAssistant: return "快捷片段 · 提示词筛选"
    case .pinCandidate: return "置顶当前候选"
    }
  }

  /// Stored rawValues from retired preset enums that must keep decoding. 快捷短语面板's Space-based
  /// presets ("ctrlShiftSpace"…) are deliberately ABSENT: they're outside the recordable range, so
  /// an upgrade migrates them to 未设置 rather than showing a combo the user could never re-record.
  var legacyPresets: [String: (keyCode: UInt32, modifiers: UInt32)] {
    switch self {
    case .quickSendPanel, .promptAssistant, .pinCandidate:
      return [:]
    case .selectionMenu:
      return [
        "ctrlShiftA": (UInt32(kVK_ANSI_A), UInt32(controlKey | shiftKey)),
        "cmdShiftA": (UInt32(kVK_ANSI_A), UInt32(cmdKey | shiftKey)),
        "optShiftA": (UInt32(kVK_ANSI_A), UInt32(optionKey | shiftKey))
      ]
    }
  }

  /// The other slots — used to reject recording a combo that's already taken (the tap/IMK matchers
  /// check in a fixed order, so a duplicate would silently dead-end whichever loses the race).
  var counterparts: [OwlHotKeySlot] {
    OwlHotKeySlot.allCases.filter { $0 != self }
  }

  /// Persisted combo; `nil` = off. Pinning has an unclaimed-combination fallback.
  var current: OwlRecordedHotKey? {
    get {
      if let stored = OwlDefaults.standard.string(forKey: defaultsKey) {
        return OwlRecordedHotKey.decode(stored, legacyPresets: legacyPresets)
      }
      guard self == .pinCandidate else { return nil }
      let proposed = OwlRecordedHotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | shiftKey))
      return counterparts.contains(where: { $0.current == proposed }) ? nil : proposed
    }
    nonmutating set {
      OwlDefaults.standard.set(newValue.map(OwlRecordedHotKey.encode) ?? "off", forKey: defaultsKey)
    }
  }
}

/// A user-RECORDED summon combo (both slots were fixed presets before). Defaults to off; the user
/// records one via 快捷键设置. For 划词工具箱, pressing it opens the toolbox for the current
/// selection — PARALLEL to the 启用划词工具箱 master toggle (which governs the 双击 ⌥ gesture
/// only, 2026-07-26 重设计): the summon needs Accessibility trust + a usable selection, not the
/// toggle; drops are logged, never silent.
///
/// Recording range is restricted to avoid shadowing app shortcuts or plain typing: the main key
/// must be a letter A–Z and the modifiers must include AT LEAST TWO of ⌃⌥⇧⌘ (single-modifier
/// combos like ⌘A collide with app shortcuts; ⇧A alone is just typing). The validating `init?`
/// is the only constructor, so out-of-range combos are unrepresentable.
struct OwlRecordedHotKey: Equatable, Sendable {
  let keyCode: UInt32
  let modifiers: UInt32

  /// Recordable main keys: Carbon ANSI letter keyCodes → display letter (`NSEvent.keyCode` uses
  /// the same numbering).
  static let letterKeyCodes: [UInt32: String] = [
    UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
    UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
    UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
    UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
    UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
    UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
    UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
    UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
    UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z"
  ]

  private static let allowedModifierBits = UInt32(controlKey | optionKey | shiftKey | cmdKey)

  /// `nil` when the combo is outside the recordable range (non-letter key, unknown modifier bits,
  /// or fewer than two modifiers).
  init?(keyCode: UInt32, modifiers: UInt32) {
    let valid: Bool = OwlAppCore.required([
      "operation": "pure_rule",
      "rule": "hotkey_validate",
      "args": ["key_code": keyCode, "modifiers": modifiers]
    ])
    guard valid else { return nil }
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  /// Build from a key press seen by the recorder. Maps only ⌃⌥⇧⌘ (caps lock / fn are ignored,
  /// not rejected — Carbon ignores them too); `nil` when out of range.
  static func fromRecordedEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> OwlRecordedHotKey? {
    var modifiers: UInt32 = 0
    if flags.contains(.control) { modifiers |= UInt32(controlKey) }
    if flags.contains(.option) { modifiers |= UInt32(optionKey) }
    if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
    if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
    return OwlRecordedHotKey(keyCode: UInt32(keyCode), modifiers: modifiers)
  }

  /// "⌃⌥⇧⌘A"-style display label (standard macOS modifier order).
  var label: String {
    var text = ""
    if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
    if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
    if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
    if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
    return text + (Self.letterKeyCodes[keyCode] ?? "?")
  }

  /// Carbon-style keyCode + modifier mask, consumed by `OwlHotKeyMatcher` on the IMK path.
  var carbonCombo: (keyCode: UInt32, modifiers: UInt32) { (keyCode, modifiers) }

  /// Encoded as "ctrl+shift+A"-style tokens; a slot's legacy preset rawValues also decode.
  static func encode(_ combo: OwlRecordedHotKey) -> String {
    OwlAppCore.required([
      "operation": "pure_rule",
      "rule": "hotkey_encode",
      "args": ["key_code": combo.keyCode, "modifiers": combo.modifiers]
    ])
  }

  static func decode(_ raw: String,
                     legacyPresets: [String: (keyCode: UInt32, modifiers: UInt32)]) -> OwlRecordedHotKey? {
    var legacy: [String: [UInt32]] = [:]
    for (k, v) in legacyPresets {
      legacy[k] = [v.keyCode, v.modifiers]
    }
    struct WireResult: Decodable {
      let keyCode: UInt32
      let modifiers: UInt32

      enum CodingKeys: String, CodingKey {
        case keyCode = "key_code"
        case modifiers
      }
    }
    let wire: WireResult? = OwlAppCore.required([
      "operation": "pure_rule",
      "rule": "hotkey_decode",
      "args": ["raw": raw, "legacy_presets": legacy]
    ])
    guard let wire else { return nil }
    return OwlRecordedHotKey(keyCode: wire.keyCode, modifiers: wire.modifiers)
  }
}

/// Match an IMK-delivered keyDown against a Carbon-style (keyCode, modifiers) combo — the ONLY
/// hotkey path (#118; see file header for why Carbon registration is banned). Exact ⌃⌥⇧⌘ set
/// equality: extra held modifiers do NOT match.
enum OwlHotKeyMatcher {
  /// Persisted (`.notice`) observability for hotkey matches — #118 root lesson: silent failure
  /// modes here ship unnoticed. Query on a real machine with:
  ///   /usr/bin/log show --last 10m --predicate 'subsystem == "im.owltype.inputmethod.Owltype" && category == "hotkey"'
  static let log = Logger(subsystem: "im.owltype.inputmethod.Owltype", category: "hotkey")

  static func matches(_ combo: (keyCode: UInt32, modifiers: UInt32),
                      keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
    OwlAppCore.required([
      "operation": "pure_rule",
      "rule": "hotkey_matches",
      "args": [
        "combo_key_code": combo.keyCode,
        "combo_modifiers": combo.modifiers,
        "key_code": keyCode,
        "flags": flags.rawValue
      ]
    ])
  }
}

/// Session-level CGEventTap hotkey listener — the CROSS-HOST path. The IMK matcher only sees keys
/// the host forwards to the input method; Chromium/Electron hosts consume modified letter keys as
/// accelerators BEFORE the IME (real machine: Hyper+J's keyDown never reached `handle()` in an
/// Electron host while TextEdit delivered it fine). The tap intercepts before app dispatch, so it
/// works in every host — at the cost of Accessibility permission, which the 划词 feature already
/// holds (the AX budget was reserved for exactly this). Without AX the tap silently stays off and
/// the IMK matcher remains the fallback for cooperative hosts; with the tap active, matched combos
/// are consumed at session level and never reach the IME, so the two paths cannot double-fire.
///
/// Consumption rule: a matched combo is consumed ONLY while 猫头鹰 is the current input source
/// (per-match check, not per-keystroke) — with another IME active it passes through untouched
/// instead of being stolen system-wide (the retired Carbon registration's sin, #118).
///
/// ⚠️ The tap runs on its OWN thread, never the main run loop (2026-10-29 system-wide typing
/// freeze). A head-inserted `.defaultTap` holds every keyDown in the login session until its
/// callback returns, whatever the input source: on the main run loop, a 600 ms main-thread stall
/// delayed every keystroke by up to 594 ms, and a 1.2 s stall made WindowServer disable the tap
/// and drop 6 of 8 keystrokes. The callback therefore touches no main-thread state: combos come
/// from UserDefaults, and "is 猫头鹰 current" is a flag the main thread keeps current.
final class OwlHotKeyEventTap: NSObject {
  private struct Shared {
    var suppressed = false
    var owltypeIsCurrent = false
  }

  private static let shared = OSAllocatedUnfairLock(initialState: Shared())

  /// While the settings recorder is capturing, the tap must pass EVERYTHING through — otherwise
  /// re-recording the currently-bound combo would be consumed here and never reach the recorder's
  /// local monitor. Written on main, read on the tap thread.
  static var isSuppressed: Bool {
    get { shared.withLock { $0.suppressed } }
    set { shared.withLock { $0.suppressed = newValue } }
  }

  /// Re-read the current input source (TIS, main thread) into the flag the tap thread reads.
  static func refreshCurrentInputSource() {
    let current = OwlInstaller.currentInputSourceID()?.hasPrefix(OwlInstaller.inputSourcePrefix) == true
    shared.withLock { $0.owltypeIsCurrent = current }
  }

  /// The slot a keyDown triggers, or `nil` to pass it through. Pure, so the consume rule is testable
  /// without a live tap: suppression, ⌃⌥⌘ pre-filter, fixed slot precedence, then the source check.
  static func slotToConsume(keyCode: UInt16, flags: NSEvent.ModifierFlags, suppressed: Bool,
                            owltypeIsCurrent: Bool,
                            combo: (OwlHotKeySlot) -> (keyCode: UInt32, modifiers: UInt32)?) -> OwlHotKeySlot? {
    // Fast pre-filter: every configured combo requires a non-shift modifier — plain typing and
    // shift-typing exit here before any defaults read.
    guard !suppressed, !flags.isDisjoint(with: [.control, .option, .command]) else { return nil }
    // Fixed precedence (allCases order): 快捷短语面板 → 划词菜单 → 提示词助手. The recorder rejects
    // duplicates, so at most one slot matches; the order only keeps a stale duplicate deterministic.
    let matched = OwlHotKeySlot.allCases.filter { $0 != .pinCandidate }.first { slot in
      combo(slot).map { OwlHotKeyMatcher.matches($0, keyCode: keyCode, flags: flags) } ?? false
    }
    guard let matched else { return nil }
    guard owltypeIsCurrent else {
      OwlHotKeyMatcher.log.notice("tap match passthrough: Owltype not current input source")
      return nil
    }
    return matched
  }

  /// The port and the tap thread's run loop, shared between main (start/stop) and the tap thread.
  private struct Installed {
    var port: CFMachPort?
    var runLoop: CFRunLoop?
  }

  private let installed = OSAllocatedUnfairLock(uncheckedState: Installed())
  private var observesInputSource = false
  var onQuickSend: (() -> Void)?
  var onSelectionSummon: (() -> Void)?
  var onPromptAssistant: (() -> Void)?

  /// Install the tap when possible. Safe to call repeatedly; no-op when installed or AX untrusted.
  func startIfPossible() {
    guard installed.withLock({ $0.port == nil }) else { return }
    guard AXIsProcessTrusted() else {
      OwlHotKeyMatcher.log.notice("event tap not installed: accessibility not trusted (IMK fallback)")
      return
    }
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    let context = Unmanaged.passUnretained(self).toOpaque()
    guard let created = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: { _, type, event, userData -> Unmanaged<CGEvent>? in
        guard let userData else { return Unmanaged.passUnretained(event) }
        let instance = Unmanaged<OwlHotKeyEventTap>.fromOpaque(userData).takeUnretainedValue()
        return instance.handle(type: type, event: event)
      },
      userInfo: context
    ) else {
      OwlHotKeyMatcher.log.notice("event tap unavailable: tapCreate failed despite AX trust")
      return
    }
    observeInputSource()
    let ready = DispatchSemaphore(value: 0)
    let thread = Thread { [installed] in
      let runLoop = CFRunLoopGetCurrent()
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
      CFRunLoopAddSource(runLoop, source, .commonModes)
      installed.withLock { $0 = Installed(port: created, runLoop: runLoop) }
      CGEvent.tapEnable(tap: created, enable: true)
      ready.signal()
      CFRunLoopRun()
    }
    thread.name = "im.owltype.hotkey-tap"
    thread.qualityOfService = .userInteractive
    thread.start()
    ready.wait()
    OwlHotKeyMatcher.log.notice("event tap installed on its own thread")
  }

  func stop() {
    let (port, runLoop) = installed.withLock { state -> (CFMachPort?, CFRunLoop?) in
      defer { state = Installed() }
      return (state.port, state.runLoop)
    }
    if let port {
      CGEvent.tapEnable(tap: port, enable: false)
      CFMachPortInvalidate(port)
    }
    if let runLoop { CFRunLoopStop(runLoop) }
    if observesInputSource { DistributedNotificationCenter.default().removeObserver(self) }
    observesInputSource = false
  }

  /// Keep `owltypeIsCurrent` fresh. `.deliverImmediately`: this accessory app is almost never
  /// active, and a suspended center would hold the change until it is.
  private func observeInputSource() {
    Self.refreshCurrentInputSource()
    guard !observesInputSource else { return }
    observesInputSource = true
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(inputSourceChanged(_:)),
      name: .init(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil,
      suspensionBehavior: .deliverImmediately)
  }

  @objc private func inputSourceChanged(_ notification: Notification) {
    Self.refreshCurrentInputSource()
  }

  /// Runs on the tap thread.
  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    // The system disables a slow tap; re-enable, log it (the 2026-10-29 freeze left no trace
    // because this branch was silent), and pass the event on.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      OwlHotKeyMatcher.log.notice("event tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)")
      if let port = installed.withLock({ $0.port }) { CGEvent.tapEnable(tap: port, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    let (suppressed, owltypeIsCurrent) = Self.shared.withLock { ($0.suppressed, $0.owltypeIsCurrent) }
    guard let matched = Self.slotToConsume(
      keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
      flags: nsFlags(event.flags), suppressed: suppressed, owltypeIsCurrent: owltypeIsCurrent,
      combo: { $0.current?.carbonCombo })
    else { return Unmanaged.passUnretained(event) }

    OwlHotKeyMatcher.log.notice("tap fired: \(String(describing: matched), privacy: .public)")
    DispatchQueue.main.async { [weak self] in
      switch matched {
      case .quickSendPanel: self?.onQuickSend?()
      case .selectionMenu: self?.onSelectionSummon?()
      case .promptAssistant: self?.onPromptAssistant?()
      case .pinCandidate: break // excluded above; handled only by IMK with live candidates
      }
    }
    return nil // consume — the host never sees a combo we acted on
  }

  private func nsFlags(_ flags: CGEventFlags) -> NSEvent.ModifierFlags {
    var out: NSEvent.ModifierFlags = []
    if flags.contains(.maskControl) { out.insert(.control) }
    if flags.contains(.maskAlternate) { out.insert(.option) }
    if flags.contains(.maskShift) { out.insert(.shift) }
    if flags.contains(.maskCommand) { out.insert(.command) }
    return out
  }
}

/// Recorder row shared by the 快捷短语面板 and 划词菜单 设置卡: click the combo button, press the
/// desired keys, done. Captures the next key press with a LOCAL `NSEvent` monitor (the settings
/// window is in-process — no event tap / Accessibility permission involved) and accepts only combos
/// inside the allowed range; out-of-range or already-taken presses show a hint and keep listening,
/// Esc cancels. All key events are consumed while recording so they can't leak into the window.
/// Labels live in this UI-layer file, invisible to `OwlSettingsCoverageTests`.
struct OwlHotKeyRecorderRow: View {
  let slot: OwlHotKeySlot
  let palette: OwlCandidatePalette

  @State private var combo: OwlRecordedHotKey?
  @State private var isRecording = false
  @State private var hint: Hint?
  @State private var keyMonitor: Any?
  @State private var accessibilityTrusted = AXIsProcessTrusted()

  private enum Hint: Equatable {
    case outOfRange
    case taken(by: String)
  }

  init(slot: OwlHotKeySlot, palette: OwlCandidatePalette) {
    self.slot = slot
    self.palette = palette
    _combo = State(initialValue: slot.current)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Text(slot == .pinCandidate ? "置顶 / 取消置顶" : "唤起热键")
          .font(.system(size: 14))
          .foregroundStyle(palette.ink)
        Spacer(minLength: 8)
        if combo != nil, !isRecording {
          Button(action: clear) {
            Text("清除")
              .font(.system(size: 13))
              .foregroundStyle(palette.ink3)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("清除\(slot.displayName)快捷键")
        }
        Button(action: toggleRecording) {
          Text(isRecording ? "请按下快捷键…" : (combo?.label ?? "点击录制"))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isRecording ? palette.accentDeep : palette.accent)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording
                            ? "正在录制\(slot.displayName)快捷键，Esc 取消"
                            : "录制\(slot.displayName)快捷键")
      }
      if isRecording {
        Text(recordingHintText)
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
      } else if slot == .selectionMenu, combo != nil, !accessibilityTrusted {
        // 平行开关（产品决策 2026-07-19，重设计后延续）：热键召唤不依赖「启用划词工具箱」总开关
        // （那只管双击 ⌥ 手势）；唯一硬前置是辅助功能权限（读选中文字必需）。未授权时点破，免得录了组合以为坏了。
        Text("需辅助功能权限（划词工具箱 → 辅助功能授权），热键才能读取选中文字")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
      }
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onDisappear { stopRecording() }
    // 授权态刷新（同 OwlSkillsPage 徽章）：去系统设置授权后切回本窗口，提示即撤。
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      accessibilityTrusted = AXIsProcessTrusted()
    }
  }

  private var recordingHintText: String {
    switch hint {
    case .outOfRange:
      return "该组合不可用：需 ⌃⌥⇧⌘ 中至少两个修饰键 + 一个字母（Esc 取消）"
    case .taken(let owner):
      return "该组合已用于\(owner)，请换一个（Esc 取消）"
    case nil:
      return "按 ⌃⌥⇧⌘ 中至少两个修饰键 + 一个字母（Esc 取消）"
    }
  }

  private func toggleRecording() {
    if isRecording { stopRecording() } else { startRecording() }
  }

  private func startRecording() {
    isRecording = true
    hint = nil
    OwlHotKeyEventTap.isSuppressed = true // let the recorder see combos the tap would consume
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      handleKeyDown(event)
      return nil // consume every key press while recording
    }
  }

  private func stopRecording() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    isRecording = false
    hint = nil
    OwlHotKeyEventTap.isSuppressed = false
  }

  private func handleKeyDown(_ event: NSEvent) {
    if event.keyCode == UInt16(kVK_Escape) {
      stopRecording()
      return
    }
    guard let recorded = OwlRecordedHotKey.fromRecordedEvent(
      keyCode: event.keyCode, flags: event.modifierFlags)
    else {
      hint = .outOfRange
      return
    }
    // All slots share one range, so a duplicate is representable — and the matchers check in a
    // fixed order, which would silently dead-end the losing feature. Reject, keep listening.
    if let taken = slot.counterparts.first(where: { $0.current == recorded }) {
      hint = .taken(by: taken.displayName)
      return
    }
    combo = recorded
    slot.current = recorded
    OwlHotKeyMatcher.log.notice(
      "\(String(describing: self.slot), privacy: .public) combo recorded: \(recorded.label, privacy: .public)")
    stopRecording()
  }

  private func clear() {
    combo = nil
    slot.current = nil
    OwlHotKeyMatcher.log.notice("\(String(describing: self.slot), privacy: .public) combo cleared")
  }
}
