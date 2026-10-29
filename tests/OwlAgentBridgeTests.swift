//
//  OwlAgentBridgeTests.swift
//  OwltypeTests
//
//  The bridge socket end to end with a real Unix socket: private directory and socket modes, the
//  hello rule, peer refusal, timeouts, cancellation on disconnect, and the access switch.
//

import Darwin
import XCTest
@testable import Owltype

/// Admits same-user peers without a code-signature check (the test host is not the helper).
private struct SameUserVerifier: OwlAgentPeerVerifying {
  var refuse = false
  func admit(_ descriptor: Int32) -> pid_t? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard !refuse, getpeereid(descriptor, &uid, &gid) == 0, uid == getuid() else { return nil }
    return getpid()
  }
}

private final class FakeService: OwlAgentBridgeService {
  var appBuild = OwlAgentBridgeProtocol.AppBuild(version: "2.2.0", build: "1")
  var calls: [(OwlAgentBridgeProtocol.Call, OwlAgentBridgeClient)] = []
  var holdReplies = false
  var cancelled = XCTestExpectation(description: "cancelled")

  func handle(_ call: OwlAgentBridgeProtocol.Call, from client: OwlAgentBridgeClient,
              cancellation: OwlAgentBridgeCancellation, reply: @escaping (OwlAgentBridgeReply) -> Void) {
    calls.append((call, client))
    cancellation.onCancel { [cancelled] in cancelled.fulfill() }
    if !holdReplies { reply(.success(.object(["ok": .bool(true)]))) }
  }
}

/// A blocking client socket with a 2 s read timeout.
private final class TestClient {
  let descriptor: Int32

  init?(_ path: String) {
    descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
    }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if connected != 0 { close(descriptor); return nil }
  }

  deinit { close(descriptor) }

  func send(_ line: String) {
    let data = Array((line + "\n").utf8)
    _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
  }

  /// The next line, or nil when the server closed the connection or nothing came in time.
  func receive() -> OwlJSONValue? {
    var line = [UInt8]()
    var byte: UInt8 = 0
    while read(descriptor, &byte, 1) == 1 {
      if byte == 0x0A { return try? JSONDecoder().decode(OwlJSONValue.self, from: Data(line)) }
      line.append(byte)
    }
    return nil
  }

  func hello(version: Int = 1) -> OwlJSONValue? {
    send(#"{"jsonrpc":"2.0","id":1,"method":"hello","params":{"protocolVersion":\#(version),"helper":{"name":"owltype-mcp","version":"0.1.0"},"agentClient":{"name":"grok-build","version":"0.9.3"}}}"#)
    return receive()
  }
}

final class OwlAgentBridgeTests: XCTestCase {
  private var directory: URL!
  private var service: FakeService!
  private var bridge: OwlAgentBridge!

  private var socketPath: String { directory.appendingPathComponent("AgentBridge/bridge.sock").path }

  override func setUpWithError() throws {
    // /tmp keeps the socket path inside sun_path's 104 bytes.
    directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("owlab-\(UUID().uuidString.prefix(8))")
    service = FakeService()
    bridge = OwlAgentBridge(socketURL: URL(fileURLWithPath: socketPath), verifier: SameUserVerifier(), service: service)
  }

  override func tearDownWithError() throws {
    bridge.stop()
    try? FileManager.default.removeItem(at: directory)
  }

  private func mode(_ path: String) -> mode_t {
    var info = stat()
    XCTAssertEqual(lstat(path, &info), 0)
    return info.st_mode & 0o777
  }

  func testDirectoryIsPrivateAndSocketIsOwnerOnly() throws {
    try FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try bridge.start()
    XCTAssertEqual(mode((socketPath as NSString).deletingLastPathComponent), 0o700)
    XCTAssertEqual(mode(socketPath), 0o600)
    bridge.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
  }

