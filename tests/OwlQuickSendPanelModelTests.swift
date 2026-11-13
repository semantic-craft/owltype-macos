//
//  OwlQuickSendPanelModelTests.swift
//  法墨输入法 (Owltype) — 快捷短语面板 model tests
//
//  The pure, unit-testable core of the picker panel (`OwlPickerPanelModel`), driven through the
//  快捷短语 source: mapping `OwlQuickSendStore` entries into `OwlPickerRow`s, the typed-search
//  FILTER (case-insensitive substring on the row's precomputed `searchText` = phrase text OR trigger
//  code), and selection / number-key navigation over the FILTERED rows. The model skeleton is now
//  shared across picker sources (短语/提示词); these tests pin the 快捷短语 behavior as the guardrail
//  for that generalization. Split out of `OwlSettingsActionTests` so that file stays under the
//  type-body-length guideline.
//
//  Out of scope here (NOT headless-testable — AppKit window lifecycle): the panel's focus-restore
//  insert path (becomesKeyOnlyIfNeeded → reactivate captured host → client.insertText) and its
//  near-caret positioning. Those are real-machine smoke items, per the panel doc.
//

import AppKit
import Carbon
import XCTest
@testable import Owltype

final class OwlQuickSendPanelModelTests: XCTestCase {

  // MARK: - Store-backed list + navigation

  private func templateEntry(title: String, body: String, trigger: String) -> OwlTemplateEntry {
    var entry = OwlTemplateEntry(title: title, body: body)
    entry.trigger = trigger
    return entry
  }

  func testQuickSendPanelModelBuildsListFromStoreAndNavigates() throws {
    let dir = try makeTempDir()
    let entries = [
      templateEntry(title: "北京市朝阳区人民法院", body: "北京市朝阳区人民法院", trigger: "fy"),
      templateEntry(title: "判决摘要", body: "判决摘要", trigger: "pjzy"),
      templateEntry(title: "最高人民法院", body: "最高人民法院", trigger: "zg")
    ]
    try OwlTemplateStore.save(OwlTemplateLibrary(entries: entries), dataDir: dir)

    var model = OwlPickerPanelModel(
      rows: try OwlTemplateStore.load(dataDir: dir).entries.map(OwlPickerRow.template)
    )
    XCTAssertEqual(model.rows.map(\.display), ["北京市朝阳区人民法院", "判决摘要", "最高人民法院"])
    // First row selected by default → the ⏎ target.
    XCTAssertFalse(model.isEmpty)
    XCTAssertTrue(model.isSelected(0))
    XCTAssertEqual(model.selectedRow?.display, "北京市朝阳区人民法院")

    // ↓↓ then clamp at the last row (no wraparound).
    model.moveSelection(by: 1)
    XCTAssertTrue(model.isSelected(1))
    model.moveSelection(by: 5)
    XCTAssertTrue(model.isSelected(2))
    XCTAssertEqual(model.selectedRow?.display, "最高人民法院")
    // ↑ back up, clamp at 0.
    model.moveSelection(by: -9)
    XCTAssertTrue(model.isSelected(0))

    // Number keys are 1-based; out-of-range returns nil (no crash).
    XCTAssertEqual(model.row(forNumber: 1)?.display, "北京市朝阳区人民法院")
    XCTAssertEqual(model.row(forNumber: 3)?.display, "最高人民法院")
    XCTAssertNil(model.row(forNumber: 4))
    XCTAssertNil(model.row(forNumber: 0))
  }

  func testQuickSendPanelModelEmptyWhenNoFile() throws {
    let dir = try makeTempDir()
    let model = OwlPickerPanelModel(
      rows: try OwlTemplateStore.load(dataDir: dir).entries.map(OwlPickerRow.template)
    )
    XCTAssertTrue(model.isEmpty)
    XCTAssertNil(model.selectedRow)
    XCTAssertNil(model.row(forNumber: 1))
    var mutated = model
    mutated.moveSelection(by: 1)  // must not crash on empty
    XCTAssertNil(mutated.selectedRow)
  }

  // MARK: - 模板 → row mapping

