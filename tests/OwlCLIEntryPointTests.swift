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
  func testRetiredRimeCommandsAreRejectedAndNotAdvertised() {
    XCTAssertEqual(
      OwlApp.retiredCLIArguments,
      Set(["--apply-keyboard-patch", "--build", "--diagnose-rime-config", "--sync"])
    )
    for argument in OwlApp.retiredCLIArguments {
      XCTAssertFalse(OwlApp.helpDoc.contains(argument), argument)
    }
  }
}
