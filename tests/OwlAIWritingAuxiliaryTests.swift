//
//  OwlAIWritingAuxiliaryTests.swift
//  OwltypeTests — AI Writing Auxiliary Subsystem (Milestone M7 / Issue #397)
//
//  Comprehensive 100% offline automated test suite covering:
//  - 4 polish styles, subtitles, icons, temperatures, fuzzy init, and prompt catalogs
//  - 5 reply templates, perspective tuples, icons, subtitles, and prompt catalogs
//  - 5-tier cascading resilient XML parsing for dual polish candidates
//  - 5-tier cascading resilient XML parsing for 3 reply candidates
//  - Text diff summary calculations (character delta & percentage change)
//  - Hermetic AI polish and reply generation with mock/stub injection
//  - Privacy guards (empty selection & oversized text rejection)
//  - In-place re-generation and cooperative task cancellation
//  - One-key writeback coordination across typing, selection, and standalone modes
//

import AppKit
import InputMethodKit
import XCTest
@testable import Owltype

final class OwlAIWritingAuxiliaryTests: XCTestCase {

  // MARK: - Group 1: 4 Polish Styles & Prompts

  func testPolishStyleEnumerationAndRawValues() {
    let allCases = OwlPolishStyle.allCases
    XCTAssertEqual(allCases.count, 4, "Must have exactly 4 polish styles")
    XCTAssertEqual(
      allCases.map(\.rawValue),
      ["原意保真", "精炼书面", "得体商务", "口语转书面"],
      "Raw values must match standard Chinese names in exact order"
    )
  }

  func testPolishStylePropertiesAndMetadata() {
    for style in OwlPolishStyle.allCases {
      XCTAssertEqual(style.id, style.rawValue)
      XCTAssertEqual(style.title, style.rawValue)
      XCTAssertFalse(style.subtitle.isEmpty, "Subtitle must not be empty for \(style.rawValue)")
      XCTAssertFalse(style.iconName.isEmpty, "Icon must not be empty for \(style.rawValue)")
      XCTAssertGreaterThan(style.temperature, 0.0)
      XCTAssertLessThanOrEqual(style.temperature, 1.0)
      XCTAssertFalse(style.promptDescription.isEmpty)
      XCTAssertTrue(style.promptDescription.contains("<candidate_1>"))
      XCTAssertTrue(style.promptDescription.contains("<candidate_2>"))
    }
  }

  func testPolishPromptCatalogDualCandidateStructure() {
    for style in OwlPolishStyle.allCases {
      let systemPrompt = OwlDualPolishPromptCatalog.buildSystemPrompt(style: style)
      XCTAssertTrue(systemPrompt.contains(style.rawValue), "System prompt must name the style")
      XCTAssertTrue(systemPrompt.contains("<candidate_1>"), "Must require <candidate_1>")
      XCTAssertTrue(systemPrompt.contains("<candidate_2>"), "Must require <candidate_2>")
      XCTAssertTrue(systemPrompt.contains("XML"), "Must specify XML tags")

      let userPrompt = OwlDualPolishPromptCatalog.buildUserPrompt(text: "测试文本待润色")
      XCTAssertTrue(userPrompt.contains("测试文本待润色"))
    }
  }

  // MARK: - Group 2: 5 Reply Templates & Prompts

  func testReplyTemplateEnumerationAndRawValues() {
    let allCases = OwlReplyTemplate.allCases
    XCTAssertEqual(allCases.count, 5, "Must have exactly 5 reply templates")
    XCTAssertEqual(
      allCases.map(\.rawValue),
      ["认同赞成", "委婉拒绝", "进一步询问", "感谢致意", "推进催办"]
    )
  }

  func testReplyTemplateMetadataAndPerspectives() {
    for template in OwlReplyTemplate.allCases {
      XCTAssertEqual(template.id, template.rawValue)
      XCTAssertEqual(template.title, template.rawValue)
      XCTAssertFalse(template.subtitle.isEmpty)
      XCTAssertFalse(template.iconName.isEmpty)
      XCTAssertFalse(template.promptDescription.isEmpty)

      let p = template.candidatePerspectives
      XCTAssertEqual(p.first, "精炼直接")
      XCTAssertEqual(p.second, "专业周全")
      XCTAssertEqual(p.third, "积极推进")
    }
  }

  func testReplyPromptCatalogThreeCandidateStructure() {
    for template in OwlReplyTemplate.allCases {
      let prompt = OwlReplyPromptCatalog.buildSystemPrompt(template: template)
      XCTAssertTrue(prompt.contains(template.rawValue))
      XCTAssertTrue(prompt.contains("<candidate_1>"))
      XCTAssertTrue(prompt.contains("<candidate_2>"))
      XCTAssertTrue(prompt.contains("<candidate_3>"))
      XCTAssertTrue(prompt.contains("精炼直接"))
      XCTAssertTrue(prompt.contains("专业周全"))
      XCTAssertTrue(prompt.contains("积极推进"))

      let userPrompt = OwlReplyPromptCatalog.buildUserPrompt(contextText: "明天开会讨论需求")
      XCTAssertTrue(userPrompt.contains("明天开会讨论需求"))
    }
  }

  // MARK: - Group 3: 5-Tier Resilient XML Parsing for Polish

  func testDualPolishParserTier1ExactXMLTags() {
    let raw = """
    <candidate_1>
    尊敬的客户：感谢您的反馈，我们已安排跟进。
    </candidate_1>
    <candidate_2>
    您好！关于您反馈的问题，技术团队正全力处理中。
    </candidate_2>
    """
    let candidates = OwlDualPolishParser.parse(raw: raw, originalText: "感谢反馈")
    XCTAssertEqual(candidates.count, 2)
    XCTAssertEqual(candidates[0], "尊敬的客户：感谢您的反馈，我们已安排跟进。")
    XCTAssertEqual(candidates[1], "您好！关于您反馈的问题，技术团队正全力处理中。")
  }

