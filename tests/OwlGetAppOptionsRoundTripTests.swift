//
//  OwlGetAppOptionsRoundTripTests.swift
//  OwltypeTests
//
//  Regression coverage for the app-options config boundary without installing Rime
//  or touching a real user directory. The base YAML and its `.custom.yaml` patch are
//  synthetic temporary files loaded through the production Rust-backed OwlConfig.
//

import XCTest
@testable import Owltype

final class OwlGetAppOptionsRoundTripTests: XCTestCase {
  private static let testBundleID = "com.owltype.test.roundtrip"

  private var temporaryRoot: URL!
  private var sharedSupport: URL!
  private var userData: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("owl-config-\(UUID().uuidString)", isDirectory: true)
    sharedSupport = temporaryRoot.appendingPathComponent("SharedSupport", isDirectory: true)
    userData = temporaryRoot.appendingPathComponent("UserData", isDirectory: true)
    try FileManager.default.createDirectory(at: sharedSupport, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)

    try """
    # synthetic base
    keyboard_layout: last
    chord_duration: 0.1
    style:
      candidate_list_layout: stacked
      inline_preedit: true
      inline_candidate: false
    app_options:
      com.apple.Terminal:
        ascii_mode: true
        no_inline: true
    """.write(
      to: sharedSupport.appendingPathComponent("owltype.yaml"),
      atomically: true,
      encoding: .utf8
    )

    try """
    # The write side emits quoted flat paths under a Rime-style patch map.
    patch:
      "app_options/\(Self.testBundleID)/ascii_mode": true
      style/inline_preedit: false
    """.write(
      to: userData.appendingPathComponent("owltype.custom.yaml"),
      atomically: true,
      encoding: .utf8
    )
  }

  override func tearDownWithError() throws {
    if let temporaryRoot {
      try? FileManager.default.removeItem(at: temporaryRoot)
    }
    try super.tearDownWithError()
  }

  private func openConfig() -> OwlConfig {
    let config = OwlConfig(sharedSupportURL: sharedSupport, userDataURL: userData)
    XCTAssertTrue(config.openBaseConfig())
    return config
  }

  func testUserAddedAppOptionReadsBackFromOwltypeDomain() {
    XCTAssertEqual(openConfig().getAppOptions(Self.testBundleID), ["ascii_mode": true])
  }

  func testFactoryPresetAndStylePatchReadBackTogether() {
    let config = openConfig()
    XCTAssertEqual(
      config.getAppOptions("com.apple.Terminal"),
      ["ascii_mode": true, "no_inline": true]
    )
    XCTAssertTrue(config.has(section: "style"))
    XCTAssertEqual(config.getString("style/candidate_list_layout"), "stacked")
    XCTAssertEqual(config.getBool("style/inline_preedit"), false)
    XCTAssertEqual(config.getDouble("chord_duration"), 0.1)
    XCTAssertNil(config.getString("missing"))
  }

  func testSchemaStyleOverlaysGlobalAndFallsBackToBaseConfig() throws {
    try """
    name: Synthetic
    style:
      candidate_list_layout: linear
      text_orientation: vertical
    """.write(
      to: sharedSupport.appendingPathComponent("synthetic.schema.yaml"),
      atomically: true,
      encoding: .utf8
    )
    try """
    patch:
      style/text_orientation: horizontal
    """.write(
      to: userData.appendingPathComponent("synthetic.custom.yaml"),
      atomically: true,
      encoding: .utf8
    )

    let global = openConfig()
    let schema = OwlConfig(sharedSupportURL: sharedSupport, userDataURL: userData)
    XCTAssertTrue(schema.open(schemaID: "synthetic", baseConfig: global))
    XCTAssertTrue(schema.has(section: "style"))
    XCTAssertEqual(schema.getString("style/candidate_list_layout"), "linear")
    XCTAssertEqual(schema.getString("style/text_orientation"), "horizontal")
    XCTAssertEqual(schema.getBool("style/inline_preedit"), false) // global fallback
  }

  func testMalformedPatchFailsWithoutTouchingAnotherConfig() throws {
    try "patch: [\n".write(
      to: userData.appendingPathComponent("owltype.custom.yaml"),
      atomically: true,
      encoding: .utf8
    )
    let config = OwlConfig(sharedSupportURL: sharedSupport, userDataURL: userData)
    XCTAssertFalse(config.openBaseConfig())
    XCTAssertFalse(config.isOpen)
    XCTAssertFalse(config.has(section: "style"))
  }

  func testRejectedSchemaIDClosesPreviouslyOpenedConfig() {
    let config = openConfig()
    XCTAssertFalse(config.open(schemaID: "../escape", baseConfig: nil))
    XCTAssertFalse(config.isOpen)
    XCTAssertFalse(config.has(section: "style"))
  }
}
