//
//  OwlProviderRegistryTests.swift
//  OwltypeTests — profile, key and verification marker as one unit
//
//  The settings page's flows against an isolated temp dir, an in-memory secret store and an
//  isolated defaults suite: add with one-per-vendor replacement (and its failure ordering),
//  verify-after-probe, Qwen workspace plus key, delete. No network, no real Keychain.
//

import Foundation
import XCTest
@testable import Owltype

final class OwlProviderRegistryTests: XCTestCase {
  private enum Injected: Error { case failure }

  /// Secret store whose writes can be made to fail.
  private final class Secrets: OwlSecretStoring {
    let backing = OwlInMemorySecretStore()
    var failWrites = false
    func secret(named name: String) throws -> String? { try backing.secret(named: name) }
    func setSecret(_ value: String, named name: String) throws {
      if failWrites { throw Injected.failure }
      try backing.setSecret(value, named: name)
    }
    func deleteSecret(named name: String) throws { try backing.deleteSecret(named: name) }
  }

  private var tempRoot: URL!
  private var defaults: UserDefaults!
  private var suiteName = ""
  private let deepSeekEndpoint = "https://api.deepseek.com/v1/chat/completions"

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("OwlProviderRegistryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    suiteName = "OwlProviderRegistryTests-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    OwlProviderKeyVerification.resetForTesting()
  }

  override func tearDownWithError() throws {
    OwlProviderKeyVerification.resetForTesting()
    defaults.removePersistentDomain(forName: suiteName)
    if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    try super.tearDownWithError()
  }

  private func makeStore() -> OwlProviderProfileStore { OwlProviderProfileStore(root: tempRoot) }

  private func makeRegistry(_ store: OwlProviderProfileStore, _ secrets: OwlSecretStoring) -> OwlProviderRegistry {
    OwlProviderRegistry(store: store, secrets: secrets, defaults: defaults)
  }

  private func deepSeekForm(model: String = "deepseek-v4-flash") -> OwlProviderRegistry.Form {
    OwlProviderRegistry.Form(
      providerID: "deepseek", displayName: "DeepSeek", endpoint: deepSeekEndpoint, model: model)
  }

  /// A verified DeepSeek provider already saved, as the starting point for a replacing add.
  private func seedVerifiedDeepSeek(_ registry: OwlProviderRegistry) throws -> OwlProviderProfile {
    let change = registry.upsert(deepSeekForm(), key: "old-key")
    guard case let .added(profile) = change.outcome else {
      XCTFail("seed add failed: \(change.outcome)")
      throw Injected.failure
    }
    registry.markVerified(profile)
    return profile
  }

  // MARK: - Add with one-per-vendor replacement

  func testAddReplacesTheSameVendorInOneWriteAndRetiresItsKey() throws {
    let store = makeStore()
    let secrets = Secrets()
    let registry = makeRegistry(store, secrets)
    let old = try seedVerifiedDeepSeek(registry)
    _ = registry.upsert(OwlProviderRegistry.Form(
      providerID: "qwen", displayName: "阿里云百炼", endpoint: OwlLLMProviderCatalog.qwenResponsesEndpoint,
      model: "qwen3.8-flash"), key: "qwen-key")
    var writes = 0
    store.beforeSave = { writes += 1 }

    let change = registry.upsert(deepSeekForm(model: "deepseek-v4-pro"), key: " new-key ")

    guard case let .added(added) = change.outcome else { return XCTFail("\(change.outcome)") }
    XCTAssertEqual(change.outcome.statusText, "已添加供应商「DeepSeek」。")
    XCTAssertEqual(writes, 1, "replacement and add are one file write")
    XCTAssertEqual(Set(makeStore().profiles().map(\.displayName)), ["阿里云百炼", "DeepSeek"])
    XCTAssertNil(makeStore().profile(id: old.id))
    XCTAssertEqual(makeStore().defaultProfile?.id, added.id)
    XCTAssertEqual(try secrets.secret(named: added.secretName), "new-key")
    XCTAssertNil(try secrets.secret(named: old.secretName), "the replaced key is retired")
    XCTAssertNil(OwlProviderKeyVerification.verifiedAt(secretName: old.secretName))
    XCTAssertEqual(registry.keyState(for: added), .unverified)
  }