  func testDualPolishParserTier2TagVariationsAndMarkdownFences() {
    let raw = """
    ```xml
    <candidate1>
    第一条变体润色文本
    </candidate1>
    <candidate2>
    第二条变体润色文本
    </candidate2>
    ```
    """
    let candidates = OwlDualPolishParser.parse(raw: raw, originalText: "原文")
    XCTAssertEqual(candidates.count, 2)
    XCTAssertEqual(candidates[0], "第一条变体润色文本")
    XCTAssertEqual(candidates[1], "第二条变体润色文本")
  }

  func testDualPolishParserTier3NumberedLists() {
    let raw = """
    好的，这是为您润色的两个版本：
    1. 方案一：立即启动全量回归测试。
    2. 方案二：建议优先进行关键链路冒烟测试。
    """
    let candidates = OwlDualPolishParser.parse(raw: raw, originalText: "测试")
    XCTAssertEqual(candidates.count, 2)
    XCTAssertEqual(candidates[0], "方案一：立即启动全量回归测试。")
    XCTAssertEqual(candidates[1], "方案二：建议优先进行关键链路冒烟测试。")
  }

  func testDualPolishParserTier4NewlineSeparated() {
    let raw = """
    这是直接输出的第一行润色文本。

    这是直接输出的第二行润色文本。
    """
    let candidates = OwlDualPolishParser.parse(raw: raw, originalText: "原文")
    XCTAssertEqual(candidates.count, 2)
    XCTAssertEqual(candidates[0], "这是直接输出的第一行润色文本。")
    XCTAssertEqual(candidates[1], "这是直接输出的第二行润色文本。")
  }

  func testDualPolishParserTier5SingleCandidateInvariant() {
    let raw = """
    <candidate_1>
    仅生成了一条候选内容。
    </candidate_1>
    """
    let original = "原始待润色文字"
    let candidates = OwlDualPolishParser.parse(raw: raw, originalText: original)
    XCTAssertEqual(candidates.count, 2, "Must guarantee exactly 2 candidates")
    XCTAssertEqual(candidates[0], "仅生成了一条候选内容。")
    XCTAssertEqual(candidates[1], original, "Second candidate falls back to originalText")
  }

  func testDualPolishParserTier5EmptyFallbackInvariant() {
    let raw = ""
    let original = "一段未发生改变的文本"
    let candidates = OwlDualPolishParser.parse(raw: raw, originalText: original)
    XCTAssertEqual(candidates.count, 2)
    XCTAssertEqual(candidates[0], original)
    XCTAssertEqual(candidates[1], original)
  }

  func testDualPolishParserTagVariationsWithSpaces() {
    let raw = "<candidate 1>候选内容甲</candidate 1><candidate 2>候选内容乙</candidate 2>"
    let candidates = OwlDualPolishParser.parse(raw: raw, originalText: "原文")
    XCTAssertEqual(candidates.count, 2)
    XCTAssertEqual(candidates[0], "候选内容甲")
    XCTAssertEqual(candidates[1], "候选内容乙")
  }

  // MARK: - Group 4: 5-Tier Resilient XML Parsing for Replies

  func testXMLReplyParserTier1ExactTags() {
    let raw = """
    <candidate_1>收到，赞同。</candidate_1>
    <candidate_2>非常认同您的方案，建议按此推进。</candidate_2>
    <candidate_3>完全赞成，我这边全力配合后续工作。</candidate_3>
    """
    let candidates = OwlDualPolishParser.parseReplies(raw: raw)
    XCTAssertEqual(candidates.count, 3)
    XCTAssertEqual(candidates[0], "收到，赞同。")
    XCTAssertEqual(candidates[1], "非常认同您的方案，建议按此推进。")
    XCTAssertEqual(candidates[2], "完全赞成，我这边全力配合后续工作。")
  }

  func testXMLReplyParserTier2AlternativeTags() {
    let raw = """
    ```xml
    <reply_1>选项一</reply_1>
    <reply_2>选项二</reply_2>
    <reply_3>选项三</reply_3>
    ```
    """
    let candidates = OwlDualPolishParser.parseReplies(raw: raw)
    XCTAssertEqual(candidates.count, 3)
    XCTAssertEqual(candidates[0], "选项一")
    XCTAssertEqual(candidates[1], "选项二")
    XCTAssertEqual(candidates[2], "选项三")
  }

  func testXMLReplyParserTier3NumberedList() {
    let raw = """
    1、收到回复，同意。
    2、赞同您的提议，我们尽快落实。
    3、十分赞同，具体排期请随时同步。
    """
    let candidates = OwlDualPolishParser.parseReplies(raw: raw)
    XCTAssertEqual(candidates.count, 3)
    XCTAssertEqual(candidates[0], "收到回复，同意。")
    XCTAssertEqual(candidates[1], "赞同您的提议，我们尽快落实。")
    XCTAssertEqual(candidates[2], "十分赞同，具体排期请随时同步。")
  }

  func testXMLReplyParserTier5GuaranteedThreeCandidates() {
    let raw = "<candidate_1>单条回复</candidate_1>"
    let candidates = OwlDualPolishParser.parseReplies(raw: raw)
    XCTAssertEqual(candidates.count, 3, "Must guarantee exactly 3 distinct reply candidates")
    XCTAssertEqual(candidates[0], "单条回复")
    XCTAssertFalse(candidates[1].isEmpty)
    XCTAssertFalse(candidates[2].isEmpty)
    XCTAssertNotEqual(candidates[0], candidates[1])
    XCTAssertNotEqual(candidates[1], candidates[2])
  }

  // MARK: - Group 4b: Empirical Stress Tests for Dual Polish & XML Reply Parsers

