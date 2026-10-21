//
//  ProviderProfileStoreTests.swift
//  OwltypeTests — multi-provider profile foundation
//  (task 06-22-owl-multi-provider-keychain-foundation, research B1+B2)
//
//  Locks the provider-profile foundation contracts against an isolated temp dir + an in-memory
//  secret store (never touches the real ~/Library/Application Support/Owltype or the real Keychain):
//    1. `providers.json` CRUD round-trips, is human-readable, and carries `schemaVersion`.
//    2. Exactly-one-default invariant across add / setDefault / delete.
//    3. A malformed providers.json reads back as empty (no crash); missing schemaVersion defaults.
//    4. The key NEVER appears in providers.json; it lives only in the secret store under secretName.
//    5. Legacy DeepSeek migration is idempotent and only fires when a legacy key exists.
//
//  No network, no librime.
//

import Foundation
import XCTest
@testable import Owltype

/// In-memory `OwlSecretStoring` for tests — upsert semantics, no Keychain.
final class OwlInMemorySecretStore: OwlSecretStoring {
  private var storage: [String: String] = [:]
  func secret(named name: String) throws -> String? { storage[name] }
  func setSecret(_ value: String, named name: String) throws { storage[name] = value }
  func deleteSecret(named name: String) throws { storage[name] = nil }
}

final class ProviderProfileStoreTests: XCTestCase {

  func testLatestFlashPresetsAndProbeRouting() throws {
    let deepseek = try XCTUnwrap(OwlLLMProviderCatalog.preset(id: "deepseek"))
    XCTAssertEqual(deepseek.model, "deepseek-flash")
    let endpoint = try XCTUnwrap(URL(string: deepseek.endpoint))
    let body = OwlProviderConnectivityCheck.body(providerID: "deepseek", model: deepseek.model, endpoint: endpoint)
    XCTAssertNotNil(body["input"])
    XCTAssertNil(body["messages"])
    XCTAssertEqual(body["model"] as? String, "deepseek-flash")
    let request = try OwlProviderConnectivityCheck.request(
      endpoint: endpoint, providerID: "deepseek", model: deepseek.model,
      apiKey: "test-placeholder", authStyle: .bearer)
    XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/responses")
    XCTAssertEqual(OwlSearchControl.transport(
      providerID: "deepseek", host: "api.deepseek.com", model: deepseek.model), .none)
    let gemini = try XCTUnwrap(OwlLLMProviderCatalog.preset(id: "gemini"))
    XCTAssertEqual(gemini.model, "gemini-3.8-flash")
    let geminiBody = OwlProviderConnectivityCheck.body(providerID: "gemini", model: gemini.model)
    XCTAssertNotNil(geminiBody["messages"])
    XCTAssertEqual(geminiBody["max_tokens"] as? Int, 1024)
    XCTAssertNil(geminiBody["thinking"])
  }

  func testMiniMaxFlashUsesLowThinkingAndAdequateProbeBudget() throws {
    let preset = try XCTUnwrap(OwlLLMProviderCatalog.preset(id: "minimax"))
    XCTAssertEqual(preset.model, "MiniMax-M3.1-Flash")
    XCTAssertEqual(preset.endpoint, "https://api.minimax.cn/v1/chat/completions", "只接国内站")
    XCTAssertEqual(OwlLLMProviderCatalog.minimaxModels.first, preset.model)
    let body = OwlProviderConnectivityCheck.body(providerID: "minimax", model: preset.model)
    XCTAssertEqual(body["reasoning_effort"] as? String, "low")
    XCTAssertEqual(body["reasoning_split"] as? Bool, true)
    XCTAssertNil(body["thinking"])
    XCTAssertNil(body["max_tokens"])
    XCTAssertEqual(body["max_completion_tokens"] as? Int, 4096)
    for model in OwlLLMProviderCatalog.minimaxModels {
      let payload = try OwlSelectionPolish.chatRequest(for: "请确认明天开会。", model: model, providerID: "minimax")
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
      XCTAssertNil(object["response_format"], "MiniMax has no documented JSON mode")
      XCTAssertEqual(object["reasoning_split"] as? Bool, true)
      if model == "MiniMax-M3" {
        XCTAssertEqual((object["thinking"] as? [String: String])?["type"], "disabled")
      } else {
        XCTAssertNil(object["thinking"], "M3.1 Flash cannot disable reasoning")
      }
    }
    // 正式版之前存下的 `-Preview` 档案不改写，仍按 M3.1 Flash 的形状发（低思考强度）。
    let legacyPreview = OwlProviderConnectivityCheck.body(
      providerID: "minimax", model: "MiniMax-M3.1-Flash-Preview")
    XCTAssertEqual(legacyPreview["reasoning_effort"] as? String, "low")
    XCTAssertNil(legacyPreview["thinking"])
    let drafting = OwlStructuredDrafting.chatRequest(
      systemPrompt: "Return JSON", draft: "安排会议", model: preset.model,
      providerID: "minimax", temperature: 0.2)
    XCTAssertEqual(drafting.reasoningEffort, "low")
    XCTAssertEqual(drafting.reasoningSplit, true)
    XCTAssertNil(drafting.responseFormat)
  }

  private var tempRoot: URL!

  func testGemini38SelectionAndDraftingOmitSamplingParameters() throws {
    let model = "gemini-3.8-flash"
    for providerID in ["gemini", ""] {
      for variant in [OwlPolishPromptCatalog.legacy, OwlPolishPromptCatalog.responsayAligned] {
        let payload = try OwlSelectionPolish.chatRequest(
          for: "请确认明天开会。", model: model, providerID: providerID, variant: variant)
        let body = try XCTUnwrap(
          JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["top_p"])
        XCTAssertNil(body["top_k"])
        XCTAssertEqual(body["model"] as? String, model)
        XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
        XCTAssertEqual(payload.messages.first?.content, variant.systemPrompt)
      }
      let payload = OwlStructuredDrafting.chatRequest(
        systemPrompt: "Return JSON", draft: "安排会议", model: model,
        providerID: providerID, temperature: 0.2)
      let body = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
      XCTAssertNil(body["temperature"])
      XCTAssertNil(body["top_p"])
      XCTAssertNil(body["top_k"])
      XCTAssertNotNil(body["messages"])
    }
  }

