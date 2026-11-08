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
//  No network, no engine.
//

import Foundation
import XCTest
@testable import Owltype

/// In-memory `OwlSecretStoring` for tests — upsert semantics, no Keychain.
final class OwlInMemorySecretStore: OwlSecretStoring {
  private(set) var storage: [String: String] = [:]
  func secret(named name: String) throws -> String? { storage[name] }
  func setSecret(_ value: String, named name: String) throws { storage[name] = value }
  func deleteSecret(named name: String) throws { storage[name] = nil }
}

final class ProviderProfileStoreTests: XCTestCase {

  func testIsolatedHostCannotReadOrWritePersonalKeychain() throws {
    XCTAssertTrue(OwlTestStorage.isEnabled)
    let secrets = OwlProviderKeychain()
    XCTAssertNil(try secrets.secret(named: "isolated-test"))
    XCTAssertThrowsError(try secrets.setSecret("synthetic", named: "isolated-test"))
    XCTAssertThrowsError(try secrets.deleteSecret(named: "isolated-test"))
    XCTAssertNil(try OwlCloudKeychain.readDeepSeekAPIKey())
    XCTAssertThrowsError(try OwlCloudKeychain.saveDeepSeekAPIKey("synthetic"))
    XCTAssertThrowsError(try OwlCloudKeychain.deleteDeepSeekAPIKey())
  }

  private final class FailingSecretStore: OwlSecretStoring {
    let backing = OwlInMemorySecretStore()
    func secret(named name: String) throws -> String? { try backing.secret(named: name) }
    func setSecret(_ value: String, named name: String) throws {
      throw OwlProviderKeychainError.unexpectedStatus(-25293)
    }
    func deleteSecret(named name: String) throws { try backing.deleteSecret(named: name) }
  }

  func testEditingRetiredDefaultPreservesEndpointWhenKeyStorageFails() throws {
    let store = makeStore()
    let secrets = FailingSecretStore()
    let retired = try store.add(OwlProviderProfile(
      displayName: "retired", endpoint: URL(string: "https://retired.example.com/v1/chat/completions")!,
      model: "retired-model", providerID: "retired-provider", isDefault: true))
    let oldKey = UUID().uuidString
    try secrets.backing.setSecret(oldKey, named: retired.secretName)
    XCTAssertNil(store.defaultProfile)

    let result = Actions.updateProviderProfile(
      retired, endpoint: "https://custom.example.com/v1/chat/completions", model: "custom-model",
      apiKey: UUID().uuidString, store: store, secrets: secrets)

    XCTAssertEqual(result.status, "保存供应商失败。")
    XCTAssertTrue(try secrets.secret(named: retired.secretName) == oldKey)
    XCTAssertNil(store.defaultProfile, "Failed key storage must not activate the retired default")
    XCTAssertEqual(makeStore().profile(id: retired.id)?.endpoint, retired.endpoint,
                   "Failed key storage must preserve the endpoint on disk")
  }

  private enum SaveFailure: Error { case injected }

  private func assertNoOldKeyAtNewEndpoint(
    secrets: OwlSecretStoring, oldKey: String, newEndpoint: String,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let reloaded = makeStore()
    if let profile = reloaded.defaultProfile {
      let key = try secrets.secret(named: profile.secretName)
      XCTAssertFalse(profile.endpoint.absoluteString == newEndpoint && key == oldKey,
                     "Reloaded default must not pair the new endpoint with the old key", file: file, line: line)
    }
    let routing = OwlCloudRouting.resolve(profile: reloaded.defaultProfile)
    let routedKey = try routing.secretName.flatMap { try secrets.secret(named: $0) }
    XCTAssertFalse(routing.endpoint.absoluteString == newEndpoint && routedKey == oldKey,
                   "Actual routing must not send the old key to the new endpoint", file: file, line: line)
  }

  func testEditingCustomDefaultPreservesEndpointWhenKeyStorageFails() throws {
    let store = makeStore()
    let secrets = FailingSecretStore()
    let profile = try store.add(OwlProviderProfile(
      displayName: "custom", endpoint: URL(string: "https://old.example.com/v1/chat/completions")!,
      model: "old-model", providerID: OwlLLMProviderCatalog.customID, isDefault: true))
    let oldKey = UUID().uuidString
    try secrets.backing.setSecret(oldKey, named: profile.secretName)
    let endpoint = "https://new.example.com/v1/chat/completions"
    let result = Actions.updateProviderProfile(
      profile, endpoint: endpoint, model: "new-model", apiKey: UUID().uuidString,
      store: store, secrets: secrets)
    XCTAssertEqual(result.status, "保存供应商失败。")
    XCTAssertEqual(makeStore().defaultProfile?.endpoint, profile.endpoint)
    try assertNoOldKeyAtNewEndpoint(secrets: secrets, oldKey: oldKey, newEndpoint: endpoint)
  }

  func testEditingDefaultCannotRouteOldKeyWhenConfigurationThrowsAfterWriting() throws {
    for providerID in ["retired-provider", OwlLLMProviderCatalog.customID] {
      let store = makeStore()
      let secrets = OwlInMemorySecretStore()
      let profile = try store.add(OwlProviderProfile(
        displayName: providerID, endpoint: URL(string: "https://old.example.com/v1/chat/completions")!,
        model: "old-model", providerID: providerID, isDefault: true))
      let oldKey = UUID().uuidString
      try secrets.setSecret(oldKey, named: profile.secretName)
      let newKey = UUID().uuidString
      store.afterAtomicWrite = { throw SaveFailure.injected }
      let endpoint = "https://new.example.com/v1/chat/completions"
      let result = Actions.updateProviderProfile(
        profile, endpoint: endpoint, model: "new-model", apiKey: newKey,
        store: store, secrets: secrets)
      XCTAssertEqual(result.status, "保存供应商失败。")
      let saved = try XCTUnwrap(makeStore().defaultProfile)
      XCTAssertTrue(try secrets.secret(named: saved.secretName) == newKey)
      XCTAssertTrue(try secrets.secret(named: profile.secretName) == oldKey)
      XCTAssertEqual(makeStore().profile(id: profile.id)?.endpoint.absoluteString, endpoint,
                     "The injected failure must occur after the actual atomic write")
      try assertNoOldKeyAtNewEndpoint(secrets: secrets, oldKey: oldKey, newEndpoint: endpoint)
    }
  }

  func testEditingDefaultCannotRouteOldKeyWhenKeyStorageAndRollbackFail() throws {
    for providerID in ["retired-provider", OwlLLMProviderCatalog.customID] {
      let store = makeStore()
      let secrets = FailingSecretStore()
      let profile = try store.add(OwlProviderProfile(
        displayName: providerID, endpoint: URL(string: "https://old.example.com/v1/chat/completions")!,
        model: "old-model", providerID: providerID, isDefault: true))
      let oldKey = UUID().uuidString
      try secrets.backing.setSecret(oldKey, named: profile.secretName)
      var writes = 0
      store.beforeSave = {
        writes += 1
        if writes > 1 { throw SaveFailure.injected }
      }
      let endpoint = "https://new.example.com/v1/chat/completions"
      let result = Actions.updateProviderProfile(
        profile, endpoint: endpoint, model: "new-model", apiKey: UUID().uuidString,
        store: store, secrets: secrets)
      XCTAssertEqual(result.status, "保存供应商失败。")
      XCTAssertEqual(writes, 0, "Key failure must now precede any configuration write or rollback")
      try assertNoOldKeyAtNewEndpoint(secrets: secrets, oldKey: oldKey, newEndpoint: endpoint)
    }
  }

  func testEditingDefaultPreservesOldPairWhenConfigurationFailsBeforeWriting() throws {
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let profile = try store.add(OwlProviderProfile(
      displayName: "custom", endpoint: URL(string: "https://old.example.com/v1/chat/completions")!,
      model: "old-model", providerID: OwlLLMProviderCatalog.customID, isDefault: true))
    let oldKey = UUID().uuidString
    try secrets.setSecret(oldKey, named: profile.secretName)
    let before = try Data(contentsOf: store.fileURL)
    store.beforeSave = { throw SaveFailure.injected }
    let endpoint = "https://new.example.com/v1/chat/completions"
    let result = Actions.updateProviderProfile(
      profile, endpoint: endpoint, model: "new-model", apiKey: UUID().uuidString,
      store: store, secrets: secrets)
    XCTAssertEqual(result.status, "保存供应商失败。")
    XCTAssertEqual(try Data(contentsOf: makeStore().fileURL), before)
    XCTAssertTrue(try secrets.secret(named: profile.secretName) == oldKey)
    XCTAssertEqual(Set(secrets.storage.keys), Set([profile.secretName]), "Uncommitted staged key must be removed")
    try assertNoOldKeyAtNewEndpoint(secrets: secrets, oldKey: oldKey, newEndpoint: endpoint)
  }