  func testCustomEntriesReplaceOnlyTheSameHost() throws {
    let registry = makeRegistry(makeStore(), Secrets())
    for endpoint in ["https://a.example.com/v1/chat/completions", "https://b.example.com/v1/chat/completions",
                     "https://a.example.com/v2/chat/completions"] {
      _ = registry.upsert(OwlProviderRegistry.Form(
        providerID: OwlLLMProviderCatalog.customID, displayName: "自定义", endpoint: endpoint, model: "m"),
        key: "")
    }
    XCTAssertEqual(Set(registry.profiles.map(\.endpoint.absoluteString)), [
      "https://b.example.com/v1/chat/completions", "https://a.example.com/v2/chat/completions",
    ])
  }

  /// The intended behaviour change: a failed add used to delete the old profile and key first.
  func testFailedKeyWriteKeepsThePreviousProviderAndWritesNothing() throws {
    let store = makeStore()
    let secrets = Secrets()
    let registry = makeRegistry(store, secrets)
    let old = try seedVerifiedDeepSeek(registry)
    let bytes = try Data(contentsOf: store.fileURL)
    var writes = 0
    store.beforeSave = { writes += 1 }
    secrets.failWrites = true

    let change = registry.upsert(deepSeekForm(), key: "new-key")

    XCTAssertEqual(change.outcome, .failed)
    XCTAssertEqual(change.outcome.statusText, "添加供应商失败。")
    XCTAssertEqual(writes, 0)
    XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
    XCTAssertEqual(change.profiles.map(\.id), [old.id])
    XCTAssertEqual(secrets.backing.storage, [old.secretName: "old-key"])
    XCTAssertEqual(registry.keyState(for: old), .verified)
  }

  func testFailedProfileWriteRemovesTheStagedKeyAndKeepsThePreviousProvider() throws {
    let store = makeStore()
    let secrets = Secrets()
    let registry = makeRegistry(store, secrets)
    let old = try seedVerifiedDeepSeek(registry)
    let bytes = try Data(contentsOf: store.fileURL)
    store.beforeSave = { throw Injected.failure }

    let change = registry.upsert(deepSeekForm(), key: "new-key")

    XCTAssertEqual(change.outcome, .failed)
    XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
    XCTAssertEqual(secrets.backing.storage, [old.secretName: "old-key"], "the staged key is removed")
    XCTAssertEqual(registry.keyState(for: old), .verified)
  }

  func testWriteThatThrowsAfterLandingKeepsEveryKey() throws {
    let store = makeStore()
    let secrets = Secrets()
    let registry = makeRegistry(store, secrets)
    let old = try seedVerifiedDeepSeek(registry)
    store.afterAtomicWrite = { throw Injected.failure }

    let change = registry.upsert(deepSeekForm(), key: "new-key")

    XCTAssertEqual(change.outcome, .failed)
    let landed = try XCTUnwrap(makeStore().profiles().first)
    XCTAssertNotEqual(landed.id, old.id, "the write did land")
    XCTAssertEqual(change.profiles, [landed])
    XCTAssertEqual(try secrets.secret(named: landed.secretName), "new-key")
    XCTAssertEqual(try secrets.secret(named: old.secretName), "old-key", "an unconfirmed commit retires nothing")
  }

  func testAddRejectsBlankNameAndInsecureEndpointWithoutWriting() throws {
    let store = makeStore()
    let registry = makeRegistry(store, Secrets())
    var form = deepSeekForm()
    form.displayName = "  "
    XCTAssertEqual(registry.upsert(form, key: "k").outcome, .blankName)
    form.displayName = "DeepSeek"
    form.endpoint = "http://api.deepseek.com/v1/chat/completions"
    XCTAssertEqual(registry.upsert(form, key: "k").outcome, .insecureEndpoint)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
  }