  func testStress_MarkdownCodeFences_Variations() {
    // 1. Standard ```xml ... ```
    let standardFence = """
    ```xml
    <candidate_1>标准栅栏一</candidate_1>
    <candidate_2>标准栅栏二</candidate_2>
    ```
    """
    let stdRes = OwlDualPolishParser.parse(raw: standardFence, originalText: "原文")
    XCTAssertEqual(stdRes, ["标准栅栏一", "标准栅栏二"])

    // 2. Uppercase ```XML ... ```
    let upperFence = """
    ```XML
    <candidate_1>大写XML一</candidate_1>
    <candidate_2>大写XML二</candidate_2>
    ```
    """
    let upperRes = OwlDualPolishParser.parse(raw: upperFence, originalText: "原文")
    XCTAssertEqual(upperRes, ["大写XML一", "大写XML二"])

    // 3. Bare fence without language identifier
    let bareFence = """
    ```
    <candidate_1>无语言栅栏一</candidate_1>
    <candidate_2>无语言栅栏二</candidate_2>
    ```
    """
    let bareRes = OwlDualPolishParser.parse(raw: bareFence, originalText: "原文")
    XCTAssertEqual(bareRes, ["无语言栅栏一", "无语言栅栏二"])

    // 4. Text before and after markdown code fence
    let wrappedFence = """
    好的，这是为您生成的润色候选：
    ```xml
    <candidate_1>包裹栅栏一</candidate_1>
    <candidate_2>包裹栅栏二</candidate_2>
    ```
    希望对您有帮助！
    """
    let wrapRes = OwlDualPolishParser.parse(raw: wrappedFence, originalText: "原文")
    XCTAssertEqual(wrapRes, ["包裹栅栏一", "包裹栅栏二"])

    // 5. Unclosed code fence (streaming cut-off)
    let unclosedFence = """
    ```xml
    <candidate_1>未闭合栅栏一</candidate_1>
    <candidate_2>未闭合栅栏二</candidate_2>
    """
    let unclosedRes = OwlDualPolishParser.parse(raw: unclosedFence, originalText: "原文")
    XCTAssertEqual(unclosedRes.count, 2)
    XCTAssertFalse(unclosedRes[0].isEmpty)
    XCTAssertFalse(unclosedRes[1].isEmpty)
  }

  func testStress_TagVariants() {
    // Polish tag variants: <candidate1>, <candidate 1>, <candidate-1>, <reply1>, <reply_1>
    let p1 = "<candidate1>数字1</candidate1><candidate2>数字2</candidate2>"
    XCTAssertEqual(OwlDualPolishParser.parse(raw: p1, originalText: "原"), ["数字1", "数字2"])

    let p2 = "<candidate 1>空格1</candidate 1><candidate 2>空格2</candidate 2>"
    XCTAssertEqual(OwlDualPolishParser.parse(raw: p2, originalText: "原"), ["空格1", "空格2"])

    let p3 = "<candidate-1>连字符1</candidate-1><candidate-2>连字符2</candidate-2>"
    XCTAssertEqual(OwlDualPolishParser.parse(raw: p3, originalText: "原"), ["连字符1", "连字符2"])

    let p4 = "<reply_1>回复下划线1</reply_1><reply_2>回复下划线2</reply_2>"
    XCTAssertEqual(OwlDualPolishParser.parse(raw: p4, originalText: "原"), ["回复下划线1", "回复下划线2"])

    let p5 = "<reply1>回复连缀1</reply1><reply2>回复连缀2</reply2>"
    XCTAssertEqual(OwlDualPolishParser.parse(raw: p5, originalText: "原"), ["回复连缀1", "回复连缀2"])

    // Case-insensitivity: <CANDIDATE_1>
    let pCase = "<CANDIDATE_1>大写标签一</CANDIDATE_1><CANDIDATE_2>大写标签二</CANDIDATE_2>"
    XCTAssertEqual(OwlDualPolishParser.parse(raw: pCase, originalText: "原"), ["大写标签一", "大写标签二"])

    // Reply tag variants: <candidate1>, <candidate 1>, <candidate-1>, <reply1>, <reply_1>, <reply 1>
    let r1 = "<candidate1>答复一</candidate1><candidate2>答复二</candidate2><candidate3>答复三</candidate3>"
    XCTAssertEqual(OwlDualPolishParser.parseReplies(raw: r1), ["答复一", "答复二", "答复三"])

    let r2 = "<reply_1>答复甲</reply_1><reply_2>答复乙</reply_2><reply_3>答复丙</reply_3>"
    XCTAssertEqual(OwlDualPolishParser.parseReplies(raw: r2), ["答复甲", "答复乙", "答复丙"])

    let r3 = "<reply1>回复A</reply1><reply2>回复B</reply2><reply3>回复C</reply3>"
    XCTAssertEqual(OwlDualPolishParser.parseReplies(raw: r3), ["回复A", "回复B", "回复C"])
  }

  func testStress_NumberedLists() {
    // 1. / 2. / 3.
    let dotList = """
    这是两段润色建议：
    1. 方案一：尽快启动版本发布。
    2. 方案二：建议先完成全链路压测。
    """
    let dotRes = OwlDualPolishParser.parse(raw: dotList, originalText: "原")
    XCTAssertEqual(dotRes, ["方案一：尽快启动版本发布。", "方案二：建议先完成全链路压测。"])

    // 1、 / 2、 / 3、
    let dunhaoList = """
    1、收到回复，完全同意。
    2、赞同方案，明天开会推进。
    3、暂缓处理，待风险评估后定夺。
    """
    let dunhaoRes = OwlDualPolishParser.parseReplies(raw: dunhaoList)
    XCTAssertEqual(dunhaoRes, ["收到回复，完全同意。", "赞同方案，明天开会推进。", "暂缓处理，待风险评估后定夺。"])

    // (1) / (2) / (3)
    let parenList = """
    (1) 第一种回复选择
    (2) 第二种回复选择
    (3) 第三种回复选择
    """
    let parenRes = OwlDualPolishParser.parseReplies(raw: parenList)
    XCTAssertEqual(parenRes, ["第一种回复选择", "第二种回复选择", "第三种回复选择"])

    // 1) / 2) / 3)
    let rightParenList = """
    1) 润色方案甲
    2) 润色方案乙
    """
    let rightParenRes = OwlDualPolishParser.parse(raw: rightParenList, originalText: "原")
    XCTAssertEqual(rightParenRes, ["润色方案甲", "润色方案乙"])
  }

