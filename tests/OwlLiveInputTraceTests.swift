//
//  OwlLiveInputTraceTests.swift
//  OwltypeTests
//

import XCTest
@testable import Owltype

final class OwlLiveInputTraceTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var traceURL: URL!

  override func setUp() {
    super.setUp()
    suiteName = "OwlLiveInputTraceTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    traceURL = FileManager.default.temporaryDirectory.appending(component: "famo-trace-\(UUID().uuidString).log")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: traceURL)
    defaults.removePersistentDomain(forName: suiteName)
    suiteName = nil
    defaults = nil
    traceURL = nil
    super.tearDown()
  }

  func testDisabledTraceDoesNotEvaluateMessage() {
    defaults.set(false, forKey: OwlLiveInputTrace.defaultsKey)
    var evaluated = false

    OwlLiveInputTrace.write({
      evaluated = true
      return "expensive"
    }, defaults: defaults, fileURL: traceURL)

    XCTAssertFalse(evaluated)
    XCTAssertFalse(FileManager.default.fileExists(atPath: traceURL.path))
  }

  func testEnabledTraceWritesEvaluatedMessage() throws {
    defaults.set(true, forKey: OwlLiveInputTrace.defaultsKey)
    var evaluationCount = 0

    OwlLiveInputTrace.write({
      evaluationCount += 1
      return "safe metadata only"
    }, defaults: defaults, fileURL: traceURL, now: { Date(timeIntervalSince1970: 0) })

    let output = try String(contentsOf: traceURL)
    XCTAssertEqual(evaluationCount, 1)
    XCTAssertTrue(output.contains("safe metadata only"))
    let permissions = try FileManager.default.attributesOfItem(atPath: traceURL.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
  }
}
