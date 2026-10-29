//
//  OwlAgentSettingsTests.swift
//  OwltypeTests
//
//  设置 → Agent 接入: the Grok Build snippets, per-template exposure and the redacted call log.
//

import XCTest
@testable import Owltype

final class OwlAgentSettingsTests: XCTestCase {
  private typealias Wire = OwlAgentBridgeProtocol

  func testGrokSnippetsPointAtTheBundledHelper() {
    let path = "/Library/Input Methods/Owltype.app/Contents/Helpers/owltype-mcp"
    XCTAssertEqual(OwlAgentSettings.agyCommand(helperPath: path),
                   "agy mcp add owltype '/Library/Input Methods/Owltype.app/Contents/Helpers/owltype-mcp'")
    XCTAssertEqual(OwlAgentSettings.grokCommand(helperPath: path),
                   "grok mcp add owltype '/Library/Input Methods/Owltype.app/Contents/Helpers/owltype-mcp'")
    XCTAssertEqual(OwlAgentSettings.grokConfig(helperPath: path), """
      [mcp_servers.owltype]
      command = "/Library/Input Methods/Owltype.app/Contents/Helpers/owltype-mcp"
      tool_timeout_sec = 610
      """)
    XCTAssertEqual(OwlAgentSettings.shellQuoted("it's"), #"'it'\''s'"#)
    XCTAssertGreaterThan(OwlAgentSettings.toolTimeoutSeconds * 1000, Wire.deliverTimeoutRangeMs.upperBound,
                         "Grok must outwait the longest confirmation window")
    let bundle = Bundle(url: URL(fileURLWithPath: "/Library/Input Methods/Owltype.app")) ?? .main
    XCTAssertTrue(OwlAgentSettings.helperPath(bundle: bundle).hasSuffix("Owltype.app/Contents/Helpers/owltype-mcp"))
  }

  func testExposureIsSavedPerTemplateAgainstTheLibraryRead() throws {
    let first = OwlTemplateEntry(title: "签名", body: "此致")
    let second = OwlTemplateEntry(title: "问候", body: "你好")
    var pending = OwlTemplateEntry(title: "导入", body: "x")
    pending.reviewState = .pending
    let library = OwlTemplateLibrary(entries: [first, second, pending])
    XCTAssertEqual(OwlAgentSettings.listedTemplates(library).map(\.id).sorted { $0.uuidString < $1.uuidString },
                   [first.id, second.id].sorted { $0.uuidString < $1.uuidString }, "pending imports are not offered")

    var saved: [(OwlTemplateLibrary, OwlTemplateLibrary)] = []
    let next = try OwlAgentSettings.setExposed(true, id: second.id, in: library) { saved.append(($0, $1)) }
    XCTAssertEqual(next.entries.map(\.isExposedToAgents), [false, true, false])
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(saved[0].0, next)
    XCTAssertEqual(saved[0].1, library, "saved against the library the page read")

    struct Changed: Error {}
    XCTAssertThrowsError(try OwlAgentSettings.setExposed(false, id: second.id, in: next) { _, _ in throw Changed() })
  }

  func testCallLogKeepsOnlyWhoWhatAndHowItEnded() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owl-agent-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("calls.json")
    let log = OwlAgentCallLog(fileURL: file)
    let client = OwlAgentBridgeClient(helper: .init(name: "owltype-mcp", version: "0.1.0"),
                                      agentClient: .init(name: "grok", version: "1.0.70"), processID: 1)
    let secret = "今天的发版改到下午三点"
    let deliver = Wire.Call.deliverText(.init(requestId: "r-1", text: secret, timeoutMs: nil))
    let delivered = Wire.DeliverResult(requestId: "r-1", status: .delivered(verified: false), replayed: false)
    log.record(deliver, from: client, reply: .success(OwlJSONValue(encoding: delivered)), at: Date(timeIntervalSince1970: 1))
    log.record(.templateGet(.init(id: UUID().uuidString)), from: client,
               reply: .failure(.init(code: .templateNotFound, message: "Template not found")), at: Date(timeIntervalSince1970: 2))
    log.record(.owltypeStatus, from: OwlAgentBridgeClient(helper: .init(name: "owltype-mcp", version: "0.1.0"), agentClient: nil, processID: 1),
               reply: .success(.object([:])), at: Date(timeIntervalSince1970: 3))
    log.flush()

    XCTAssertEqual(log.records.map(\.method), ["owltype_status", "template_get", "deliver_text"], "newest first")
    XCTAssertEqual(log.records.map(\.outcome), ["ok", "template_not_found", "delivered"])
    XCTAssertEqual(log.records.map(\.client), ["owltype-mcp 0.1.0", "grok 1.0.70", "grok 1.0.70"])
    let stored = try String(contentsOf: file, encoding: .utf8)
    XCTAssertFalse(stored.contains(secret), "delivered text is never logged")
    XCTAssertFalse(stored.contains("r-1"), "request ids are not logged")
    let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
    XCTAssertEqual(mode & 0o777, 0o600)
    XCTAssertEqual(OwlAgentCallLog(fileURL: file).records, log.records, "read back after a restart")

    for index in 0..<(OwlAgentCallLog.limit + 5) {
      log.record(.owltypeStatus, from: client, reply: .success(.object([:])), at: Date(timeIntervalSince1970: Double(10 + index)))
    }
    XCTAssertEqual(log.records.count, OwlAgentCallLog.limit)
    log.clear()
    log.flush()
    XCTAssertEqual(OwlAgentCallLog(fileURL: file).records, [])
  }

  func testConcurrentRecordsAndClearLeaveTheDiskMatchingMemory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owl-agent-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("calls.json")
    let log = OwlAgentCallLog(fileURL: file)
    let client = OwlAgentBridgeClient(helper: .init(name: "owltype-mcp", version: "0.1.0"), agentClient: nil, processID: 1)
    for _ in 0..<20 {
      DispatchQueue.concurrentPerform(iterations: 40) { index in
        if index == 20 { log.clear() } else { log.record(.owltypeStatus, from: client, reply: .success(.object([:]))) }
      }
      log.flush()
      XCTAssertEqual(OwlAgentCallLog(fileURL: file).records.count, log.records.count, "the last write on disk is the latest state")
    }
  }

  func testAccessRecordsEachAnsweredCall() {
    let suite = "OwlAgentSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let log = OwlAgentCallLog(fileURL: nil)
    let access = OwlAgentAccess(defaults: defaults, callLog: log)
    let client = OwlAgentBridgeClient(helper: .init(name: "owltype-mcp", version: "0.1.0"),
                                      agentClient: .init(name: "grok", version: "1.0.70"), processID: 1)
    var answered = 0
    access.handle(.templatesList, from: client, cancellation: OwlAgentBridgeCancellation()) { _ in answered += 1 }
    XCTAssertEqual(answered, 1)
    XCTAssertEqual(log.records.map(\.outcome), ["agent_access_disabled"], "refused calls are recorded too")
    OwlAgentAccessPreferences.setEnabled(true, defaults)
    access.loadLibrary = { OwlTemplateLibrary() }
    access.handle(.templatesList, from: client, cancellation: OwlAgentBridgeCancellation()) { _ in answered += 1 }
    XCTAssertEqual(log.records.map(\.outcome), ["ok", "agent_access_disabled"])
    XCTAssertEqual(log.records.first?.method, "templates_list")
  }
}
