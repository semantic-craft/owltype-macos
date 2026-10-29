//
//  OwlAgentTemplatesTests.swift
//  OwltypeTests
//
//  Agents see only templates the user exposed: the field defaults off and survives old files,
//  list/get/render answer the contract shapes, and rendering never reads the pasteboard.
//

import XCTest
@testable import Owltype

final class OwlAgentTemplatesTests: XCTestCase {
  private typealias Wire = OwlAgentBridgeProtocol
  private var defaults: UserDefaults!
  private var suite: String!

  override func setUp() {
    suite = "OwlAgentTemplatesTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
    OwlAgentAccessPreferences.setEnabled(true, defaults)
  }

  override func tearDown() { defaults.removePersistentDomain(forName: suite) }

  private func entry(_ title: String, _ body: String, exposed: Bool = true) -> OwlTemplateEntry {
    var entry = OwlTemplateEntry(title: title, body: body)
    entry.bodyType = .template
    entry.isExposedToAgents = exposed
    return entry
  }

  private func access(_ entries: [OwlTemplateEntry]) -> OwlAgentAccess {
    let access = OwlAgentAccess(defaults: defaults)
    access.loadLibrary = { OwlTemplateLibrary(entries: entries) }
    return access
  }

  private func answer(_ access: OwlAgentAccess, _ call: Wire.Call) -> OwlAgentBridgeReply? {
    var result: OwlAgentBridgeReply?
    let client = OwlAgentBridgeClient(helper: .init(name: "owltype-mcp", version: "0.1.0"), agentClient: nil, processID: 1)
    access.handle(call, from: client, cancellation: OwlAgentBridgeCancellation()) { result = $0 }
    return result
  }

  func testExposureDefaultsOffAndOldFilesStayUnexposed() throws {
    let plain = OwlTemplateEntry(title: "a", body: "b")
    XCTAssertFalse(plain.isExposedToAgents)
    let encoded = try OwlTemplateStore.encoded(.init(entries: [plain]))
    XCTAssertFalse((String(bytes: encoded, encoding: .utf8) ?? "").contains("exposedToAgents"), "unexposed entries keep their stored shape")
    let library = try JSONDecoder().decode(OwlTemplateLibrary.self, from: encoded)
    XCTAssertFalse(library.entries[0].isExposedToAgents)

    var exposed = plain
    exposed.isExposedToAgents = true
    let reread = try JSONDecoder().decode(OwlTemplateLibrary.self, from: try OwlTemplateStore.encoded(.init(entries: [exposed])))
    XCTAssertTrue(reread.entries[0].isExposedToAgents)
    XCTAssertFalse(exposed.duplicated().isExposedToAgents, "a copy is not exposed until the user exposes it")
  }

  func testListShowsOnlyExposedReadyTemplates() throws {
    var pending = entry("待审", "x")
    pending.reviewState = .pending
    let broken = entry("坏的", "{argument name=}")
    let shared = entry("会议", "{date} 会议：{argument name=议题}")
    let access = access([shared, entry("私有", "y", exposed: false), pending, broken])
    guard case .success(let value) = answer(access, .templatesList) else { return XCTFail("expected a list") }
    let list = try Wire.decodeStrict(Wire.TemplateList.self, from: value)
    XCTAssertEqual(list.templates.map(\.title), ["会议"])
    XCTAssertEqual(list.templates[0].parameters.map(\.key), ["n:议题"])
    XCTAssertEqual(list.templates[0].requirements, [.date])
  }

  func testUnexposedAndMissingTemplatesAreBothNotFound() {
    let hidden = entry("私有", "y", exposed: false)
    let access = access([hidden])
    for id in [hidden.id.uuidString, UUID().uuidString, "not-a-uuid"] {
      guard case .failure(let error) = answer(access, .templateGet(.init(id: id))) else { return XCTFail(id) }
      XCTAssertEqual(error.code, .templateNotFound)
      guard case .failure(let render) = answer(access, .templateRender(.init(id: id, arguments: nil))) else { return XCTFail(id) }
      XCTAssertEqual(render.code, .templateNotFound)
    }
  }

  func testGetReturnsTheBody() throws {
    let shared = entry("签名", "此致\n{argument name=姓名}")
    guard case .success(let value) = answer(access([shared]), .templateGet(.init(id: shared.id.uuidString))) else { return XCTFail("unexpected reply") }
    let detail = try Wire.decodeStrict(Wire.TemplateDetail.self, from: value)
    XCTAssertEqual(detail.template.body, "此致\n{argument name=姓名}")
    XCTAssertEqual(detail.template.parameters.first?.name, "姓名")
  }

  func testRenderFillsArgumentsAndReportsMissingOnes() throws {
    let shared = entry("会议", "会议：{argument name=议题}，语气：{argument name=语气 default=正式}{cursor}")
    let access = access([shared])
    guard case .success(let value) = answer(access, .templateRender(.init(id: shared.id.uuidString, arguments: ["n:议题": "发版"]))) else {
      return XCTFail("unexpected reply")
    }
    let render = try Wire.decodeStrict(Wire.Render.self, from: value)
    XCTAssertEqual(render.previewText, "会议：发版，语气：正式")
    XCTAssertEqual(render.cursorOffset, "会议：发版，语气：正式".utf16.count)
    XCTAssertEqual(render.missingKeys, [])

    guard case .success(let missingValue) = answer(access, .templateRender(.init(id: shared.id.uuidString, arguments: nil))) else {
      return XCTFail("unexpected reply")
    }
    XCTAssertEqual(try Wire.decodeStrict(Wire.Render.self, from: missingValue).missingKeys, ["n:议题"])

    guard case .failure(let error) = answer(access, .templateRender(.init(id: shared.id.uuidString, arguments: ["n:主题": "x"]))) else {
      return XCTFail("unexpected reply")
    }
    XCTAssertEqual(error.code, .invalidParams)
    XCTAssertEqual(error.data?.field, "arguments")
  }

  func testClipboardFieldsPreviewEmptyWithAWarning() throws {
    let shared = entry("引用", "引用：{clipboard}")
    let result = OwlAgentTemplates.render(shared, arguments: [:])
    guard case .success(let render) = result else { return XCTFail("unexpected reply") }
    XCTAssertEqual(render.previewText, "引用：")
    XCTAssertTrue(render.diagnostics.contains { $0.severity == .warning && $0.message.contains("剪贴板") })
    XCTAssertEqual(OwlAgentTemplates.summary(shared).requirements, [.clipboard])
  }

  func testStatusCountsExposedTemplates() throws {
    let access = access([entry("a", "1"), entry("b", "2"), entry("c", "3", exposed: false)])
    access.inputSnapshot = { OwlAgentInputSnapshot(schemaID: "rime_ice", asciiMode: false) }
    access.resourceGeneration = { "g" }
    let done = expectation(description: "status")
    var status: Wire.Status?
    let client = OwlAgentBridgeClient(helper: .init(name: "owltype-mcp", version: "0.1.0"), agentClient: nil, processID: 1)
    access.handle(.owltypeStatus, from: client, cancellation: OwlAgentBridgeCancellation()) {
      if case .success(let value) = $0 { status = try? Wire.decodeStrict(Wire.Status.self, from: value) }
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
    XCTAssertEqual(status?.exposedTemplateCount, 2)
  }
}