  func testOtherChatModelsKeepConfiguredTemperature() throws {
    for model in ["gemini-2.5-flash", "gpt-4o", "MiniMax-M3.1-Flash"] {
      let selection = try OwlSelectionPolish.chatRequest(
        for: "请确认明天开会。", model: model, variant: OwlPolishPromptCatalog.legacy)
      let drafting = OwlStructuredDrafting.chatRequest(
        systemPrompt: "Return JSON", draft: "安排会议", model: model, temperature: 0.2)
      for (payload, expected) in [(selection, 0.3), (drafting, 0.2)] {
        let body = try XCTUnwrap(
          JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertEqual(body["temperature"] as? Double, expected)
      }
    }
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("OwlProviderStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
      try FileManager.default.removeItem(at: tempRoot)
    }
    try super.tearDownWithError()
  }

  private func makeStore() -> OwlProviderProfileStore {
    OwlProviderProfileStore(root: tempRoot)
  }

  private func makeProfile(
    name: String,
    model: String = "deepseek-v4-flash",
    isDefault: Bool = false
  ) -> OwlProviderProfile {
    OwlProviderProfile(
      displayName: name,
      endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
      model: model,
      isDefault: isDefault
    )
  }

  // MARK: - CRUD round-trip

  func testAddPersistsHumanReadableJSONWithSchemaVersion() throws {
    let store = makeStore()
    let added = try store.add(makeProfile(name: "work DeepSeek"))

    XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    let json = try String(contentsOf: store.fileURL, encoding: .utf8)
    XCTAssertTrue(json.contains("\"schemaVersion\""), "providers.json must carry a schema version")
    XCTAssertTrue(json.contains("\"displayName\" : \"work DeepSeek\""), "must be human-readable")
    let rootMode = try FileManager.default.attributesOfItem(atPath: tempRoot.path)[.posixPermissions] as? NSNumber
    let fileMode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(rootMode?.intValue, 0o700)
    XCTAssertEqual(fileMode?.intValue, 0o600)

    let reloaded = try XCTUnwrap(store.profile(id: added.id))
    XCTAssertEqual(reloaded.displayName, "work DeepSeek")
    XCTAssertEqual(reloaded.kind, .openAICompatible)
    XCTAssertEqual(reloaded.secretName, "owltype.provider.\(added.id).apiKey")
  }

  func testKeyIsNeverWrittenToProvidersJSON() throws {
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let profile = try store.add(makeProfile(name: "p"))
    try secrets.setSecret("sk-super-secret-value", named: profile.secretName)

    let json = try String(contentsOf: store.fileURL, encoding: .utf8)
    XCTAssertFalse(json.contains("sk-super-secret-value"), "the API key must never land in providers.json")
    XCTAssertEqual(try secrets.secret(named: profile.secretName), "sk-super-secret-value")
  }

  func testUpdateChangesFieldsAndUnknownIDThrows() throws {
    let store = makeStore()
    var profile = try store.add(makeProfile(name: "before"))
    profile.displayName = "after"
    profile.model = "deepseek-v4-pro"
    _ = try store.update(profile)

    let reloaded = try XCTUnwrap(store.profile(id: profile.id))
    XCTAssertEqual(reloaded.displayName, "after")
    XCTAssertEqual(reloaded.model, "deepseek-v4-pro")

    let ghost = makeProfile(name: "ghost")
    XCTAssertThrowsError(try store.update(ghost)) { error in
      XCTAssertEqual(error as? OwlProviderError, .notFound(ghost.id))
    }
  }

  func testProfilesReturnedInStableOrder() throws {
    let store = makeStore()
    let a = try store.add(makeProfile(name: "A"))
    let b = try store.add(makeProfile(name: "B"))
    XCTAssertEqual(Set(store.profiles().map(\.id)), [a.id, b.id])
    XCTAssertEqual(store.profiles().map(\.id), store.profiles().map(\.id), "order must be stable")
  }

  // MARK: - Exactly-one-default invariant

  func testFirstProfileBecomesDefaultSecondDoesNot() throws {
    let store = makeStore()
    let first = try store.add(makeProfile(name: "first"))
    let second = try store.add(makeProfile(name: "second"))

    XCTAssertEqual(store.defaultProfile?.id, first.id, "first profile auto-becomes default")
    XCTAssertEqual(store.profiles().filter(\.isDefault).count, 1)
    XCTAssertFalse(try XCTUnwrap(store.profile(id: second.id)).isDefault)
  }

  func testSetDefaultSwitchesAndKeepsExactlyOne() throws {
    let store = makeStore()
    let first = try store.add(makeProfile(name: "first"))
    let second = try store.add(makeProfile(name: "second"))

    try store.setDefault(id: second.id)
    XCTAssertEqual(store.defaultProfile?.id, second.id)
    XCTAssertEqual(store.profiles().filter(\.isDefault).count, 1)
    XCTAssertFalse(try XCTUnwrap(store.profile(id: first.id)).isDefault)

    XCTAssertThrowsError(try store.setDefault(id: "nope")) { error in
      XCTAssertEqual(error as? OwlProviderError, .notFound("nope"))
    }
  }

  func testDeletingDefaultPromotesAnother() throws {
    let store = makeStore()
    let first = try store.add(makeProfile(name: "first"))
    let second = try store.add(makeProfile(name: "second"))

    try store.delete(id: first.id)  // first was default
    XCTAssertNil(store.profile(id: first.id))
    XCTAssertEqual(store.defaultProfile?.id, second.id, "deleting the default must promote another")
    XCTAssertEqual(store.profiles().filter(\.isDefault).count, 1)

    try store.delete(id: second.id)
    XCTAssertNil(store.defaultProfile, "no profiles → no default")
    XCTAssertTrue(store.profiles().isEmpty)
  }

  // MARK: - Robustness

  func testMalformedFileReadsAsEmpty() throws {
    let store = makeStore()
    try Data("{ this is not valid json".utf8).write(to: store.fileURL, options: .atomic)
    XCTAssertTrue(store.profiles().isEmpty, "a corrupt providers.json must not crash; reads as empty")
    XCTAssertNil(store.defaultProfile)
    // And the store recovers: a subsequent add overwrites the garbage with a valid file.
    let added = try store.add(makeProfile(name: "recovered"))
    XCTAssertEqual(store.profiles().map(\.id), [added.id])
  }

  func testMissingSchemaVersionDefaults() throws {
    let store = makeStore()
    // A file with no schemaVersion (older writer) still decodes, defaulting to the current version.
    let legacy = """
    { "profiles": [] }
    """
    try Data(legacy.utf8).write(to: store.fileURL, options: .atomic)
    XCTAssertEqual(store.load().schemaVersion, OwlProviderProfilesFile.currentSchemaVersion)
  }

  func testLegacyMaxCandidatesFieldIsToleratedOnDecodeAndDroppedOnEncode() throws {
    let store = makeStore()
    // providers.json written before the cloud-candidate removal carries `maxCandidates`. Decoding
    // must tolerate the retired field (keyed containers ignore unknown keys), and a re-save must
    // no longer write it.
    let legacy = """
    { "schemaVersion": 1, "profiles": [ {
      "id": "legacy", "displayName": "old", "kind": "openai_compatible",
      "endpoint": "https://api.deepseek.com/chat/completions", "model": "deepseek-v4-flash",
      "maxCandidates": 4, "secretName": "owltype.provider.legacy.apiKey",
      "isDefault": true, "createdAt": "2026-06-22T00:00:00Z"
    } ] }
    """
    try Data(legacy.utf8).write(to: store.fileURL, options: .atomic)
    let profiles = store.profiles()
    XCTAssertEqual(profiles.map(\.id), ["legacy"], "a pre-removal record must still decode")
    XCTAssertEqual(store.defaultProfile?.model, "deepseek-v4-flash")

    try store.setDefault(id: "legacy")  // any public mutation re-saves the file
    let json = try String(contentsOf: store.fileURL, encoding: .utf8)
    XCTAssertFalse(json.contains("maxCandidates"), "the retired field must not be re-written")
    XCTAssertTrue(json.contains("\"legacy\""))
  }

  func testUnknownProviderIDDecodesAndDegradesSafely() throws {
    // A profile saved by an older build whose providerID is no longer in the preset catalog must
    // still decode (providerID is a free-form string, not a rawValue enum), but it is no longer a
    // usable default: the store reports no active profile, routing falls back to the legacy DeepSeek
    // config (endpoint + legacy key), and the settings form shows it as a custom entry. The flagged
    // profile itself stays intact — nothing is dropped, rewritten, or deleted.
    let store = makeStore()
    let legacy = """
    { "schemaVersion": 1, "profiles": [ {
      "id": "legacy", "displayName": "retired", "kind": "openai_compatible",
      "endpoint": "https://retired.example.com/v1/chat/completions", "model": "retired-1",
      "providerID": "retired-provider", "secretName": "owltype.provider.legacy.apiKey",
      "isDefault": true, "createdAt": "2026-06-22T00:00:00Z"
    } ] }
    """
    try Data(legacy.utf8).write(to: store.fileURL, options: .atomic)

    // 旧档案本身不解码崩溃、不丢弃。
    let profiles = store.profiles()
    XCTAssertEqual(profiles.map(\.id), ["legacy"], "an unknown providerID must still decode")
    let profile = try XCTUnwrap(profiles.first)
    XCTAssertEqual(profile.providerID, "retired-provider")
    XCTAssertEqual(OwlLLMProviderCatalog.inferredProviderID(for: profile), "retired-provider")

    // 已退出预设目录的 id 不再作为有效默认：store 无活动档案，路由回落到仓库默认 DeepSeek，
    // 而不是继续打已下线服务的端点，密钥也回到 legacy（secretName 为空）。
    XCTAssertNil(store.defaultProfile, "a retired default is not a usable default")
    let routing = OwlCloudRouting.resolve(profile: store.defaultProfile)
    XCTAssertEqual(routing.providerID, "deepseek")
    XCTAssertNotEqual(routing.endpoint, profile.endpoint, "must not route to the retired endpoint")
    XCTAssertNil(routing.secretName, "the legacy key is used, not the retired profile's secretName")

    // 设置读取路径：编辑该档案时按 custom 展示（端点可改），不出现悬空的预设 id。
    XCTAssertEqual(
      OwlLLMProviderCatalog.formProviderID(for: profile), OwlLLMProviderCatalog.customID,
      "the edit form shows a retired provider as custom")

    // 能力降级：不联网、不来源核验。
    XCTAssertEqual(
      OwlLLMProviderCatalog.sourceSupport(for: profile), .searchPlanOnly,
      "an unknown provider must not claim source verification")
    XCTAssertEqual(
      OwlSearchControl.channel(providerID: "retired-provider", host: "retired.example.com"), .none)
    XCTAssertFalse(
      OwlSearchControl.supportsSearch(providerID: "retired-provider", host: "retired.example.com"))
  }

  // MARK: - Secret store

  func testInMemorySecretStoreUpsertAndDelete() throws {
    let secrets = OwlInMemorySecretStore()
    XCTAssertNil(try secrets.secret(named: "owltype.provider.x.apiKey"))
    try secrets.setSecret("k1", named: "owltype.provider.x.apiKey")
    XCTAssertEqual(try secrets.secret(named: "owltype.provider.x.apiKey"), "k1")
    try secrets.setSecret("k2", named: "owltype.provider.x.apiKey")  // upsert
    XCTAssertEqual(try secrets.secret(named: "owltype.provider.x.apiKey"), "k2")
    try secrets.deleteSecret(named: "owltype.provider.x.apiKey")
    XCTAssertNil(try secrets.secret(named: "owltype.provider.x.apiKey"))
  }

  // MARK: - Legacy migration

  func testLegacyMigrationCreatesDefaultProfileAndCopiesKey() throws {
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()

    let migrated = try XCTUnwrap(OwlProviderMigration.migrateLegacyDeepSeekIfNeeded(
      store: store,
      secrets: secrets,
      legacyKeyReader: { "sk-legacy-deepseek" },
      legacyEndpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
      legacyModel: "deepseek-v4-flash"
    ))

    XCTAssertEqual(migrated.displayName, "DeepSeek")
    XCTAssertTrue(migrated.isDefault)
    XCTAssertEqual(store.defaultProfile?.id, migrated.id)
    XCTAssertEqual(try secrets.secret(named: migrated.secretName), "sk-legacy-deepseek",
                   "the legacy key must be copied into the per-profile secretName")
    // providers.json holds the profile but not the key.
    let json = try String(contentsOf: store.fileURL, encoding: .utf8)
    XCTAssertFalse(json.contains("sk-legacy-deepseek"))
  }

  func testLegacyMigrationIsIdempotent() throws {
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let reader: () throws -> String? = { "sk-legacy-deepseek" }

    let first = OwlProviderMigration.migrateLegacyDeepSeekIfNeeded(
      store: store, secrets: secrets, legacyKeyReader: reader)
    XCTAssertNotNil(first)
    let second = OwlProviderMigration.migrateLegacyDeepSeekIfNeeded(
      store: store, secrets: secrets, legacyKeyReader: reader)
    XCTAssertNil(second, "migration must not run again once a profile exists")
    XCTAssertEqual(store.profiles().count, 1)
  }

  func testNoLegacyKeyMeansNoMigration() throws {
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let migrated = OwlProviderMigration.migrateLegacyDeepSeekIfNeeded(
      store: store, secrets: secrets, legacyKeyReader: { nil })
    XCTAssertNil(migrated, "a fresh install with no legacy key creates no profile")
    XCTAssertTrue(store.profiles().isEmpty)
  }

  // MARK: - Settings actions (Slice 3)

  func testAddProviderProfileActionPersistsProfileAndKey() throws {
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let result = OwlSettingsActions.addProviderProfile(
      displayName: " work DeepSeek ",
      endpoint: "https://api.deepseek.com/chat/completions",
      model: "deepseek-chat",
      apiKey: " sk-add ",
      makeDefault: true,
      store: store,
      secrets: secrets,
      providerID: "deepseek"
    )
    XCTAssertEqual(result.profiles.count, 1)
    let profile = try XCTUnwrap(result.profiles.first)
    XCTAssertEqual(profile.displayName, "work DeepSeek", "name is trimmed")
    XCTAssertEqual(profile.providerID, "deepseek")
    XCTAssertTrue(profile.isDefault)
    XCTAssertTrue(result.status.hasPrefix("已添加"))
    XCTAssertEqual(try secrets.secret(named: profile.secretName), "sk-add",
                   "the key is written to the secret store, trimmed")
    let json = try String(contentsOf: store.fileURL, encoding: .utf8)
    XCTAssertFalse(json.contains("sk-add"), "the key must never land in providers.json")
  }

  func testLLMProviderCatalogMarksSourceSearchProviders() throws {
    XCTAssertNil(OwlLLMProviderCatalog.preset(id: "zhipu"), "智谱已下架，不得再出现在预设目录里")

    let sourceCapable = ["qwen", "doubao", "openai"]
    for id in sourceCapable {
      let preset = try XCTUnwrap(OwlLLMProviderCatalog.preset(id: id))
      XCTAssertEqual(preset.sourceSupport, .sourceResults, "\(id) should support source verification")
    }

    let planOnly = ["deepseek", "gemini", "minimax"]
    for id in planOnly {
      let preset = try XCTUnwrap(OwlLLMProviderCatalog.preset(id: id))
      XCTAssertEqual(preset.sourceSupport, .searchPlanOnly, "\(id) should not pretend to return sources")
    }

    // 语义已反转（2026-07-31 百炼全面转 Responses）：来源核验能力属于**平台**而非型号。此前这里
    // 断言的是「非 qwen 型号降级为辅助检索」——那道降级正是旧 chat 回退的一部分，已随之拆掉。
    // 型号真不被 Responses 服务时由上游 400 说话，比猫头鹰先替阿里猜一个型号白名单更贴近真相。
    let nonQwenOnDashScope = OwlProviderProfile(
      displayName: "百炼托管 DeepSeek",
      endpoint: URL(string: OwlLLMProviderCatalog.qwenResponsesEndpoint)!,
      model: "deepseek-v3.2",
      providerID: "qwen")
    XCTAssertEqual(
      OwlLLMProviderCatalog.sourceSupport(for: nonQwenOnDashScope),
      .sourceResults,
      "百炼整体走 Responses，来源核验能力不按型号名降级")
  }

  /// The default Flash model is selectable first; existing explicit Plus/Max choices remain.
  func testQwenPresetOffersTheWholeCuratedListWithItsDefaultInside() throws {
    let preset = try XCTUnwrap(OwlLLMProviderCatalog.preset(id: "qwen"))
    XCTAssertEqual(preset.model, "qwen3.8-flash")
    XCTAssertEqual(
      preset.endpoint,
      OwlLLMProviderCatalog.qwenResponsesEndpoint)
    XCTAssertEqual(OwlLLMProviderCatalog.qwenModels.first, preset.model)
    XCTAssertTrue(
      OwlLLMProviderCatalog.qwenModels.contains("qwen3.7-max"),
      "高质量档 qwen3.7-max 必须可选")
    XCTAssertEqual(
      Set(OwlLLMProviderCatalog.qwenModels).count, OwlLLMProviderCatalog.qwenModels.count,
      "清单不能有重复项，下拉会出现两个一样的")
    let request = try OwlResponsesWire.request(
      endpoint: URL(string: preset.endpoint)!, model: preset.model,
      messages: [OwlDeepSeekMessage(role: "user", content: "Search the web")],
      apiKey: "test-placeholder", authHeaderStyle: .bearer, dialect: .qwen,
      stream: false, webSearch: true, timeout: 20)
    XCTAssertEqual(request.url?.absoluteString, preset.endpoint)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "qwen3.8-flash")
    XCTAssertEqual(body["tool_choice"] as? String, "required")
    XCTAssertEqual((body["tools"] as? [[String: String]])?.first?["type"], "web_search")
    XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "none")

  }

  /// 豆包预设 = 高质量档 doubao-seed-2-1-pro，端点直指方舟 Responses（2026-07-31 起
  /// 豆包全面走 Responses：store=false + thinking:{disabled} 均在 Responses 请求体上）。
  func testDoubaoPresetUsesProModelOnTheResponsesEndpoint() throws {
    let preset = try XCTUnwrap(OwlLLMProviderCatalog.preset(id: "doubao"))
    XCTAssertEqual(preset.model, "doubao-seed-2-1-pro-260628")
    XCTAssertEqual(
      preset.endpoint,
      "https://ark.cn-beijing.volces.com/api/v3/responses")
    XCTAssertEqual(preset.sourceSupport, .sourceResults)
  }

  func testQwenWorkspaceInputAcceptsWorkspaceIDHostAndFullEndpoint() throws {
    let workspaceID = "ws-test123abc"
    let workspaceHost = "ws-test123abc.cn-beijing.maas.aliyuncs.com"
    let endpoint = "https://\(workspaceHost)/compatible-mode/v1/responses"

    XCTAssertEqual(OwlQwenWorkspace.normalizedAPIHost(workspaceID), workspaceHost)
    XCTAssertEqual(OwlQwenWorkspace.normalizedAPIHost(workspaceHost), workspaceHost)
    XCTAssertEqual(OwlQwenWorkspace.normalizedAPIHost(endpoint), workspaceHost)
    XCTAssertEqual(
      OwlQwenWorkspace.responsesEndpoint(for: workspaceID)?.absoluteString,
      endpoint)
  }

  func testQwenWorkspaceRejectsInvalidOrForeignHosts() {
    for invalid in [
      "workspace.example.com",
      "ws-good.cn-beijing.maas.aliyuncs.com.evil.example",
      "ws-good@cn-beijing.maas.aliyuncs.com",
      "ws-good/compatible-mode/v1/responses",
      "ws-空间",
      "https://dashscope.aliyuncs.com/compatible-mode/v1/responses",
    ] {
      XCTAssertNil(OwlQwenWorkspace.normalizedAPIHost(invalid), invalid)
    }
  }

  func testQwenWorkspaceSettingPersistsOnlyTheNormalizedHost() throws {
    let suiteName = "OwlQwenWorkspaceTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertTrue(OwlQwenWorkspaceSettings.save("ws-test123abc", defaults: defaults))
    XCTAssertEqual(
      OwlQwenWorkspaceSettings.apiHost(defaults: defaults),
      "ws-test123abc.cn-beijing.maas.aliyuncs.com")
    XCTAssertEqual(
      OwlQwenWorkspaceSettings.responsesEndpoint(defaults: defaults).absoluteString,
      "https://ws-test123abc.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/responses")

    XCTAssertFalse(OwlQwenWorkspaceSettings.save("workspace.example.com", defaults: defaults))
    XCTAssertEqual(
      OwlQwenWorkspaceSettings.apiHost(defaults: defaults),
      "ws-test123abc.cn-beijing.maas.aliyuncs.com",
      "invalid input must not overwrite the last usable host")

    XCTAssertTrue(OwlQwenWorkspaceSettings.save("", defaults: defaults))
    XCTAssertEqual(OwlQwenWorkspaceSettings.apiHost(defaults: defaults), "")
    XCTAssertEqual(
      OwlQwenWorkspaceSettings.responsesEndpoint(defaults: defaults).absoluteString,
      OwlLLMProviderCatalog.qwenResponsesEndpoint,
      "empty workspace falls back to the documented generic Responses host")
  }

  func testSavingQwenWorkspaceAlsoUpdatesAnExistingQwenProfileEndpoint() throws {
    let store = makeStore()
    let profile = OwlProviderProfile(
      displayName: "阿里云百炼",
      endpoint: URL(string: OwlLLMProviderCatalog.qwenResponsesEndpoint)!,
      model: "qwen3.7-plus",
      providerID: "qwen")
    _ = try store.add(profile)
    let suiteName = "OwlQwenWorkspaceActionTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let result = OwlSettingsActions.saveQwenWorkspace(
      "ws-test123abc.cn-beijing.maas.aliyuncs.com",
      store: store,
      defaults: defaults)

    XCTAssertTrue(result.saved)
    XCTAssertEqual(
      try XCTUnwrap(store.profile(id: profile.id)).endpoint.absoluteString,
      "https://ws-test123abc.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/responses")
    XCTAssertEqual(
      OwlQwenWorkspaceSettings.apiHost(defaults: defaults),
      "ws-test123abc.cn-beijing.maas.aliyuncs.com")
  }

  /// 密钥三态：「有值」不等于「能用」。实机踩过的就是 Key 已 401，设置页仍写「已设置」，
  /// 用户想不到是密钥的问题。所以只有真的调通过一次（`拉取最新`）才升到「已验证」，
  /// 而换钥匙/删钥匙都让上一次验证作废 —— 旧标记配新密钥就是假验证。
  func testKeyStatusIsVerifiedOnlyAfterARealCallAndIsInvalidatedByKeyChanges() throws {
    OwlProviderKeyVerification.resetForTesting()
    defer { OwlProviderKeyVerification.resetForTesting() }
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let added = OwlSettingsActions.addProviderProfile(
      displayName: "豆包", endpoint: "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
      model: "doubao-seed-2-1-turbo-260628", apiKey: "sk-ark", makeDefault: true,
      store: store, secrets: secrets, providerID: "doubao")
    let profile = try XCTUnwrap(added.profiles.first)
    XCTAssertEqual(
      OwlSettingsActions.providerProfileKeyStatus(profile, secrets: secrets), "已设置·未验证")

    OwlSettingsActions.markProviderProfileKeyVerified(profile)
    XCTAssertEqual(
      OwlSettingsActions.providerProfileKeyStatus(profile, secrets: secrets), "已验证")

    // 换钥匙 → 上一次验证不再代表当前这把 Key。
    _ = OwlSettingsActions.saveProviderProfileKey(profile, apiKey: "sk-rotated", secrets: secrets)
    XCTAssertEqual(
      OwlSettingsActions.providerProfileKeyStatus(profile, secrets: secrets), "已设置·未验证")

    OwlSettingsActions.markProviderProfileKeyVerified(profile)
    _ = OwlSettingsActions.clearProviderProfileKey(profile, secrets: secrets)
    XCTAssertEqual(
      OwlSettingsActions.providerProfileKeyStatus(profile, secrets: secrets), "未设置")
    XCTAssertNil(
      OwlProviderKeyVerification.verifiedAt(secretName: profile.secretName),
      "删钥匙也要把标记一起清掉，否则重新填一把新 Key 会直接显示已验证")
  }

  /// 原地编辑时 Key 留空＝保持不变，那么上一次的验证状态也该保持；只有真的换了钥匙才作废。
  func testUpdateKeepsVerificationWhenKeyIsUnchangedAndDropsItWhenRotated() throws {
    OwlProviderKeyVerification.resetForTesting()
    defer { OwlProviderKeyVerification.resetForTesting() }
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let profile = try XCTUnwrap(OwlSettingsActions.addProviderProfile(
      displayName: "豆包", endpoint: "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
      model: "doubao-seed-2-1-turbo-260628", apiKey: "sk-ark", makeDefault: true,
      store: store, secrets: secrets, providerID: "doubao").profiles.first)
    OwlSettingsActions.markProviderProfileKeyVerified(profile)

    _ = OwlSettingsActions.updateProviderProfile(
      profile, endpoint: profile.endpoint.absoluteString, model: "doubao-seed-2-2",
      apiKey: "", store: store, secrets: secrets)
    XCTAssertEqual(
      OwlSettingsActions.providerProfileKeyStatus(profile, secrets: secrets), "已验证",
      "只换了模型，Key 没动 → 验证状态保持")

    _ = OwlSettingsActions.updateProviderProfile(
      profile, endpoint: profile.endpoint.absoluteString, model: "doubao-seed-2-2",
      apiKey: "sk-new", store: store, secrets: secrets)
    XCTAssertEqual(
      OwlSettingsActions.providerProfileKeyStatus(profile, secrets: secrets), "已设置·未验证",
      "换了钥匙 → 作废")
  }

  /// 换模型的核心不变式：不重填 Key 也能改。`secretName` 是从 profile 的 UUID 推出来的，所以
  /// 「删掉再加一条」会换一个 Keychain 账号并把旧 Key 一起删掉 —— 原地更新才保得住。
  func testUpdateProviderProfileChangesModelAndKeepsStoredKey() throws {
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let added = OwlSettingsActions.addProviderProfile(
      displayName: "豆包", endpoint: "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
      model: "doubao-seed-2-1-turbo-260628", apiKey: "sk-ark", makeDefault: true,
      store: store, secrets: secrets, providerID: "doubao")
    let original = try XCTUnwrap(added.profiles.first)

    let result = OwlSettingsActions.updateProviderProfile(
      original,
      endpoint: "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
      model: " doubao-seed-2-2 ",
      apiKey: "",                       // 用户没重填 Key
      store: store,
      secrets: secrets
    )
    let updated = try XCTUnwrap(result.profiles.first)
    XCTAssertEqual(updated.model, "doubao-seed-2-2", "model is updated and trimmed")
    XCTAssertEqual(updated.id, original.id, "same profile, not a replacement")
    XCTAssertEqual(updated.secretName, original.secretName)
    XCTAssertTrue(updated.isDefault, "编辑模型不该把默认供应商弄丢")
    XCTAssertEqual(try secrets.secret(named: updated.secretName), "sk-ark",
                   "留空的 Key 字段意味着「保持不变」，不是「清空」")
    XCTAssertEqual(result.profiles.count, 1, "原地更新不该多出一条")
  }

  func testUpdateProviderProfileWritesNewKeyWhenTypedAndRejectsNonHTTPS() throws {
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let added = OwlSettingsActions.addProviderProfile(
      displayName: "豆包", endpoint: "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
      model: "doubao-seed-2-1-turbo-260628", apiKey: "sk-old", makeDefault: true,
      store: store, secrets: secrets, providerID: "doubao")
    let original = try XCTUnwrap(added.profiles.first)

    let rotated = OwlSettingsActions.updateProviderProfile(
      original, endpoint: original.endpoint.absoluteString, model: original.model,
      apiKey: " sk-new ", store: store, secrets: secrets)
    XCTAssertTrue(rotated.status.hasPrefix("已保存"))
    XCTAssertEqual(try secrets.secret(named: original.secretName), "sk-new", "typed key wins, trimmed")

    let insecure = OwlSettingsActions.updateProviderProfile(
      original, endpoint: "http://ark.cn-beijing.volces.com/api/v3/chat/completions",
      model: original.model, apiKey: "", store: store, secrets: secrets)
    XCTAssertEqual(insecure.status, "端点必须是 https。")
    XCTAssertEqual(store.profiles().first?.endpoint.scheme, "https", "被拒的端点不能落盘")
  }

  func testAddProviderProfileActionRejectsBlankNameAndNonHTTPS() throws {
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()

    let blank = OwlSettingsActions.addProviderProfile(
      displayName: "   ", endpoint: "https://api.openai.com/v1/chat/completions",
      model: "gpt-4o", apiKey: "", makeDefault: true, store: store, secrets: secrets)
    XCTAssertEqual(blank.status, "供应商名称不能为空。")
    XCTAssertTrue(store.profiles().isEmpty)

    let insecure = OwlSettingsActions.addProviderProfile(
      displayName: "p", endpoint: "http://api.openai.com/v1/chat/completions",
      model: "gpt-4o", apiKey: "", makeDefault: true, store: store, secrets: secrets)
    XCTAssertEqual(insecure.status, "端点必须是 https。")
    XCTAssertTrue(store.profiles().isEmpty, "a non-https endpoint must not create a profile")
  }

  func testAddProviderProfileActionAllowsEmptyKeyForLaterEntry() throws {
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let result = OwlSettingsActions.addProviderProfile(
      displayName: "personal OpenAI", endpoint: "https://api.openai.com/v1/chat/completions",
      model: "gpt-4o", apiKey: "  ", makeDefault: true, store: store, secrets: secrets)
    let profile = try XCTUnwrap(result.profiles.first)
    XCTAssertNil(try secrets.secret(named: profile.secretName), "no key supplied → none stored")
    XCTAssertTrue(result.status.hasPrefix("已添加"))
  }

  func testSetDefaultDeleteAndSaveKeyActions() throws {
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let first = try XCTUnwrap(OwlSettingsActions.addProviderProfile(
      displayName: "first", endpoint: "https://a.example.com/v1/chat/completions",
      model: "m1", apiKey: "", makeDefault: true, store: store, secrets: secrets).profiles.first)
    let added2 = OwlSettingsActions.addProviderProfile(
      displayName: "second", endpoint: "https://b.example.com/v1/chat/completions",
      model: "m2", apiKey: "", makeDefault: false, store: store, secrets: secrets)
    let second = try XCTUnwrap(added2.profiles.first { $0.displayName == "second" })

    // set default
    let setResult = OwlSettingsActions.setDefaultProviderProfile(second, store: store)
    XCTAssertEqual(store.defaultProfile?.id, second.id)
    XCTAssertTrue(setResult.status.contains("second"))

    // save key (write-only, status never echoes the value)
    let saveResult = OwlSettingsActions.saveProviderProfileKey(second, apiKey: " sk-second ", secrets: secrets)
    XCTAssertEqual(saveResult.input, "")
    XCTAssertEqual(saveResult.status, "已保存到 Keychain")
    XCTAssertEqual(try secrets.secret(named: second.secretName), "sk-second")
    // 三态：刚存进去只是「有值」，还没拿它真的调通过任何一次请求。
    XCTAssertEqual(
      OwlSettingsActions.providerProfileKeyStatus(second, secrets: secrets), "已设置·未验证")

    let emptyKey = OwlSettingsActions.saveProviderProfileKey(second, apiKey: "  ", secrets: secrets)
    XCTAssertEqual(emptyKey.status, "请输入 API Key")

    // clear key
    XCTAssertEqual(OwlSettingsActions.clearProviderProfileKey(second, secrets: secrets), "已删除 API Key")
    XCTAssertEqual(OwlSettingsActions.providerProfileKeyStatus(second, secrets: secrets), "未设置")

    // delete profile (removes the profile and its stored key; promotes the other to default)
    try secrets.setSecret("sk-first", named: first.secretName)
    let deleteResult = OwlSettingsActions.deleteProviderProfile(second, store: store, secrets: secrets)
    XCTAssertNil(store.profile(id: second.id))
    XCTAssertEqual(store.defaultProfile?.id, first.id, "deleting the default promotes the remaining profile")
    XCTAssertTrue(deleteResult.status.contains("second"))
  }
}