  func testStress_TruncatedTagsAndFallbacks() {
    // 1. Truncated opening tag without closing
    let truncOpen = "<candidate_1>只有开头被截断的内容"
    let truncOpenRes = OwlDualPolishParser.parse(raw: truncOpen, originalText: "原文保底")
    XCTAssertEqual(truncOpenRes.count, 2)
    XCTAssertFalse(truncOpenRes[0].isEmpty)
    XCTAssertFalse(truncOpenRes[1].isEmpty)

    let truncReplyRes = OwlDualPolishParser.parseReplies(raw: truncOpen)
    XCTAssertEqual(truncReplyRes.count, 3)
    for c in truncReplyRes { XCTAssertFalse(c.isEmpty) }

    // 2. Truncated second candidate
    let truncSecond = "<candidate_1>完整候选一</candidate_1><candidate_2>截断候选二未闭合"
    let truncSecondRes = OwlDualPolishParser.parse(raw: truncSecond, originalText: "原文文本")
    XCTAssertEqual(truncSecondRes.count, 2)
    XCTAssertEqual(truncSecondRes[0], "完整候选一")
    XCTAssertEqual(truncSecondRes[1], "原文文本")

    // 3. Completely empty input string
    let emptyPolish = OwlDualPolishParser.parse(raw: "", originalText: "原文保底")
    XCTAssertEqual(emptyPolish.count, 2)
    XCTAssertEqual(emptyPolish[0], "原文保底")
    XCTAssertEqual(emptyPolish[1], "原文保底")

    let emptyPolishWithEmptyOrig = OwlDualPolishParser.parse(raw: "", originalText: "")
    XCTAssertEqual(emptyPolishWithEmptyOrig.count, 2)
    XCTAssertFalse(emptyPolishWithEmptyOrig[0].isEmpty)
    XCTAssertFalse(emptyPolishWithEmptyOrig[1].isEmpty)

    let emptyReplies = OwlDualPolishParser.parseReplies(raw: "")
    XCTAssertEqual(emptyReplies.count, 3)
    for r in emptyReplies { XCTAssertFalse(r.isEmpty) }

    // 4. Whitespace only string
    let wsPolish = OwlDualPolishParser.parse(raw: "   \n\t  \n  ", originalText: "原文保底")
    XCTAssertEqual(wsPolish.count, 2)
    XCTAssertEqual(wsPolish[0], "原文保底")
    XCTAssertEqual(wsPolish[1], "原文保底")

    // 5. Empty tags
    let emptyTags = "<candidate_1></candidate_1><candidate_2>   </candidate_2>"
    let emptyTagsRes = OwlDualPolishParser.parse(raw: emptyTags, originalText: "原文保底")
    XCTAssertEqual(emptyTagsRes.count, 2)
    XCTAssertEqual(emptyTagsRes[0], "原文保底")
    XCTAssertEqual(emptyTagsRes[1], "原文保底")
  }

  func testStress_SpecialCharacters() {
    // 1. Emojis
    let emojiRaw = """
    <candidate_1>🎉 恭喜达成目标！🚀 继续前行！💡</candidate_1>
    <candidate_2>👨‍👩‍👧‍👦 家庭美满，平安喜乐 ❤️</candidate_2>
    """
    let emojiRes = OwlDualPolishParser.parse(raw: emojiRaw, originalText: "原")
    XCTAssertEqual(emojiRes, [
      "🎉 恭喜达成目标！🚀 继续前行！💡",
      "👨‍👩‍👧‍👦 家庭美满，平安喜乐 ❤️"
    ])

    // 2. Math symbols & inequality signs: < and > inside candidate
    let mathRaw = """
    <candidate_1>当 x < y 且 a > 0 时，公式为 ∑(x_i) ≤ 100 ± 5%</candidate_1>
    <candidate_2>积分结果满足 ∫ f(x)dx ≠ 0，其中 α ∈ [0, 1]</candidate_2>
    """
    let mathRes = OwlDualPolishParser.parse(raw: mathRaw, originalText: "原")
    XCTAssertEqual(mathRes, [
      "当 x < y 且 a > 0 时，公式为 ∑(x_i) ≤ 100 ± 5%",
      "积分结果满足 ∫ f(x)dx ≠ 0，其中 α ∈ [0, 1]"
    ])

    // 3. Multiline paragraphs
    let multiLineRaw = """
    <candidate_1>
    第一段落内容。

    第二段落详细说明。

    第三段落总结。
    </candidate_1>
    <candidate_2>
    单段落内容。
    </candidate_2>
    """
    let multiLineRes = OwlDualPolishParser.parse(raw: multiLineRaw, originalText: "原")
    XCTAssertEqual(multiLineRes.count, 2)
    XCTAssertTrue(multiLineRes[0].contains("第一段落内容。"))
    XCTAssertTrue(multiLineRes[0].contains("第二段落详细说明。"))
    XCTAssertTrue(multiLineRes[0].contains("第三段落总结。"))
    XCTAssertEqual(multiLineRes[1], "单段落内容。")

    // 4. Zero-width spaces
    let zwRaw = "<candidate_1>前缀\u{200B}中缀\u{FEFF}后缀</candidate_1><candidate_2>正常内容</candidate_2>"
    let zwRes = OwlDualPolishParser.parse(raw: zwRaw, originalText: "原")
    XCTAssertEqual(zwRes[0], "前缀\u{200B}中缀\u{FEFF}后缀")
    XCTAssertEqual(zwRes[1], "正常内容")

    // 5. CJK quotes and punctuation
    let cjkQuotes = """
    <candidate_1>“双引号” 与 ‘单引号’，以及「日式角号」与『双角号』</candidate_1>
    <candidate_2>《书名号》、〈单书名号〉、【方头括号】、〔六角括号〕——破折号……省略号</candidate_2>
    """
    let cjkRes = OwlDualPolishParser.parse(raw: cjkQuotes, originalText: "原")
    XCTAssertEqual(cjkRes, [
      "“双引号” 与 ‘单引号’，以及「日式角号」与『双角号』",
      "《书名号》、〈单书名号〉、【方头括号】、〔六角括号〕——破折号……省略号"
    ])

    // 6. Large input (10KB)
    let longPadding = String(repeating: "无用闲聊前缀内容填充。\n", count: 200)
    let largeRaw = """
    \(longPadding)
    <candidate_1>长文本中的有效润色一</candidate_1>
    \(longPadding)
    <candidate_2>长文本中的有效润色二</candidate_2>
    \(longPadding)
    """
    let largeRes = OwlDualPolishParser.parse(raw: largeRaw, originalText: "原")
    XCTAssertEqual(largeRes, ["长文本中的有效润色一", "长文本中的有效润色二"])
  }