  func testEditingDefaultRoutesNewKeyEvenWhenOldKeyCleanupFails() throws {
    final class CleanupFailingSecrets: OwlSecretStoring {
      let backing = OwlInMemorySecretStore()
      func secret(named name: String) throws -> String? { try backing.secret(named: name) }
      func setSecret(_ value: String, named name: String) throws { try backing.setSecret(value, named: name) }
      func deleteSecret(named name: String) throws { throw SaveFailure.injected }
    }
    let store = makeStore()
    let secrets = CleanupFailingSecrets()
    let profile = try store.add(OwlProviderProfile(
      displayName: "custom", endpoint: URL(string: "https://old.example.com/v1/chat/completions")!,
      model: "old-model", providerID: OwlLLMProviderCatalog.customID, isDefault: true))
    let oldKey = UUID().uuidString
    let newKey = UUID().uuidString
    try secrets.setSecret(oldKey, named: profile.secretName)
    let endpoint = "https://new.example.com/v1/chat/completions"
    let result = Actions.updateProviderProfile(
      profile, endpoint: endpoint, model: "new-model", apiKey: newKey,
      store: store, secrets: secrets)
    XCTAssertTrue(result.status.hasPrefix("已保存"))
    let saved = try XCTUnwrap(makeStore().defaultProfile)
    XCTAssertEqual(saved.endpoint.absoluteString, endpoint)
    XCTAssertTrue(try secrets.secret(named: saved.secretName) == newKey)
    XCTAssertTrue(try secrets.secret(named: profile.secretName) == oldKey)
    try assertNoOldKeyAtNewEndpoint(secrets: secrets, oldKey: oldKey, newEndpoint: endpoint)
  }

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
    XCTAssertEqual(
      OwlSearchControl.transport(providerID: "deepseek", host: "api.deepseek.com"),
      .deepSeekSearchAPI, "预置的 flash 档案经搜索接口联网")
    let gemini = try XCTUnwrap(OwlLLMProviderCatalog.preset(id: "gemini"))
    XCTAssertEqual(gemini.model, "gemini-3.8-flash")
    let geminiBody = OwlProviderConnectivityCheck.body(providerID: "gemini", model: gemini.model)
    XCTAssertNotNil(geminiBody["messages"])
    XCTAssertEqual(geminiBody["max_tokens"] as? Int, 1024)
    XCTAssertNil(geminiBody["thinking"])
  }

  func testMiniMaxFlashUsesLowThinkingAndAdequateProbeBudget() throws {
    XCTAssertEqual(
      OwlLLMProviderCatalog.presets.map(\.id),
      ["qwen", "doubao", "openai", "gemini", "deepseek"],
      "UI 预设目录收敛为 5 家核心供应商（已移除 Grok）"
    )
    XCTAssertNil(OwlLLMProviderCatalog.preset(id: "grok"))
    let geminiPreset = try XCTUnwrap(OwlLLMProviderCatalog.preset(id: "gemini"))
    let geminiProfile = OwlProviderProfile(
      displayName: geminiPreset.displayName, endpoint: URL(string: geminiPreset.endpoint)!,
      model: geminiPreset.model, providerID: "gemini")
    XCTAssertEqual(OwlLLMProviderCatalog.capabilitySummary(for: geminiProfile), "LLM · 语音识别")
    let deepSeekProfile = OwlProviderProfile(
      displayName: "DeepSeek", endpoint: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
      model: "deepseek-flash", providerID: "deepseek")
    XCTAssertEqual(OwlLLMProviderCatalog.capabilitySummary(for: deepSeekProfile), "LLM · 联网搜索 · 语音润色")

    let defaultMiniMaxModel = try XCTUnwrap(OwlLLMProviderCatalog.minimaxModels.first)
    XCTAssertEqual(defaultMiniMaxModel, "MiniMax-M3.1-Flash")
    let body = OwlProviderConnectivityCheck.body(providerID: "minimax", model: defaultMiniMaxModel)
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
      systemPrompt: "Return JSON", draft: "安排会议", model: defaultMiniMaxModel,
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

  func testReadableProfilesMissingFileReturnsEmpty() {
    XCTAssertEqual(makeStore().readableProfiles(), [])
  }

  func testReadableProfilesMalformedFileReturnsNil() throws {
    let store = makeStore()
    try Data("invalid JSON".utf8).write(to: store.fileURL)
    XCTAssertNil(store.readableProfiles())
    XCTAssertEqual(store.profiles(), [])
  }

  func testReadableProfilesReadFailureReturnsNil() throws {
    let store = makeStore()
    try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
    XCTAssertNil(store.readableProfiles())
  }

  func testReadableProfilesReturnsSortedProfiles() throws {
    let store = makeStore()
    for (id, timestamp) in [("b", 2.0), ("c", 1.0), ("a", 2.0)] {
      let profile = OwlProviderProfile(
        id: id, displayName: id, endpoint: URL(string: "https://example.com/v1")!,
        model: "test-model", createdAt: Date(timeIntervalSince1970: timestamp))
      try store.add(profile)
    }
    let profiles = try XCTUnwrap(store.readableProfiles())
    XCTAssertEqual(profiles.map(\.id), ["c", "a", "b"])
    XCTAssertEqual(profiles, store.profiles())
  }

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

    // 能力降级：不联网。
    XCTAssertEqual(
      OwlProviderCapabilities.searchChannel(providerID: "retired-provider", host: "retired.example.com"), .none)
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
    let result = Actions.addProviderProfile(
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

  func testRetiredZhipuPresetStaysOutOfTheCatalog() {
    XCTAssertNil(OwlLLMProviderCatalog.preset(id: "zhipu"), "智谱已下架，不得再出现在预设目录里")
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
    let secrets = OwlInMemorySecretStore()
    for endpoint in [
      "HTTPS://WS-test123abc.cn-beijing.maas.aliyuncs.com:443/compatible-mode/v1/other-path",
      "https://ws-test123abc.cn-beijing.maas.aliyuncs.com/another-path",
    ] {
      let profile = try store.add(OwlProviderProfile(
        displayName: "阿里云百炼", endpoint: URL(string: endpoint)!,
        model: "qwen3.7-plus", providerID: "qwen"))
      try secrets.setSecret(UUID().uuidString, named: profile.secretName)
    }
    let profilesBefore = store.profiles()
    let secretsBefore = secrets.storage
    let suiteName = "OwlQwenWorkspaceActionTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let result = Actions.saveQwenWorkspace(
      "ws-test123abc", apiKey: "", store: store, secrets: secrets, defaults: defaults)

    XCTAssertTrue(result.saved)
    let endpoint = URL(string:
      "https://ws-test123abc.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/responses")!
    let expected = profilesBefore.map { profile in
      var updated = profile
      updated.endpoint = endpoint
      return updated
    }
    XCTAssertEqual(result.profiles, expected)
    XCTAssertEqual(makeStore().profiles(), expected)
    XCTAssertTrue(secrets.storage == secretsBefore)
    XCTAssertEqual(
      OwlQwenWorkspaceSettings.apiHost(defaults: defaults),
      "ws-test123abc.cn-beijing.maas.aliyuncs.com")
  }

  func testSavingQwenWorkspaceMalformedFileWithEmptyKeyPreservesState() throws {
    try assertMalformedWorkspaceSavePreservesState(apiKey: "")
  }

  func testSavingQwenWorkspaceMalformedFileWithReplacementKeyPreservesState() throws {
    try assertMalformedWorkspaceSavePreservesState(apiKey: "new-key")
  }

  func testSavingQwenWorkspaceMalformedFileStillValidatesInputFirst() throws {
    try assertMalformedWorkspaceSavePreservesState(
      apiKey: "new-key", input: "foreign.example.com",
      expectedStatus: "Workspace ID / API Host 格式无效，未覆盖原配置。")
  }

  private func assertMalformedWorkspaceSavePreservesState(
    apiKey: String, input: String = "ws-test123abc",
    expectedStatus: String = "保存 Workspace API Host 失败。"
  ) throws {
    OwlProviderKeyVerification.resetForTesting()
    defer { OwlProviderKeyVerification.resetForTesting() }
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let profile = try store.add(OwlProviderProfile(
      displayName: "Qwen", endpoint: URL(string: OwlLLMProviderCatalog.qwenResponsesEndpoint)!,
      model: "qwen3.7-plus", providerID: "qwen"))
    try secrets.setSecret("old-key", named: profile.secretName)
    Actions.markProviderProfileKeyVerified(profile)
    let verified = OwlProviderKeyVerification.verifiedAt(secretName: profile.secretName)
    let keys = secrets.storage
    let bytes = Data("{ invalid JSON".utf8)
    try bytes.write(to: store.fileURL)
    let suite = "WorkspaceMalformed-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertTrue(OwlQwenWorkspaceSettings.save("ws-original", defaults: defaults))
    let settings = defaults.dictionaryRepresentation()
    var writes = 0
    store.beforeSave = { writes += 1 }

    let result = Actions.saveQwenWorkspace(
      input, apiKey: apiKey, store: store, secrets: secrets, defaults: defaults)

    XCTAssertFalse(result.saved)
    XCTAssertEqual(result.status, expectedStatus)
    XCTAssertEqual(result.profiles, [])
    XCTAssertEqual(writes, 0)
    XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
    XCTAssertEqual(secrets.storage, keys)
    XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, settings as NSDictionary)
    XCTAssertEqual(OwlProviderKeyVerification.verifiedAt(secretName: profile.secretName), verified)
  }

  func testSavingQwenWorkspaceMissingFileOnlyUpdatesSettings() throws {
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let suite = "WorkspaceMissing-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let result = Actions.saveQwenWorkspace(
      "ws-test123abc", apiKey: "new-key", store: store, secrets: secrets, defaults: defaults)
    XCTAssertTrue(result.saved)
    XCTAssertEqual(result.profiles, [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    XCTAssertTrue(secrets.storage.isEmpty)
    XCTAssertEqual(OwlQwenWorkspaceSettings.apiHost(defaults: defaults),
                   "ws-test123abc.cn-beijing.maas.aliyuncs.com")
  }

  func testEditingProfileAfterWorkspaceSaveVerifiesReplacementKey() throws {
    OwlProviderKeyVerification.resetForTesting()
    defer { OwlProviderKeyVerification.resetForTesting() }
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    for index in 0..<2 {
      let profile = try store.add(OwlProviderProfile(
        displayName: "Qwen \(index)",
        endpoint: URL(string: OwlLLMProviderCatalog.qwenResponsesEndpoint)!,
        model: "qwen3.7-plus", providerID: "qwen"))
      try secrets.setSecret("old-key", named: profile.secretName)
      Actions.markProviderProfileKeyVerified(profile)
    }
    let editing = try XCTUnwrap(store.profiles().last)
    let suite = "WorkspaceEditing-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let result = Actions.saveQwenWorkspace(
      "ws-test123abc", apiKey: "new-key", store: store, secrets: secrets, defaults: defaults)
    XCTAssertTrue(result.saved)
    let refreshed = try XCTUnwrap(OwlSettingsActions.editingProfileAfterWorkspaceSave(
      editing, profiles: result.profiles))
    XCTAssertEqual(refreshed, store.profile(id: editing.id))
    XCTAssertNotEqual(refreshed.secretName, editing.secretName)
    XCTAssertEqual(try secrets.secret(named: refreshed.secretName), "new-key")
    XCTAssertNil(OwlProviderKeyVerification.verifiedAt(secretName: refreshed.secretName))

    Actions.markProviderProfileKeyVerified(refreshed)

    XCTAssertNotNil(OwlProviderKeyVerification.verifiedAt(secretName: refreshed.secretName))
    XCTAssertNil(OwlProviderKeyVerification.verifiedAt(secretName: editing.secretName))
  }

  func testEditingProfileAfterWorkspaceSaveWithoutEditingReturnsNil() {
    XCTAssertNil(OwlSettingsActions.editingProfileAfterWorkspaceSave(
      nil, profiles: [makeProfile(name: "Other")]))
  }

  func testEditingProfileAfterWorkspaceSaveWithoutMatchPreservesEditing() {
    let editing = makeProfile(name: "Editing")
    XCTAssertEqual(OwlSettingsActions.editingProfileAfterWorkspaceSave(
      editing, profiles: []), editing)
    XCTAssertEqual(OwlSettingsActions.editingProfileAfterWorkspaceSave(
      editing, profiles: [makeProfile(name: "Other")]), editing)
  }

  func testWorkspacePreparedSaveValidatesWithoutWriting() throws {
    let suite = "WorkspacePrepared-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertTrue(OwlQwenWorkspaceSettings.save("ws-original", defaults: defaults))
    let before = defaults.dictionaryRepresentation()
    XCTAssertNil(OwlQwenWorkspaceSettings.prepareSave("foreign.example.com", defaults: defaults))
    let commit = try XCTUnwrap(OwlQwenWorkspaceSettings.prepareSave(
      "  WS-test123abc  ", defaults: defaults))
    XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before as NSDictionary)
    commit()
    XCTAssertEqual(OwlQwenWorkspaceSettings.apiHost(defaults: defaults),
                   "ws-test123abc.cn-beijing.maas.aliyuncs.com")
    let clear = try XCTUnwrap(OwlQwenWorkspaceSettings.prepareSave(" \n", defaults: defaults))
    XCTAssertFalse(OwlQwenWorkspaceSettings.apiHost(defaults: defaults).isEmpty)
    clear()
    XCTAssertEqual(OwlQwenWorkspaceSettings.apiHost(defaults: defaults), "")
  }

  func testSavingQwenWorkspaceWhitespaceKeyRejectsEntireBatchWithoutMutation() throws {
    try assertQwenWorkspaceOriginChangeRejected(
      input: "ws-test123abc", currentEndpoint: OwlLLMProviderCatalog.qwenResponsesEndpoint,
      apiKey: "  \n")
  }

  func testSavingQwenWorkspaceKeyRotatesOnlyChangedOriginsInOneSave() throws {
    try assertWorkspaceKeyTransaction(failure: nil)
  }

  func testSavingQwenWorkspaceKeyWriteFailureCleansStagedKeys() throws {
    try assertWorkspaceKeyTransaction(failure: "key")
  }

  func testSavingQwenWorkspaceProfileCommitFailureCleansStagedKeys() throws {
    try assertWorkspaceKeyTransaction(failure: "config")
  }

  func testSavingQwenWorkspacePostWriteFailureFinishesCommit() throws {
    try assertWorkspaceKeyTransaction(failure: "afterWrite")
  }

  func testSavingQwenWorkspaceUnreadableCommitRetainsKeys() throws {
    try assertWorkspaceKeyTransaction(failure: "unreadable")
  }

  func testSavingQwenWorkspacePreservesSharedOldKey() throws {
    try assertWorkspaceKeyTransaction(failure: nil, sharedOldKey: true)
  }

  func testSavingQwenWorkspacePostWriteFailurePreservesSharedOldKey() throws {
    try assertWorkspaceKeyTransaction(failure: "afterWrite", sharedOldKey: true)
  }

  func testSavingQwenWorkspaceSuccessfulUpdateUsesReturnedProfiles() throws {
    try assertWorkspaceKeyTransaction(failure: "unreadableAfterSuccess", sharedOldKey: true)
  }

  private func assertWorkspaceKeyTransaction(failure: String?, sharedOldKey: Bool = false) throws {
    enum Injected: Error { case failure }
    final class Secrets: OwlSecretStoring {
      let backing = OwlInMemorySecretStore()
      var writes = 0
      var fail = false
      func secret(named name: String) throws -> String? { try backing.secret(named: name) }
      func setSecret(_ value: String, named name: String) throws {
        writes += 1
        try backing.setSecret(value, named: name)
        // Fail after the second write to exercise cleanup of every staged key.
        if fail && writes == 2 { throw Injected.failure }
      }
      func deleteSecret(named name: String) throws { try backing.deleteSecret(named: name) }
    }
    OwlProviderKeyVerification.resetForTesting()
    defer { OwlProviderKeyVerification.resetForTesting() }
    let store = makeStore()
    let secrets = Secrets()
    let target = try XCTUnwrap(OwlQwenWorkspace.responsesEndpoint(for: "ws-test123abc"))
    for index in 0..<3 {
      _ = try store.add(OwlProviderProfile(
        displayName: "Qwen \(index)",
        endpoint: index == 2 ? target.appendingPathComponent("old")
          : URL(string: OwlLLMProviderCatalog.qwenResponsesEndpoint)!,
        model: "qwen3.7-plus", providerID: "qwen",
        secretName: sharedOldKey && index != 1 ? "shared-old-key" : nil,
        isDefault: index == 0))
    }
    _ = try store.add(makeProfile(name: "DeepSeek"))
    let before = store.profiles()
    let bytes = try Data(contentsOf: store.fileURL)
    for profile in before {
      try secrets.backing.setSecret("old-" + profile.id, named: profile.secretName)
      OwlProviderKeyVerification.markVerified(secretName: profile.secretName)
    }
    let keys = secrets.backing.storage
    let verified = before.map { OwlProviderKeyVerification.verifiedAt(secretName: $0.secretName) }
    let suite = "WorkspaceTransaction-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertTrue(OwlQwenWorkspaceSettings.save("ws-original", defaults: defaults))
    let hostBefore = OwlQwenWorkspaceSettings.apiHost(defaults: defaults)
    var saves = 0
    store.beforeSave = {
      saves += 1
      if failure == "config" { throw Injected.failure }
    }
    store.afterAtomicWrite = {
      if failure == "unreadable" || failure == "unreadableAfterSuccess" {
        try Data("invalid JSON".utf8).write(to: store.fileURL)
      }
      if failure == "afterWrite" || failure == "unreadable" { throw Injected.failure }
    }
    secrets.fail = failure == "key"
    let result = Actions.saveQwenWorkspace(
      "ws-test123abc", apiKey: "  new-key \n", store: store, secrets: secrets, defaults: defaults)
    let succeeds = failure == nil || failure == "afterWrite" || failure == "unreadableAfterSuccess"
    XCTAssertEqual(result.saved, succeeds)
    XCTAssertEqual(saves, failure == "key" ? 0 : 1)
    if failure == "unreadable" {
      XCTAssertNil(makeStore().readableProfiles())
      XCTAssertEqual(secrets.backing.storage.count, keys.count + 2)
      XCTAssertEqual(secrets.backing.storage.filter { keys[$0.key] == nil }.values.sorted(),
                     ["new-key", "new-key"])
      for (name, value) in keys { XCTAssertEqual(try secrets.secret(named: name), value) }
      XCTAssertEqual(before.map { OwlProviderKeyVerification.verifiedAt(secretName: $0.secretName) }, verified)
      XCTAssertEqual(OwlQwenWorkspaceSettings.apiHost(defaults: defaults), hostBefore)
      return
    }
    if !succeeds {
      XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
      XCTAssertEqual(result.profiles, before)
      XCTAssertEqual(secrets.backing.storage, keys)
      XCTAssertEqual(before.map { OwlProviderKeyVerification.verifiedAt(secretName: $0.secretName) }, verified)
      XCTAssertEqual(OwlQwenWorkspaceSettings.apiHost(defaults: defaults), hostBefore)
      return
    }
    XCTAssertEqual(result.status, "已保存 Workspace API Host，所有 Qwen 供应商将共用。")
    if failure != "unreadableAfterSuccess" {
      XCTAssertEqual(makeStore().profiles(), result.profiles)
    }
    XCTAssertEqual(result.profiles.first(where: { $0.isDefault })?.id,
                   before.first(where: { $0.isDefault })?.id)
    var newNames = Set<String>()
    for (index, old) in before.enumerated() {
      let saved = try XCTUnwrap(result.profiles.first(where: { $0.id == old.id }))
      if old.displayName == "Qwen 0" || old.displayName == "Qwen 1" {
        var expected = old
        expected.endpoint = target
        expected.secretName = saved.secretName
        XCTAssertEqual(saved, expected)
        XCTAssertNotEqual(saved.secretName, old.secretName)
        newNames.insert(saved.secretName)
        XCTAssertEqual(try secrets.secret(named: saved.secretName), "new-key")
        if sharedOldKey && old.displayName == "Qwen 0" {
          XCTAssertEqual(try secrets.secret(named: old.secretName), keys[old.secretName])
          XCTAssertEqual(OwlProviderKeyVerification.verifiedAt(secretName: old.secretName), verified[index])
        } else {
          XCTAssertNil(try secrets.secret(named: old.secretName))
          XCTAssertNil(OwlProviderKeyVerification.verifiedAt(secretName: old.secretName))
        }
        XCTAssertNil(OwlProviderKeyVerification.verifiedAt(secretName: saved.secretName))
      } else {
        var expected = old
        if old.providerID == "qwen" { expected.endpoint = target }
        XCTAssertEqual(saved, expected)
        XCTAssertEqual(try secrets.secret(named: old.secretName), keys[old.secretName])
        XCTAssertEqual(OwlProviderKeyVerification.verifiedAt(secretName: old.secretName), verified[index])
      }
    }
    XCTAssertEqual(newNames.count, 2)
    XCTAssertEqual(OwlQwenWorkspaceSettings.apiHost(defaults: defaults), target.host)
  }

  func testSavingQwenWorkspaceSameOriginIgnoresReplacementKey() throws {
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let target = try XCTUnwrap(OwlQwenWorkspace.responsesEndpoint(for: "ws-test123abc"))
    for index in 0..<2 {
      let profile = try store.add(OwlProviderProfile(
        displayName: "Qwen \(index)", endpoint: target.appendingPathComponent("old"),
        model: "qwen3.7-plus", providerID: "qwen"))
      try secrets.setSecret("old-" + profile.id, named: profile.secretName)
    }
    let before = store.profiles()
    let keys = secrets.storage
    let suite = "WorkspaceSameOrigin-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let result = Actions.saveQwenWorkspace(
      "ws-test123abc", apiKey: "new-key", store: store, secrets: secrets, defaults: defaults)
    XCTAssertTrue(result.saved)
    XCTAssertEqual(result.profiles, before.map { old in
      var updated = old
      updated.endpoint = target
      return updated
    })
    XCTAssertEqual(secrets.storage, keys)
  }

  func testBatchUpdatePreservesDefaultAndSavesOnce() throws {
    let store = makeStore()
    let first = try store.add(makeProfile(name: "First", isDefault: true))
    let second = try store.add(makeProfile(name: "Second"))
    var updates = [first, second]
    updates[0].model = "new-first"
    updates[0].isDefault = false
    updates[1].model = "new-second"
    updates[1].isDefault = true
    var saves = 0
    store.beforeSave = { saves += 1 }
    try store.update(updates)
    XCTAssertEqual(saves, 1)
    XCTAssertEqual(makeStore().defaultProfile?.id, first.id)
    XCTAssertEqual(makeStore().profile(id: first.id)?.model, "new-first")
    XCTAssertEqual(makeStore().profile(id: second.id)?.model, "new-second")
  }

  func testBatchUpdateUnknownIDDoesNotWrite() throws {
    let store = makeStore()
    var existing = try store.add(makeProfile(name: "Existing", isDefault: true))
    let before = try Data(contentsOf: store.fileURL)
    existing.model = "changed"
    let unknown = makeProfile(name: "Unknown")
    var saves = 0
    store.beforeSave = { saves += 1 }
    XCTAssertThrowsError(try store.update([existing, unknown])) { error in
      XCTAssertEqual(error as? OwlProviderError, .notFound(unknown.id))
    }
    XCTAssertEqual(saves, 0)
    XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
  }

  func testSavingQwenWorkspaceHostChangeRejectsEntireBatchWithoutMutation() throws {
    try assertQwenWorkspaceOriginChangeRejected(
      input: "ws-test123abc", currentEndpoint: OwlLLMProviderCatalog.qwenResponsesEndpoint)
  }

  func testClearingQwenWorkspaceRejectsEntireBatchWithoutMutation() throws {
    try assertQwenWorkspaceOriginChangeRejected(
      input: "",
      currentEndpoint: "https://ws-test123abc.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/responses")
  }

  func testSavingQwenWorkspaceSchemeChangeRejectsEntireBatchWithoutMutation() throws {
    try assertQwenWorkspaceOriginChangeRejected(
      input: "ws-test123abc",
      currentEndpoint: "http://ws-test123abc.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/responses")
  }

  func testSavingQwenWorkspacePortChangeRejectsEntireBatchWithoutMutation() throws {
    try assertQwenWorkspaceOriginChangeRejected(
      input: "ws-test123abc",
      currentEndpoint: "https://ws-test123abc.cn-beijing.maas.aliyuncs.com:8443/compatible-mode/v1/responses")
  }

  private func assertQwenWorkspaceOriginChangeRejected(
    input: String, currentEndpoint: String, apiKey: String = ""
  ) throws {
    OwlProviderKeyVerification.resetForTesting()
    defer { OwlProviderKeyVerification.resetForTesting() }
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let target = input.isEmpty
      ? URL(string: OwlLLMProviderCatalog.qwenResponsesEndpoint)!
      : try XCTUnwrap(OwlQwenWorkspace.responsesEndpoint(for: input))
    // Stable ordering puts a same-origin edit before the rejecting profile.
    var sameOrigin = OwlProviderProfile(
      displayName: "Qwen same origin", endpoint: target.appendingPathComponent("other-path"),
      model: "qwen3.7-plus", isDefault: true)
    sameOrigin.createdAt = Date(timeIntervalSince1970: 1)
    _ = try store.add(sameOrigin)
    var differentOrigin = OwlProviderProfile(
      displayName: "Qwen different origin", endpoint: URL(string: currentEndpoint)!,
      model: "qwen3.7-plus", providerID: "qwen")
    differentOrigin.createdAt = Date(timeIntervalSince1970: 2)
    _ = try store.add(differentOrigin)
    _ = try store.add(makeProfile(name: "DeepSeek"))
    let profilesBefore = store.profiles()
    for profile in profilesBefore {
      try secrets.setSecret(UUID().uuidString, named: profile.secretName)
      OwlProviderKeyVerification.markVerified(secretName: profile.secretName)
    }
    let verificationBefore = profilesBefore.map {
      OwlProviderKeyVerification.verifiedAt(secretName: $0.secretName)
    }
    let suiteName = "OwlQwenWorkspaceRejectionTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    XCTAssertTrue(OwlQwenWorkspaceSettings.save("ws-existing123", defaults: defaults))
    let hostBefore = OwlQwenWorkspaceSettings.apiHost(defaults: defaults)
    let before = try Data(contentsOf: store.fileURL)
    let defaultBefore = store.defaultProfile
    let secretsBefore = secrets.storage
    var writes = 0
    store.beforeSave = { writes += 1 }

    let result = Actions.saveQwenWorkspace(
      input, apiKey: apiKey, store: store, secrets: secrets, defaults: defaults)

    XCTAssertEqual(result.status, "更换地址后请重新填写 API Key。")
    XCTAssertFalse(result.saved)
    XCTAssertEqual(writes, 0)
    XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    XCTAssertEqual(result.profiles, profilesBefore)
    XCTAssertEqual(makeStore().profiles(), profilesBefore)
    XCTAssertEqual(makeStore().defaultProfile, defaultBefore)
    XCTAssertTrue(secrets.storage == secretsBefore)
    XCTAssertEqual(profilesBefore.map {
      OwlProviderKeyVerification.verifiedAt(secretName: $0.secretName)
    }, verificationBefore)
    XCTAssertEqual(OwlQwenWorkspaceSettings.apiHost(defaults: defaults), hostBefore)
  }

  func testSavingQwenWorkspaceWithoutQwenProfilesOnlyUpdatesSettings() throws {
    let secrets = OwlInMemorySecretStore()
    let store = makeStore()
    _ = try store.add(makeProfile(name: "DeepSeek", isDefault: true))
    let profilesBefore = store.profiles()
    let defaultBefore = store.defaultProfile
    let before = try Data(contentsOf: store.fileURL)
    let suiteName = "OwlQwenWorkspaceWithoutProfilesTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var writes = 0
    store.beforeSave = { writes += 1 }

    let result = Actions.saveQwenWorkspace(
      "ws-test123abc", apiKey: "", store: store, secrets: secrets, defaults: defaults)

    XCTAssertTrue(result.saved)
    XCTAssertEqual(writes, 0)
    XCTAssertEqual(result.profiles, profilesBefore)
    XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    XCTAssertEqual(makeStore().profiles(), profilesBefore)
    XCTAssertEqual(makeStore().defaultProfile, defaultBefore)
    XCTAssertEqual(OwlQwenWorkspaceSettings.apiHost(defaults: defaults),
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
    let added = Actions.addProviderProfile(
      displayName: "豆包", endpoint: "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
      model: "doubao-seed-2-1-turbo-260628", apiKey: "sk-ark", makeDefault: true,
      store: store, secrets: secrets, providerID: "doubao")
    let profile = try XCTUnwrap(added.profiles.first)
    XCTAssertEqual(
      Actions.providerProfileKeyStatus(profile, secrets: secrets), "已设置·未验证")

    Actions.markProviderProfileKeyVerified(profile)
    XCTAssertEqual(
      Actions.providerProfileKeyStatus(profile, secrets: secrets), "已验证")

    // 换钥匙 → 上一次验证不再代表当前这把 Key。
    let rotated = try XCTUnwrap(Actions.updateProviderProfile(
      profile, endpoint: profile.endpoint.absoluteString, model: profile.model,
      apiKey: "sk-rotated", store: store, secrets: secrets).profiles.first)
    XCTAssertEqual(
      Actions.providerProfileKeyStatus(rotated, secrets: secrets), "已设置·未验证")

    Actions.markProviderProfileKeyVerified(rotated)
    _ = Actions.deleteProviderProfile(rotated, store: store, secrets: secrets)
    XCTAssertEqual(
      Actions.providerProfileKeyStatus(rotated, secrets: secrets), "未设置")
    XCTAssertNil(
      OwlProviderKeyVerification.verifiedAt(secretName: rotated.secretName),
      "删钥匙也要把标记一起清掉，否则重新填一把新 Key 会直接显示已验证")
  }

  /// 原地编辑时 Key 留空＝保持不变，那么上一次的验证状态也该保持；只有真的换了钥匙才作废。
  func testUpdateKeepsVerificationWhenKeyIsUnchangedAndDropsItWhenRotated() throws {
    OwlProviderKeyVerification.resetForTesting()
    defer { OwlProviderKeyVerification.resetForTesting() }
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let profile = try XCTUnwrap(Actions.addProviderProfile(
      displayName: "豆包", endpoint: "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
      model: "doubao-seed-2-1-turbo-260628", apiKey: "sk-ark", makeDefault: true,
      store: store, secrets: secrets, providerID: "doubao").profiles.first)
    Actions.markProviderProfileKeyVerified(profile)

    _ = Actions.updateProviderProfile(
      profile, endpoint: profile.endpoint.absoluteString, model: "doubao-seed-2-2",
      apiKey: "", store: store, secrets: secrets)
    XCTAssertEqual(
      Actions.providerProfileKeyStatus(profile, secrets: secrets), "已验证",
      "只换了模型，Key 没动 → 验证状态保持")

    let rotated = Actions.updateProviderProfile(
      profile, endpoint: profile.endpoint.absoluteString, model: "doubao-seed-2-2",
      apiKey: "sk-new", store: store, secrets: secrets)
    let saved = try XCTUnwrap(rotated.profiles.first)
    XCTAssertEqual(
      Actions.providerProfileKeyStatus(saved, secrets: secrets), "已设置·未验证",
      "换了钥匙 → 作废")
  }

  /// 换模型的核心不变式：不重填 Key 也能改。`secretName` 是从 profile 的 UUID 推出来的，所以
  /// 「删掉再加一条」会换一个 Keychain 账号并把旧 Key 一起删掉 —— 原地更新才保得住。
  func testUpdateProviderProfileChangesModelAndKeepsStoredKey() throws {
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let added = Actions.addProviderProfile(
      displayName: "豆包", endpoint: "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
      model: "doubao-seed-2-1-turbo-260628", apiKey: "sk-ark", makeDefault: true,
      store: store, secrets: secrets, providerID: "doubao")
    let original = try XCTUnwrap(added.profiles.first)

    let result = Actions.updateProviderProfile(
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
    let added = Actions.addProviderProfile(
      displayName: "豆包", endpoint: "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
      model: "doubao-seed-2-1-turbo-260628", apiKey: "sk-old", makeDefault: true,
      store: store, secrets: secrets, providerID: "doubao")
    let original = try XCTUnwrap(added.profiles.first)

    let rotated = Actions.updateProviderProfile(
      original, endpoint: original.endpoint.absoluteString, model: original.model,
      apiKey: " sk-new ", store: store, secrets: secrets)
    XCTAssertTrue(rotated.status.hasPrefix("已保存"))
    let saved = try XCTUnwrap(makeStore().defaultProfile)
    XCTAssertNotEqual(saved.secretName, original.secretName)
    XCTAssertTrue(try secrets.secret(named: saved.secretName) == "sk-new", "typed key wins, trimmed")
    XCTAssertNil(try secrets.secret(named: original.secretName), "confirmed commit retires the old key")

    let insecure = Actions.updateProviderProfile(
      original, endpoint: "http://ark.cn-beijing.volces.com/api/v3/chat/completions",
      model: original.model, apiKey: "", store: store, secrets: secrets)
    XCTAssertEqual(insecure.status, "更换地址后请重新填写 API Key。")
    XCTAssertEqual(store.profiles().first?.endpoint.scheme, "https", "被拒的端点不能落盘")
  }

  func testAddProviderProfileActionAllowsEmptyKeyForLaterEntry() throws {
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let result = Actions.addProviderProfile(
      displayName: "personal OpenAI", endpoint: "https://api.openai.com/v1/chat/completions",
      model: "gpt-4o", apiKey: "  ", makeDefault: true, store: store, secrets: secrets)
    let profile = try XCTUnwrap(result.profiles.first)
    XCTAssertNil(try secrets.secret(named: profile.secretName), "no key supplied → none stored")
    XCTAssertTrue(result.status.hasPrefix("已添加"))
  }

  private final class ProbeSecretStore: OwlSecretStoring {
    let backing = OwlInMemorySecretStore()
    private(set) var readNames: [String] = []
    func secret(named name: String) throws -> String? {
      readNames.append(name)
      return try backing.secret(named: name)
    }
    func setSecret(_ value: String, named name: String) throws {
      try backing.setSecret(value, named: name)
    }
    func deleteSecret(named name: String) throws { try backing.deleteSecret(named: name) }
  }

  func testProbeKeyRejectsStoredKeyForNewOriginAndAllowsSameOrigin() throws {
    for providerID in ["retired-provider", OwlLLMProviderCatalog.customID] {
      let store = makeStore()
      let secrets = ProbeSecretStore()
      let profile = try store.add(OwlProviderProfile(
        displayName: providerID, endpoint: URL(string: "https://old.example.com/v1/chat/completions")!,
        model: "old-model", providerID: providerID))
      let oldKey = UUID().uuidString
      try secrets.setSecret(oldKey, named: profile.secretName)

      for typedKey in ["", " \t\n "] {
        for endpoint in [
          "https://new.example.com/v1/chat/completions",
          "https://old.example.com:8443/v1/chat/completions",
          "http://old.example.com/v1/chat/completions",
        ] {
          let readsBefore = secrets.readNames.count
          let result = Actions.providerProbeKey(
            editing: profile, endpoint: URL(string: endpoint)!, typedKey: typedKey,
            store: store, secrets: secrets)
          XCTAssertNil(result.key)
          XCTAssertEqual(result.status, "更换地址后请重新填写 API Key。")
          XCTAssertEqual(secrets.readNames.count, readsBefore, "Cross-origin probes must not read secrets")
        }
        for endpoint in [
          "https://old.example.com/v2/models",
          "HTTPS://OLD.EXAMPLE.COM:443/v1/models",
        ] {
          let result = Actions.providerProbeKey(
            editing: profile, endpoint: URL(string: endpoint)!, typedKey: typedKey,
            store: store, secrets: secrets)
          XCTAssertTrue(result.key == oldKey)
          XCTAssertNil(result.status)
        }
      }

      let typedKey = UUID().uuidString
      let readsBeforeTyped = secrets.readNames.count
      let typed = Actions.providerProbeKey(
        editing: profile, endpoint: URL(string: "https://new.example.com/v1")!,
        typedKey: " \t" + typedKey + "\n ", store: store, secrets: secrets)
      XCTAssertTrue(typed.key == typedKey)
      XCTAssertNil(typed.status)
      XCTAssertEqual(secrets.readNames.count, readsBeforeTyped)
      for keyInput in ["", " \t\n "] {
        let empty = Actions.providerProbeKey(
          editing: nil, endpoint: profile.endpoint, typedKey: keyInput, store: store, secrets: secrets)
        XCTAssertNil(empty.key)
        XCTAssertNil(empty.status)
      }
      XCTAssertEqual(secrets.readNames.count, readsBeforeTyped)

      var current = profile
      current.endpoint = URL(string: "https://new.example.com/v1/chat/completions")!
      current.secretName = OwlProviderProfile.defaultSecretName(for: UUID().uuidString)
      _ = try store.update(current)
      let currentKey = UUID().uuidString
      try secrets.setSecret(currentKey, named: current.secretName)
      let readsBeforeStale = secrets.readNames.count
      let rejected = Actions.providerProbeKey(
        editing: profile, endpoint: profile.endpoint, typedKey: "", store: store, secrets: secrets)
      XCTAssertNil(rejected.key)
      XCTAssertEqual(rejected.status, "更换地址后请重新填写 API Key。")
      XCTAssertEqual(secrets.readNames.count, readsBeforeStale)
      let refreshed = Actions.providerProbeKey(
        editing: profile, endpoint: current.endpoint, typedKey: "", store: store, secrets: secrets)
      XCTAssertTrue(refreshed.key == currentKey)
      XCTAssertNil(refreshed.status)
      XCTAssertEqual(secrets.readNames.last, current.secretName)

      // Missing and empty stored values preserve the existing missing-key prompt.
      for storedValue in [nil, ""] as [String?] {
        if let storedValue {
          try secrets.setSecret(storedValue, named: current.secretName)
        } else {
          try secrets.deleteSecret(named: current.secretName)
        }
        let missing = Actions.providerProbeKey(
          editing: profile, endpoint: current.endpoint, typedKey: "", store: store, secrets: secrets)
        XCTAssertNil(missing.key)
        XCTAssertNil(missing.status)
      }

      // A profile absent from the store falls back to the supplied snapshot.
      try store.delete(id: profile.id)
      let fallback = Actions.providerProbeKey(
        editing: profile, endpoint: profile.endpoint, typedKey: "", store: store, secrets: secrets)
      XCTAssertTrue(fallback.key == oldKey)
      XCTAssertNil(fallback.status)
    }
  }

  func testOriginChangeWithoutKeyRejectsWithoutAnyMutation() throws {
    OwlProviderKeyVerification.resetForTesting()
    defer { OwlProviderKeyVerification.resetForTesting() }
    for providerID in ["retired-provider", OwlLLMProviderCatalog.customID] {
      for isDefault in [true, false] {
        for endpoint in [
          "https://new.example.com/v1/chat/completions",
          "http://old.example.com/v1/chat/completions",
          "https://old.example.com:8443/v1/chat/completions",
        ] {
          for keyInput in ["", " \t\n "] {
            let store = makeStore()
            let secrets = OwlInMemorySecretStore()
            // Seed another default so the false case is not promoted as the first profile.
            _ = try store.add(OwlProviderProfile(
              displayName: "current", endpoint: URL(string: "https://current.example.com/v1")!,
              model: "current-model", providerID: OwlLLMProviderCatalog.customID, isDefault: true))
            let profile = try store.add(OwlProviderProfile(
              displayName: providerID, endpoint: URL(string: "https://old.example.com/v1/chat/completions")!,
              model: "old-model", providerID: providerID, isDefault: isDefault))
            try secrets.setSecret(UUID().uuidString, named: profile.secretName)
            OwlProviderKeyVerification.markVerified(secretName: profile.secretName)
            let verifiedAt = OwlProviderKeyVerification.verifiedAt(secretName: profile.secretName)
            let before = try Data(contentsOf: store.fileURL)
            let profilesBefore = store.profiles()
            let defaultBefore = store.defaultProfile
            let secretsBefore = secrets.storage
            var writes = 0
            store.beforeSave = { writes += 1 }

            let result = Actions.updateProviderProfile(
              profile, endpoint: endpoint, model: "new-model", apiKey: keyInput,
              store: store, secrets: secrets)

            XCTAssertEqual(result.status, "更换地址后请重新填写 API Key。")
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
            XCTAssertEqual(result.profiles, profilesBefore)
            XCTAssertEqual(makeStore().profiles(), profilesBefore)
            XCTAssertEqual(makeStore().defaultProfile, defaultBefore)
            XCTAssertTrue(secrets.storage == secretsBefore, "Rejected edit must not mutate secrets")
            XCTAssertEqual(OwlProviderKeyVerification.verifiedAt(secretName: profile.secretName), verifiedAt)
          }
        }
      }
    }
  }

  func testUppercaseHTTPSEndpointPassesSharedSchemeCheck() throws {
    for endpoint in [
      "HTTPS://api.example.com/v1",
      "Https://api.example.com/v1",
      "https://api.example.com/v1",
    ] {
      XCTAssertTrue(Actions.isHTTPSEndpoint(try XCTUnwrap(URL(string: endpoint))), endpoint)
    }
    for endpoint in [
      "http://api.example.com/v1",
      "HTTP://api.example.com/v1",
      "ftp://api.example.com",
    ] {
      XCTAssertFalse(Actions.isHTTPSEndpoint(try XCTUnwrap(URL(string: endpoint))), endpoint)
    }

    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let profile = try store.add(OwlProviderProfile(
      displayName: "custom", endpoint: URL(string: "https://api.example.com/v1")!,
      model: "old-model", providerID: OwlLLMProviderCatalog.customID, isDefault: true))
    try secrets.setSecret(UUID().uuidString, named: profile.secretName)
    let endpoint = "HTTPS://api.example.com/v1"

    let result = Actions.updateProviderProfile(
      profile, endpoint: endpoint, model: profile.model, apiKey: "",
      store: store, secrets: secrets)

    XCTAssertTrue(result.status.hasPrefix("已保存"))
    let saved = try XCTUnwrap(makeStore().profile(id: profile.id))
    XCTAssertEqual(saved.endpoint, URL(string: endpoint))
    XCTAssertTrue(Actions.isHTTPSEndpoint(saved.endpoint))
  }

  func testSameOriginEditsPreserveKeyIncludingCaseAndDefaultPort() throws {
    OwlProviderKeyVerification.resetForTesting()
    defer { OwlProviderKeyVerification.resetForTesting() }
    for providerID in ["retired-provider", OwlLLMProviderCatalog.customID] {
      for (endpoint, model) in [
        ("https://old.example.com/v1/chat/completions", "new-model"),
        ("https://old.example.com/v2/chat/completions", "old-model"),
        ("HTTPS://OLD.EXAMPLE.COM:443/v1/chat/completions", "old-model"),
      ] {
        let store = makeStore()
        let secrets = OwlInMemorySecretStore()
        let profile = try store.add(OwlProviderProfile(
          displayName: providerID, endpoint: URL(string: "https://old.example.com/v1/chat/completions")!,
          model: "old-model", providerID: providerID, isDefault: true))
        try secrets.setSecret(UUID().uuidString, named: profile.secretName)
        let secretsBefore = secrets.storage
        OwlProviderKeyVerification.markVerified(secretName: profile.secretName)
        let verifiedAt = OwlProviderKeyVerification.verifiedAt(secretName: profile.secretName)

        let result = Actions.updateProviderProfile(
          profile, endpoint: endpoint, model: model, apiKey: "",
          store: store, secrets: secrets)

        XCTAssertTrue(result.status.hasPrefix("已保存"))
        let saved = try XCTUnwrap(makeStore().profile(id: profile.id))
        XCTAssertEqual(saved.endpoint, URL(string: endpoint))
        XCTAssertEqual(saved.model, model)
        XCTAssertEqual(saved.secretName, profile.secretName)
        XCTAssertTrue(secrets.storage == secretsBefore, "Same-origin edit must preserve secrets")
        XCTAssertEqual(OwlProviderKeyVerification.verifiedAt(secretName: profile.secretName), verifiedAt)
      }
    }
  }

  func testRetryAfterCommittedFailureUsesPersistedKeyAndRefreshesEditingProfile() throws {
    for providerID in ["retired-provider", OwlLLMProviderCatalog.customID] {
      let store = makeStore()
      let secrets = OwlInMemorySecretStore()
      let profile = try store.add(OwlProviderProfile(
        displayName: providerID, endpoint: URL(string: "https://old.example.com/v1/chat/completions")!,
        model: "old-model", providerID: providerID, isDefault: true))
      let oldKey = UUID().uuidString
      let newKey = UUID().uuidString
      try secrets.setSecret(oldKey, named: profile.secretName)
      store.afterAtomicWrite = { throw SaveFailure.injected }
      let endpoint = "https://new.example.com/v1/chat/completions"
      let failed = Actions.updateProviderProfile(
        profile, endpoint: endpoint, model: "new-model", apiKey: newKey,
        store: store, secrets: secrets)
      XCTAssertEqual(failed.status, "保存供应商失败。")
      let persisted = try XCTUnwrap(makeStore().profile(id: profile.id))
      XCTAssertEqual(persisted.endpoint.absoluteString, endpoint)
      XCTAssertNotEqual(persisted.secretName, profile.secretName)
      XCTAssertTrue(try secrets.secret(named: persisted.secretName) == newKey)
      XCTAssertEqual(OwlSettingsActions.providerProfileForRetry(profile, profiles: failed.profiles), persisted)
      XCTAssertNil(OwlSettingsActions.providerProfileForRetry(profile, profiles: []))

      store.afterAtomicWrite = nil
      let retried = Actions.updateProviderProfile(
        profile, endpoint: endpoint, model: "retry-model", apiKey: "",
        store: store, secrets: secrets)
      XCTAssertTrue(retried.status.hasPrefix("已保存"))
      let saved = try XCTUnwrap(makeStore().profile(id: profile.id))
      XCTAssertEqual(saved.secretName, persisted.secretName)
      XCTAssertEqual(saved.endpoint, persisted.endpoint)
      XCTAssertEqual(saved.model, "retry-model")
      XCTAssertTrue(try secrets.secret(named: saved.secretName) == newKey)
      try assertNoOldKeyAtNewEndpoint(secrets: secrets, oldKey: oldKey, newEndpoint: endpoint)
    }
  }

  func testEditingRetiredProviderThenSettingDefaultRoutesToSavedProfile() throws {
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let current = try store.add(OwlProviderProfile(
      displayName: "current", endpoint: URL(string: "https://current.example.com/v1/chat/completions")!,
      model: "current-model", providerID: OwlLLMProviderCatalog.customID))
    let retired = try store.add(OwlProviderProfile(
      displayName: "retired", endpoint: URL(string: "https://retired.example.com/v1/chat/completions")!,
      model: "retired-model", providerID: "retired-provider"))
    try secrets.setSecret("test-placeholder", named: retired.secretName)

    XCTAssertEqual(OwlLLMProviderCatalog.formProviderID(for: retired), OwlLLMProviderCatalog.customID)
    let persistedBefore = try XCTUnwrap(store.profile(id: retired.id))
    let rejected = Actions.updateProviderProfile(
      retired, endpoint: "https://custom.example.com/v1/chat/completions", model: " custom-model ",
      apiKey: "", store: store, secrets: secrets)
    XCTAssertEqual(rejected.status, "更换地址后请重新填写 API Key。")
    XCTAssertEqual(store.profile(id: retired.id), persistedBefore)
    let newKey = UUID().uuidString
    let result = Actions.updateProviderProfile(
      retired, endpoint: "https://custom.example.com/v1/chat/completions", model: " custom-model ",
      apiKey: newKey, store: store, secrets: secrets)
    XCTAssertTrue(result.status.hasPrefix("已保存"))
    let saved = try XCTUnwrap(store.profile(id: retired.id))
    XCTAssertEqual(saved.providerID, OwlLLMProviderCatalog.customID)
    XCTAssertNotEqual(saved.secretName, retired.secretName)
    XCTAssertTrue(try secrets.secret(named: saved.secretName) == newKey)
    XCTAssertEqual(store.defaultProfile?.id, current.id)

    let selected = Actions.setDefaultProviderProfile(saved, store: store)
    XCTAssertTrue(selected.status.hasPrefix("已将"))
    XCTAssertEqual(selected.profiles.filter { $0.isDefault }.map(\.id), [saved.id])
    XCTAssertEqual(store.defaultProfile?.id, saved.id)
    let routing = OwlCloudRouting.resolve(profile: store.defaultProfile)
    XCTAssertEqual(routing.providerID, OwlLLMProviderCatalog.customID)
    XCTAssertEqual(routing.endpoint.absoluteString, "https://custom.example.com/v1/chat/completions")
    XCTAssertEqual(routing.model, "custom-model")
    XCTAssertEqual(routing.secretName, saved.secretName)
    XCTAssertTrue(try routing.secretName.flatMap { try secrets.secret(named: $0) } == newKey)
  }

  func testSettingUneditedRetiredProviderDefaultRejectsAndPreservesCurrentDefault() throws {
    let store = makeStore()
    let current = try store.add(OwlProviderProfile(
      displayName: "current", endpoint: URL(string: "https://current.example.com/v1/chat/completions")!,
      model: "current-model", providerID: OwlLLMProviderCatalog.customID))
    let retired = try store.add(OwlProviderProfile(
      displayName: "retired", endpoint: URL(string: "https://retired.example.com/v1/chat/completions")!,
      model: "retired-model", providerID: "retired-provider"))
    let before = try Data(contentsOf: store.fileURL)

    let result = Actions.setDefaultProviderProfile(retired, store: store)

    XCTAssertEqual(result.status, "请先编辑并保存该供应商，再设为默认。")
    XCTAssertEqual(result.profiles.filter { $0.isDefault }.map(\.id), [current.id])
    XCTAssertEqual(store.defaultProfile?.id, current.id)
    XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    XCTAssertEqual(OwlCloudRouting.resolve(profile: store.defaultProfile).secretName, current.secretName)
  }

  func testSetDefaultDeleteAndSaveKeyActions() throws {
    let store = makeStore()
    let secrets = OwlInMemorySecretStore()
    let first = try XCTUnwrap(Actions.addProviderProfile(
      displayName: "first", endpoint: "https://a.example.com/v1/chat/completions",
      model: "m1", apiKey: "", makeDefault: true, store: store, secrets: secrets).profiles.first)
    let added2 = Actions.addProviderProfile(
      displayName: "second", endpoint: "https://b.example.com/v1/chat/completions",
      model: "m2", apiKey: "", makeDefault: false, store: store, secrets: secrets)
    let second = try XCTUnwrap(added2.profiles.first { $0.displayName == "second" })

    // set default
    let setResult = Actions.setDefaultProviderProfile(second, store: store)
    XCTAssertEqual(store.defaultProfile?.id, second.id)
    XCTAssertTrue(setResult.status.contains("second"))

    // 三态：没有值是「未设置」；刚存进去只是「有值」，还没拿它真的调通过任何一次请求。
    XCTAssertEqual(Actions.providerProfileKeyStatus(second, secrets: secrets), "未设置")
    try secrets.setSecret("sk-second", named: second.secretName)
    XCTAssertEqual(
      Actions.providerProfileKeyStatus(second, secrets: secrets), "已设置·未验证")

    // delete profile (removes the profile and its stored key; promotes the other to default)
    try secrets.setSecret("sk-first", named: first.secretName)
    let deleteResult = Actions.deleteProviderProfile(second, store: store, secrets: secrets)
    XCTAssertNil(store.profile(id: second.id))
    XCTAssertEqual(store.defaultProfile?.id, first.id, "deleting the default promotes the remaining profile")
    XCTAssertTrue(deleteResult.status.contains("second"))
  }
}

/// The settings page's provider calls as before the registry: one registry change plus its copy.
/// Keeps the transaction tests above reading as the user-visible strings they pin.
private enum Actions {
  static func addProviderProfile(
    displayName: String, endpoint: String, model: String, apiKey: String, makeDefault: Bool,
    store: OwlProviderProfileStore, secrets: OwlSecretStoring, providerID: String? = nil
  ) -> (profiles: [OwlProviderProfile], status: String) {
    let form = OwlProviderRegistry.Form(
      providerID: providerID ?? "", displayName: displayName, endpoint: endpoint, model: model)
    let change = OwlProviderRegistry(store: store, secrets: secrets)
      .upsert(form, key: apiKey, makeDefault: makeDefault)
    return (change.profiles, change.outcome.statusText)
  }

  static func updateProviderProfile(
    _ profile: OwlProviderProfile, endpoint: String, model: String, apiKey: String,
    store: OwlProviderProfileStore, secrets: OwlSecretStoring
  ) -> (profiles: [OwlProviderProfile], status: String) {
    let change = OwlProviderRegistry(store: store, secrets: secrets)
      .replaceEndpoint(of: profile, endpoint: endpoint, model: model, key: apiKey)
    return (change.profiles, change.outcome.statusText)
  }

  static func saveQwenWorkspace(
    _ input: String, apiKey: String, store: OwlProviderProfileStore, secrets: OwlSecretStoring,
    defaults: UserDefaults
  ) -> (profiles: [OwlProviderProfile], status: String, saved: Bool) {
    let change = OwlProviderRegistry(store: store, secrets: secrets, defaults: defaults)
      .applyQwenWorkspace(input, key: apiKey)
    guard case .saved = change.outcome else { return (change.profiles, change.outcome.statusText, false) }
    return (change.profiles, change.outcome.statusText, true)
  }

  static func providerProbeKey(
    editing profile: OwlProviderProfile?, endpoint: URL, typedKey: String,
    store: OwlProviderProfileStore, secrets: OwlSecretStoring
  ) -> (key: String?, status: String?) {
    switch OwlProviderRegistry(store: store, secrets: secrets)
      .probeKey(editing: profile, endpoint: endpoint, typedKey: typedKey) {
    case let .key(key): return (key, nil)
    case .missing: return (nil, nil)
    case .needsReplacementKey: return (nil, OwlProviderRegistry.ProbeKey.replacementKeyPrompt)
    }
  }

  static func setDefaultProviderProfile(
    _ profile: OwlProviderProfile, store: OwlProviderProfileStore
  ) -> (profiles: [OwlProviderProfile], status: String) {
    let change = OwlProviderRegistry(store: store, secrets: OwlInMemorySecretStore()).setDefault(profile)
    return (change.profiles, change.outcome.statusText)
  }

  static func deleteProviderProfile(
    _ profile: OwlProviderProfile, store: OwlProviderProfileStore, secrets: OwlSecretStoring
  ) -> (profiles: [OwlProviderProfile], status: String) {
    let change = OwlProviderRegistry(store: store, secrets: secrets).delete(profile)
    return (change.profiles, change.outcome.statusText)
  }

  static func providerProfileKeyStatus(_ profile: OwlProviderProfile, secrets: OwlSecretStoring) -> String {
    OwlProviderRegistry(secrets: secrets).keyState(for: profile).statusText
  }

  static func markProviderProfileKeyVerified(_ profile: OwlProviderProfile) {
    OwlProviderKeyVerification.markVerified(secretName: profile.secretName)
  }

  static func isHTTPSEndpoint(_ url: URL) -> Bool { OwlProviderRegistry.isHTTPS(url) }
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
    XCTAssertEqual(
      OwlProviderModelList.modelsURL(from: URL(string: "https://api.x.ai/v1/audio/transcriptions")!)?.absoluteString,
      "https://api.x.ai/v1/models")
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
      .rejected(status: 401, message: "Invalid API-key provided.", code: "x"))

    // DashScope 原生是顶层 message，不是 error.message。
    let dashScopeShape = Data(#"{"code":"InvalidParameter","message":"url error, please check url"}"#.utf8)
    XCTAssertEqual(
      OwlProviderConnectivityCheck.outcome(
        data: dashScopeShape, response: response(400), latencyMS: 5),
      .rejected(status: 400, message: "url error, please check url", code: "InvalidParameter"))
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
      transport: OwlStubTransport { _ in throw URLError(.notConnectedToInternet) })
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
      transport: OwlStubTransport { request in
        (Data(#"{"choices":[]}"#.utf8),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
      },
      clock: { ticks.removeFirst() })
    XCTAssertEqual(outcome, .ok(latencyMS: 1250))
  }
}
