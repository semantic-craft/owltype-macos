import Foundation
import XCTest
@testable import Owltype

final class OwlRimeSchemaCompatibilityReportTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("rime-compat-report-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testSyntheticSchemaAndCustomPatchReportLuaWithoutChangingSources() throws {
    let schema = root.appendingPathComponent("synthetic.schema.yaml")
    let custom = root.appendingPathComponent("synthetic.custom.yaml")
    let schemaText = """
    schema:
      schema_id: synthetic_demo
    engine:
      processors:
        - lua_processor@*synthetic_processor
      translators:
        - lua_translator@*synthetic_translator
        - table_translator
      filters:
        - lua_filter@*synthetic_filter
    # - lua_filter@*commented_out
    """
    let customText = """
    patch:
      "engine/translators/+":
        - lua_translator@*custom_patch_translator
      helper: lua/synthetic_helper.lua
    """
    try Data(schemaText.utf8).write(to: schema)
    try Data(customText.utf8).write(to: custom)
    let schemaBefore = try Data(contentsOf: schema)
    let customBefore = try Data(contentsOf: custom)

    let report = try OwlRimeSchemaCompatibilityReport.inspect(fileURLs: [schema, custom])

    XCTAssertEqual(report.files.map(\.kind), [.schema, .custom])
    XCTAssertEqual(report.files.map(\.schemaID), ["synthetic_demo", nil])
    XCTAssertEqual(
      report.files[0].luaReferences,
      [
        "lua_processor@*synthetic_processor",
        "lua_translator@*synthetic_translator",
        "lua_filter@*synthetic_filter"
      ]
    )
    XCTAssertEqual(
      report.files[1].luaReferences,
      ["lua_translator@*custom_patch_translator", "lua/synthetic_helper.lua"]
    )
    XCTAssertEqual(report.nativeEquivalentCapabilities, ["日期", "农历", "Unicode", "表达式"])
    XCTAssertTrue(report.originalPreserved)
    XCTAssertTrue(report.externalExecution.contains("不执行 Lua"))
    XCTAssertTrue(report.notice.contains("原生等价"))
    XCTAssertEqual(try Data(contentsOf: schema), schemaBefore)
    XCTAssertEqual(try Data(contentsOf: custom), customBefore)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
      ["synthetic.custom.yaml", "synthetic.schema.yaml"]
    )
  }

  func testReportRejectsFilesOutsideTheTwoSupportedSuffixes() throws {
    let unsupported = root.appendingPathComponent("synthetic.yaml")
    try Data("schema_id: wrong".utf8).write(to: unsupported)

    XCTAssertFalse(OwlRimeSchemaCompatibilityReport.supports(fileURL: unsupported))
    XCTAssertTrue(
      OwlRimeSchemaCompatibilityReport.supports(
        fileURL: root.appendingPathComponent("synthetic.schema.yaml")
      )
    )
    XCTAssertTrue(
      OwlRimeSchemaCompatibilityReport.supports(
        fileURL: root.appendingPathComponent("synthetic.custom.yaml")
      )
    )
    XCTAssertThrowsError(try OwlRimeSchemaCompatibilityReport.inspect(fileURLs: [unsupported])) {
      XCTAssertEqual(
        $0 as? OwlRimeSchemaCompatibilityReport.Failure,
        .unsupportedFile("synthetic.yaml")
      )
    }
  }
}