  func testQuickSendRowMappingBuildsDisplayAndSearchableCode() {
    let entry = templateEntry(title: "最高人民法院", body: "最高人民法院", trigger: "zgfy")
    let row = OwlPickerRow.template(entry)
    XCTAssertEqual(row.id, entry.id.uuidString)
    XCTAssertEqual(row.display, "最高人民法院")
    XCTAssertTrue(row.searchText.contains("最高人民法院"))
    XCTAssertTrue(row.searchText.contains("zgfy"))
  }

  func testPromptRowMappingShowsTitleAndKeepsIdForBodyLookup() {
    var entry = templateEntry(title: "民事答辩状模板", body: "答辩人：{{当事人}}……", trigger: "dbz")
    entry.bodyType = .template
    entry.syntax = .legacyDoubleBraces
    let row = OwlPickerRow.template(entry)
    XCTAssertEqual(row.id, entry.id.uuidString)
    XCTAssertEqual(row.display, "民事答辩状模板")
    XCTAssertFalse(row.display.contains("答辩人"))
    XCTAssertTrue(row.searchText.contains("民事答辩状模板"))
    XCTAssertTrue(row.searchText.contains("dbz"))
  }

  // MARK: - typed-search filter

  private func quickSendModel() -> OwlPickerPanelModel {
    OwlPickerPanelModel(rows: [
      templateEntry(title: "北京市朝阳区人民法院", body: "北京市朝阳区人民法院", trigger: "fybj"),
      templateEntry(title: "最高人民法院", body: "最高人民法院", trigger: "zgfy"),
      templateEntry(title: "Contract Draft", body: "Contract Draft", trigger: "cd")
    ].map(OwlPickerRow.template))
  }

  func testQuickSendModelEmptyQueryShowsAll() {
    let model = quickSendModel()
    XCTAssertEqual(model.query, "")
    XCTAssertEqual(model.visible.map(\.display),
                   ["北京市朝阳区人民法院", "最高人民法院", "Contract Draft"])
    // Whitespace-only query is also treated as empty (full list).
    var blank = model
    blank.setQuery("   ")
    XCTAssertEqual(blank.visible.count, 3)
  }

  func testQuickSendModelFiltersByTextCaseInsensitively() {
    var model = quickSendModel()
    // Substring on the Chinese phrase text.
    model.setQuery("人民法院")
    XCTAssertEqual(model.visible.map(\.display), ["北京市朝阳区人民法院", "最高人民法院"])
    // Case-insensitive substring on Latin phrase text.
    model.setQuery("contract")
    XCTAssertEqual(model.visible.map(\.display), ["Contract Draft"])
    model.setQuery("DRAFT")
    XCTAssertEqual(model.visible.map(\.display), ["Contract Draft"])
  }

  func testQuickSendModelFiltersByCodeCaseInsensitively() {
    var model = quickSendModel()
    model.setQuery("zg")
    XCTAssertEqual(model.visible.map(\.display), ["最高人民法院"])
    // Codes are stored lowercased; an uppercased query still matches (case-insensitive).
    model.setQuery("FYBJ")
    XCTAssertEqual(model.visible.map(\.display), ["北京市朝阳区人民法院"])
  }

  func testQuickSendModelNoMatchIsEmptyAndSafe() {
    var model = quickSendModel()
    model.setQuery("zzz-no-such-thing")
    XCTAssertTrue(model.visible.isEmpty)
    XCTAssertTrue(model.isEmpty)
    XCTAssertNil(model.selectedRow)
    XCTAssertNil(model.row(forNumber: 1))
    model.moveSelection(by: 1)  // must not crash / must not resurrect a selection
    XCTAssertNil(model.selectedRow)
    // The full list is still the source of truth (distinguishes "no match" from "nothing configured").
    XCTAssertEqual(model.rows.count, 3)
  }

