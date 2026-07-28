//
//  FamoKeyboardPatchBuilderTests.swift
//  FamoTests — keyboard-config patch builders (default / famo / rime_ice / wubi .custom.yaml)
//
//  Extracted from CandidateStoreTests.swift (2026-07-08, task 07-08) to keep test files focused
//  (每个测试文件聚焦一类) and under the 1200-line file_length limit. Self-contained: the
//  `fuzzyOff` / `snapshot(...)` helpers are private members of this class.
//

import XCTest
@testable import Famo

final class FamoKeyboardPatchBuilderTests: XCTestCase {
  private let fuzzyOff = FamoFuzzySnapshot(
    zhz: false, chc: false, shs: false, nl: false, rl: false,
    fh: false, anang: false, eneng: false, ining: false
  )

  private func snapshot(
    _ inputMethod: FamoInputMethod,
    shiftSwitchCJK: Bool = true,
    cjkPunctToggle: Bool = false,
    pageMinusEquals: Bool = true,
    pageBrackets: Bool = true,
    pageCommaPeriod: Bool = false,
    select23Semicolon: Bool = false,
    fuzzy: FamoFuzzySnapshot? = nil,
    wubiCodeHint: Bool = false,
    wubiAutoClear: Bool = false,
    wubiCandidateMode: FamoWubiCandidateMode = .normal,
    wubiScheme: FamoWubiScheme = .jidian86,
    wubiZReverseLookup: Bool = true,
    appEnglishBundleIDs: [String] = [],
    angleSymbolMenu: Bool = false,
    wubiEnglishChannel: Bool = false
  ) -> FamoKeyboardSnapshot {
    FamoKeyboardSnapshot(
      inputMethod: inputMethod,
      doublePinyin: .flypy,
      shiftSwitchCJK: shiftSwitchCJK,
      cjkPunctToggle: cjkPunctToggle,
      pageSize: 8,
      pageMinusEquals: pageMinusEquals,
      pageBrackets: pageBrackets,
      pageCommaPeriod: pageCommaPeriod,
      select23Semicolon: select23Semicolon,
      fuzzy: fuzzy ?? fuzzyOff,
      wubiCodeHint: wubiCodeHint,
      wubiAutoClear: wubiAutoClear,
      wubiCandidateMode: wubiCandidateMode,
      appEnglishBundleIDs: appEnglishBundleIDs,
      wubiScheme: wubiScheme,
      wubiZReverseLookup: wubiZReverseLookup,
      angleSymbolMenu: angleSymbolMenu,
      wubiEnglishChannel: wubiEnglishChannel
    )
  }

  // MARK: - N1「<」符号选单

  func testAngleSymbolMenuEmitsHalfShapeListOnlyWhenEnabled() {
    // 开：整键替换（非 /+ 合并——rime-ice half_shape 的 < 是标量，标量→列表合并类型不兼容），
    // 列表含 ASCII <（成对输入的入口）；`>` 绝不能跟着变列表（会杀掉 skip-over，见 builder 注释）。
    let on = famoDefaultCustomYAML(from: snapshot(.pinyin, angleSymbolMenu: true))
    XCTAssertTrue(on.contains("\"punctuator/half_shape/<\":"), "开=整键替换 half_shape 的 <")
    // 【 已按机主 07-21 拍板剔除；弯引号 “ 同日应机主要求加入（自动配对表已有 “→”，选中即成对）。
    XCTAssertTrue(on.contains("[\"《\", \"〈\", \"<\", \"「\", \"“\"]"), "列表=《〈 ASCII< 「 “")
    XCTAssertFalse(on.contains("\"punctuator/half_shape/>\""), "> 保持标量直上屏，skip-over 依赖它")

    // 关：默认快照（angleSymbolMenu 缺省 false）绝不产出该键——出厂行为零变化。
    let off = famoDefaultCustomYAML(from: snapshot(.pinyin))
    XCTAssertFalse(off.contains("punctuator/half_shape/<"))

    // 五笔快照同样产出（default.custom.yaml 一份 patch，五笔 schema import_preset: default 通吃）。
    let wubi = famoDefaultCustomYAML(from: snapshot(.wubi, angleSymbolMenu: true))
    XCTAssertTrue(wubi.contains("\"punctuator/half_shape/<\":"))
  }