  func testHelloThenCallReachesTheServiceWithTheClientNamed() throws {
    try bridge.start()
    let client = try XCTUnwrap(TestClient(socketPath))
    let hello = try XCTUnwrap(client.hello())
    XCTAssertEqual(hello["result"]?["protocolVersion"], .number(1))
    XCTAssertEqual(hello["result"]?["app"]?["version"], .string("2.2.0"))
    client.send(#"{"jsonrpc":"2.0","id":2,"method":"owltype_status"}"#)
    XCTAssertEqual(client.receive(), .object(["jsonrpc": .string("2.0"), "id": .number(2), "result": .object(["ok": .bool(true)])]))
    XCTAssertEqual(bridge.queue.sync { service.calls.count }, 1)
    XCTAssertEqual(service.calls.first?.0, .owltypeStatus)
    XCTAssertEqual(service.calls.first?.1.agentClient, .init(name: "grok-build", version: "0.9.3"))
  }

  func testRequestBeforeHelloIsRefused() throws {
    try bridge.start()
    let client = try XCTUnwrap(TestClient(socketPath))
    client.send(#"{"jsonrpc":"2.0","id":5,"method":"owltype_status"}"#)
    XCTAssertEqual(client.receive()?["error"]?["code"], .number(-32002))
    XCTAssertTrue(service.calls.isEmpty)
  }

  func testOtherProtocolVersionIsRefusedWithTheSupportedOne() throws {
    try bridge.start()
    let client = try XCTUnwrap(TestClient(socketPath))
    let answer = client.hello(version: 9)
    XCTAssertEqual(answer?["error"]?["code"], .number(-32001))
    XCTAssertEqual(answer?["error"]?["data"]?["supportedProtocolVersions"], .array([.number(1)]))
  }

  func testMalformedLinesGetContractErrors() throws {
    try bridge.start()
    let client = try XCTUnwrap(TestClient(socketPath))
    client.send("not json")
    let parse = client.receive()
    XCTAssertEqual(parse?["error"]?["code"], .number(-32700))
    XCTAssertEqual(parse?["id"], .null)
    _ = client.hello()
    client.send(#"{"jsonrpc":"2.0","id":3,"method":"nope"}"#)
    XCTAssertEqual(client.receive()?["error"]?["code"], .number(-32601))
    client.send(#"{"jsonrpc":"2.0","id":4,"method":"deliver_text","params":{"requestId":"a b","text":"x"}}"#)
    let invalid = client.receive()
    XCTAssertEqual(invalid?["error"]?["code"], .number(-32602))
    XCTAssertEqual(invalid?["error"]?["data"]?["field"], .string("requestId"))
  }

  func testRefusedPeerIsClosedWithoutAnAnswer() throws {
    bridge = OwlAgentBridge(socketURL: URL(fileURLWithPath: socketPath), verifier: SameUserVerifier(refuse: true), service: service)
    try bridge.start()
    let client = try XCTUnwrap(TestClient(socketPath))
    XCTAssertNil(client.hello())
    XCTAssertTrue(service.calls.isEmpty)
  }

  func testSilentConnectionClosesAfterTheHelloTimeout() throws {
    bridge.helloTimeout = .milliseconds(100)
    try bridge.start()
    let client = try XCTUnwrap(TestClient(socketPath))
    let started = Date()
    XCTAssertNil(client.receive())
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
  }

  func testDisconnectCancelsTheRequestInFlight() throws {
    service.holdReplies = true
    bridge.idleTimeout = .milliseconds(100)
    try bridge.start()
    var client = TestClient(socketPath)
    _ = client?.hello()
    client?.send(#"{"jsonrpc":"2.0","id":2,"method":"owltype_status"}"#)
    // A pending request keeps the connection past its idle timeout.
    Thread.sleep(forTimeInterval: 0.3)
    XCTAssertEqual(bridge.queue.sync { service.calls.count }, 1)
    client = nil
    wait(for: [service.cancelled], timeout: 2)
  }

  func testStopClosesOpenConnections() throws {
    try bridge.start()
    let client = try XCTUnwrap(TestClient(socketPath))
    _ = client.hello()
    bridge.stop()
    XCTAssertNil(client.receive())
    XCTAssertNil(TestClient(socketPath))
  }

  func testRefusesASymlinkedSocketDirectory() throws {
    let elsewhere = directory.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("AgentBridge"), withDestinationURL: elsewhere)
    XCTAssertThrowsError(try bridge.start())
  }

  func testPeerPolicyNeedsTheAppTeamAndHelperIdentifier() {
    let team = OwlAgentPeerVerifier.Policy.team("ABCDE12345")
    func info(_ team: String?, _ identifier: String) -> [String: Any] {
      var info: [String: Any] = [kSecCodeInfoIdentifier as String: identifier]
      if let team { info[kSecCodeInfoTeamIdentifier as String] = team }
      return info
    }
    XCTAssertTrue(OwlAgentPeerVerifier.allows(team, info: info("ABCDE12345", "owltype-mcp"), path: nil))
    XCTAssertFalse(OwlAgentPeerVerifier.allows(team, info: info("ZZZZZ99999", "owltype-mcp"), path: nil))
    XCTAssertFalse(OwlAgentPeerVerifier.allows(team, info: info("ABCDE12345", "com.example.tool"), path: nil))
    XCTAssertFalse(OwlAgentPeerVerifier.allows(team, info: info(nil, "owltype-mcp"), path: nil))
    let hash = Data([1, 2, 3])
    let bundled = OwlAgentPeerVerifier.Policy.bundledHelper(path: "/A/Contents/Helpers/owltype-mcp", cdhash: hash)
    XCTAssertTrue(OwlAgentPeerVerifier.allows(bundled, info: [kSecCodeInfoUnique as String: hash], path: "/A/Contents/Helpers/owltype-mcp"))
    XCTAssertFalse(OwlAgentPeerVerifier.allows(bundled, info: [kSecCodeInfoUnique as String: Data([9])], path: "/A/Contents/Helpers/owltype-mcp"))
    XCTAssertFalse(OwlAgentPeerVerifier.allows(bundled, info: [kSecCodeInfoUnique as String: hash], path: "/tmp/owltype-mcp"))
    XCTAssertFalse(OwlAgentPeerVerifier.allows(.refuseAll, info: info("ABCDE12345", "owltype-mcp"), path: nil))
  }

  func testTheProductionVerifierRefusesThisTestProcess() throws {
    bridge = OwlAgentBridge(socketURL: URL(fileURLWithPath: socketPath), verifier: OwlAgentPeerVerifier(), service: service)
    try bridge.start()
    let client = try XCTUnwrap(TestClient(socketPath))
    XCTAssertNil(client.hello())
  }
}

final class OwlAgentAccessTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suite: String!
  private var directory: URL!

  override func setUp() {
    suite = "OwlAgentAccessTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
    directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("owlaa-\(UUID().uuidString.prefix(8))")
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }

  private func access() -> OwlAgentAccess {
    let access = OwlAgentAccess(defaults: defaults)
    access.inputSnapshot = { OwlAgentInputSnapshot(schemaID: "wubi86_jidian", asciiMode: true) }
    access.resourceGeneration = { "generation-7" }
    access.exposedTemplateCount = { 2 }
    return access
  }

  private func waitForMain() {
    let drained = expectation(description: "main queue")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)
  }

  func testOffByDefaultAndFollowsTheSwitch() {
    XCTAssertFalse(OwlAgentAccessPreferences.isEnabled(defaults))
    let access = access()
    let socket = directory.appendingPathComponent("AgentBridge/bridge.sock")
    access.start { OwlAgentBridge(socketURL: socket, verifier: SameUserVerifier(), service: $0) }
    defer { access.stopFollowing() }
    XCTAssertNil(access.bridge)
    XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))

    OwlAgentAccessPreferences.setEnabled(true, defaults)
    waitForMain()
    XCTAssertEqual(access.bridge?.isListening, true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))

