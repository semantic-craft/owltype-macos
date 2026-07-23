//
//  FamoPromptStoreTests.swift
//  FamoTests — 提示词存储 / 模型 / 校验（R1）+ 派生 Rime 表与 patch（R1 dict）+ 变量引擎（R3）
//
//  Locks the pure-logic contracts of the prompt feature:
//    1. `save` now writes THREE files atomically through `FamoConfigWriter` against an isolated
//       temp dir — the `famo_prompts.json` source of truth PLUS the derived `famo_prompts.txt`
//       Rime stabledb (`📝title\tcode\t100000` + the `v{code}` collision variant) PLUS the
//       `rime_ice.custom.yaml` patch registering `table_translator@famo_prompts`. `load` still
//       reads JSON only. Round-trip: save → load equal, normalized (deduped + sorted by code).
//    2. Validation: trigger-code format, single-line/non-empty title, non-empty body, and the
//       shared-namespace collision against existing 快捷短语 codes — each a typed `FamoPromptError`.
//    3. Variable engine: `extract` (dedup, first-seen order) and `substitute`
//       (unfilled placeholder preserved, same var twice replaced, explicit empty value honored).
//
//  No network, no librime. The store is pointed at a unique temp root so it never touches the
//  real ~/Library/Application Support/Famo. (The commit-interception decision function + the
//  `PromptResolving` port are covered in FamoPromptInterceptionTests.swift.)
//

import Foundation
import XCTest
@testable import Famo

final class FamoPromptStoreTests: XCTestCase {