  func testQwenAddSavesItsWorkspaceOnlyWhenTheAddCommits() throws {
    let store = makeStore()
    let registry = makeRegistry(store, Secrets())
    let endpoint = try XCTUnwrap(OwlQwenWorkspace.responsesEndpoint(for: "ws-test123abc"))
    let form = OwlProviderRegistry.Form(
      providerID: "qwen", displayName: "阿里云百炼", endpoint: endpoint.absoluteString,
      model: "qwen3.8-flash", qwenWorkspace: "ws-test123abc")
    store.beforeSave = { throw Injected.failure }
    XCTAssertEqual(registry.upsert(form, key: "k").outcome, .failed)
    XCTAssertEqual(OwlQwenWorkspaceSettings.apiHost(defaults: defaults), "")

    store.beforeSave = nil
    guard case .added = registry.upsert(form, key: "k").outcome else { return XCTFail() }
    XCTAssertEqual(OwlQwenWorkspaceSettings.apiHost(defaults: defaults),
                   "ws-test123abc.cn-beijing.maas.aliyuncs.com")
  }

  // MARK: - Verify after probe

  func testProbeBeforeAddMarksTheAddedKeyVerified() throws {
    let registry = makeRegistry(makeStore(), Secrets())
    registry.probeSucceeded(endpoint: URL(string: deepSeekEndpoint)!, key: "probed-key", editing: nil)

    guard case let .added(added) = registry.upsert(deepSeekForm(), key: " probed-key ").outcome else {
      return XCTFail()
    }
    XCTAssertEqual(registry.keyState(for: added), .verified)
    XCTAssertEqual(registry.keyState(for: added).statusText, "已验证")
  }

  func testProbeOfAnotherKeyOrEndpointDoesNotMarkTheAddedKey() throws {
    for (endpoint, key) in [(deepSeekEndpoint, "other-key"), ("https://api.deepseek.com/beta/chat/completions", "k")] {
      let registry = makeRegistry(makeStore(), Secrets())
      registry.probeSucceeded(endpoint: URL(string: endpoint)!, key: key, editing: nil)
      guard case let .added(added) = registry.upsert(deepSeekForm(), key: "k").outcome else {
        return XCTFail()
      }
      XCTAssertEqual(registry.keyState(for: added), .unverified, "\(endpoint) \(key)")
    }
  }

  func testProbeWithTheStoredKeyMarksTheEditedProfileAtOnce() throws {
    let secrets = Secrets()
    let registry = makeRegistry(makeStore(), secrets)
    guard case let .added(profile) = registry.upsert(deepSeekForm(), key: "stored").outcome else {
      return XCTFail()
    }
    let endpoint = profile.endpoint
    guard case let .key(key) = registry.probeKey(editing: profile, endpoint: endpoint, typedKey: "") else {
      return XCTFail()
    }
    registry.probeSucceeded(endpoint: endpoint, key: key, editing: profile)
    XCTAssertEqual(registry.keyState(for: profile), .verified)

    // A typed key that is not saved yet does not vouch for the stored one.
    let other = makeRegistry(makeStore(), secrets)
    OwlProviderKeyVerification.clear(secretName: profile.secretName)
    other.probeSucceeded(endpoint: endpoint, key: "typed-not-saved", editing: profile)
    XCTAssertEqual(other.keyState(for: profile), .unverified)
  }

  func testProbeOfATypedReplacementKeyMarksItWhenTheEditSaves() throws {
    let secrets = Secrets()
    let registry = makeRegistry(makeStore(), secrets)
    guard case let .added(profile) = registry.upsert(deepSeekForm(), key: "old").outcome else {
      return XCTFail()
    }
    registry.markVerified(profile)
    registry.probeSucceeded(endpoint: profile.endpoint, key: "new", editing: profile)
    XCTAssertEqual(registry.keyState(for: profile), .verified, "the old key's marker is untouched")

    let change = registry.replaceEndpoint(
      of: profile, endpoint: profile.endpoint.absoluteString, model: "deepseek-v4-pro", key: "new")

    guard case let .saved(saved) = change.outcome else { return XCTFail() }
    XCTAssertNotEqual(saved.secretName, profile.secretName)
    XCTAssertEqual(registry.keyState(for: saved), .verified)
    XCTAssertNil(OwlProviderKeyVerification.verifiedAt(secretName: profile.secretName))
  }