/// Pure model-list helpers behind the AI-config 「拉取最新」 button (network `fetch` is not unit-tested).
final class OwlProviderModelListTests: XCTestCase {
  func testModelsURLSwapsChatCompletionsSuffix() {
    XCTAssertEqual(
      OwlProviderModelList.modelsURL(from: URL(string: "https://api.deepseek.com/v1/chat/completions")!)?.absoluteString,
      "https://api.deepseek.com/v1/models")
    XCTAssertEqual(
      OwlProviderModelList.modelsURL(from: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!)?.absoluteString,
      "https://generativelanguage.googleapis.com/v1beta/openai/models")
  }

  func testModelsURLFallsBackToParentPath() {
    // No /chat/completions suffix → append `models` to the parent path.
    XCTAssertEqual(
      OwlProviderModelList.modelsURL(from: URL(string: "https://api.example.com/v1/responses")!)?.absoluteString,
      "https://api.example.com/v1/models")
  }

  func testParseModelIDsKeepsOrderAndDedupes() {
    let json = Data(#"{"data":[{"id":"gpt-4o"},{"id":"gpt-4o-mini"},{"id":"gpt-4o"},{"id":""}]}"#.utf8)
    XCTAssertEqual(OwlProviderModelList.parseModelIDs(json), ["gpt-4o", "gpt-4o-mini"])
    XCTAssertEqual(OwlProviderModelList.parseModelIDs(Data("not json".utf8)), [])
  }

  func testMergedPutsCuratedFirstThenNewFetched() {
    XCTAssertEqual(
      OwlProviderModelList.merged(curated: ["deepseek-chat", "deepseek-reasoner"],
                                   fetched: ["deepseek-chat", "deepseek-coder"]),
      ["deepseek-chat", "deepseek-reasoner", "deepseek-coder"])
  }
}

/// 「验证连通性」按钮背后的判定。`fetch` 注入，测试不碰网络。
///
/// 这个按钮存在的理由就是「拉取最新」证明不了的那一段：`/models` 通不代表**你选的那个型号**能用。
/// 2026-07-28 实盘撞到的正是这类 —— 同一把 Key 拉 `/models` 一切正常，而 `qwen3.7-plus` 打错端点
/// 路径直接 400 `url error`。所以失败分支必须把服务端原话带出来，只报状态码等于让人去猜。
final class OwlProviderConnectivityCheckTests: XCTestCase {