  func testQuickSendModelSelectionClampsWithinFilteredResults() {
    var model = quickSendModel()
    // Highlight the last (3rd) row, then narrow to a 1-row result → selection clamps to 0.
    model.moveSelection(by: 2)
    XCTAssertEqual(model.selectedRow?.display, "Contract Draft")
    model.setQuery("zg")
    XCTAssertTrue(model.isSelected(0))
    XCTAssertEqual(model.selectedRow?.display, "最高人民法院")
    // ⏎ target + number-1 both resolve to the single filtered row (number keys are 1-based over
    // the FILTERED list); row 2 is out of range now.
    XCTAssertEqual(model.row(forNumber: 1)?.display, "最高人民法院")
    XCTAssertNil(model.row(forNumber: 2))
    // Clearing the query restores the full list; the clamped selection (0) stays valid.
    model.setQuery("")
    XCTAssertEqual(model.visible.count, 3)
    XCTAssertEqual(model.row(forNumber: 3)?.display, "Contract Draft")
  }

  // MARK: - Hotkey preference (PR3)

  /// Both slots default to OFF and round-trip a recorded combo through UserDefaults. The read-back
  /// is the assertion (see owl-app-options-test-fake-coverage — asserting the written string only
  /// would be fake coverage).
  func testHotKeySlotsDefaultToOffAndRoundTripRecordedCombos() {
    for slot in OwlHotKeySlot.allCases.filter({ $0 != .pinCandidate }) {
      restoreDefaultsAfterTest(key: slot.defaultsKey)

      // Default (no stored value) = 未设置 — a global hotkey never claims a key uninvited.
      OwlDefaults.standard.removeObject(forKey: slot.defaultsKey)
      XCTAssertNil(slot.current, "\(slot.displayName) 默认应为未设置")

      let recorded = OwlRecordedHotKey(keyCode: UInt32(kVK_ANSI_K),
                                        modifiers: UInt32(optionKey | cmdKey))
      XCTAssertNotNil(recorded)
      slot.current = recorded
      XCTAssertEqual(slot.current, recorded)
      XCTAssertEqual(slot.current?.label, "⌥⌘K")
      XCTAssertEqual(slot.current?.carbonCombo.keyCode, UInt32(kVK_ANSI_K))

      // nil (off) round-trips too.
      slot.current = nil
      XCTAssertNil(slot.current)
    }
  }

  /// Legacy decoding is per-slot: 划词菜单's retired presets still resolve; 快捷短语面板's Space-based
  /// presets deliberately do NOT (they're outside the recordable range — upgrading migrates them to
  /// 未设置, product decision 2026-07-19).
  func testLegacyPresetRawValuesDecodePerSlot() {
    restoreDefaultsAfterTest(key: OwlHotKeySlot.selectionMenu.defaultsKey)
    restoreDefaultsAfterTest(key: OwlHotKeySlot.quickSendPanel.defaultsKey)

    OwlDefaults.standard.set("ctrlShiftA", forKey: OwlHotKeySlot.selectionMenu.defaultsKey)
    XCTAssertEqual(OwlHotKeySlot.selectionMenu.current?.carbonCombo.keyCode, UInt32(kVK_ANSI_A))
    XCTAssertEqual(OwlHotKeySlot.selectionMenu.current?.carbonCombo.modifiers,
                   UInt32(controlKey | shiftKey))

    for legacy in ["ctrlShiftSpace", "cmdShiftSpace", "optShiftSpace", "off"] {
      OwlDefaults.standard.set(legacy, forKey: OwlHotKeySlot.quickSendPanel.defaultsKey)
      XCTAssertNil(OwlHotKeySlot.quickSendPanel.current,
                   "快捷短语面板旧预设 \(legacy) 应迁移为未设置")
    }
  }

