//
//  OwlAICandidateTests.swift
//  OwltypeTests — Lane A: Cloud AI Candidate Association Tests (#392)
//

import Carbon
// swiftlint:disable:next duplicate_imports
import Carbon.HIToolbox
import XCTest
@testable import Owltype

final class OwlAICandidateTests: XCTestCase {

  override func setUp() {
    super.setUp()
    OwlAICandidatePreferences.resetForTesting()
  }

  override func tearDown() {
    OwlAICandidatePreferences.resetForTesting()
    super.tearDown()
  }

  // MARK: - 1. Settings Preferences & Defaults

  func testPreferencesDefaultsAreFalse() {
    XCTAssertFalse(OwlAICandidatePreferences.aiAssociationEnabled)
    XCTAssertFalse(OwlAICandidatePreferences.aiEnglishCandidateEnabled)
    XCTAssertFalse(OwlAICandidatePreferences.jevDiscriminativeRerankEnabled)
  }

  func testPreferencesTogglesPersist() {
    OwlAICandidatePreferences.aiAssociationEnabled = true
    XCTAssertTrue(OwlAICandidatePreferences.aiAssociationEnabled)

    OwlAICandidatePreferences.aiEnglishCandidateEnabled = true
    XCTAssertTrue(OwlAICandidatePreferences.aiEnglishCandidateEnabled)

    OwlAICandidatePreferences.jevDiscriminativeRerankEnabled = true
    XCTAssertTrue(OwlAICandidatePreferences.jevDiscriminativeRerankEnabled)

    OwlAICandidatePreferences.resetForTesting()
    XCTAssertFalse(OwlAICandidatePreferences.aiAssociationEnabled)
    XCTAssertFalse(OwlAICandidatePreferences.aiEnglishCandidateEnabled)
    XCTAssertFalse(OwlAICandidatePreferences.jevDiscriminativeRerankEnabled)
  }

  func testSettingsStateMirrorsPreferences() {
    let state = OwlSettingsState()
    XCTAssertFalse(state.aiAssociationEnabled)
    XCTAssertFalse(state.aiEnglishCandidateEnabled)
    XCTAssertFalse(state.jevDiscriminativeRerankEnabled)

    OwlAICandidatePreferences.aiAssociationEnabled = true
    let updated = OwlSettingsState()
    XCTAssertTrue(updated.aiAssociationEnabled)
  }

  // MARK: - 2. Candidate Line Parsing & Sanitization

  func testCandidateParsingStripsNumberingAndBulletPoints() {
    let raw = """
    1. 你好呀
    2. 你好世界
    - 你好朋友
    * 你好大家
    """
    let candidates = OwlAICandidateService.parseCandidates(raw, rawInput: "nihao")
    XCTAssertEqual(candidates, ["你好呀", "你好世界", "你好朋友"])
  }

  func testCandidateParsingDeduplicatesAndFiltersRawInput() {
    let raw = """
    你好
    你好
    nihao

    你好世界
    """
    let candidates = OwlAICandidateService.parseCandidates(raw, rawInput: "nihao")
    XCTAssertEqual(candidates, ["你好", "你好世界"])
  }

  func testCandidateParsingCapsAtThree() {
    let raw = """
    候选一
    候选二
    候选三
    候选四
    候选五
    """
    let candidates = OwlAICandidateService.parseCandidates(raw, rawInput: "test")
    XCTAssertEqual(candidates.count, 3)
    XCTAssertEqual(candidates, ["候选一", "候选二", "候选三"])
  }

  // MARK: - 3. Service Execution & Mock Transport

  func testServiceWithCustomGeneratorReturnsCandidates() async {
    let service = OwlAICandidateService(customGenerator: { ticket, _ in
      XCTAssertEqual(ticket.rawInput, "nihao")
      return ["你好啊", "你好呀"]
    })

    let ticket = OwlAICandidateTicket(sessionID: 1, generation: 1, rawInput: "nihao", actionEpoch: 1)
    let candidates = await service.generateCandidates(ticket: ticket, preContext: "前文")
    XCTAssertEqual(candidates, ["你好啊", "你好呀"])
  }