  // MARK: - N3 ` 临时英文（五笔前缀英文通道）

  func testWubiEnglishChannelEmitsMeltEngWiringOnlyWhenEnabled() {
    // 开：每个五笔变体的 custom.yaml 都要有完整接线——alphabet 带 `、segmentors 整表替换
    // （affix 在 abc 之前，绝不能是 /+ 追加——那会排到 fallback 之后永远不执行）、melt_eng
    // 翻译器 + recognizer。四码上屏配置不被触碰。
    for target in famoWubiPatchTargets {
      let on = famoWubiCustomYAML(
        from: snapshot(.wubi, wubiEnglishChannel: true), target: target)
      XCTAssertTrue(
        on.contains("\"speller/alphabet\": \"zyxwvutsrqponmlkjihgfedcba`\""),
        "\(target.fileName): alphabet 必须带 `")
      XCTAssertTrue(on.contains("\"engine/segmentors\":"), "\(target.fileName): 整表替换")
      XCTAssertFalse(on.contains("\"engine/segmentors/+\""), "\(target.fileName): 绝不能 /+ 追加 segmentor")
      // affix_segmentor 必须排在 abc_segmentor 之前（顺序即语义）。
      if let affix = on.range(of: "affix_segmentor@melt_eng"),
         let abc = on.range(of: "- abc_segmentor") {
        XCTAssertTrue(affix.lowerBound < abc.lowerBound, "\(target.fileName): affix 需在 abc 之前")
      } else {
        XCTFail("\(target.fileName): 缺 affix_segmentor 或 abc_segmentor")
      }
      XCTAssertTrue(on.contains("- table_translator@melt_eng"), target.fileName)
      XCTAssertTrue(on.contains("dictionary: melt_eng"), target.fileName)
      XCTAssertTrue(on.contains("prefix: \"`\""), target.fileName)
      XCTAssertTrue(
        on.contains("\"recognizer/patterns/melt_eng\": \"^`[A-Za-z]*$\""), target.fileName)
    }

    // 关（缺省）：不产出任何 melt_eng 接线——五笔行为零变化。
    let off = famoWubiCustomYAML(from: snapshot(.wubi), target: famoWubiPatchTargets[0])
    XCTAssertFalse(off.contains("melt_eng"))
    XCTAssertFalse(off.contains("speller/alphabet"))
  }

  func testWubiModesAreFirstClassSchemaChoices() {
    let wubi = famoDefaultCustomYAML(from: snapshot(.wubi))
    let wubiSchemas = wubi.split(separator: "\n").filter { $0.contains("- { schema:") }
    XCTAssertTrue(wubiSchemas.first?.contains("wubi86_jidian }") == true)
    XCTAssertTrue(wubi.contains("wubi86_jidian_pinyin"))
    XCTAssertTrue(wubi.contains("wubi86_jidian_trad"))
    XCTAssertTrue(wubi.contains("wubi86_jidian_trad_pinyin"))

    let mixed = famoDefaultCustomYAML(from: snapshot(.wubi, wubiScheme: .pinyinMix))
    let mixedSchemas = mixed.split(separator: "\n").filter { $0.contains("- { schema:") }
    XCTAssertTrue(mixedSchemas.first?.contains("wubi86_jidian_pinyin") == true)
    XCTAssertTrue(mixed.contains("wubi86_jidian }"))
  }