  private func response(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: URL(string: "https://api.example.com/v1/chat/completions")!,
      statusCode: status, httpVersion: nil, headerFields: nil)!
  }

  /// Qwen 连通性也必须打 Responses，不能只验证旧 chat/completions。
  func testRequestIsAMinimalPostCarryingTheModelUnderTest() throws {
    let request = try OwlProviderConnectivityCheck.request(
      endpoint: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!,
      providerID: "qwen", model: "qwen3.7-plus", apiKey: "sk-k", authStyle: .bearer)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(
      request.url?.absoluteString,
      "https://dashscope.aliyuncs.com/compatible-mode/v1/responses")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-k")

    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "qwen3.7-plus", "验的就是这个型号")
    XCTAssertNil(body["max_tokens"])
    XCTAssertNil(body["max_output_tokens"])
    XCTAssertEqual(body["stream"] as? Bool, false)
    XCTAssertEqual(
      (body["reasoning"] as? [String: Any])?["effort"] as? String, "none")
    XCTAssertNil(body["messages"])
    XCTAssertNil(body["enable_thinking"])
  }

  /// 豆包连通性同样必须打 Responses（2026-07-31 起豆包全面走 Responses）：请求体带
  /// thinking:{disabled} + store:false，绝不带 qwen 的 reasoning 字段。
  func testDoubaoRequestVerifiesTheResponsesEndpointWithThinkingOff() throws {
    let request = try OwlProviderConnectivityCheck.request(
      endpoint: URL(string: "https://ark.cn-beijing.volces.com/api/v3/responses")!,
      providerID: "doubao", model: "doubao-seed-2-1-pro-260628", apiKey: "sk-a", authStyle: .bearer)
    XCTAssertEqual(
      request.url?.absoluteString, "https://ark.cn-beijing.volces.com/api/v3/responses")
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "doubao-seed-2-1-pro-260628")
    XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "disabled")
    XCTAssertEqual(body["store"] as? Bool, false)
    XCTAssertNil(body["reasoning"], "reasoning.effort 是 qwen 的字段，方舟不认")
    XCTAssertNil(body["messages"])
    XCTAssertNil(body["max_tokens"])
  }

  func testOKRequiresAChatShapedBodyNotJustA200() {
    let chat = Data(#"{"choices":[{"message":{"role":"assistant","content":"pong"}}]}"#.utf8)
    XCTAssertEqual(
      OwlProviderConnectivityCheck.outcome(data: chat, response: response(200), latencyMS: 412),
      .ok(latencyMS: 412))

    let responses = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"pong"}]}]}"#.utf8)
    XCTAssertEqual(
      OwlProviderConnectivityCheck.outcome(
        data: responses, response: response(200), latencyMS: 99),
      .ok(latencyMS: 99))

    // 200 但不是 chat 响应：多半是网关/代理插进来的页面。报「通了」会把人引向错误的方向。
    XCTAssertEqual(
      OwlProviderConnectivityCheck.outcome(
        data: Data("<html>ok</html>".utf8), response: response(200), latencyMS: 1),
      .malformed)
  }

  /// 失败必须带上服务端原话：看到「url error」才知道是换型号，看到「Invalid API-key」才知道是换 Key。
  func testRejectionCarriesTheServerMessageInBothErrorShapes() {
    let openAIShape = Data(#"{"error":{"message":"Invalid API-key provided.","type":"x"}}"#.utf8)
    XCTAssertEqual(
      OwlProviderConnectivityCheck.outcome(
        data: openAIShape, response: response(401), latencyMS: 5),
      .rejected(status: 401, message: "Invalid API-key provided."))

    // DashScope 原生是顶层 message，不是 error.message。
    let dashScopeShape = Data(#"{"code":"InvalidParameter","message":"url error, please check url"}"#.utf8)
    XCTAssertEqual(
      OwlProviderConnectivityCheck.outcome(
        data: dashScopeShape, response: response(400), latencyMS: 5),
      .rejected(status: 400, message: "url error, please check url"))
  }

  /// 状态字要把「下一步动哪里」直接说出来，而不是只丢一个数字给用户。
  func testStatusTextPointsAtTheThingToFix() {
    XCTAssertTrue(
      OwlProviderConnectivityCheck.Outcome.rejected(status: 401, message: "bad key")
        .statusText.contains("API Key"))
    XCTAssertTrue(
      OwlProviderConnectivityCheck.Outcome.rejected(status: 400, message: "url error")
        .statusText.contains("换个型号"),
      "400/404 几乎总是型号或端点不匹配 —— 实盘撞到的就是这一类")
    XCTAssertTrue(
      OwlProviderConnectivityCheck.Outcome.rejected(status: 400, message: "url error")
        .statusText.contains("url error"), "服务端原话必须出现在状态里")
    XCTAssertTrue(OwlProviderConnectivityCheck.Outcome.ok(latencyMS: 300).statusText.contains("300"))
  }

  func testRunReportsUnreachableInsteadOfThrowing() async {
    let outcome = await OwlProviderConnectivityCheck.run(
      endpoint: URL(string: "https://api.example.com/v1/chat/completions")!,
      providerID: "custom", model: "m", apiKey: "k", authStyle: .bearer,
      fetch: { _ in throw URLError(.notConnectedToInternet) })
    guard case .unreachable = outcome else {
      return XCTFail("断网是一种结论，不能抛给调用方：\(outcome)")
    }
    XCTAssertFalse(outcome.isOK)
  }

  func testRunMeasuresLatencyFromTheInjectedClock() async {
    var ticks = [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 1.25)]
    let outcome = await OwlProviderConnectivityCheck.run(
      endpoint: URL(string: "https://api.example.com/v1/chat/completions")!,
      providerID: "custom", model: "m", apiKey: "k", authStyle: .bearer,
      fetch: { _ in (Data(#"{"choices":[]}"#.utf8), self.response(200)) },
      clock: { ticks.removeFirst() })
    XCTAssertEqual(outcome, .ok(latencyMS: 1250))
  }
}