    OwlAgentAccessPreferences.setEnabled(false, defaults)
    waitForMain()
    XCTAssertNil(access.bridge)
    XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
  }

  private func answer(_ access: OwlAgentAccess, _ call: OwlAgentBridgeProtocol.Call) -> OwlAgentBridgeReply? {
    let done = expectation(description: "reply")
    var result: OwlAgentBridgeReply?
    let client = OwlAgentBridgeClient(helper: .init(name: "owltype-mcp", version: "0.1.0"), agentClient: nil, processID: 1)
    access.handle(call, from: client, cancellation: OwlAgentBridgeCancellation()) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
    return result
  }

  func testCallsWhileSwitchedOffAreRefused() {
    guard case .failure(let error) = answer(access(), .owltypeStatus) else { return XCTFail("expected a refusal") }
    XCTAssertEqual(error.code, .agentAccessDisabled)
  }

  func testStatusIsTheRedactedContractShape() throws {
    OwlAgentAccessPreferences.setEnabled(true, defaults)
    guard case .success(let value) = answer(access(), .owltypeStatus) else { return XCTFail("expected a status") }
    let status = try OwlAgentBridgeProtocol.decodeStrict(OwlAgentBridgeProtocol.Status.self, from: value)
    XCTAssertEqual(status.inputSchema, .init(id: "wubi86_jidian", name: "极点五笔86"))
    XCTAssertEqual(status.inputMode, .english)
    XCTAssertEqual(status.resourceGeneration, "generation-7")
    XCTAssertEqual(status.exposedTemplateCount, 2)
  }
}