  func testWubiCustomPatchEmitsCodeHintAutoClearAndSingleCharMode() {
    let normal = famoWubiCustomYAML(from: snapshot(.wubi), target: famoWubiPatchTargets[0])
    // 候选编码提示默认关：只压五笔那一路的注释。z 临时拼音反查的注释是主方案词典反查出的
    // 五笔编码（练习用），恒开，不跟着这个开关被 xform 抹掉。
    XCTAssertTrue(normal.contains("\"translator/comment_format\":\n    - xform/.+//"))
    XCTAssertTrue(normal.contains("\"reverse_lookup/comment_format\": []"))
    XCTAssertFalse(normal.contains("\"reverse_lookup/comment_format\":\n    - xform/.+//"))
    XCTAssertTrue(normal.contains("\"speller/auto_clear\": \"\""))
    XCTAssertFalse(normal.contains("lua_filter@*wubi86_jidian_single_char_first_filter"))
    XCTAssertFalse(normal.contains("lua_filter@*wubi86_jidian_single_char_only"))
    // z 反查默认开：不应清空 recognizer 反查正则。
    XCTAssertFalse(normal.contains("\"recognizer/patterns/reverse_lookup\": \"\""))
    XCTAssertTrue(normal.contains("\"reverse_lookup/prefix\": \"z\""))
    XCTAssertTrue(normal.contains("\"recognizer/patterns/reverse_lookup\": \"^z[a-z]*'?$\""))

    let zOff = famoWubiCustomYAML(from: snapshot(.wubi, wubiZReverseLookup: false), target: famoWubiPatchTargets[0])
    XCTAssertTrue(zOff.contains("\"recognizer/patterns/reverse_lookup\": \"\""))

    let singleFirst = famoWubiCustomYAML(from: snapshot(
      .wubi,
      wubiCodeHint: true,
      wubiAutoClear: true,
      wubiCandidateMode: .singleFirst
    ), target: famoWubiPatchTargets[0])
    XCTAssertTrue(singleFirst.contains("\"translator/comment_format\": []"))
    XCTAssertTrue(singleFirst.contains("\"reverse_lookup/comment_format\": []"))
    XCTAssertTrue(singleFirst.contains("\"speller/auto_clear\": max_length"))
    XCTAssertTrue(singleFirst.contains("lua_filter@*wubi86_jidian_single_char_first_filter"))
    XCTAssertFalse(singleFirst.contains("lua_filter@*wubi86_jidian_single_char_only"))

    let singleOnly = famoWubiCustomYAML(from: snapshot(.wubi, wubiCandidateMode: .singleOnly), target: famoWubiPatchTargets[0])
    XCTAssertTrue(singleOnly.contains("lua_filter@*wubi86_jidian_single_char_only"))
    XCTAssertFalse(singleOnly.contains("lua_filter@*wubi86_jidian_single_char_first_filter"))
  }

  func testAppEnglishBundleIDsUseRimeAppOptions() {
    // app_options → famo 域 (famo.custom.yaml, task 07-08), the only domain getAppOptions reads.
    let yaml = famoAppOptionsCustomYAML(from: FamoKeyboardSnapshot(
      inputMethod: .pinyin,
      doublePinyin: .flypy,
      shiftSwitchCJK: true,
      cjkPunctToggle: false,
      pageSize: 8,
      pageMinusEquals: true,
      pageBrackets: true,
      pageCommaPeriod: false,
      select23Semicolon: false,
      fuzzy: fuzzyOff,
      wubiCodeHint: false,
      wubiAutoClear: false,
      wubiCandidateMode: .normal,
      appEnglishBundleIDs: ["com.example.Editor", "bad:key"]
    ))
    XCTAssertTrue(yaml.contains("\"app_options/com.example.Editor/ascii_mode\": true"))
    XCTAssertFalse(yaml.contains("bad:key"))
  }

  func testAppEnglishBundleIDParserDedupesAndRejectsUnsafeInput() {
    XCTAssertEqual(
      FamoKeyboardPreferences.normalizedAppEnglishBundleIDs(
        from: "com.apple.Terminal, com.apple.Terminal\nbad:key org.gnu.Emacs"
      ),
      ["com.apple.Terminal", "org.gnu.Emacs"]
    )
  }

  func testRemovingAppEnglishBundleIDsDoesNotChangeGlobalInputMethod() {
    let previousInputMethod = FamoKeyboardPreferences.inputMethod
    let previousAppEnglishBundleIDs = FamoKeyboardPreferences.appEnglishBundleIDs
    defer {
      FamoKeyboardPreferences.inputMethod = previousInputMethod
      FamoKeyboardPreferences.appEnglishBundleIDs = previousAppEnglishBundleIDs
    }

    FamoKeyboardPreferences.inputMethod = .wubi
    FamoKeyboardPreferences.appEnglishBundleIDs = ["com.apple.TextEdit", "com.google.Chrome"]
    FamoKeyboardPreferences.appEnglishBundleIDs = []

    XCTAssertEqual(FamoKeyboardPreferences.inputMethod, .wubi)
    XCTAssertEqual(FamoKeyboardPreferences.appEnglishBundleIDs, [])

    let yaml = famoDefaultCustomYAML(from: FamoKeyboardSnapshot.current())
    let schemas = yaml.split(separator: "\n").filter { $0.contains("- { schema:") }
    XCTAssertTrue(schemas.first?.contains("wubi86_jidian") == true)
    XCTAssertFalse(yaml.contains("\"app_options/"))
  }

