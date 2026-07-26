//
//  ProviderProfileStoreTests.swift
//  FamoTests — multi-provider profile foundation
//  (task 06-22-famo-multi-provider-keychain-foundation, research B1+B2)
//
//  Locks the provider-profile foundation contracts against an isolated temp dir + an in-memory
//  secret store (never touches the real ~/Library/Application Support/Famo or the real Keychain):
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
@testable import Famo

/// In-memory `FamoSecretStoring` for tests — upsert semantics, no Keychain.
final class FamoInMemorySecretStore: FamoSecretStoring {
  private var storage: [String: String] = [:]
  func secret(named name: String) throws -> String? { storage[name] }
  func setSecret(_ value: String, named name: String) throws { storage[name] = value }
  func deleteSecret(named name: String) throws { storage[name] = nil }
}

final class ProviderProfileStoreTests: XCTestCase {

  private var tempRoot: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("FamoProviderStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
      try FileManager.default.removeItem(at: tempRoot)
    }
    try super.tearDownWithError()
  }

  private func makeStore() -> FamoProviderProfileStore {
    FamoProviderProfileStore(root: tempRoot)
  }

  private func makeProfile(
    name: String,
    model: String = "deepseek-v4-flash",
    isDefault: Bool = false
  ) -> FamoProviderProfile {
    FamoProviderProfile(
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
    XCTAssertEqual(reloaded.secretName, "famo.provider.\(added.id).apiKey")
  }

  func testKeyIsNeverWrittenToProvidersJSON() throws {
    let store = makeStore()
    let secrets = FamoInMemorySecretStore()
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
      XCTAssertEqual(error as? FamoProviderError, .notFound(ghost.id))
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
      XCTAssertEqual(error as? FamoProviderError, .notFound("nope"))
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
    XCTAssertEqual(store.load().schemaVersion, FamoProviderProfilesFile.currentSchemaVersion)
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
      "maxCandidates": 4, "secretName": "famo.provider.legacy.apiKey",
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

  // MARK: - Secret store

  func testInMemorySecretStoreUpsertAndDelete() throws {
    let secrets = FamoInMemorySecretStore()
    XCTAssertNil(try secrets.secret(named: "famo.provider.x.apiKey"))
    try secrets.setSecret("k1", named: "famo.provider.x.apiKey")
    XCTAssertEqual(try secrets.secret(named: "famo.provider.x.apiKey"), "k1")
    try secrets.setSecret("k2", named: "famo.provider.x.apiKey")  // upsert
    XCTAssertEqual(try secrets.secret(named: "famo.provider.x.apiKey"), "k2")
    try secrets.deleteSecret(named: "famo.provider.x.apiKey")
    XCTAssertNil(try secrets.secret(named: "famo.provider.x.apiKey"))
  }

  // MARK: - Legacy migration

  func testLegacyMigrationCreatesDefaultProfileAndCopiesKey() throws {
    let store = makeStore()
    let secrets = FamoInMemorySecretStore()

    let migrated = try XCTUnwrap(FamoProviderMigration.migrateLegacyDeepSeekIfNeeded(
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
    let secrets = FamoInMemorySecretStore()
    let reader: () throws -> String? = { "sk-legacy-deepseek" }

    let first = FamoProviderMigration.migrateLegacyDeepSeekIfNeeded(
      store: store, secrets: secrets, legacyKeyReader: reader)
    XCTAssertNotNil(first)
    let second = FamoProviderMigration.migrateLegacyDeepSeekIfNeeded(
      store: store, secrets: secrets, legacyKeyReader: reader)
    XCTAssertNil(second, "migration must not run again once a profile exists")
    XCTAssertEqual(store.profiles().count, 1)
  }

  func testNoLegacyKeyMeansNoMigration() throws {
    let store = makeStore()
    let secrets = FamoInMemorySecretStore()
    let migrated = FamoProviderMigration.migrateLegacyDeepSeekIfNeeded(
      store: store, secrets: secrets, legacyKeyReader: { nil })
    XCTAssertNil(migrated, "a fresh install with no legacy key creates no profile")
    XCTAssertTrue(store.profiles().isEmpty)
  }

  // MARK: - Settings actions (Slice 3)

  func testAddProviderProfileActionPersistsProfileAndKey() throws {
    let store = makeStore()
    let secrets = FamoInMemorySecretStore()
    let result = FamoSettingsActions.addProviderProfile(
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

  func testLLMProviderCatalogMarksSourceSearchProvidersAndMiMoAuth() throws {
    XCTAssertNil(FamoLLMProviderCatalog.preset(id: "zhipu"), "智谱已下架，不得再出现在预设目录里")

    let sourceCapable = ["qwen", "doubao", "mimo", "openai"]
    for id in sourceCapable {
      let preset = try XCTUnwrap(FamoLLMProviderCatalog.preset(id: id))
      XCTAssertEqual(preset.sourceSupport, .sourceResults, "\(id) should support source verification")
    }

    let planOnly = ["deepseek", "gemini", "minimax"]
    for id in planOnly {
      let preset = try XCTUnwrap(FamoLLMProviderCatalog.preset(id: id))
      XCTAssertEqual(preset.sourceSupport, .searchPlanOnly, "\(id) should not pretend to return sources")
    }

    let mimo = FamoProviderProfile(
      displayName: "小米 MiMo",
      endpoint: URL(string: "https://api.xiaomimimo.com/v1/chat/completions")!,
      model: "mimo-v2.5",
      providerID: "mimo"
    )
    XCTAssertEqual(FamoLLMProviderCatalog.authHeaderStyle(for: mimo), .apiKey)
    XCTAssertEqual(FamoLLMProviderCatalog.sourceSupport(for: mimo), .sourceResults)
  }

  func testAddProviderProfileActionRejectsBlankNameAndNonHTTPS() throws {
    let store = makeStore()
    let secrets = FamoInMemorySecretStore()

    let blank = FamoSettingsActions.addProviderProfile(
      displayName: "   ", endpoint: "https://api.openai.com/v1/chat/completions",
      model: "gpt-4o", apiKey: "", makeDefault: true, store: store, secrets: secrets)
    XCTAssertEqual(blank.status, "供应商名称不能为空。")
    XCTAssertTrue(store.profiles().isEmpty)

    let insecure = FamoSettingsActions.addProviderProfile(
      displayName: "p", endpoint: "http://api.openai.com/v1/chat/completions",
      model: "gpt-4o", apiKey: "", makeDefault: true, store: store, secrets: secrets)
    XCTAssertEqual(insecure.status, "端点必须是 https。")
    XCTAssertTrue(store.profiles().isEmpty, "a non-https endpoint must not create a profile")
  }

  func testAddProviderProfileActionAllowsEmptyKeyForLaterEntry() throws {
    let store = makeStore()
    let secrets = FamoInMemorySecretStore()
    let result = FamoSettingsActions.addProviderProfile(
      displayName: "personal OpenAI", endpoint: "https://api.openai.com/v1/chat/completions",
      model: "gpt-4o", apiKey: "  ", makeDefault: true, store: store, secrets: secrets)
    let profile = try XCTUnwrap(result.profiles.first)
    XCTAssertNil(try secrets.secret(named: profile.secretName), "no key supplied → none stored")
    XCTAssertTrue(result.status.hasPrefix("已添加"))
  }

  func testSetDefaultDeleteAndSaveKeyActions() throws {
    let store = makeStore()
    let secrets = FamoInMemorySecretStore()
    let first = try XCTUnwrap(FamoSettingsActions.addProviderProfile(
      displayName: "first", endpoint: "https://a.example.com/v1/chat/completions",
      model: "m1", apiKey: "", makeDefault: true, store: store, secrets: secrets).profiles.first)
    let added2 = FamoSettingsActions.addProviderProfile(
      displayName: "second", endpoint: "https://b.example.com/v1/chat/completions",
      model: "m2", apiKey: "", makeDefault: false, store: store, secrets: secrets)
    let second = try XCTUnwrap(added2.profiles.first { $0.displayName == "second" })

    // set default
    let setResult = FamoSettingsActions.setDefaultProviderProfile(second, store: store)
    XCTAssertEqual(store.defaultProfile?.id, second.id)
    XCTAssertTrue(setResult.status.contains("second"))

    // save key (write-only, status never echoes the value)
    let saveResult = FamoSettingsActions.saveProviderProfileKey(second, apiKey: " sk-second ", secrets: secrets)
    XCTAssertEqual(saveResult.input, "")
    XCTAssertEqual(saveResult.status, "已保存到 Keychain")
    XCTAssertEqual(try secrets.secret(named: second.secretName), "sk-second")
    XCTAssertEqual(FamoSettingsActions.providerProfileKeyStatus(second, secrets: secrets), "已设置")

    let emptyKey = FamoSettingsActions.saveProviderProfileKey(second, apiKey: "  ", secrets: secrets)
    XCTAssertEqual(emptyKey.status, "请输入 API Key")

    // clear key
    XCTAssertEqual(FamoSettingsActions.clearProviderProfileKey(second, secrets: secrets), "已删除 API Key")
    XCTAssertEqual(FamoSettingsActions.providerProfileKeyStatus(second, secrets: secrets), "未设置")

    // delete profile (removes the profile and its stored key; promotes the other to default)
    try secrets.setSecret("sk-first", named: first.secretName)
    let deleteResult = FamoSettingsActions.deleteProviderProfile(second, store: store, secrets: secrets)
    XCTAssertNil(store.profile(id: second.id))
    XCTAssertEqual(store.defaultProfile?.id, first.id, "deleting the default promotes the remaining profile")
    XCTAssertTrue(deleteResult.status.contains("second"))
  }
}

/// Pure model-list helpers behind the AI-config 「拉取最新」 button (network `fetch` is not unit-tested).
final class FamoProviderModelListTests: XCTestCase {
  func testModelsURLSwapsChatCompletionsSuffix() {
    XCTAssertEqual(
      FamoProviderModelList.modelsURL(from: URL(string: "https://api.deepseek.com/v1/chat/completions")!)?.absoluteString,
      "https://api.deepseek.com/v1/models")
    XCTAssertEqual(
      FamoProviderModelList.modelsURL(from: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!)?.absoluteString,
      "https://generativelanguage.googleapis.com/v1beta/openai/models")
  }

  func testModelsURLFallsBackToParentPath() {
    // No /chat/completions suffix → append `models` to the parent path.
    XCTAssertEqual(
      FamoProviderModelList.modelsURL(from: URL(string: "https://api.example.com/v1/responses")!)?.absoluteString,
      "https://api.example.com/v1/models")
  }

  func testParseModelIDsKeepsOrderAndDedupes() {
    let json = Data(#"{"data":[{"id":"gpt-4o"},{"id":"gpt-4o-mini"},{"id":"gpt-4o"},{"id":""}]}"#.utf8)
    XCTAssertEqual(FamoProviderModelList.parseModelIDs(json), ["gpt-4o", "gpt-4o-mini"])
    XCTAssertEqual(FamoProviderModelList.parseModelIDs(Data("not json".utf8)), [])
  }

  func testMergedPutsCuratedFirstThenNewFetched() {
    XCTAssertEqual(
      FamoProviderModelList.merged(curated: ["deepseek-chat", "deepseek-reasoner"],
                                   fetched: ["deepseek-chat", "deepseek-coder"]),
      ["deepseek-chat", "deepseek-reasoner", "deepseek-coder"])
  }
}