  func testServiceUnconfiguredReturnsEmptyArray() async {
    let service = OwlAICandidateService(
      authGateProvider: { .unconfigured },
      customGenerator: nil
    )
    let ticket = OwlAICandidateTicket(sessionID: 1, generation: 1, rawInput: "nihao", actionEpoch: 1)
    let candidates = await service.generateCandidates(ticket: ticket, preContext: nil)
    XCTAssertTrue(candidates.isEmpty)
  }

  // MARK: - 4. 120ms Debounce & Epoch Invalidation

  func testDebounceIntervalIs120ms() {
    XCTAssertEqual(OwlInputController.aiCandidateDebounceInterval, 0.12, accuracy: 0.001)
  }

  func testTicketEqualityAndFields() {
    let ticket1 = OwlAICandidateTicket(sessionID: 10, generation: 20, rawInput: "abc", actionEpoch: 5)
    let ticket2 = OwlAICandidateTicket(sessionID: 10, generation: 20, rawInput: "abc", actionEpoch: 5)
    let ticket3 = OwlAICandidateTicket(sessionID: 10, generation: 20, rawInput: "abc", actionEpoch: 6)

    XCTAssertEqual(ticket1, ticket2)
    XCTAssertNotEqual(ticket1, ticket3)
    XCTAssertEqual(ticket1.sessionID, 10)
    XCTAssertEqual(ticket1.generation, 20)
    XCTAssertEqual(ticket1.rawInput, "abc")
    XCTAssertEqual(ticket1.actionEpoch, 5)
  }

  @MainActor
  func testBothCandidateLanesReceiveBoundedTextBeforeTheComposition() async throws {
    OwlAICandidatePreferences.aiAssociationEnabled = true
    OwlAICandidatePreferences.jevDiscriminativeRerankEnabled = true
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    defer { controller.destroySession() }
    let client = HabitsTextClient()
    controller.client = client
    let session = FakeEngineSession(sessionID: 80, generation: 1, isValid: true, input: "nihao")
    controller.engineSession = session
    controller.lastPanelComposition = OwlPanelCompositionParams(
      preedit: "nihao", cursor: 5, selStart: 0, selEnd: 5, candidates: ["你好", "拟好"],
      comments: [], labels: [], highlighted: 0, page: 0, lastPage: true, pageSize: 5)

    let preceding = String(repeating: "旧", count: 220) + "讨论计划🙂"
    client.text.string = preceding + "后文不能发送"
    client.text.setSelectedRange(NSRange(location: preceding.utf16.count, length: 0))
    client.setMarkedText("nihao", selectionRange: NSRange(location: 5, length: 0), replacementRange: .empty)
    let expected = String(preceding.suffix(100))
    let generated = expectation(description: "generative context")
    let reranked = expectation(description: "discriminative context")
    controller.aiCandidateService = OwlAICandidateService(
      customGenerator: { _, context in
        XCTAssertEqual(context, expected)
        generated.fulfill()
        return []
      },
      customReranker: { context, _, _, _ in
        XCTAssertEqual(context, expected)
        reranked.fulfill()
        return nil
      })
    controller.aiCandidateDebounceFired()
    await fulfillment(of: [generated, reranked], timeout: 2)
  }

  @MainActor
  func testCandidateContextHandlesStartAndUnavailableSelection() async throws {
    OwlAICandidatePreferences.aiAssociationEnabled = true
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    defer { controller.destroySession() }
    let client = HabitsTextClient()
    controller.client = client
    controller.engineSession = FakeEngineSession(sessionID: 81, generation: 1, isValid: true, input: "ni")
    client.text.string = "不能读取的后文"
    client.text.setSelectedRange(NSRange(location: 0, length: 0))
    for exposesText in [true, false] {
      client.exposesText = exposesText
      let generated = expectation(description: "no preceding text")
      controller.aiCandidateService = OwlAICandidateService(customGenerator: { _, context in
        XCTAssertNil(context)
        generated.fulfill()
        return []
      })
      controller.aiCandidateDebounceFired()
      await fulfillment(of: [generated], timeout: 2)
    }
  }

  // MARK: - 5. Layout Merging & Non-Jump Guarantee