  func testRecordedHotKeyRecordingRangeIsRestricted() {
    // Single-modifier combos shadow app shortcuts (⌘A = select all) — rejected.
    XCTAssertNil(OwlRecordedHotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey)))
    // No modifiers = plain typing — rejected.
    XCTAssertNil(OwlRecordedHotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: 0))
    // Non-letter main keys (Space, digits, …) — rejected. Space staying out of range is what
    // migrates the retired 快捷短语面板 presets to 未设置.
    XCTAssertNil(OwlRecordedHotKey(keyCode: UInt32(kVK_Space),
                                    modifiers: UInt32(controlKey | shiftKey)))
    XCTAssertNil(OwlRecordedHotKey(keyCode: UInt32(kVK_ANSI_1),
                                    modifiers: UInt32(controlKey | shiftKey)))
    // Two+ modifiers + a letter is the allowed shape.
    XCTAssertNotNil(OwlRecordedHotKey(keyCode: UInt32(kVK_ANSI_A),
                                       modifiers: UInt32(controlKey | shiftKey)))

    // The recorder's NSEvent conversion feeds the same validation.
    XCTAssertEqual(
      OwlRecordedHotKey.fromRecordedEvent(keyCode: UInt16(kVK_ANSI_A),
                                           flags: [.control, .shift])?.carbonCombo.modifiers,
      UInt32(controlKey | shiftKey))
    XCTAssertNil(OwlRecordedHotKey.fromRecordedEvent(keyCode: UInt16(kVK_ANSI_A),
                                                      flags: [.command]))
  }

  /// IMK-path matcher (#118): exact ⌃⌥⇧⌘ set equality with Carbon semantics — extra held
  /// modifiers don't match; capsLock/fn noise is ignored.
  func testHotKeyMatcherExactModifierSetSemantics() {
    let combo = (keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey))
    XCTAssertTrue(OwlHotKeyMatcher.matches(combo, keyCode: UInt16(kVK_Space),
                                            flags: [.control, .shift]))
    XCTAssertTrue(OwlHotKeyMatcher.matches(combo, keyCode: UInt16(kVK_Space),
                                            flags: [.control, .shift, .capsLock]))
    XCTAssertFalse(OwlHotKeyMatcher.matches(combo, keyCode: UInt16(kVK_Space),
                                             flags: [.control, .shift, .command]))
    XCTAssertFalse(OwlHotKeyMatcher.matches(combo, keyCode: UInt16(kVK_Space),
                                             flags: [.control]))
    XCTAssertFalse(OwlHotKeyMatcher.matches(combo, keyCode: UInt16(kVK_ANSI_A),
                                             flags: [.control, .shift]))
  }

  /// Hyper（⌃⌥⇧⌘ 四修饰键全按）必须可录、可存、可匹配——07-21 机主点名支持。校验规则是
  /// 「字母 + ≥2 修饰键」，四个是合法上界；此测试锁死这一点，防止未来把校验收紧时误杀。
  func testHyperComboIsRecordableRoundTrippableAndMatchable() {
    let hyperFlags: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    let recorded = OwlRecordedHotKey.fromRecordedEvent(
      keyCode: UInt16(kVK_ANSI_P), flags: hyperFlags)
    XCTAssertNotNil(recorded, "Hyper+P 必须落在可录范围内")
    XCTAssertEqual(recorded?.label, "⌃⌥⇧⌘P")

    // 编码 → 解码往返不丢修饰键。
    let encoded = OwlRecordedHotKey.encode(recorded!)
    XCTAssertEqual(encoded, "ctrl+opt+shift+cmd+P")
    let decoded = OwlRecordedHotKey.decode(encoded, legacyPresets: [:])
    XCTAssertEqual(decoded, recorded)

    // 匹配器：四修饰键精确命中；少一个修饰键不命中（防误触）。
    XCTAssertTrue(
      OwlHotKeyMatcher.matches(
        recorded!.carbonCombo, keyCode: UInt16(kVK_ANSI_P), flags: hyperFlags))
    XCTAssertFalse(
      OwlHotKeyMatcher.matches(
        recorded!.carbonCombo, keyCode: UInt16(kVK_ANSI_P),
        flags: [.control, .option, .shift]))
  }

  /// All slots record from the SAME range, so a duplicate combo is representable — and the
  /// matchers check in allCases order, which would silently dead-end the losing feature. The
  /// recorder rejects a combo held by ANY other slot; `counterparts` is the set it consults.
  func testSlotCounterpartPairingGuardsAgainstDuplicateCombos() {
    // askAnything 槽已退役（2026-07-26）：任意提问只从划词菜单点进，不再有直达热键。
    XCTAssertEqual(OwlHotKeySlot.quickSendPanel.counterparts, [.selectionMenu, .pinCandidate])
    XCTAssertEqual(OwlHotKeySlot.selectionMenu.counterparts, [.quickSendPanel, .pinCandidate])

    restoreDefaultsAfterTest(key: OwlHotKeySlot.quickSendPanel.defaultsKey)
    restoreDefaultsAfterTest(key: OwlHotKeySlot.selectionMenu.defaultsKey)

    let combo = OwlRecordedHotKey(keyCode: UInt32(kVK_ANSI_J),
                                   modifiers: UInt32(controlKey | optionKey))
    OwlHotKeySlot.quickSendPanel.current = combo
    XCTAssertTrue(OwlHotKeySlot.selectionMenu.counterparts.contains { $0.current == combo },
                  "划词菜单录制时应能读到快捷短语面板已占用的组合")
  }

  // MARK: - Helpers

  /// Snapshot a UserDefaults key and restore it when the test ends.
  private func restoreDefaultsAfterTest(key: String) {
    let saved = OwlDefaults.standard.string(forKey: key)
    addTeardownBlock {
      if let saved { OwlDefaults.standard.set(saved, forKey: key) } else {
        OwlDefaults.standard.removeObject(forKey: key)
      }
    }
  }

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("OwlQuickSendTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }
}

