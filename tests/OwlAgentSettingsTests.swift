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

  func testTestHostRoutesTemplatesAndAgentLogToItsOwnDataRoot() throws {
    XCTAssertTrue(OwlTestStorage.isEnabled)
    XCTAssertTrue(OwlApp.userDir.path.hasPrefix(OwlTestStorage.root.path + "/"))
    XCTAssertEqual(OwlAgentBridge.defaultSocketURL.deletingLastPathComponent(),
                   OwlApp.userDir.appendingPathComponent("AgentBridge", isDirectory: true))
    let entry = OwlTemplateEntry(title: "isolated acceptance", body: "synthetic")
    let original = OwlTemplateStore.mode() == .empty ? OwlTemplateLibrary(entries: []) : try OwlTemplateStore.load()
    defer { try? OwlTemplateStore.save(original) }
    try OwlTemplateStore.save(OwlTemplateLibrary(entries: [entry]))
    XCTAssertEqual(try OwlTemplateStore.load().entries.map(\.id), [entry.id])
  }

  func testDefaultAgentSwitchAndServiceUseIsolatedPreferences() throws {
    XCTAssertTrue(OwlTestStorage.isEnabled)
    let isolated = OwlDefaults.standard
    let key = OwlAgentAccessPreferences.enabledKey
    let previous = isolated.object(forKey: key)
    let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
    let dailyBefore = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
    defer {
      if let previous { isolated.set(previous, forKey: key) } else { isolated.removeObject(forKey: key) }
    }
    // Prove the read path first: a regression must fail without writing the daily domain.
    for enabled in [false, true] {
      isolated.set(enabled, forKey: key)
      guard OwlAgentAccessPreferences.isEnabled() == enabled else {
        XCTFail("Default Agent preference read escaped the isolated suite; no default write attempted")
        return
      }
    }
    let log = OwlAgentCallLog(fileURL: nil)
    let access = OwlAgentAccess(callLog: log)
    access.loadLibrary = { OwlTemplateLibrary() }
    let client = OwlAgentBridgeClient(helper: .init(name: "owltype-mcp", version: "0.1.0"),
                                      agentClient: nil, processID: 1)
    for enabled in [false, true, false] {
      log.clear()
      OwlAgentAccessPreferences.setEnabled(enabled)
      XCTAssertEqual(isolated.bool(forKey: key), enabled)
      XCTAssertEqual(OwlAgentAccessPreferences.isEnabled(), enabled)
      access.handle(.templatesList, from: client, cancellation: OwlAgentBridgeCancellation()) { _ in }
      XCTAssertEqual(log.records.last?.outcome, enabled ? "ok" : "agent_access_disabled")
      let dailyAfter = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
      XCTAssertTrue(NSDictionary(dictionary: dailyBefore).isEqual(to: dailyAfter), "Daily preferences changed")
    }
    print("OWL_AGENT_ISOLATION_SUITE=" + OwlDefaults.testSuiteName)
  }

  func testGrokSnippetsPointAtTheBundledHelper() {
    let path = "/Library/Input Methods/Owltype.app/Contents/Helpers/owltype-mcp"
    let config = OwlAgentSettings.cliConfig(helperPath: path)
    XCTAssertEqual(config.agyCommand,
                   "agy mcp add owltype '/Library/Input Methods/Owltype.app/Contents/Helpers/owltype-mcp'")
    XCTAssertEqual(config.grokCommand,
                   "grok mcp add owltype '/Library/Input Methods/Owltype.app/Contents/Helpers/owltype-mcp'")
    XCTAssertEqual(config.grokConfig, """
      [mcp_servers.owltype]
      command = "/Library/Input Methods/Owltype.app/Contents/Helpers/owltype-mcp"
      tool_timeout_sec = 610
      """)
    let quoted = OwlAgentSettings.cliConfig(helperPath: "/tmp/it's/owltype-mcp")
    XCTAssertEqual(quoted.agyCommand, #"agy mcp add owltype '/tmp/it'\''s/owltype-mcp'"#)
    XCTAssertGreaterThan(610 * 1000, Wire.deliverTimeoutRangeMs.upperBound,
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