  func testFirstAICandidatePositionedAtLastSlotOfFirstPage() throws {
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    let client = HabitsTextClient()
    controller.client = client
    defer {
      controller.destroySession()
      NSApp.owlAppDelegate.owlPanel?.hidePanel()
    }
    let fakeSession = FakeEngineSession(sessionID: 100, generation: 1, isValid: true, input: "nihao")
    controller.engineSession = fakeSession

    let ticket = OwlAICandidateTicket(sessionID: 100, generation: 1, rawInput: "nihao", actionEpoch: 0)
    controller.activeAICandidates = ["你好呀", "你好吗"]
    controller.activeAICandidateTicket = ticket

    let candidates = ["你好", "拟好", "妮好", "泥好", "尼豪"]
    let labels = ["1.", "2.", "3.", "4.", "5."]
    controller.showPanel(
      preedit: "nihao",
      cursor: 5,
      selStart: 0,
      selEnd: 5,
      candidates: candidates,
      comments: [],
      labels: labels,
      highlighted: 0,
      page: 0,
      lastPage: false,
      pageSize: 5
    )

    // Verify controller identified slot 4 for the AI candidate
    XCTAssertEqual(controller.activeAICandidateSlot, 4)

    // Verify non-jump guarantee for local candidates 0..<4
    let models = controller.lastComposedCandidates
    XCTAssertEqual(models.count, 5)
    XCTAssertEqual(models[0].text, "你好")
    XCTAssertEqual(models[1].text, "拟好")
    XCTAssertEqual(models[2].text, "妮好")
    XCTAssertEqual(models[3].text, "泥好")
    XCTAssertNil(models[0].provenance)
    XCTAssertNil(models[1].provenance)
    XCTAssertNil(models[2].provenance)
    XCTAssertNil(models[3].provenance)

    // Verify slot 4 holds AI candidate with .ai badge, comment "AI", and sentinel token
    XCTAssertEqual(models[4].text, "你好呀")
    XCTAssertEqual(models[4].provenance, .ai)
    XCTAssertEqual(models[4].comment, "AI")
    XCTAssertEqual(models[4].label, "5.")
    XCTAssertEqual(models[4].token.candidateID, 999_999)

    // Verify pure layout algorithm also confirms identical result
    var pureModels = candidates.indices.map { i in
      CandidateViewModel(id: i, label: labels[i], text: candidates[i])
    }
    let slot = OwlAICandidateLayout.applyAICandidate(
      into: &pureModels,
      activeAICandidates: ["你好呀"],
      activeAICandidateTicket: ticket,
      currentSessionID: 100,
      currentGen: 1,
      rawInput: "nihao",
      page: 0,
      pageSize: 5,
      labels: labels
    )
    XCTAssertEqual(slot, 4)
    XCTAssertEqual(pureModels[4].text, "你好呀")
    XCTAssertEqual(pureModels[4].provenance, .ai)
  }

  func testLayoutWhenLocalCandidateCountLessThanPageSize() throws {
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    let client = HabitsTextClient()
    controller.client = client
    defer {
      controller.destroySession()
      NSApp.owlAppDelegate.owlPanel?.hidePanel()
    }
    let fakeSession = FakeEngineSession(sessionID: 100, generation: 1, isValid: true, input: "test")
    controller.engineSession = fakeSession

    let ticket = OwlAICandidateTicket(sessionID: 100, generation: 1, rawInput: "test", actionEpoch: 0)
    controller.activeAICandidates = ["AI联想词"]
    controller.activeAICandidateTicket = ticket

    let candidates = ["候选A", "候选B", "候选C"]
    let labels = ["1.", "2.", "3.", "4.", "5."]
    controller.showPanel(
      preedit: "test",
      cursor: 4,
      selStart: 0,
      selEnd: 4,
      candidates: candidates,
      comments: [],
      labels: labels,
      highlighted: 0,
      page: 0,
      lastPage: true,
      pageSize: 5
    )

    // When local candidate count is 3 (< pageSize 5), AI candidate is appended at slot 3
    XCTAssertEqual(controller.activeAICandidateSlot, 3)

    let models = controller.lastComposedCandidates
    XCTAssertEqual(models.count, 4)
    XCTAssertEqual(models[0].text, "候选A")
    XCTAssertEqual(models[1].text, "候选B")
    XCTAssertEqual(models[2].text, "候选C")
    XCTAssertEqual(models[3].text, "AI联想词")
    XCTAssertEqual(models[3].provenance, .ai)
    XCTAssertEqual(models[3].comment, "AI")
    XCTAssertEqual(models[3].token.candidateID, 999_999)

    // On subsequent pages (page > 0), AI candidate must NOT appear
    controller.showPanel(
      preedit: "test",
      cursor: 4,
      selStart: 0,
      selEnd: 4,
      candidates: ["候选D", "候选E"],
      comments: [],
      labels: labels,
      highlighted: 0,
      page: 1,
      lastPage: true,
      pageSize: 5
    )
    XCTAssertNil(controller.activeAICandidateSlot)
    XCTAssertNil(controller.lastComposedCandidates.first(where: { $0.provenance == .ai }))
  }