/// The built owltype-mcp (bin/, from scripts/build-rust-ffi.sh) against this bridge, with the real
/// signature check: MCP in on the helper's stdin, the bridge's status out as structured content.
final class OwlAgentHelperInteropTests: XCTestCase {
  func testRealHelperIsAdmittedAndAnswersOwltypeStatus() throws {
    let built = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("bin/owltype-mcp")
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: built.path), "bin/owltype-mcp is not built")
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("owlhi-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // strip leaves the linker's signature invalid; the App signs its copy, so this test signs its own.
    let helper = directory.appendingPathComponent("owltype-mcp")
    try FileManager.default.copyItem(at: built, to: helper)
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["--force", "--sign", "-", helper.path]
    try sign.run()
    sign.waitUntilExit()
    XCTAssertEqual(sign.terminationStatus, 0)
    var code: SecStaticCode?
    var info: CFDictionary?
    XCTAssertEqual(SecStaticCodeCreateWithPath(helper as CFURL, [], &code), errSecSuccess)
    XCTAssertEqual(SecCodeCopySigningInformation(code!, SecCSFlags(rawValue: kSecCSSigningInformation), &info), errSecSuccess)
    let cdhash = try XCTUnwrap((info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data)

    let suite = "OwlAgentHelperInteropTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    OwlAgentAccessPreferences.setEnabled(true, defaults)
    let access = OwlAgentAccess(defaults: defaults)
    access.inputSnapshot = { OwlAgentInputSnapshot(schemaID: "rime_ice", asciiMode: false) }
    access.resourceGeneration = { "generation-1" }
    let socket = directory.appendingPathComponent("AgentBridge/bridge.sock")
    let policy = OwlAgentPeerVerifier.Policy.bundledHelper(path: helper.resolvingSymlinksInPath().path, cdhash: cdhash)
    let bridge = OwlAgentBridge(socketURL: socket, verifier: OwlAgentPeerVerifier(policy: policy), service: access)
    try bridge.start()
    defer { bridge.stop() }

    let process = Process()
    process.executableURL = helper
    process.environment = ["OWLTYPE_AGENT_BRIDGE_SOCKET": socket.path]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    defer { process.terminate() }
    let messages = [
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"interop-test","version":"1"}}}"#,
      #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
      #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"owltype_status","arguments":{}}}"#
    ]
    input.fileHandleForWriting.write(Data((messages.joined(separator: "\n") + "\n").utf8))

    // Read off the main thread: owltype_status takes its snapshot on the main queue, which the
    // expectation wait keeps running.
    let answered = expectation(description: "tools/call answer")
    let lock = NSLock()
    var buffer = Data()
    var answer: OwlJSONValue?
    output.fileHandleForReading.readabilityHandler = { handle in
      lock.withLock {
        buffer.append(handle.availableData)
        guard answer == nil else { return }
        for line in buffer.split(separator: 0x0A) {
          if let value = try? JSONDecoder().decode(OwlJSONValue.self, from: Data(line)), value["id"] == .number(2) {
            answer = value
            answered.fulfill()
          }
        }
      }
    }
    wait(for: [answered], timeout: 10)
    output.fileHandleForReading.readabilityHandler = nil
    let result = try XCTUnwrap(answer?["result"])
    XCTAssertEqual(result["isError"], .bool(false), "\(result)")
    let status = try OwlAgentBridgeProtocol.decodeStrict(OwlAgentBridgeProtocol.Status.self, from: try XCTUnwrap(result["structuredContent"]))
    XCTAssertEqual(status.inputSchema, .init(id: "rime_ice", name: "雾凇拼音"))
    XCTAssertEqual(status.resourceGeneration, "generation-1")
  }
}