  func testRetiredSlashToDunNeverEmits() {
    // slash→顿号 已按机主 07-21 拍板整体下线：任何快照都不得再产出 `/` 的 punctuator patch，
    // 托管块重生成后 `/` 回归 rime-ice 原生行为。
    let yaml = famoDefaultCustomYAML(from: snapshot(.pinyin, angleSymbolMenu: true))
    XCTAssertFalse(yaml.contains("\"/\": ["), "retired slash→顿号 leaked back into the patch")
    XCTAssertFalse(yaml.contains("punctuator/half_shape/+"), "旧 /+ 合并块应随 slash→顿号 一起消失")
  }

  func testRimeBackedKeyboardControlsEmitExpectedPatchKeys() {
    let yaml = famoDefaultCustomYAML(from: snapshot(
      .pinyin,
      cjkPunctToggle: true,
      pageMinusEquals: true,
      pageBrackets: true,
      pageCommaPeriod: true,
      select23Semicolon: true,
      angleSymbolMenu: true
    ))

    XCTAssertTrue(yaml.contains("ascii_composer/switch_key/Shift_L"))
    XCTAssertTrue(yaml.contains("ascii_composer/switch_key/Shift_R"))
    XCTAssertTrue(yaml.contains("toggle: ascii_punct"))
    XCTAssertTrue(yaml.contains("accept: minus"))
    XCTAssertTrue(yaml.contains("accept: bracketleft"))
    XCTAssertTrue(yaml.contains("accept: comma"))
    XCTAssertTrue(yaml.contains("send: 2"))
    XCTAssertTrue(yaml.contains("send: 3"))
    // punctuator 断言改由 `<` 符号选单承载（slash→顿号 已下线）。
    XCTAssertTrue(yaml.contains("punctuator/half_shape/<"))
    XCTAssertFalse(yaml.contains("Super_L"))
  }

  func testFuzzyPinyinEmitsSchemaLevelConfigOnlyWhenEnabled() throws {
    let fuzzyOn = FamoFuzzySnapshot(
      zhz: true, chc: false, shs: false, nl: false, rl: false,
      fh: false, anang: true, eneng: false, ining: false
    )
    let enabled = snapshot(.pinyin, fuzzy: fuzzyOn)

    XCTAssertFalse(famoDefaultCustomYAML(from: enabled).contains("speller/algebra"))
    XCTAssertFalse(famoRimeIceCustomYAML(from: snapshot(.pinyin)).contains("speller/algebra"))

    let rimeIceYAML = famoRimeIceCustomYAML(from: enabled)
    XCTAssertTrue(rimeIceYAML.contains("\"speller/algebra/+\""))
    XCTAssertTrue(rimeIceYAML.contains("derive/^zh/z/"))
    XCTAssertTrue(rimeIceYAML.contains("derive/an$/ang/"))

    let rimeIceFile = try XCTUnwrap(
      FamoManagedKeyboardPatchPlan.files(from: enabled)
        .first { $0.fileName == "rime_ice.custom.yaml" }
    )
    XCTAssertTrue(rimeIceFile.block.yamlLinesIndentedUnderPatch.contains { $0.contains("derive/^zh/z/") })
  }

  func testFuzzyPinyinPlanClearsManagedBlockWhenDisabled() throws {
    let rimeIceFile = try XCTUnwrap(
      FamoManagedKeyboardPatchPlan.files(from: snapshot(.pinyin))
        .first { $0.fileName == "rime_ice.custom.yaml" }
    )

    XCTAssertTrue(rimeIceFile.block.yamlLinesIndentedUnderPatch.isEmpty)
  }

  func testKeyboardAutoApplyStatusReportsDeployFailureAsNotEffective() {
    let status = FamoKeyboardPage.autoApplyStatusMessage(
      written: ["default.custom.yaml"],
      deploySucceeded: false
    )

    // PR3: copy moved from deploy-implying "重新部署失败" to immediate "应用失败".
    XCTAssertTrue(status.contains("应用失败"))
    XCTAssertFalse(status.contains("重新部署"))
    XCTAssertTrue(status.contains("改动未生效"))
  }
}
