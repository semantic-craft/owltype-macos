//
//  OwlQuickSendPanelModelTests.swift
//  猫头鹰输入法 (Owltype) — 快捷短语面板 model tests
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

  func testQuickSendPanelModelBuildsListFromStoreAndNavigates() throws {
    let dir = try makeTempDir()
    // Legacy dict-only dir (no JSON): text<TAB>code lines, plus a comment line the store must skip.
    // The migration read normalizes → rows come back sorted by code (fy < pjzy < zg).
    let file = dir.appendingPathComponent(OwlQuickSendStore.dictFileName)
    try "# comment\n北京市朝阳区人民法院\tfy\n最高人民法院\tzg\n判决摘要\tpjzy\n"
      .write(to: file, atomically: true, encoding: .utf8)

    var model = OwlPickerPanelModel(
      rows: OwlQuickSendStore.load(dataDir: dir).map(OwlPickerRow.quickSend)
    )
    XCTAssertEqual(model.rows.map(\.display), ["北京市朝阳区人民法院", "判决摘要", "最高人民法院"])
    XCTAssertEqual(model.rows.map(\.id), ["fy", "pjzy", "zg"])
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
    let dir = try makeTempDir()  // no owl_quick_send.txt written
    let model = OwlPickerPanelModel(
      rows: OwlQuickSendStore.load(dataDir: dir).map(OwlPickerRow.quickSend)
    )
    XCTAssertTrue(model.isEmpty)
    XCTAssertNil(model.selectedRow)
    XCTAssertNil(model.row(forNumber: 1))
    var mutated = model
    mutated.moveSelection(by: 1)  // must not crash on empty
    XCTAssertNil(mutated.selectedRow)
  }

  // MARK: - 快捷短语 → row mapping

  func testQuickSendRowMappingBuildsDisplayAndSearchableCode() {
    let row = OwlPickerRow.quickSend(OwlQuickSendEntry(text: "最高人民法院", code: "zgfy"))
    XCTAssertEqual(row.id, "zgfy")
    XCTAssertEqual(row.display, "最高人民法院")           // list shows the phrase
    XCTAssertTrue(row.searchText.contains("最高人民法院"))  // searchable by phrase…
    XCTAssertTrue(row.searchText.contains("zgfy"))       // …and by trigger code
  }

  // The 提示词 source maps into the SAME picker row: the list shows the (single-line) title, and the
  // row is searchable by title OR trigger code. The body/variables stay on the source entry, resolved
  // back by `id` at pick time — so the row deliberately does NOT carry them.
  func testPromptRowMappingShowsTitleAndKeepsIdForBodyLookup() {
    let entry = OwlPromptEntry(code: "dbz", title: "民事答辩状模板", body: "答辩人：{{当事人}}……")
    let row = OwlPickerRow.prompt(entry)
    XCTAssertEqual(row.id, "dbz")                        // id = code → resolves back to the entry
    XCTAssertEqual(row.display, "民事答辩状模板")           // list shows the title, never the body
    XCTAssertFalse(row.display.contains("答辩人"))          // body must not leak into the row
    XCTAssertTrue(row.searchText.contains("民事答辩状模板"))  // searchable by title…
    XCTAssertTrue(row.searchText.contains("dbz"))          // …and by trigger code
  }

  // MARK: - typed-search filter

  // The typed-search filter is the one part of the panel that IS unit-testable. Filtering is a
  // case-insensitive substring on the row's `searchText` (phrase text OR trigger code for 快捷短语);
  // an empty query = the full list; selection / number keys operate on the FILTERED rows and stay
  // clamped.
  private func quickSendModel() -> OwlPickerPanelModel {
    OwlPickerPanelModel(rows: [
      OwlQuickSendEntry(text: "北京市朝阳区人民法院", code: "fybj"),
      OwlQuickSendEntry(text: "最高人民法院", code: "zgfy"),
      OwlQuickSendEntry(text: "Contract Draft", code: "cd")
    ].map(OwlPickerRow.quickSend))
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
    XCTAssertEqual(OwlHotKeySlot.quickSendPanel.counterparts, [.selectionMenu, .promptAssistant, .pinCandidate])
    XCTAssertEqual(OwlHotKeySlot.selectionMenu.counterparts, [.quickSendPanel, .promptAssistant, .pinCandidate])
    XCTAssertEqual(OwlHotKeySlot.promptAssistant.counterparts, [.quickSendPanel, .selectionMenu, .pinCandidate])

    restoreDefaultsAfterTest(key: OwlHotKeySlot.quickSendPanel.defaultsKey)
    restoreDefaultsAfterTest(key: OwlHotKeySlot.selectionMenu.defaultsKey)
    restoreDefaultsAfterTest(key: OwlHotKeySlot.promptAssistant.defaultsKey)

    let combo = OwlRecordedHotKey(keyCode: UInt32(kVK_ANSI_J),
                                   modifiers: UInt32(controlKey | optionKey))
    OwlHotKeySlot.quickSendPanel.current = combo
    XCTAssertTrue(OwlHotKeySlot.selectionMenu.counterparts.contains { $0.current == combo },
                  "划词菜单录制时应能读到快捷短语面板已占用的组合")
    XCTAssertTrue(OwlHotKeySlot.promptAssistant.counterparts.contains { $0.current == combo },
                  "提示词助手录制时同样应看到该组合已被占用")
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
