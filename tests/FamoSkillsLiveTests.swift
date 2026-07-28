//
//  FamoSkillsLiveTests.swift
//  FamoTests — 全部 AI 技能对阿里云百炼的「实盘」验收
//
//  与 `FamoPromptOptimizeLiveTests` 同一契约：**默认跳过**，仅当 `~/.famo-test-key`（仓库外）
//  存在时才跑。目的不是回归（离线套件管回归），而是回答「每个 AI 技能在真实供应商上到底
//  能不能达到预期效果」——mock 喂的永远是我们自己想象的响应形状。
//
//  覆盖的四条真实链路（提示词优化已在 FamoPromptOptimizeLiveTests）：
//    A. SSE 流式（FamoStreamingChatClient）—— 翻译 / 润色·多版本 / 润色·仿范例 / 公文排版 /
//       辅助检索共用的传输，逐技能用真实 prompt 打，断言产出符合各自的输出契约。
//    B. 任意提问·联网搜索 —— 同一流式客户端 + qwen 的 enable_search extraBody。
//    C. 划词润色（FamoSelectionPolishClient）—— 非流式 json_object 候选契约，v1/v2 变体各一发。
//    D. 来源核验（FamoSourceVerificationService）—— DashScope 原生 generation 端点 +
//       forced_search/enable_source，与其他技能完全不同的一条 wire。
//

import Foundation
import XCTest

@testable import Famo

@MainActor
final class FamoSkillsLiveTests: XCTestCase {

