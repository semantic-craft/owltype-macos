//
//  FamoQuickSendHotKey.swift
//  法墨输入法 (Famo) — IMK 内快捷面板热键
//
//  快捷短语和提示词面板使用用户录制的受限组合键
//  (`FamoRecordedHotKey` + `FamoHotKeySlot` + the shared recorder row below), default OFF — a global
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
//  The working design only matters while 法墨 is the ACTIVE input source — every keyDown already
//  flows through `FamoInputController.handle()`. `FamoHotKeyMatcher` matches the combos there;
//  no registration, no extra permissions, no reapply choreography (combos are read live).
//

import AppKit
import Carbon
import os
import SwiftUI

/// The summon hotkey slots. Same recordable range, same recorder row, same default (off);
/// they differ only in where they persist, what they're called, and which legacy rawValues decode.
enum FamoHotKeySlot: CaseIterable, Sendable {
  case quickSendPanel
  /// 提示词助手直达（07-21 机主提案）：同一块面板、初始分段=提示词——五笔用户的专属入口
  /// （提示词表不挂五笔 schema，打字触发只在拼音下存在）。
  case promptAssistant

  /// UserDefaults key (unchanged from the preset era — the stored values changed, not the keys).
  var defaultsKey: String {
    switch self {
    case .quickSendPanel: return "FamoQuickSendPanelHotKey"
    case .promptAssistant: return "FamoPromptAssistantHotKey"
    }
  }

  /// Feature name used in the recorder's labels/accessibility strings. Lives here (NOT in a
  /// `settings-` source file) so it stays invisible to `FamoSettingsCoverageTests`.
  var displayName: String {
    switch self {
    case .quickSendPanel: return "快捷短语面板"
    case .promptAssistant: return "提示词助手"
    }
  }

  /// Stored rawValues from retired preset enums that must keep decoding. 快捷短语面板's Space-based
  /// presets ("ctrlShiftSpace"…) are deliberately ABSENT: they're outside the recordable range, so
  /// an upgrade migrates them to 未设置 rather than showing a combo the user could never re-record.
  var legacyPresets: [String: (keyCode: UInt32, modifiers: UInt32)] {
    [:]
  }

  /// The other slots — used to reject recording a combo that's already taken (the tap/IMK matchers
  /// check in a fixed order, so a duplicate would silently dead-end whichever loses the race).
  var counterparts: [FamoHotKeySlot] {
    FamoHotKeySlot.allCases.filter { $0 != self }
  }

  /// Persisted combo; `nil` = off (the default — stored as "off").
  var current: FamoRecordedHotKey? {
    get {
      FamoDefaults.standard.string(forKey: defaultsKey)
        .flatMap { FamoRecordedHotKey.decode($0, legacyPresets: legacyPresets) }
    }
    nonmutating set {
      FamoDefaults.standard.set(newValue.map(FamoRecordedHotKey.encode) ?? "off", forKey: defaultsKey)
    }
  }
}