  private var tempRoot: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("FamoPromptStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
      try FileManager.default.removeItem(at: tempRoot)
    }
    try super.tearDownWithError()
  }

  // MARK: - JSON round-trip

  func testSaveLoadRoundTripThroughConfigWriter() throws {
    let writer = FamoConfigWriter(rimeDir: tempRoot)
    let entries = [
      try FamoPromptStore.entry(code: "hetong", title: "合同审查", body: "请审查以下合同：\n{{合同正文}}", category: "法律"),
      try FamoPromptStore.entry(code: "fanyi", title: "翻译", body: "把下面译成{{语言}}：{{原文}}"),
    ]
    try FamoPromptStore.save(entries, writer: writer, timestamp: "20260630-000000")

    let url = tempRoot.appendingPathComponent(FamoPromptStore.fileName)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "famo_prompts.json must be written")

    let loaded = FamoPromptStore.load(rimeDir: tempRoot)
    // normalized() sorts by code: fanyi < hetong.
    XCTAssertEqual(loaded.map(\.code), ["fanyi", "hetong"])
    XCTAssertEqual(loaded, try FamoPromptStore.normalized(entries))
    let hetong = try XCTUnwrap(loaded.first { $0.code == "hetong" })
    XCTAssertEqual(hetong.title, "合同审查")
    XCTAssertEqual(hetong.body, "请审查以下合同：\n{{合同正文}}")
    XCTAssertEqual(hetong.category, "法律")
    XCTAssertEqual(hetong.variables, ["合同正文"])
  }

  func testLoadMissingFileReturnsEmpty() {
    XCTAssertTrue(FamoPromptStore.load(rimeDir: tempRoot).isEmpty)
  }

  // MARK: - Derived Rime dict + rime_ice patch (R1 dict)

  func testSaveWritesDerivedDictWithMarkerAndCollisionVariant() throws {
    let writer = FamoConfigWriter(rimeDir: tempRoot)
    let entries = [
      try FamoPromptStore.entry(code: "hetong", title: "合同审查", body: "请审查以下合同：\n{{合同正文}}", category: "法律"),
    ]
    try FamoPromptStore.save(entries, writer: writer, timestamp: "20260630-000010")

    let dictURL = tempRoot.appendingPathComponent(FamoPromptStore.dictFileName)
    XCTAssertEqual(FamoPromptStore.dictFileName, "famo_prompts.txt")
    let dict = try String(contentsOf: dictURL, encoding: .utf8)
    // 📝-marked title + score, plus the v-prefixed collision-proof variant.
    XCTAssertTrue(dict.contains("📝合同审查\thetong\t100000"), "marked title row missing:\n\(dict)")
    XCTAssertTrue(dict.contains("📝合同审查\tvhetong\t100000"), "collision-proof v-variant missing:\n\(dict)")
    // Body must NEVER leak into the Rime table (it lives only in JSON).
    XCTAssertFalse(dict.contains("请审查以下合同"), "body must not appear in the derived dict")
    XCTAssertFalse(dict.contains("{{合同正文}}"), "variable placeholder must not appear in the derived dict")
    // tabledb header (mirrors quick-send).
    XCTAssertTrue(dict.contains("#@/db_name famo_prompts"))
  }

  func testSaveWritesRimeIcePatchRegisteringTranslator() throws {
    let writer = FamoConfigWriter(rimeDir: tempRoot)
    let entries = [try FamoPromptStore.entry(code: "abc", title: "T", body: "B")]
    try FamoPromptStore.save(entries, writer: writer, timestamp: "20260630-000011")

    let patchURL = tempRoot.appendingPathComponent("rime_ice.custom.yaml")
    let patch = try String(contentsOf: patchURL, encoding: .utf8)
    XCTAssertTrue(patch.contains("FAMO MANAGED PROMPTS RIME_ICE PATCH v1"), "managed marker missing:\n\(patch)")
    XCTAssertTrue(patch.contains("table_translator@famo_prompts"), "translator registration missing")
    XCTAssertTrue(patch.contains("user_dict: famo_prompts"))
  }

  func testSaveDictIsDerivedNotLoaded() throws {
    // `load` reads JSON only; the .txt is a pure projection regenerated every save. Saving an
    // empty list still rewrites the .txt to an entries-free table (so old rows are cleared).
    let writer = FamoConfigWriter(rimeDir: tempRoot)
    try FamoPromptStore.save([try FamoPromptStore.entry(code: "abc", title: "T", body: "B")],
                             writer: writer, timestamp: "20260630-000012")
    try FamoPromptStore.save([], writer: writer, timestamp: "20260630-000013")
    let dict = try String(contentsOf: tempRoot.appendingPathComponent(FamoPromptStore.dictFileName), encoding: .utf8)
    XCTAssertFalse(dict.contains("\tabc\t"), "stale entry row must be regenerated away on empty save")
    XCTAssertTrue(FamoPromptStore.load(rimeDir: tempRoot).isEmpty, "load reads JSON, which is now empty")
  }

  func testRenderDictIsPureProjection() {
    let rows = FamoPromptStore.renderDict([
      FamoPromptEntry(code: "fanyi", title: "翻译", body: "把下面译成{{语言}}：{{原文}}"),
    ])
    XCTAssertTrue(rows.contains("📝翻译\tfanyi\t100000"))
    XCTAssertTrue(rows.contains("📝翻译\tvfanyi\t100000"))
    XCTAssertFalse(rows.contains("原文"), "body/variables never enter the derived table")
  }

  func testLoadDropsInvalidEntries() throws {
    // Hand-write a JSON array with one valid + one invalid (bad code) entry, bypassing the store.
    let json = """
    [
      {"code":"good","title":"ok","body":"hi","category":""},
      {"code":"1bad","title":"x","body":"y","category":""}
    ]
    """
    let url = tempRoot.appendingPathComponent(FamoPromptStore.fileName)
    try json.data(using: .utf8)!.write(to: url, options: .atomic)

    let loaded = FamoPromptStore.load(rimeDir: tempRoot)
    XCTAssertEqual(loaded.map(\.code), ["good"], "invalid-code entry should be dropped on load")
  }

  func testSaveIsIdempotentNoOpWhenUnchanged() throws {
    let writer = FamoConfigWriter(rimeDir: tempRoot)
    let entries = [try FamoPromptStore.entry(code: "abc", title: "T", body: "B")]
    try FamoPromptStore.save(entries, writer: writer, timestamp: "20260630-000001")
    let url = tempRoot.appendingPathComponent(FamoPromptStore.fileName)
    let first = try Data(contentsOf: url)
    try FamoPromptStore.save(entries, writer: writer, timestamp: "20260630-000002")
    let second = try Data(contentsOf: url)
    XCTAssertEqual(first, second, "re-saving identical entries must be byte-stable")
  }

  // MARK: - normalized

  func testNormalizedDedupesByCodeLastWinsAndSorts() throws {
    let entries = [
      FamoPromptEntry(code: "zeta", title: "Z", body: "z"),
      FamoPromptEntry(code: "alpha", title: "A1", body: "a1"),
      FamoPromptEntry(code: "alpha", title: "A2", body: "a2"),
    ]
    let out = try FamoPromptStore.normalized(entries)
    XCTAssertEqual(out.map(\.code), ["alpha", "zeta"], "sorted by code")
    XCTAssertEqual(out.first { $0.code == "alpha" }?.title, "A2", "later duplicate wins")
  }

  // MARK: - Validation: format

  func testEntryRejectsBadCodes() {
    // Note: uppercase is NOT rejected — `entry` lowercases first (mirrors quick-send), so "ABC"
    // normalizes to a valid "abc". These are codes that stay invalid after trim + lowercase.
    let bad = ["", "1abc", "ab c", "a-b", "你好", String(repeating: "a", count: 33)]
    for code in bad {
      XCTAssertThrowsError(try FamoPromptStore.entry(code: code, title: "t", body: "b")) { error in
        XCTAssertEqual(error as? FamoPromptError, .invalidCode, "code \(code.debugDescription) must be invalid")
      }
    }
  }

  func testEntryAcceptsValidCodeAndLowercases() throws {
    let e = try FamoPromptStore.entry(code: "  Hetong  ", title: "  合同  ", body: "  正文  ")
    XCTAssertEqual(e.code, "hetong", "code is trimmed + lowercased")
    XCTAssertEqual(e.title, "合同", "title trimmed")
    XCTAssertEqual(e.body, "正文", "body trimmed")
  }

  func testEntryRejectsBadTitle() {
    for title in ["", "  ", "two\nlines", "tab\there"] {
      XCTAssertThrowsError(try FamoPromptStore.entry(code: "abc", title: title, body: "b")) { error in
        XCTAssertEqual(error as? FamoPromptError, .invalidTitle)
      }
    }
  }

  func testEntryRejectsEmptyBody() {
    XCTAssertThrowsError(try FamoPromptStore.entry(code: "abc", title: "t", body: "   ")) { error in
      XCTAssertEqual(error as? FamoPromptError, .invalidBody)
    }
  }

  // MARK: - Validation: cross-feature collision

  func testCollisionWithQuickSendCodeThrows() {
    XCTAssertThrowsError(
      try FamoPromptStore.validatedEntry(
        code: "pjzy", title: "判决摘要", body: "正文",
        quickSendCodes: ["pjzy", "yocc"]
      )
    ) { error in
      XCTAssertEqual(error as? FamoPromptError, .duplicateCode("pjzy"))
    }
  }

  func testNoCollisionPasses() throws {
    let e = try FamoPromptStore.validatedEntry(
      code: "fljs", title: "法律检索", body: "检索：{{关键词}}",
      quickSendCodes: ["pjzy", "yocc"]
    )
    XCTAssertEqual(e.code, "fljs")
    XCTAssertEqual(e.variables, ["关键词"])
  }

  func testQuickSendCodesReadFromStore() throws {
    // Persist a quick-send entry into the temp dir, then confirm the collision source reads it back.
    let writer = FamoConfigWriter(rimeDir: tempRoot)
    let qs = try FamoQuickSendStore.entry(text: "判决摘要", code: "pjzy")
    try FamoQuickSendStore.save([qs], writer: writer, timestamp: "20260630-000003")

    let codes = FamoPromptStore.quickSendCodes(rimeDir: tempRoot)
    XCTAssertTrue(codes.contains("pjzy"))
    XCTAssertThrowsError(
      try FamoPromptStore.assertNoQuickSendCollision(code: "PJZY", quickSendCodes: codes)
    ) { error in
      XCTAssertEqual(error as? FamoPromptError, .duplicateCode("pjzy"))
    }
  }

  // MARK: - Variable engine: extract

  func testExtractDedupesAndPreservesFirstSeenOrder() {
    let body = "你好 {{name}}，今天是 {{date}}，再见 {{name}}。空：{{}} 带空格：{{  spaced  }}"
    XCTAssertEqual(FamoPromptVariables.extract(from: body), ["name", "date", "spaced"])
  }

  func testExtractNoVariablesReturnsEmpty() throws {
    XCTAssertTrue(FamoPromptVariables.extract(from: "just plain text").isEmpty)
    let entry = try FamoPromptStore.entry(code: "a", title: "t", body: "no vars here")
    XCTAssertEqual(entry.variables, [], "derived variables empty when body has no placeholders")
  }

  // MARK: - Variable engine: substitute

  func testSubstituteReplacesAllOccurrences() {
    let out = FamoPromptVariables.substitute("{{x}} 和 {{x}} 与 {{y}}", values: ["x": "甲", "y": "乙"])
    XCTAssertEqual(out, "甲 和 甲 与 乙")
  }

  func testSubstituteKeepsUnfilledPlaceholder() {
    let out = FamoPromptVariables.substitute("{{filled}}-{{missing}}", values: ["filled": "F"])
    XCTAssertEqual(out, "F-{{missing}}", "unfilled variable keeps its placeholder")
  }

  func testSubstituteHonorsExplicitEmptyValue() {
    let out = FamoPromptVariables.substitute("[{{x}}]", values: ["x": ""])
    XCTAssertEqual(out, "[]", "a key present with empty value substitutes empty, not the placeholder")
  }

  func testSubstituteAdjacentPlaceholders() {
    let out = FamoPromptVariables.substitute("{{语言}}{{原文}}", values: ["语言": "中文：", "原文": "hello"])
    XCTAssertEqual(out, "中文：hello")
  }

  func testSubstituteNoValuesIsIdentityOnPlaceholders() {
    let body = "保留 {{a}} 和 {{b}}"
    XCTAssertEqual(FamoPromptVariables.substitute(body, values: [:]), body)
  }

  func testSubstituteRoundTripWithExtract() {
    let body = "把下面译成{{语言}}：{{原文}}"
    let vars = FamoPromptVariables.extract(from: body)
    XCTAssertEqual(vars, ["语言", "原文"])
    let filled = FamoPromptVariables.substitute(body, values: ["语言": "英语", "原文": "你好"])
    XCTAssertEqual(filled, "把下面译成英语：你好")
  }

  // MARK: - 官方 XML 模板包（A1）

  func testPresetTemplatesAllValidateAndCarryVariables() throws {
    // 每条预置都得过存储的单条校验（合法触发码、单行标题、非空正文），且至少含一个填空变量。
    XCTAssertEqual(FamoPromptPresets.templates.count, 5, "通用组五条（法律组已按用户决定剔除）")
    for template in FamoPromptPresets.templates {
      XCTAssertNoThrow(
        try FamoPromptStore.entry(
          code: template.code, title: template.title, body: template.body,
          category: template.category),
        "预置「\(template.code)」必须通过校验")
      XCTAssertFalse(template.variables.isEmpty, "预置「\(template.code)」应含 {{变量}} 供填空")
      XCTAssertEqual(template.category, FamoPromptPresets.category)
    }
  }

  func testPresetMergeIntoEmptyAddsEveryTemplate() {
    let result = FamoPromptPresets.merge(into: [], quickSendCodes: [])
    XCTAssertEqual(result.added, ["four", "icx", "fewshot", "docs", "role"])
    XCTAssertTrue(result.skipped.isEmpty)
    XCTAssertEqual(result.merged.count, 5)
  }

  func testPresetMergeSkipsTakenCodesAndNeverOverwrites() {
    // 用户已有一条 code=four（正文不同）+ 一条快捷短语 code=role → 这两个预置跳过、不覆盖。
    let userFour = FamoPromptEntry(code: "four", title: "我的四要素", body: "我自己的正文")
    let result = FamoPromptPresets.merge(into: [userFour], quickSendCodes: ["role"])

    XCTAssertEqual(result.added, ["icx", "fewshot", "docs"], "撞码的 four/role 不导入")
    XCTAssertEqual(result.skipped, ["four", "role"])
    // 用户原条目原封不动——绝不被官方模板覆盖。
    let keptFour = result.merged.first { $0.code == "four" }
    XCTAssertEqual(keptFour?.body, "我自己的正文")
    XCTAssertEqual(keptFour?.title, "我的四要素")
  }

  func testPresetMergeRoundTripsThroughSaveLoad() throws {
    let writer = FamoConfigWriter(rimeDir: tempRoot)
    let result = FamoPromptPresets.merge(into: [], quickSendCodes: [])
    try FamoPromptStore.save(result.merged, writer: writer, timestamp: "20260721-000000")

    let loaded = FamoPromptStore.load(rimeDir: tempRoot)
    XCTAssertEqual(Set(loaded.map(\.code)), ["four", "icx", "fewshot", "docs", "role"])
    // 嵌套骨架的正文与变量在落盘后仍完整。
    let docs = loaded.first { $0.code == "docs" }
    XCTAssertEqual(docs?.body.contains("<documents>"), true)
    XCTAssertEqual(docs?.body.contains("{{来源1，如文件名}}"), true)
  }
}