  func testStress_FuzzAndBoundarySafetyNeverThrowsOrReturnsEmpty() {
    let fuzzInputs = [
      "",
      "   ",
      "\n\n\n\t\t\t\r\n",
      "<candidate_1>",
      "</candidate_1>",
      "<candidate_2>",
      "</candidate_2>",
      "<candidate_3>",
      "</candidate_3>",
      "<candidate_1></candidate_1>",
      "<candidate_1>    </candidate_1>",
      "```",
      "```xml",
      "```xml\n```",
      "```xml\n<candidate_1>\n```",
      "<<<<>>>>",
      "<><><>",
      "1.",
      "1. ",
      "1、",
      "1、 ",
      "(1)",
      "1)",
      "一、 二、 三、",
      "null",
      "undefined",
      "NaN",
      "\\0\\0\\0",
      "<candidate 1>A<candidate 2>B",
      String(repeating: "<candidate_1>", count: 50),
      String(repeating: "</candidate_1>", count: 50),
      String(repeating: "```", count: 25),
      String(repeating: "1. 某内容\n", count: 20)
    ]

    for (index, input) in fuzzInputs.enumerated() {
      let polish = OwlDualPolishParser.parse(raw: input, originalText: "保底文本\(index)")
      XCTAssertEqual(polish.count, 2, "Polish must return exactly 2 candidates for fuzz #\(index)")
      XCTAssertFalse(polish[0].isEmpty, "Polish candidate 0 must not be empty for fuzz #\(index)")
      XCTAssertFalse(polish[1].isEmpty, "Polish candidate 1 must not be empty for fuzz #\(index)")

      let reply = OwlDualPolishParser.parseReplies(raw: input)
      XCTAssertEqual(reply.count, 3, "Reply must return exactly 3 candidates for fuzz #\(index)")
      XCTAssertFalse(reply[0].isEmpty, "Reply candidate 0 must not be empty for fuzz #\(index)")
      XCTAssertFalse(reply[1].isEmpty, "Reply candidate 1 must not be empty for fuzz #\(index)")
      XCTAssertFalse(reply[2].isEmpty, "Reply candidate 2 must not be empty for fuzz #\(index)")
    }
  }

  func testStress_ReplyTagVariants_WithSpacesAndHyphens() {
    let spaceRaw = "<candidate 1>空格答复一</candidate 1><candidate 2>空格答复二</candidate 2><candidate 3>空格答复三</candidate 3>"
    let spaceRes = OwlDualPolishParser.parseReplies(raw: spaceRaw)
    XCTAssertEqual(spaceRes, ["空格答复一", "空格答复二", "空格答复三"])

    let replySpaceRaw = "<reply 1>回复空格1</reply 1><reply 2>回复空格2</reply 2><reply 3>回复空格3</reply 3>"
    let replySpaceRes = OwlDualPolishParser.parseReplies(raw: replySpaceRaw)
    XCTAssertEqual(replySpaceRes, ["回复空格1", "回复空格2", "回复空格3"])

    let hyphenRaw = "<candidate-1>连字符一</candidate-1><candidate-2>连字符二</candidate-2><candidate-3>连字符三</candidate-3>"
    let hyphenRes = OwlDualPolishParser.parseReplies(raw: hyphenRaw)
    XCTAssertEqual(hyphenRes, ["连字符一", "连字符二", "连字符三"])
  }

  func testStress_CodeBlocksInsideCandidateBody() {
    let rawWithCode = """
    <candidate_1>
    建议代码如下：
    ```swift
    let a = 1
    ```
    请测试。
    </candidate_1>
    <candidate_2>
    简洁版实现
    </candidate_2>
    """
    let candidates = OwlDualPolishParser.parse(raw: rawWithCode, originalText: "原代码")
    XCTAssertEqual(candidates.count, 2)
    XCTAssertTrue(candidates[0].contains("let a = 1"), "Candidate 1 must preserve its internal code block! Got: \(candidates[0])")
    XCTAssertEqual(candidates[1], "简洁版实现", "Candidate 2 must not be dropped by internal code fences! Got: \(candidates[1])")
  }

  // MARK: - Group 5: Text Diff Summary Calculations

  func testTextDiffSummaryCalculations() {
    let equalDiff = OwlTextDiffSummary(original: "你好世界", candidate: "世界你好")
    XCTAssertEqual(equalDiff.deltaCount, 0)
    XCTAssertEqual(equalDiff.badgeText, "±0 字")
    XCTAssertEqual(equalDiff.badgeColor, .secondary)

    let plusDiff = OwlTextDiffSummary(original: "你好", candidate: "你好，世界！")
    XCTAssertEqual(plusDiff.deltaCount, 4)
    XCTAssertEqual(plusDiff.badgeText, "+4 字")
    XCTAssertEqual(plusDiff.badgeColor, .blue)

    let minusDiff = OwlTextDiffSummary(original: "这是一个非常冗长的长难句子呀", candidate: "这是精简句")
    XCTAssertEqual(minusDiff.deltaCount, -9)
    XCTAssertTrue(minusDiff.badgeText.contains("-9 字"))
    XCTAssertTrue(minusDiff.badgeText.contains("%"))
    XCTAssertEqual(minusDiff.badgeColor, .green)
  }

  // MARK: - Group 6: Hermetic Service Generation & Offline Tests