/// A user-recorded summon combo. Defaults to off and is matched only on the IMK path.
///
/// Recording range is restricted to avoid shadowing app shortcuts or plain typing: the main key
/// must be a letter A–Z and the modifiers must include AT LEAST TWO of ⌃⌥⇧⌘ (single-modifier
/// combos like ⌘A collide with app shortcuts; ⇧A alone is just typing). The validating `init?`
/// is the only constructor, so out-of-range combos are unrepresentable.
struct FamoRecordedHotKey: Equatable, Sendable {
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
    guard Self.letterKeyCodes[keyCode] != nil,
          modifiers & ~Self.allowedModifierBits == 0,
          modifiers.nonzeroBitCount >= 2
    else { return nil }
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  /// Build from a key press seen by the recorder. Maps only ⌃⌥⇧⌘ (caps lock / fn are ignored,
  /// not rejected — Carbon ignores them too); `nil` when out of range.
  static func fromRecordedEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> FamoRecordedHotKey? {
    var modifiers: UInt32 = 0
    if flags.contains(.control) { modifiers |= UInt32(controlKey) }
    if flags.contains(.option) { modifiers |= UInt32(optionKey) }
    if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
    if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
    return FamoRecordedHotKey(keyCode: UInt32(keyCode), modifiers: modifiers)
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

  /// Carbon-style keyCode + modifier mask, consumed by `FamoHotKeyMatcher` on the IMK path.
  var carbonCombo: (keyCode: UInt32, modifiers: UInt32) { (keyCode, modifiers) }

  /// Encoded as "ctrl+shift+A"-style tokens; a slot's legacy preset rawValues also decode.
  static func encode(_ combo: FamoRecordedHotKey) -> String {
    var tokens: [String] = []
    if combo.modifiers & UInt32(controlKey) != 0 { tokens.append("ctrl") }
    if combo.modifiers & UInt32(optionKey) != 0 { tokens.append("opt") }
    if combo.modifiers & UInt32(shiftKey) != 0 { tokens.append("shift") }
    if combo.modifiers & UInt32(cmdKey) != 0 { tokens.append("cmd") }
    tokens.append(letterKeyCodes[combo.keyCode] ?? "?")
    return tokens.joined(separator: "+")
  }

  static func decode(_ raw: String,
                     legacyPresets: [String: (keyCode: UInt32, modifiers: UInt32)]) -> FamoRecordedHotKey? {
    if let legacy = legacyPresets[raw] {
      return FamoRecordedHotKey(keyCode: legacy.keyCode, modifiers: legacy.modifiers)
    }
    let tokens = raw.split(separator: "+").map(String.init)
    guard tokens.count >= 2, let letter = tokens.last,
          let keyCode = letterKeyCodes.first(where: { $0.value == letter })?.key
    else { return nil }
    var modifiers: UInt32 = 0
    for token in tokens.dropLast() {
      switch token {
      case "ctrl": modifiers |= UInt32(controlKey)
      case "opt": modifiers |= UInt32(optionKey)
      case "shift": modifiers |= UInt32(shiftKey)
      case "cmd": modifiers |= UInt32(cmdKey)
      default: return nil
      }
    }
    return FamoRecordedHotKey(keyCode: keyCode, modifiers: modifiers)
  }
}

/// Match an IMK-delivered keyDown against a Carbon-style (keyCode, modifiers) combo — the ONLY
/// hotkey path (#118; see file header for why Carbon registration is banned). Exact ⌃⌥⇧⌘ set
/// equality: extra held modifiers do NOT match.
enum FamoHotKeyMatcher {
  /// Persisted (`.notice`) observability for hotkey matches — #118 root lesson: silent failure
  /// modes here ship unnoticed. Query on a real machine with:
  ///   /usr/bin/log show --last 10m --predicate 'subsystem == "im.famo.inputmethod.Famo" && category == "hotkey"'
  static let log = Logger(subsystem: "im.famo.inputmethod.Famo", category: "hotkey")

  static func matches(_ combo: (keyCode: UInt32, modifiers: UInt32),
                      keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
    guard UInt32(keyCode) == combo.keyCode else { return false }
    var expected: NSEvent.ModifierFlags = []
    if combo.modifiers & UInt32(controlKey) != 0 { expected.insert(.control) }
    if combo.modifiers & UInt32(optionKey) != 0 { expected.insert(.option) }
    if combo.modifiers & UInt32(shiftKey) != 0 { expected.insert(.shift) }
    if combo.modifiers & UInt32(cmdKey) != 0 { expected.insert(.command) }
    return flags.intersection([.control, .option, .shift, .command]) == expected
  }
}

/// Recorder row shared by the local picker settings cards: click the combo button, press the
/// desired keys, done. Captures the next key press with a LOCAL `NSEvent` monitor (the settings
/// window is in-process — no event tap / Accessibility permission involved) and accepts only combos
/// inside the allowed range; out-of-range or already-taken presses show a hint and keep listening,
/// Esc cancels. All key events are consumed while recording so they can't leak into the window.
/// Labels live in this UI-layer file, invisible to `FamoSettingsCoverageTests`.
struct FamoHotKeyRecorderRow: View {
  let slot: FamoHotKeySlot
  let palette: FamoCandidatePalette

  @State private var combo: FamoRecordedHotKey?
  @State private var isRecording = false
  @State private var hint: Hint?
  @State private var keyMonitor: Any?

  private enum Hint: Equatable {
    case outOfRange
    case taken(by: String)
  }

  init(slot: FamoHotKeySlot, palette: FamoCandidatePalette) {
    self.slot = slot
    self.palette = palette
    _combo = State(initialValue: slot.current)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Text("唤起热键")
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
      }
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onDisappear { stopRecording() }
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
  }

  private func handleKeyDown(_ event: NSEvent) {
    if event.keyCode == UInt16(kVK_Escape) {
      stopRecording()
      return
    }
    guard let recorded = FamoRecordedHotKey.fromRecordedEvent(
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
    FamoHotKeyMatcher.log.notice(
      "\(String(describing: self.slot), privacy: .public) combo recorded: \(recorded.label, privacy: .public)")
    stopRecording()
  }

  private func clear() {
    combo = nil
    slot.current = nil
    FamoHotKeyMatcher.log.notice("\(String(describing: self.slot), privacy: .public) combo cleared")
  }
}
