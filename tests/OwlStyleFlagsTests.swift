//
//  OwlStyleFlagsTests.swift
//  OwltypeTests — OwlStyleFlags defaults and panel-preference layout derivation
//

import XCTest
@testable import Owltype

final class OwlStyleFlagsTests: XCTestCase {
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    defaults = makeIsolatedDefaults(prefix: "OwlStyleFlagsTests")
  }

  override func tearDown() {
    defaults = nil
    super.tearDown()
  }

  func testDefaultsAreInlineLinearWithMixStatusMessage() {
    let flags = OwlStyleFlags()
    XCTAssertTrue(flags.linear)
    XCTAssertFalse(flags.vertical)
    XCTAssertTrue(flags.inlinePreedit)
    XCTAssertFalse(flags.inlineCandidate)
    XCTAssertEqual(flags.statusMessageType, .mix)
  }

  func testApplyLayoutPreferencesDerivesLinearAndVerticalFromOrientation() {
    let catalog = NoReadFontCatalog()
    let settings = OwlCandidatePanelSettings(defaults: defaults, fontCatalog: catalog)
    let cases: [(OwlPanelOrientation, Bool, Bool)] = [
      (.vertical, false, true),
      (.horizontal, true, false),
      (.scroll, true, false),
      (.auto, true, false)
    ]

    for (orientation, expectedLinear, expectedVertical) in cases {
      defaults.set(orientation.rawValue, forKey: "OwlPanelOrientation")
      var style = OwlStyleFlags()
      settings.applyLayoutPreferences(to: &style)
      XCTAssertEqual(style.linear, expectedLinear, "linear for \(orientation)")
      XCTAssertEqual(style.vertical, expectedVertical, "vertical for \(orientation)")
      XCTAssertTrue(style.inlinePreedit)
      XCTAssertFalse(style.inlineCandidate)
    }
    XCTAssertEqual(catalog.readCount, 0, "layout preference derivation must not touch font catalog")
  }

  func testApplyLayoutPreferencesPropagatesInlineCandidateAndAlwaysKeepsInlinePreedit() {
    let settings = OwlCandidatePanelSettings(defaults: defaults, fontCatalog: NoReadFontCatalog())
    defaults.set(true, forKey: "OwlPanelInlineCandidate")
    var style = OwlStyleFlags(linear: false, vertical: true, inlinePreedit: false, inlineCandidate: false)

    settings.applyLayoutPreferences(to: &style)

    XCTAssertTrue(style.inlinePreedit)
    XCTAssertTrue(style.inlineCandidate)
  }
}

private final class NoReadFontCatalog: OwlCandidateFontCatalog {
  private(set) var readCount = 0

  func availableFontFamilies() -> [String] {
    readCount += 1
    return []
  }
}
