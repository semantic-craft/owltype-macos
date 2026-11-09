//
//  OwlCLIEntryPointTests.swift
//  OwltypeTests
//
//  Locks the retired Rime command surface while the daemon, installer and
//  diagnosis CLI paths remain supported.
//

import XCTest
@testable import Owltype

final class OwlCLIEntryPointTests: XCTestCase {
  func testHelpDocAdvertisesOnlySupportedCommands() {
    for argument in ["--apply-keyboard-patch", "--build", "--diagnose-rime-config", "--sync"] {
      XCTAssertFalse(OwlApp.helpDoc.contains(argument), argument)
    }
    XCTAssertTrue(OwlApp.helpDoc.contains("--diagnose-tis"))
    XCTAssertTrue(OwlApp.helpDoc.contains("--ui-test-show-settings"))
  }
}