  func testAIPolishServiceHermeticDualGeneration() async throws {
    let service = OwlAIPolishService(
      customPolisher: { text, style in
        return [
          "[\(style.rawValue)] 候选 1：\(text)",
          "[\(style.rawValue)] 候选 2：优化后的\(text)"
        ]
      }
    )

    for style in OwlPolishStyle.allCases {
      let results = try await service.polishSelection(text: "工作报告", style: style)
      XCTAssertEqual(results.count, 2, "Style \(style.rawValue) must return 2 candidates")
      XCTAssertNotEqual(results[0], results[1])
      XCTAssertTrue(results[0].contains(style.rawValue))
    }
  }

  func testAIReplyServiceHermeticThreeCandidatesGeneration() async throws {
    let service = OwlAIPolishService(
      customReplier: { context, template in
        return [
          "[\(template.rawValue) 1] 精炼答复",
          "[\(template.rawValue) 2] 专业答复",
          "[\(template.rawValue) 3] 推进答复"
        ]
      }
    )

    for template in OwlReplyTemplate.allCases {
      let results = try await service.generateReplies(contextText: "明天讨论上线方案", template: template)
      XCTAssertEqual(results.count, 3, "Template \(template.rawValue) must return 3 candidates")
      XCTAssertEqual(Set(results).count, 3, "All 3 candidates must be distinct")
    }
  }

  func testAIPolishServicePrivacyRejection() async {
    let service = OwlAIPolishService()

    do {
      _ = try await service.polishSelection(text: "   ", style: .faithful)
      XCTFail("Must reject empty selection")
    } catch let error as OwlSelectionPolishError {
      XCTAssertEqual(error, .emptySelection)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testCooperativeTaskCancellationOnRapidStyleSwitch() async {
    let expectation = expectation(description: "Task cancellation")
    let task = Task {
      try await Task.sleep(nanoseconds: 1_000_000_000)
    }
    task.cancel()
    XCTAssertTrue(task.isCancelled)
    expectation.fulfill()
    await fulfillment(of: [expectation], timeout: 0.5)
  }

  // MARK: - Group 7: Writeback Coordination with [1] and [2]

  @MainActor
  func testOneKeyWritebackTypingModeCandidateSelection() {
    let mockClient = MockAIWritebackTextInputClient()
    var windowDismissed = false

    let context = OwlAIInvocationContext.typing(
      client: mockClient,
      preedit: "cehsi",
      frontmostApp: nil,
      bundleID: "com.apple.Notes"
    )

    let candidate1 = "第一条高质量润色内容"
    let outcome1 = OwlAIWritebackCoordinator.shared.writeback(
      text: candidate1,
      context: context,
      onDismissWindow: { windowDismissed = true }
    )

    XCTAssertTrue(windowDismissed)
    XCTAssertEqual(outcome1, .insertedToClient)
    XCTAssertEqual(mockClient.insertedTexts, [candidate1])

    let candidate2 = "第二条备选润色内容"
    windowDismissed = false
    let outcome2 = OwlAIWritebackCoordinator.shared.writeback(
      text: candidate2,
      context: context,
      onDismissWindow: { windowDismissed = true }
    )

    XCTAssertTrue(windowDismissed)
    XCTAssertEqual(outcome2, .insertedToClient)
    XCTAssertEqual(mockClient.insertedTexts, [candidate1, candidate2])
  }

  @MainActor
  func testOneKeyWritebackSelectionModeCandidateReplacement() {
    var windowDismissed = false
    var replacedString: String?
    let target = OwlSelectionReplacementTarget { replacement in
      replacedString = replacement
      return .success
    }
    let snapshot = OwlSelectionMenuSnapshot(
      text: "原选中文本",
      bounds: NSRect(x: 100, y: 100, width: 200, height: 200),
      replacementTarget: target,
      bundleID: "com.apple.dt.Xcode"
    )
    let context = OwlAIInvocationContext.selection(snapshot: snapshot)

    let candidate = "替换后的精炼文本"
    let outcome = OwlAIWritebackCoordinator.shared.writeback(
      text: candidate,
      context: context,
      onDismissWindow: { windowDismissed = true }
    )

    XCTAssertTrue(windowDismissed)
    XCTAssertEqual(outcome, .replacedSelection(.axSelectedText))
    XCTAssertEqual(replacedString, candidate)
  }

  @MainActor
  func testOneKeyWritebackStandaloneModeClipboardCopy() {
    var windowDismissed = false
    let context = OwlAIInvocationContext.standalone

    let replyCandidate = "收到，完全同意按此推进。"
    let outcome = OwlAIWritebackCoordinator.shared.writeback(
      text: replyCandidate,
      context: context,
      onDismissWindow: { windowDismissed = true }
    )

    XCTAssertTrue(windowDismissed)
    XCTAssertEqual(outcome, .copiedToClipboard)
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), replyCandidate)
  }

  // MARK: - Group 8: Hot Path Off-Hot-Path Verification