  // MARK: - Qwen workspace plus key

  func testWorkspaceKeyRotationDoesNotInheritAProbeOfTheOldKey() throws {
    let store = makeStore()
    let secrets = Secrets()
    let registry = makeRegistry(store, secrets)
    guard case let .added(qwen) = registry.upsert(OwlProviderRegistry.Form(
      providerID: "qwen", displayName: "阿里云百炼", endpoint: OwlLLMProviderCatalog.qwenResponsesEndpoint,
      model: "qwen3.8-flash"), key: "old-key").outcome else { return XCTFail() }
    registry.markVerified(qwen)
    registry.probeSucceeded(endpoint: qwen.endpoint, key: "old-key", editing: qwen)

    let change = registry.applyQwenWorkspace("ws-test123abc", key: "new-key")

    XCTAssertEqual(change.outcome, .saved(cleared: false))
    XCTAssertEqual(change.outcome.statusText, "已保存 Workspace API Host，所有 Qwen 供应商将共用。")
    let moved = try XCTUnwrap(change.profiles.first)
    XCTAssertEqual(moved.endpoint, OwlQwenWorkspace.responsesEndpoint(for: "ws-test123abc"))
    XCTAssertEqual(try secrets.secret(named: moved.secretName), "new-key")
    XCTAssertNil(try secrets.secret(named: qwen.secretName))
    XCTAssertEqual(registry.keyState(for: moved), .unverified)

    // The probe's result arrives after the rotation: it must not vouch for the new key.
    registry.probeSucceeded(endpoint: qwen.endpoint, key: "old-key", editing: qwen)
    XCTAssertEqual(registry.keyState(for: moved), .unverified)
    registry.probeSucceeded(endpoint: moved.endpoint, key: "new-key", editing: moved)
    XCTAssertEqual(registry.keyState(for: moved), .verified)
  }

  func testWorkspaceOriginChangeWithoutKeyIsRejectedUnchanged() throws {
    let store = makeStore()
    let secrets = Secrets()
    let registry = makeRegistry(store, secrets)
    _ = registry.upsert(OwlProviderRegistry.Form(
      providerID: "qwen", displayName: "阿里云百炼", endpoint: OwlLLMProviderCatalog.qwenResponsesEndpoint,
      model: "qwen3.8-flash"), key: "old-key")
    let bytes = try Data(contentsOf: store.fileURL)

    let change = registry.applyQwenWorkspace("ws-test123abc", key: " ")

    XCTAssertEqual(change.outcome, .needsReplacementKey)
    XCTAssertEqual(change.outcome.statusText, "更换地址后请重新填写 API Key。")
    XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
    XCTAssertEqual(OwlQwenWorkspaceSettings.apiHost(defaults: defaults), "")
  }

  // MARK: - Delete

  func testDeleteRetiresTheKeyUnlessAnotherProfileNamesIt() throws {
    let store = makeStore()
    let secrets = Secrets()
    let registry = makeRegistry(store, secrets)
    let shared = try store.add(OwlProviderProfile(
      displayName: "A", endpoint: URL(string: "https://a.example.com/v1")!, model: "m",
      providerID: OwlLLMProviderCatalog.customID, secretName: "shared", isDefault: true))
    let other = try store.add(OwlProviderProfile(
      displayName: "B", endpoint: URL(string: "https://b.example.com/v1")!, model: "m",
      providerID: OwlLLMProviderCatalog.customID, secretName: "shared"))
    try secrets.setSecret("k", named: "shared")
    registry.markVerified(shared)

    let first = registry.delete(shared)
    XCTAssertEqual(first.outcome.statusText, "已删除供应商「A」。")
    XCTAssertEqual(first.profiles.map(\.id), [other.id])
    XCTAssertEqual(registry.defaultProfile?.id, other.id)
    XCTAssertEqual(registry.keyState(for: other), .verified)

    _ = registry.delete(other)
    XCTAssertNil(try secrets.secret(named: "shared"))
    XCTAssertEqual(registry.keyState(for: other), .missing)
  }
}
