import XCTest
@testable import Owltype

@MainActor
final class OwlTemplateCursorTests: XCTestCase {
  private func entry(_ body: String) -> OwlTemplateEntry {
    var value = OwlTemplateEntry(title: "合成光标", body: body)
    value.bodyType = .template
    return value
  }

  func testFinalExpansionOffsetsAndFrozenValues() {
    let invocation = OwlTemplateInvocation(content: .template(entry("{clipboard}/{argument name=x}/{date format=yyyy-MM-dd}\n{cursor}尾")),
      broker: OwlPanelInsertionBroker(), deliver: nil, intent: .resultPreview,
      captureContext: { _ in .init(clipboard: .text("中😀"), temporal: .init(date: Date(timeIntervalSince1970: 0),
        timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US_POSIX"), calendar: Calendar(identifier: .gregorian))) })
    let result = invocation.preview(values: ["n:x": "e\u{301}"])
    XCTAssertEqual(result.text, "中😀/e\u{301}/1970-01-01\n尾")
    XCTAssertEqual(result.cursorOffset, 18)
  }

  func testCursorLiteralsDuplicatesAndAttributes() {
    XCTAssertNotNil(OwlTemplateEngine.render(OwlTemplateEngine.parse(entry("{cursor}{cursor}")), values: [:]).diagnostics.first { $0.severity == .error })
    for body in ["{cursor format=x}", "{cursor|uppercase}", "{cursor"] {
      XCTAssertNil(OwlTemplateEngine.render(OwlTemplateEngine.parse(entry(body)), values: [:]).readyText)
    }
    for syntax in [OwlTemplateEntry.Syntax.standard, .legacyDoubleBraces] {
      let parsed = OwlTemplateEngine.parse(body: "{cursor}", bodyType: .plainText, syntax: syntax)
      XCTAssertEqual(OwlTemplateEngine.render(parsed, values: [:]).readyText, "{cursor}")
    }
    let legacy = OwlTemplateEngine.parse(body: "{{cursor}}{cursor}", syntax: .legacyDoubleBraces)
    XCTAssertEqual(OwlTemplateEngine.render(legacy, values: ["n:cursor": "值"]).readyText, "值{cursor}")
    let parsed = OwlTemplateEngine.parse(entry("{argument name=x}{cursor}"))
    let result = OwlTemplateEngine.render(parsed, values: ["n:x": "{cursor}"])
    XCTAssertEqual(result.readyText, "{cursor}")
    XCTAssertEqual(result.cursorOffset, 8)
  }

  func testUnicodeOffsetsAndCrossTokenBoundaries() {
    for (prefix, length) in [("中文", 2), ("中😀", 3), ("e\u{301}", 2), ("👩‍💻", 5), ("🇨🇳", 4), ("甲\r\n", 3), ("", 0)] {
      let result = OwlTemplateEngine.render(OwlTemplateEngine.parse(entry(prefix + "{cursor}尾")), values: [:])
      XCTAssertEqual(result.cursorOffset, length)
      XCTAssertEqual(result.readyText, prefix + "尾")
    }
    for body in ["e{cursor}\u{301}", "👩{cursor}\u{200D}💻", "\r{cursor}\n", "{cursor}"] {
      XCTAssertNil(OwlTemplateEngine.render(OwlTemplateEngine.parse(entry(body)), values: [:]).readyText)
    }
  }

  func testTailIsLiteralAndFinalBoundaryIsValidated() {
    let invocation = OwlTemplateInvocation(content: .template(entry("甲{cursor}尾")), broker: OwlPanelInsertionBroker(),
      deliver: nil, trailingText: "\n{cursor}")
    XCTAssertEqual(invocation.preview(values: [:]), .init(text: "甲尾\n{cursor}", cursorOffset: 1))
    let split = OwlTemplateInvocation(content: .template(entry("e{cursor}")), broker: OwlPanelInsertionBroker(),
      deliver: nil, trailingText: "\u{301}")
    XCTAssertFalse(split.confirm(values: [:]))
  }

  func testExplicitPendingReviewOnlyUnlocksSupportedCursor() {
    var value = entry("前{cursor}后")
    value.reviewState = .pending
    XCTAssertTrue(OwlTemplateEngine.parse(value).contextRequirements.isEmpty)
    XCTAssertTrue(OwlRaycastImport.enableAfterReview(&value))
    XCTAssertFalse(value.isPendingReview)
    for body in ["{cursor}{clipboard offset=1}", "{cursor}{snippet name=x}", "{cursor}{{legacy}}", "{cursor}{cursor}"] {
      var pending = entry(body); pending.reviewState = .pending
      XCTAssertFalse(OwlRaycastImport.enableAfterReview(&pending))
      XCTAssertTrue(pending.isPendingReview)
    }
  }

  func testEditorAddsOneCursorAndFailedSaveDoesNotPublishReviewedEntry() throws {
    let model = OwlTemplateEditorModel(write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    model.draft = entry("前")
    XCTAssertTrue(model.insertCursorField())
    let once = model.draft
    XCTAssertFalse(model.insertCursorField())
    XCTAssertEqual(model.draft, once)
    XCTAssertThrowsError(try OwlTemplateStore.validate(.init(entries: [entry("前{cursor}{cursor}")])))
    var pending = entry("前{cursor}后"); pending.reviewState = .pending
    model.library.entries = [pending]; model.draft = pending
    XCTAssertTrue(model.enableReviewedDraft())
    XCTAssertFalse(model.draft.isPendingReview)
    XCTAssertFalse(model.save())
    XCTAssertTrue(try XCTUnwrap(model.library.entries.first).isPendingReview)
  }

  func testBoundedHostContextRejectsHiddenEmojiPrefixAndCombiningSuffix() {
    let prefix = "👩" + String(repeating: "\u{FE0F}", count: 40) + "\u{200D}"
    let full = prefix + "💻尾"
    let offset = prefix.utf16.count
    XCTAssertFalse(OwlTemplateCursorPlacement.isBoundary(offset, in: full))
    let clipped = (full as NSString).substring(from: offset - 32)
    XCTAssertFalse(OwlTemplateCursorPlacement.isHostBoundary(32, in: clipped, startsAtDocumentStart: false))
    let tagPrefix = "👩" + String(repeating: "\u{E0020}", count: 40) + "\u{FE0F}\u{200D}"
    let tagFull = tagPrefix + "💻尾"
    let tagOffset = tagPrefix.utf16.count
    XCTAssertFalse(OwlTemplateCursorPlacement.isBoundary(tagOffset, in: tagFull))
    let tagClipped = (tagFull as NSString).substring(from: tagOffset - 32)
    XCTAssertFalse(OwlTemplateCursorPlacement.isHostBoundary(32, in: tagClipped, startsAtDocumentStart: false))
    XCTAssertFalse(OwlTemplateCursorPlacement.isHostBoundary(1, in: "e\u{301}", startsAtDocumentStart: true))
    XCTAssertTrue(OwlTemplateCursorPlacement.isHostBoundary(3, in: "中😀尾", startsAtDocumentStart: false))
    XCTAssertFalse(OwlTemplateCursorPlacement.isHostBoundary(2, in: "🏽尾", startsAtDocumentStart: false))
    XCTAssertFalse(OwlTemplateCursorPlacement.isHostBoundary(2, in: "\u{FFFD}\u{200D}💻", startsAtDocumentStart: false))
  }

  func testPurePlacementRejectsWrongReadbackAndOverflow() {
    XCTAssertEqual(OwlTemplateCursorPlacement.target(text: "中😀尾", offset: 3, base: 8,
      selection: NSRange(location: 12, length: 0), readback: "中😀尾"), NSRange(location: 11, length: 0))
    XCTAssertNil(OwlTemplateCursorPlacement.target(text: "e\u{301}", offset: 2, base: 0,
      selection: NSRange(location: 2, length: 0), readback: "é"))
    XCTAssertNil(OwlTemplateCursorPlacement.target(text: "😀", offset: 1, base: 0,
      selection: NSRange(location: 2, length: 0), readback: "😀"))
    XCTAssertNil(OwlTemplateCursorPlacement.target(text: "abc", offset: 1, base: Int.max - 1,
      selection: NSRange(location: 0, length: 0), readback: "abc"))
  }
}