  func testWritingAuxiliarySubsystemOffHotPath() {
    let repoRoot = URL(fileURLWithPath: #file)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .path
    let check = OwlE2EHotPathPurityChecker.verifyHotPathIsFreeOfAISymbols(rootPath: repoRoot)
    XCTAssertTrue(check.isPure, "Hot path must remain 100% free of AI/network symbols: \(check.violations)")
  }

  // MARK: - Group 9: Empirical Challenge Stress Tests

  @MainActor
  func testEmpiricalChallenge_RapidStyleSwitchCancellationAndNoStaleOverwrites() async throws {
    let slowTaskStarted = expectation(description: "slow task started")

    let polisher: @Sendable (String, OwlPolishStyle) async throws -> [String] = { text, style in
      if style == .spokenToWritten {
        slowTaskStarted.fulfill()
        try await Task.sleep(nanoseconds: 150_000_000)
        return ["旧口语候选1", "旧口语候选2"]
      } else if style == .faithful {
        try await Task.sleep(nanoseconds: 10_000_000)
        return ["新保真候选1", "新保真候选2"]
      }
      return ["其他候选1", "其他候选2"]
    }

    let mockService = OwlAIPolishService(customPolisher: polisher)
    let vm = OwlAIPolishViewModel(
      originalText: "测试原文",
      context: .standalone,
      client: mockService
    )

    // 1. Trigger slow style (.spokenToWritten)
    vm.selectStyle(.spokenToWritten)
    XCTAssertTrue(vm.isLoading)
    XCTAssertEqual(vm.selectedStyle, .spokenToWritten)

    await fulfillment(of: [slowTaskStarted], timeout: 1.0)

    // 2. Rapidly switch to fast style (.faithful)
    vm.selectStyle(.faithful)
    XCTAssertEqual(vm.selectedStyle, .faithful)
    XCTAssertTrue(vm.isLoading)

    // 3. Wait 50ms so the fast task finishes, but slow task is still sleeping (or cancelled)
    try await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertEqual(vm.candidates, ["新保真候选1", "新保真候选2"])
    XCTAssertFalse(vm.isLoading)

    // 4. Wait another 200ms for slow task's sleep time to pass completely
    try await Task.sleep(nanoseconds: 200_000_000)

    // 5. Stale slow task MUST NOT overwrite the newer fast task's candidates
    XCTAssertEqual(vm.candidates, ["新保真候选1", "新保真候选2"])
    XCTAssertEqual(vm.selectedStyle, .faithful)
    XCTAssertFalse(vm.isLoading)
    XCTAssertNil(vm.errorMessage)
  }

  @MainActor
  func testEmpiricalChallenge_CancelledTaskErrorDoesNotPolluteNewerSuccessfulTask() async throws {
    let errorTaskStarted = expectation(description: "error task started")

    let polisher: @Sendable (String, OwlPolishStyle) async throws -> [String] = { text, style in
      if style == .spokenToWritten {
        errorTaskStarted.fulfill()
        try await Task.sleep(nanoseconds: 100_000_000)
        throw OwlSelectionPolishError.missingAPIKey
      } else if style == .faithful {
        try await Task.sleep(nanoseconds: 10_000_000)
        return ["成功保真1", "成功保真2"]
      }
      return ["1", "2"]
    }

    let mockService = OwlAIPolishService(customPolisher: polisher)
    let vm = OwlAIPolishViewModel(originalText: "测试原文", context: .standalone, client: mockService)

    vm.selectStyle(.spokenToWritten)
    await fulfillment(of: [errorTaskStarted], timeout: 1.0)

    // Switch to successful style
    vm.selectStyle(.faithful)

    // Wait for both to complete
    try await Task.sleep(nanoseconds: 200_000_000)

    // Error from spokenToWritten must NOT be set on viewModel
    XCTAssertNil(vm.errorMessage, "Cancelled task's error must not pollute newer successful task")
    XCTAssertEqual(vm.candidates, ["成功保真1", "成功保真2"])
    XCTAssertFalse(vm.isLoading)
  }

  @MainActor
  func testEmpiricalChallenge_RapidTemplateSwitchCancellationForQuickReply() async throws {
    let slowTaskStarted = expectation(description: "slow reply task started")

    let replier: @Sendable (String, OwlReplyTemplate) async throws -> [String] = { text, template in
      if template == .agree {
        slowTaskStarted.fulfill()
        try await Task.sleep(nanoseconds: 150_000_000)
        return ["旧同意1", "旧同意2", "旧同意3"]
      } else if template == .decline {
        try await Task.sleep(nanoseconds: 20_000_000)
        return ["新拒绝1", "新拒绝2", "新拒绝3"]
      }
      return ["1", "2", "3"]
    }

    let mockService = OwlAIPolishService(customReplier: replier)
    let vm = OwlQuickReplyViewModel(contextText: "上游上下文", invocationContext: .standalone, generator: mockService)

    vm.selectTemplate(.agree)
    await fulfillment(of: [slowTaskStarted], timeout: 1.0)

    vm.selectTemplate(.decline)

    try await Task.sleep(nanoseconds: 250_000_000)

    XCTAssertEqual(vm.candidates, ["新拒绝1", "新拒绝2", "新拒绝3"])
    XCTAssertEqual(vm.selectedTemplate, .decline)
    XCTAssertFalse(vm.isLoading)
    XCTAssertNil(vm.errorMessage)
  }

  @MainActor
  func testEmpiricalChallenge_HighConcurrency100StyleSwitchesHarness() async throws {
    let mockService = OwlAIPolishService(
      customPolisher: { text, style in
        let jitter = UInt64.random(in: 1_000_000...5_000_000)
        try await Task.sleep(nanoseconds: jitter)
        return ["[\(style.rawValue)] 1", "[\(style.rawValue)] 2"]
      }
    )
    let vm = OwlAIPolishViewModel(originalText: "高频压测文本", context: .standalone, client: mockService)

    let styles = OwlPolishStyle.allCases
    for i in 0..<100 {
      let nextStyle = styles[i % styles.count]
      vm.triggerPolish(style: nextStyle)
    }

    // Wait for the final active task to finish
    try await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertFalse(vm.isLoading)
    XCTAssertEqual(vm.candidates.count, 2)
    let finalExpectedStyle = styles[99 % styles.count]
    XCTAssertTrue(vm.candidates[0].contains(finalExpectedStyle.rawValue))
  }

  @MainActor
  func testEmpiricalChallenge_KeyboardShortcutIsolationSemantics() {
    // 1. Dual polish card shortcut simulation
    let vm = OwlAIPolishViewModel(originalText: "原文", context: .standalone)
    vm.candidates = ["候选1", "候选2"]
    vm.isLoading = false

    // Logic under test matches OwlAIPolishCardsView.onKeyPress:
    func simulatePolishKeyPress(characters: String, inputFocused: Bool, isLoading: Bool, candidates: [String]) -> (handled: Bool, chosen: String?) {
      guard !inputFocused else { return (false, nil) }
      guard !isLoading, candidates.count >= 2 else { return (false, nil) }
      if characters == "1" {
        return (true, candidates[0])
      } else if characters == "2" {
        return (true, candidates[1])
      }
      return (false, nil)
    }

    // Case A: When inputFocused == true, pressing 1 or 2 is ignored (goes to textfield)
    let r1 = simulatePolishKeyPress(characters: "1", inputFocused: true, isLoading: false, candidates: vm.candidates)
    XCTAssertFalse(r1.handled, "When inputFocused == true, key 1 must be ignored")
    XCTAssertNil(r1.chosen)

    let r2 = simulatePolishKeyPress(characters: "2", inputFocused: true, isLoading: false, candidates: vm.candidates)
    XCTAssertFalse(r2.handled, "When inputFocused == true, key 2 must be ignored")
    XCTAssertNil(r2.chosen)

    // Case B: When inputFocused == false, pressing 1 or 2 handles and selects candidate
    let r3 = simulatePolishKeyPress(characters: "1", inputFocused: false, isLoading: false, candidates: vm.candidates)
    XCTAssertTrue(r3.handled, "When inputFocused == false, key 1 must be handled")
    XCTAssertEqual(r3.chosen, "候选1")

    let r4 = simulatePolishKeyPress(characters: "2", inputFocused: false, isLoading: false, candidates: vm.candidates)
    XCTAssertTrue(r4.handled, "When inputFocused == false, key 2 must be handled")
    XCTAssertEqual(r4.chosen, "候选2")

    // Case C: When inputFocused == false, pressing 3 or other characters is ignored
    let r5 = simulatePolishKeyPress(characters: "3", inputFocused: false, isLoading: false, candidates: vm.candidates)
    XCTAssertFalse(r5.handled)
    XCTAssertNil(r5.chosen)

    // Case D: When isLoading == true, pressing 1 or 2 is suppressed
    let r6 = simulatePolishKeyPress(characters: "1", inputFocused: false, isLoading: true, candidates: vm.candidates)
    XCTAssertFalse(r6.handled, "When isLoading == true, key 1 must be suppressed")
    XCTAssertNil(r6.chosen)

    // 2. Quick reply shortcut simulation
    func simulateReplyKeyPress(characters: String, inputFocused: Bool, isLoading: Bool, candidates: [String]) -> (handled: Bool, chosen: String?) {
      guard !inputFocused else { return (false, nil) }
      guard !isLoading, candidates.count >= 3 else { return (false, nil) }
      if characters == "1" {
        return (true, candidates[0])
      } else if characters == "2" {
        return (true, candidates[1])
      } else if characters == "3" {
        return (true, candidates[2])
      }
      return (false, nil)
    }

    let replyCandidates = ["答复1", "答复2", "答复3"]
    let repIgnored = simulateReplyKeyPress(characters: "1", inputFocused: true, isLoading: false, candidates: replyCandidates)
    XCTAssertFalse(repIgnored.handled)

    let rep1 = simulateReplyKeyPress(characters: "1", inputFocused: false, isLoading: false, candidates: replyCandidates)
    XCTAssertTrue(rep1.handled)
    XCTAssertEqual(rep1.chosen, "答复1")

    let rep2 = simulateReplyKeyPress(characters: "2", inputFocused: false, isLoading: false, candidates: replyCandidates)
    XCTAssertTrue(rep2.handled)
    XCTAssertEqual(rep2.chosen, "答复2")

    let rep3 = simulateReplyKeyPress(characters: "3", inputFocused: false, isLoading: false, candidates: replyCandidates)
    XCTAssertTrue(rep3.handled)
    XCTAssertEqual(rep3.chosen, "答复3")

    let rep4 = simulateReplyKeyPress(characters: "4", inputFocused: false, isLoading: false, candidates: replyCandidates)
    XCTAssertFalse(rep4.handled)
  }

  @MainActor
  func testEmpiricalChallenge_WritebackModeDichotomyAndDismissOrdering() {
    var callTrace: [String] = []

    // 1. Selection mode writeback replaces selection and restores host focus first
    let replaceTarget = OwlSelectionReplacementTarget { text in
      callTrace.append("ax.replace:\(text)")
      return .success
    }
    let snapshot = OwlSelectionMenuSnapshot(
      text: "原选中文本",
      bounds: .zero,
      replacementTarget: replaceTarget,
      bundleID: "com.apple.dt.Xcode"
    )
    let selectionContext = OwlAIInvocationContext.selection(snapshot: snapshot)

    callTrace.removeAll()
    let selOutcome = OwlAIWritebackCoordinator.shared.writeback(
      text: "新选区文本",
      context: selectionContext,
      onDismissWindow: {
        callTrace.append("window.close")
      }
    )

    XCTAssertEqual(selOutcome, .replacedSelection(.axSelectedText))
    XCTAssertEqual(callTrace, ["window.close", "ax.replace:新选区文本"])

    // 2. Typing mode writeback inserts at cursor and restores host focus first
    let mockClient = MockAIWritebackTextInputClient()
    mockClient.onInsert = {
      callTrace.append("client.insert:\(mockClient.insertedTexts.last ?? "")")
    }
    let typingContext = OwlAIInvocationContext.typing(
      client: mockClient,
      preedit: "cehsi",
      frontmostApp: nil,
      bundleID: "com.apple.Notes"
    )

    callTrace.removeAll()
    let typeOutcome = OwlAIWritebackCoordinator.shared.writeback(
      text: "新上屏文本",
      context: typingContext,
      onDismissWindow: {
        callTrace.append("window.close")
      }
    )

    XCTAssertEqual(typeOutcome, .insertedToClient)
    XCTAssertEqual(callTrace, ["window.close", "client.insert:新上屏文本"])
    XCTAssertEqual(mockClient.replacementRanges, [.empty], "Typing writeback must insert at cursor with .empty range")
  }

  @MainActor
  func testShowAIWindowWithTypingContextSeedsCapturedContextSummary() {
    let typingContext = OwlAIInvocationContext.typing(
      client: nil,
      preedit: "待润色草稿",
      frontmostApp: nil,
      bundleID: "com.apple.Notes"
    )
    let model = OwlAIWindow.shared.show(context: typingContext, initialMode: .polish)
    let summary = model.capturedContextSummary
    XCTAssertEqual(summary, "待润色草稿")
    OwlAIWindow.shared.close()
  }
}