/// The session tap's consume rule (2026-10-29 typing freeze): the tap now runs off the main thread,
/// so the decision is a pure function of the key, the stored combos and two flags main keeps current.
extension OwlQuickSendPanelModelTests {
  private func tapSlot(keyCode: Int, flags: NSEvent.ModifierFlags, suppressed: Bool = false,
                       owltypeIsCurrent: Bool = true) -> OwlHotKeySlot? {
    let combos: [OwlHotKeySlot: (keyCode: UInt32, modifiers: UInt32)] = [
      .quickSendPanel: (UInt32(kVK_ANSI_J), UInt32(controlKey | optionKey)),
      .selectionMenu: (UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey)),
      .pinCandidate: (UInt32(kVK_ANSI_P), UInt32(controlKey | shiftKey))
    ]
    return OwlHotKeyEventTap.slotToConsume(
      keyCode: UInt16(keyCode), flags: flags, suppressed: suppressed,
      owltypeIsCurrent: owltypeIsCurrent, combo: { combos[$0] })
  }

  func testEventTapConsumesOnlyAMatchedComboWhileOwltypeIsCurrent() {
    XCTAssertEqual(tapSlot(keyCode: kVK_ANSI_J, flags: [.control, .option]), .quickSendPanel)
    XCTAssertEqual(tapSlot(keyCode: kVK_ANSI_K, flags: [.control, .option]), .selectionMenu)
    XCTAssertNil(tapSlot(keyCode: kVK_ANSI_J, flags: [.control, .option], owltypeIsCurrent: false),
                 "another input source keeps the combo")
    XCTAssertNil(tapSlot(keyCode: kVK_ANSI_J, flags: [.control, .option], suppressed: true),
                 "the recorder must see the combo")
    XCTAssertNil(tapSlot(keyCode: kVK_ANSI_J, flags: [.shift]), "shift-typing passes")
    XCTAssertNil(tapSlot(keyCode: kVK_ANSI_J, flags: []), "plain typing passes")
    XCTAssertNil(tapSlot(keyCode: kVK_ANSI_P, flags: [.control, .shift]),
                 "pinning belongs to the IMK path with live candidates")
  }

  func testEventTapFlagsAreSharedAcrossThreads() {
    let saved = OwlHotKeyEventTap.isSuppressed
    defer { OwlHotKeyEventTap.isSuppressed = saved }
    OwlHotKeyEventTap.isSuppressed = true
    let read = expectation(description: "tap thread reads the recorder's flag")
    Thread {
      XCTAssertTrue(OwlHotKeyEventTap.isSuppressed)
      read.fulfill()
    }.start()
    wait(for: [read], timeout: 2)
  }
}