  private static let endpoint = URL(
    string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!

  /// 打哪个型号。默认 = 百炼预设当前的默认模型，也就是新用户实际会用上的那个 —— 实盘测试要测的
  /// 是「我们发出去的配置」，把型号写死在这里就会和预设悄悄脱节。
  ///
  /// `~/.famo-test-model` 覆盖它：要回答「这个技能该用 3.7-plus 还是 3.6-flash」，唯一靠谱的办法是
  /// **同一套用例、同样的提示词，分别打两个型号看耗时**。
  ///     echo qwen3.6-flash > ~/.famo-test-model
  ///
  /// ⚠️ 为什么是文件而不是环境变量（2026-07-28 踩过，代价是一整轮假对照数据）：
  /// **xcodebuild 不会把 shell 的环境变量转发给测试宿主进程**。`FAMO_LIVE_MODEL=… xcodebuild test`
  /// 看起来跑了、耗时也有波动，其实全程打的还是默认型号。判据很简单：喂一个不存在的型号进去，
  /// 如果测试照样通过，就说明覆盖压根没生效。Key 走文件也是同一个原因。
  private static let model: String = {
    let path = ("~/.famo-test-model" as NSString).expandingTildeInPath
    let override = (try? String(contentsOfFile: path, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let override, !override.isEmpty { return override }
    return FamoLLMProviderCatalog.preset(id: "qwen")?.model ?? "qwen3.7-plus"
  }()

  private var routing: FamoCloudRouting {
    FamoCloudRouting(
      providerID: "qwen", endpoint: Self.endpoint, model: Self.model,
      secretName: "famo.live.test", authHeaderStyle: .bearer)
  }

  private func testAPIKey() throws -> String {
    let path = ("~/.famo-test-key" as NSString).expandingTildeInPath
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
      throw XCTSkip("无 ~/.famo-test-key，跳过实盘测试（离线套件不受影响）")
    }
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if key.isEmpty { throw XCTSkip("~/.famo-test-key 为空，跳过实盘测试") }
    return key
  }

  override func setUp() async throws {
    try await super.setUp()
    FamoCloudPreferences.resetForTesting()
    FamoExperimentalPreferences.resetForTesting()
  }

  override func tearDown() async throws {
    FamoCloudPreferences.resetForTesting()
    FamoExperimentalPreferences.resetForTesting()
    try await super.tearDown()
  }

  /// 消费整条 SSE 流为完整回答；落盘供人工核对。qwen3.6-flash 有静默推理段，上限放宽到 90s。
  private func streamAnswer(
    question: String, selectedText: String? = nil,
    extraBody: [String: Any] = [:], label: String
  ) async throws -> String {
    let apiKey = try testAPIKey()
    let client = FamoStreamingChatClient(timeout: 90)
    let messages = FamoAIContextAssembler.assemble(
      selectedText: selectedText, question: question)

    var answer = ""
    for try await delta in client.stream(
      messages: messages, routing: routing, apiKey: apiKey, extraBody: extraBody) {
      answer += delta
    }
    try? answer.write(
      toFile: "/tmp/famo-skill-\(label).txt", atomically: true, encoding: .utf8)
    return answer
  }

  // MARK: - A. 流式窗口技能（各自的输出契约）

  func testTranslateSkillTurnsChineseIntoEnglishOnly() async throws {
    let answer = try await streamAnswer(
      question: FamoSelectionSkillPrompts.translationQuestion,
      selectedText: "本院认为，双方当事人签订的买卖合同系真实意思表示，合法有效。",
      label: "translate")

    XCTAssertFalse(answer.isEmpty)
    XCTAssertNotNil(
      answer.range(of: "[A-Za-z]{4,}", options: .regularExpression),
      "中文选区应译成英文")
    XCTAssertFalse(answer.contains("```"), "契约要求不使用 Markdown 代码块")
    XCTAssertFalse(
      answer.contains("直译") || answer.contains("反思"),
      "内部三步法不得泄漏到输出（只输出最终意译）")
  }

  // 公文排版 / 润色·多版本挑选 / 润色·仿我的范例 的活体契约测试已随技能删除（2026-07-26 技能
  // 精简）：个性化加工由「任意提问」对选区直接下指令兜底，没有固定输出契约可断言。

  func testResearchAssistSkillReturnsSearchPlan() async throws {
    let answer = try await streamAnswer(
      question: FamoSelectionSkillPrompts.researchAssistQuestion,
      selectedText: "夫妻共同债务的认定标准",
      label: "research")

    XCTAssertFalse(answer.isEmpty)
    XCTAssertTrue(
      answer.contains("检索") || answer.contains("关键词"),
      "辅助检索应产出可复制的检索方案")
  }

  // MARK: - B. 任意提问 · 联网搜索（qwen enable_search）

  func testAskWithWebSearchStreamsAnAnswer() async throws {
    let extraBody = FamoSearchControl.extraBody(
      providerID: "qwen", host: Self.endpoint.host ?? "")
    XCTAssertEqual(extraBody["enable_search"] as? Bool, true, "qwen 联网走顶层 enable_search")

    let answer = try await streamAnswer(
      question: "最高人民法院现任院长是谁？只答姓名与就任年份。",
      extraBody: extraBody,
      label: "websearch")

    XCTAssertFalse(answer.isEmpty, "联网搜索路由下必须仍能流式出答案")
  }

  // MARK: - C. 划词润色（非流式 json_object 候选契约，v1 / v2 变体）

  func testSelectionPolishReturnsRewritesOnBothPromptVariants() async throws {
    let apiKey = try testAPIKey()

    for variantID in [
      FamoPolishPromptCatalog.legacyVariantID,
      FamoPolishPromptCatalog.responsayAlignedVariantID
    ] {
      FamoExperimentalPreferences.selectionPolishPromptVariant = variantID
      let client = FamoSelectionPolishClient(
        endpoint: Self.endpoint, model: Self.model, authHeaderStyle: .bearer)
      let rewrites = try await client.fetchPolishedRewrites(
        for: "这个事情我们得赶紧弄一下，不然要出问题。", apiKey: apiKey)

      XCTAssertFalse(rewrites.isEmpty, "变体 \(variantID) 未产出任何改写")
      XCTAssertFalse(
        rewrites[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        "变体 \(variantID) 首个改写为空")
      try? rewrites.joined(separator: "\n---\n").write(
        toFile: "/tmp/famo-skill-polish-\(variantID).txt", atomically: true, encoding: .utf8)
    }
  }

  // MARK: - D. 来源核验（DashScope 原生端点 + forced_search/enable_source）

  func testSourceVerificationReturnsContentAndSources() async throws {
    let apiKey = try testAPIKey()
    FamoCloudPreferences.isEnabled = true

    let profile = FamoProviderProfile(
      displayName: "阿里云百炼（实盘测试）",
      endpoint: Self.endpoint, model: Self.model,
      providerID: "qwen", secretName: "famo.live.test", isDefault: true)
    let service = FamoSourceVerificationService(
      profileProvider: { profile },
      profileSecretProvider: { _ in apiKey })

    let outcome = try await service.verifyStructured(
      "《中华人民共和国民法典》自2021年1月1日起施行。")
    try? outcome.content.write(
      toFile: "/tmp/famo-skill-verify.txt", atomically: true, encoding: .utf8)

    XCTAssertFalse(outcome.content.isEmpty, "核验必须给出结论文本")
    XCTAssertFalse(
      outcome.sources.isEmpty,
      "forced_search + enable_source 下应返回可跳查的来源；为空说明来源抽取断了")
  }

  // MARK: - E. 通义千问当**检索器**（搜索服务下拉里的第三档）

  /// 守住这一档赖以成立的两个实盘事实（2026-07-28 首次跑通）：
  ///
  ///   1. **model / endpoint / content 必须配套**。原生端点分文本与多模态两条，挑错就是
  ///      `400 InvalidParameter · url error`。实测对照：multimodal 收 qwen3.7-plus / 3.7-flash、
  ///      拒 3.7-max；text 收 qwen-plus / 3.7-max、拒 3.7-plus / 3.7-flash。两条路 `content` 形状
  ///      也不同（多模态要 `[{text:…}]`，纯文本要裸字符串）。跑挂成 400 就是有人只换了其中一个。
  ///   2. **来源只能从原生端点拿**。兼容模式实测 `search_info` 恒为 ABSENT（连 `enable_source: true`
  ///      也只是被静默忽略，`prepend_search_result` 更是直接 400「not supported in OpenAI protocol」）。
  ///      端点被改回 compatible-mode 的话，这一档会变成永远 0 条、被静默顺位掉 —— 这条断言是那道闸。
  ///
  /// 顺带钉住那件反直觉的事：来源**没有正文摘要**，`snippet` 为空是 API 如此，不是解析漏了。
  func testQwenWorksAsARetrieverOnTheNativeEndpoint() async throws {
    let apiKey = try testAPIKey()

    let results = try await FamoDashScopeSearchClient().search(
      query: "2026 年杭州亚运会主办城市有哪些协办城市",
      apiKey: apiKey,
      limit: FamoStreamingChatService.webSearchResultCount)

    let dump = results.enumerated()
      .map { FamoWebSearchContext.entry(index: $0.offset + 1, result: $0.element) }
      .joined(separator: "\n\n")
    try? dump.write(toFile: "/tmp/famo-qwen-search.txt", atomically: true, encoding: .utf8)

    XCTAssertFalse(
      results.isEmpty,
      "0 条 = 要么 \(FamoDashScopeSearchWire.model) 没被这个端点收编，要么 enable_source 没回来源")
    for result in results {
      XCTAssertTrue(result.url.hasPrefix("http"), "来源必须可跳查")
      XCTAssertFalse(result.title.isEmpty)
    }
    XCTAssertTrue(
      results.allSatisfy { $0.snippet.isEmpty },
      "百炼的 search_results 不带摘要——真回了摘要说明 API 变了，注入上下文可以顺势加强")
  }

  // MARK: - F. 规范排版（此前唯一没有实盘覆盖的技能）

  /// 这个技能的成败**不看模型说得好不好，只看它有没有忍住不改字**：`generateReplacement` 会拿
  /// `contentFingerprint` 比对，AI 一旦顺手润色，整段输出被丢弃、回退纯规则版 —— 于是那次调用
  /// 白花了钱和时间，而用户只会觉得「AI 排版没起作用」，不会看到任何报错。
  ///
  /// 越强的模型越忍不住改字，所以这条用例在换型号时尤其要跑：它是「3.7-plus 值不值」在这个技能上
  /// 的唯一判据。
  func testPublishFormattingReflowsWithoutChangingASingleCharacter() async throws {
    let apiKey = try testAPIKey()
    // 典型的 PDF 复制品：硬换行把句子拦腰截断，段落之间空行。
    let pasted = """
      输入法的候选窗需要在用户翻页之后才展开
      多行，这样短词输入不会被突然变高的窗
      口打断。

      翻页后上方固定保留一行前页候选，走到
      末页也不会掉回单行。
      """
    let cleaned = FamoChineseTypesetting.preClean(pasted)

    let client = FamoStreamingChatClient(timeout: 90)
    let messages = [
      FamoDeepSeekMessage(
        role: "system", content: FamoSelectionSkillPrompts.publishReflowSystemPrompt),
      FamoDeepSeekMessage(role: "user", content: cleaned),
    ]
    var reflowed = ""
    let started = Date()
    for try await delta in client.stream(messages: messages, routing: routing, apiKey: apiKey) {
      reflowed += delta
    }
    let elapsed = Date().timeIntervalSince(started)
    try? reflowed.write(
      toFile: "/tmp/famo-skill-publish.txt", atomically: true, encoding: .utf8)

    XCTAssertFalse(reflowed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    XCTAssertEqual(
      FamoChineseTypesetting.contentFingerprint(reflowed),
      FamoChineseTypesetting.contentFingerprint(cleaned),
      """
      \(Self.model) 在重排时改了字，指纹护栏会丢弃它的输出、回退纯规则版 —— \
      也就是这个技能在这个型号上「花了钱但没生效」。耗时 \(elapsed)s。
      """)
    XCTAssertFalse(
      reflowed.contains("```"), "输出裹了代码块，会被原样粘进用户编辑器")
  }

  // MARK: - G. 任务书（此前只在豆包上实盘过，换到百炼要重验一次契约）

  /// 任务书是全部技能里产出最长的一条，也是最容易顶穿超时的一条（1.5.12 修的正是豆包
  /// 「隐藏思考烧穿 60s」）。换到百炼后必须重新回答两件事：七问小节齐不齐、耗时离硬超时还有多远。
  func testGoalBriefProducesSevenSectionsWithinTheHardTimeout() async throws {
    let apiKey = try testAPIKey()
    let draft = """
      我们输入法的词库下载老是断，用户一断网就得重头下，帮我把这个下载搞稳一点，\
      最好断了能接着下，下载完还得校验一下别装出坏包。
      """

    let client = FamoGoalBriefClient(
      endpoint: Self.endpoint, model: Self.model, authHeaderStyle: .bearer)
    let started = Date()
    let outcome = try await client.fetchOptimizedPrompt(
      forDraft: draft, clarifications: [], apiKey: apiKey)
    let elapsed = Date().timeIntervalSince(started)

    guard case let .ready(brief) = outcome else {
      return XCTFail("意图可辨的草稿应当直接出任务书，实际 \(outcome)")
    }
    try? brief.write(toFile: "/tmp/famo-skill-goalbrief.txt", atomically: true, encoding: .utf8)
    XCTAssertFalse(
      brief.hasPrefix("{"), "任务书不该是 JSON 原文——那说明解析层漏了，会把 JSON 粘进用户编辑器")
    for section in ["目的", "完成态", "证据", "反作弊", "边界", "取舍", "未知"] {
      XCTAssertTrue(brief.contains(section), "任务书缺〈\(section)〉一节：\(brief.prefix(200))")
    }
    // 60s 是产品侧硬超时；实盘要留重试余量，逼近就该换型号而不是等线上被掐断。
    XCTAssertLessThan(
      elapsed, 55, "\(Self.model) 出一份任务书要 \(elapsed)s，逼近 60s 硬超时 —— 该换更快的型号")
  }
}