  // MARK: - 6. Selection Interception Logic

  func testShortcutSelectionMatchesSlotIndex() throws {
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    defer { controller.destroySession() }
    controller.activeAICandidates = ["你好呀"]
    controller.activeAICandidateSlot = 4

    // Slot 4 corresponds to number key 5 (XK_5) and keypad 5 (XK_KP_5)
    XCTAssertTrue(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_5), modifiers: 0))
    XCTAssertTrue(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_KP_5), modifiers: 0))

    // Non-matching number keys must not intercept
    XCTAssertFalse(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_1), modifiers: 0))
    XCTAssertFalse(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_2), modifiers: 0))
    XCTAssertFalse(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_3), modifiers: 0))
    XCTAssertFalse(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_4), modifiers: 0))

    // When slot is 2 (e.g. fewer candidates), number key 3 (XK_3) intercepts
    controller.activeAICandidateSlot = 2
    XCTAssertTrue(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_3), modifiers: 0))
    XCTAssertTrue(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_KP_3), modifiers: 0))
    XCTAssertFalse(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_5), modifiers: 0))

    // Modifier combinations (Command, Control, Alt) must not intercept
    XCTAssertFalse(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_3), modifiers: UInt32(kControlMask.rawValue)))
    XCTAssertFalse(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_3), modifiers: UInt32(kAltMask.rawValue)))
    XCTAssertFalse(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_3), modifiers: UInt32(kSuperMask.rawValue)))

    // When no active AI candidates exist, shortcut must not intercept
    controller.activeAICandidates = []
    XCTAssertFalse(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_3), modifiers: 0))
  }

  func testSpaceOrEnterSelectsWhenHighlightMatchesSlot() throws {
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    defer { controller.destroySession() }
    controller.activeAICandidates = ["你好呀"]
    controller.activeAICandidateSlot = 4
    controller.currentHighlightedCandidateIndex = 4

    // When highlight matches slot index 4, Space, Return, and KP_Enter intercept
    XCTAssertTrue(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_space), modifiers: 0))
    XCTAssertTrue(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_Return), modifiers: 0))
    XCTAssertTrue(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_KP_Enter), modifiers: 0))

    // When highlight is on a different candidate (e.g. slot 0), Space and Return do not intercept
    controller.currentHighlightedCandidateIndex = 0
    XCTAssertFalse(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_space), modifiers: 0))
    XCTAssertFalse(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_Return), modifiers: 0))
    XCTAssertFalse(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_KP_Enter), modifiers: 0))

    // Blocked modifiers (Control, Alt, Super) suppress interception even when highlighted
    controller.currentHighlightedCandidateIndex = 4
    XCTAssertFalse(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_space), modifiers: UInt32(kControlMask.rawValue)))
    XCTAssertFalse(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_Return), modifiers: UInt32(kAltMask.rawValue)))
    XCTAssertFalse(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_Return), modifiers: UInt32(kSuperMask.rawValue)))

    // When slot is nil or active candidates empty, do not intercept
    controller.activeAICandidateSlot = nil
    XCTAssertFalse(controller.shouldInterceptForAICandidate(keycode: UInt32(XK_space), modifiers: 0))
  }

  // MARK: - 7. Secure Input Gating

  func testSecureInputBlocksNetwork() throws {
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    defer { controller.destroySession() }
    let fakeSession = FakeEngineSession(sessionID: 100, generation: 1, isValid: true, input: "nihao")
    controller.engineSession = fakeSession
    OwlAICandidatePreferences.aiAssociationEnabled = true

    // Baseline: When secure input is not enabled, armAICandidateAfterInput schedules debounce timer
    XCTAssertFalse(controller.isSecureInputGated())
    controller.armAICandidateAfterInput()
    XCTAssertNotNil(controller.aiCandidateDebounceTimer)
    controller.invalidateAICandidateForAction()
    XCTAssertNil(controller.aiCandidateDebounceTimer)

    // 1. Carbon SecureEventInput enabled -> isSecureInputGated returns true and arming is blocked
    EnableSecureEventInput()
    XCTAssertTrue(IsSecureEventInputEnabled())
    XCTAssertTrue(controller.isSecureInputGated())
    controller.armAICandidateAfterInput()
    XCTAssertNil(controller.aiCandidateDebounceTimer, "armAICandidateAfterInput must abort without scheduling timer when secure input is enabled")
    DisableSecureEventInput()
    XCTAssertFalse(IsSecureEventInputEnabled())
    XCTAssertFalse(controller.isSecureInputGated())

    // 2. Client privacy state provider reports isSecureInputEnabled / isPasswordLike -> isSecureInputGated returns true and arming is blocked
    controller.privacyStateProvider = { OwlClientPrivacyState(isSecureInputEnabled: true, isPasswordLike: false) }
    XCTAssertTrue(controller.isSecureInputGated())
    controller.armAICandidateAfterInput()
    XCTAssertNil(controller.aiCandidateDebounceTimer, "armAICandidateAfterInput must abort when client privacy indicates secure input")

    controller.privacyStateProvider = { OwlClientPrivacyState(isSecureInputEnabled: false, isPasswordLike: true) }
    XCTAssertTrue(controller.isSecureInputGated())
    controller.armAICandidateAfterInput()
    XCTAssertNil(controller.aiCandidateDebounceTimer, "armAICandidateAfterInput must abort when client privacy indicates password field")

    // Restore provider
    controller.privacyStateProvider = { OwlClientPrivacyState.current() }
    XCTAssertFalse(controller.isSecureInputGated())
  }

  // MARK: - 8. Jev Discriminative Reranking Tests (#395)

  func testJevRerankResponseParsing() {
    // "c2" -> 2
    XCTAssertEqual(OwlAICandidateService.parseRerankResponse("c2", candidateCount: 5), 2)
    // "c0" -> 0
    XCTAssertEqual(OwlAICandidateService.parseRerankResponse("c0", candidateCount: 5), 0)
    // "c31" -> 31
    XCTAssertEqual(OwlAICandidateService.parseRerankResponse("c31", candidateCount: 32), 31)
    // Case-insensitive "C3" -> 3
    XCTAssertEqual(OwlAICandidateService.parseRerankResponse("C3", candidateCount: 5), 3)
    // Markdown / backticks "`c1`" -> 1
    XCTAssertEqual(OwlAICandidateService.parseRerankResponse("`c1`", candidateCount: 5), 1)
    // Direct integer string "4" -> 4
    XCTAssertEqual(OwlAICandidateService.parseRerankResponse("4", candidateCount: 5), 4)

    // "none" / "None" / "NONE" -> nil
    XCTAssertNil(OwlAICandidateService.parseRerankResponse("none", candidateCount: 5))
    XCTAssertNil(OwlAICandidateService.parseRerankResponse("None", candidateCount: 5))
    XCTAssertNil(OwlAICandidateService.parseRerankResponse("NONE", candidateCount: 5))
    XCTAssertNil(OwlAICandidateService.parseRerankResponse("none: keep original", candidateCount: 5))

    // Out of bounds -> nil (strict zero hallucination)
    XCTAssertNil(OwlAICandidateService.parseRerankResponse("c32", candidateCount: 32))
    XCTAssertNil(OwlAICandidateService.parseRerankResponse("c99", candidateCount: 5))

    // Unparseable / hallucinated text -> nil
    XCTAssertNil(OwlAICandidateService.parseRerankResponse("你好世界", candidateCount: 5))
    XCTAssertNil(OwlAICandidateService.parseRerankResponse("", candidateCount: 5))
    XCTAssertNil(OwlAICandidateService.parseRerankResponse("   ", candidateCount: 5))
  }

  func testJevContextAndCandidateCollectionBudgets() {
    let longContext = String(repeating: "中", count: 150)
    let candidates40 = (0..<40).map { "候选\($0)" }

    let trimmedContext = String(longContext.suffix(100))
    XCTAssertEqual(trimmedContext.count, 100)

    let candidatePool = Array(candidates40.prefix(32))
    XCTAssertEqual(candidatePool.count, 32)
    XCTAssertEqual(candidatePool.first, "候选0")
    XCTAssertEqual(candidatePool.last, "候选31")

    let key = OwlAICandidateService.cacheKey(preContext: longContext, pinyin: "nihao", candidates: candidatePool)
    XCTAssertTrue(key.contains("nihao"))
    XCTAssertTrue(key.contains("候选31"))
  }

  func testJevDiscriminativeRerankServiceExecution() async throws {
    let ticket = OwlAICandidateTicket(sessionID: 1, generation: 1, rawInput: "nihao", actionEpoch: 1)
    let service = OwlAICandidateService(customReranker: { preContext, pinyin, localCandidates, ticket in
      XCTAssertEqual(preContext, "测试前文")
      XCTAssertEqual(pinyin, "nihao")
      XCTAssertEqual(localCandidates.count, 5)
      XCTAssertEqual(ticket.rawInput, "nihao")
      return 2
    })

    let selectedIndex = try await service.rerankCandidates(
      preContext: "测试前文",
      pinyin: "nihao",
      localCandidates: ["你好", "拟好", "妮好", "泥好", "尼豪"],
      ticket: ticket
    )
    XCTAssertEqual(selectedIndex, 2)
  }

  func testJevPromotionToRankZeroLayout() {
    let candidates = ["你好", "拟好", "妮好", "泥好", "尼豪"]
    let labels = ["1.", "2.", "3.", "4.", "5."]
    var models = candidates.indices.map { i in
      CandidateViewModel(
        id: i,
        label: labels[i],
        text: candidates[i],
        token: OwlCandidateToken(sessionID: 100, generation: 1, candidateID: i, isAbsolute: false)
      )
    }

    let ticket = OwlAICandidateTicket(sessionID: 100, generation: 1, rawInput: "nihao", actionEpoch: 0)
    let applied = OwlAICandidateLayout.applyJevRerank(
      into: &models,
      elevatedIndex: 2, // "妮好"
      ticket: ticket,
      currentSessionID: 100,
      currentGen: 1,
      rawInput: "nihao",
      page: 0,
      labels: labels,
      allLocalCandidates: candidates
    )

    XCTAssertTrue(applied)
    XCTAssertEqual(models.count, 5)

    // Rank 0 is "妮好" with label "1." and preserved candidateID 2
    XCTAssertEqual(models[0].text, "妮好")
    XCTAssertEqual(models[0].label, "1.")
    XCTAssertEqual(models[0].token.candidateID, 2)

    // Shifted rank 1 is "你好" with label "2." and candidateID 0
    XCTAssertEqual(models[1].text, "你好")
    XCTAssertEqual(models[1].label, "2.")
    XCTAssertEqual(models[1].token.candidateID, 0)

    // Shifted rank 2 is "拟好" with label "3." and candidateID 1
    XCTAssertEqual(models[2].text, "拟好")
    XCTAssertEqual(models[2].label, "3.")
    XCTAssertEqual(models[2].token.candidateID, 1)

    // Ranks 3 and 4 maintain original positions
    XCTAssertEqual(models[3].text, "泥好")
    XCTAssertEqual(models[3].label, "4.")
    XCTAssertEqual(models[4].text, "尼豪")
    XCTAssertEqual(models[4].label, "5.")
  }

  func testJevPromotionFromLaterPageCandidate() {
    let allCandidates = (0..<10).map { "词条\($0)" }
    let labels = ["1.", "2.", "3.", "4.", "5."]
    var models = (0..<5).map { i in
      CandidateViewModel(
        id: i,
        label: labels[i],
        text: allCandidates[i],
        token: OwlCandidateToken(sessionID: 100, generation: 1, candidateID: i, isAbsolute: false)
      )
    }

    let ticket = OwlAICandidateTicket(sessionID: 100, generation: 1, rawInput: "test", actionEpoch: 0)
    // Elevate index 7 ("词条7") which was originally on page 2
    let applied = OwlAICandidateLayout.applyJevRerank(
      into: &models,
      elevatedIndex: 7,
      ticket: ticket,
      currentSessionID: 100,
      currentGen: 1,
      rawInput: "test",
      page: 0,
      labels: labels,
      allLocalCandidates: allCandidates
    )

    XCTAssertTrue(applied)
    XCTAssertEqual(models[0].text, "词条7")
    XCTAssertEqual(models[0].label, "1.")
    XCTAssertEqual(models[0].token.candidateID, 7)
    XCTAssertTrue(models[0].token.isAbsolute)

    XCTAssertEqual(models[1].text, "词条0")
    XCTAssertEqual(models[1].label, "2.")
  }

  func testJevZeroHallucinationConstraint() {
    let localPool = ["法墨", "输入法", "智能", "本地"]
    let parsedIndex = OwlAICandidateService.parseRerankResponse("c2", candidateCount: localPool.count)
    XCTAssertNotNil(parsedIndex)
    let selectedWord = localPool[try! XCTUnwrap(parsedIndex)]
    XCTAssertEqual(selectedWord, "智能")
    XCTAssertTrue(localPool.contains(selectedWord))

    // Attempted hallucination: invalid choice returns nil and does not inject foreign strings
    let invalidParsed = OwlAICandidateService.parseRerankResponse("新发明词汇", candidateCount: localPool.count)
    XCTAssertNil(invalidParsed)
  }

  func testJevNoneOrTimeoutPreservesOriginalOrder() {
    let candidates = ["你好", "拟好", "妮好", "泥好", "尼豪"]
    let labels = ["1.", "2.", "3.", "4.", "5."]
    var models = candidates.indices.map { i in
      CandidateViewModel(
        id: i,
        label: labels[i],
        text: candidates[i],
        token: OwlCandidateToken(sessionID: 100, generation: 1, candidateID: i, isAbsolute: false)
      )
    }

    let ticket = OwlAICandidateTicket(sessionID: 100, generation: 1, rawInput: "nihao", actionEpoch: 0)
    // When elevatedIndex is nil (e.g. model returned "none" or timed out)
    let applied = OwlAICandidateLayout.applyJevRerank(
      into: &models,
      elevatedIndex: nil,
      ticket: ticket,
      currentSessionID: 100,
      currentGen: 1,
      rawInput: "nihao",
      page: 0,
      labels: labels,
      allLocalCandidates: candidates
    )

    XCTAssertFalse(applied)
    XCTAssertEqual(models.map(\.text), candidates)
    XCTAssertEqual(models.map(\.label), labels)
  }

  func testJevPreservesOrderWhenUserPagingOrNavigated() {
    let candidates = ["你好", "拟好", "妮好", "泥好", "尼豪"]
    let labels = ["1.", "2.", "3.", "4.", "5."]
    var models = candidates.indices.map { i in
      CandidateViewModel(
        id: i,
        label: labels[i],
        text: candidates[i],
        token: OwlCandidateToken(sessionID: 100, generation: 1, candidateID: i, isAbsolute: false)
      )
    }

    let ticket = OwlAICandidateTicket(sessionID: 100, generation: 1, rawInput: "nihao", actionEpoch: 0)
    // When page > 0 (user turned pages to page 1)
    let appliedOnPage1 = OwlAICandidateLayout.applyJevRerank(
      into: &models,
      elevatedIndex: 2,
      ticket: ticket,
      currentSessionID: 100,
      currentGen: 1,
      rawInput: "nihao",
      page: 1,
      labels: labels,
      allLocalCandidates: candidates
    )

    XCTAssertFalse(appliedOnPage1, "applyJevRerank must not alter candidates when user is on page > 0")
    XCTAssertEqual(models.map(\.text), candidates)
  }

  func testJevLRUCacheAvoidsDuplicateNetworkCalls() async throws {
    let cache = OwlCandidateRerankCache(capacity: 2)
    let key1 = OwlAICandidateService.cacheKey(preContext: "ctx", pinyin: "ni", candidates: ["你", "泥"])
    let key2 = OwlAICandidateService.cacheKey(preContext: "ctx", pinyin: "hao", candidates: ["好", "号"])
    let key3 = OwlAICandidateService.cacheKey(preContext: "ctx", pinyin: "ma", candidates: ["吗", "马"])
    XCTAssertFalse(cache.get(key1).hit)

    cache.set(key1, value: 1)
    let hit = cache.get(key1)
    XCTAssertTrue(hit.hit)
    XCTAssertEqual(hit.value, 1)

    cache.set(key2, value: 0)
    cache.set(key3, value: nil)
    XCTAssertFalse(cache.get(key1).hit)
    XCTAssertTrue(cache.get(key2).hit)
    XCTAssertTrue(cache.get(key3).hit)
  }

  func testJevControllerKeyInterceptionAndCommit() throws {
    let controller = try XCTUnwrap(OwlInputController(server: nil, delegate: nil, client: nil))
    controller.destroySession()
    let client = HabitsTextClient()
    controller.client = client
    defer {
      controller.destroySession()
      NSApp.owlAppDelegate.owlPanel?.hidePanel()
    }
    let fakeSession = FakeEngineSession(sessionID: 100, generation: 1, isValid: true, input: "nihao")
    controller.engineSession = fakeSession

    let ticket = OwlAICandidateTicket(sessionID: 100, generation: 1, rawInput: "nihao", actionEpoch: 0)
    controller.activeJevRerankIndex = 2
    controller.activeJevRerankTicket = ticket
    controller.activeJevLocalCandidates = ["你好", "拟好", "妮好", "泥好", "尼豪"]

    let candidates = ["你好", "拟好", "妮好", "泥好", "尼豪"]
    let labels = ["1.", "2.", "3.", "4.", "5."]
    controller.showPanel(
      preedit: "nihao",
      cursor: 5,
      selStart: 0,
      selEnd: 5,
      candidates: candidates,
      comments: [],
      labels: labels,
      highlighted: 0,
      page: 0,
      lastPage: false,
      pageSize: 5
    )

    // Verify UI models have "妮好" promoted to index 0
    XCTAssertEqual(controller.lastComposedCandidates[0].text, "妮好")
    XCTAssertEqual(controller.lastComposedCandidates[0].label, "1.")
    XCTAssertEqual(controller.lastComposedCandidates[0].token.candidateID, 2)

    // Interception: number key 1 routes to slot 0
    XCTAssertEqual(controller.shouldInterceptForJevRerank(keycode: UInt32(XK_1), modifiers: 0), 0)
    // Interception: number key 2 routes to slot 1
    XCTAssertEqual(controller.shouldInterceptForJevRerank(keycode: UInt32(XK_2), modifiers: 0), 1)
    // Space and Return when highlight is 0 route to slot 0
    XCTAssertEqual(controller.shouldInterceptForJevRerank(keycode: UInt32(XK_space), modifiers: 0), 0)
    XCTAssertEqual(controller.shouldInterceptForJevRerank(keycode: UInt32(XK_Return), modifiers: 0), 0)

    // Non-selection key returns nil
    XCTAssertNil(controller.shouldInterceptForJevRerank(keycode: UInt32(XK_a), modifiers: 0))

    // Select panel index 0 (promoted candidate "妮好")
    controller.selectPanelIndex(0)
    // Verifies candidateID 2 was selected in fakeSession
    XCTAssertTrue(fakeSession.selectedIndices.contains(2) || fakeSession.selectedAbsoluteIndices.contains(2))
  }
}
