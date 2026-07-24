//
//  CloudRoutingTests.swift
//  FamoTests — multi-provider fetcher routing (task 06-22-famo-multi-provider-keychain-foundation, B1)
//
//  Contracts: cloud requests route endpoint / model + the API key through the ACTIVE provider
//  profile, falling back to the legacy DeepSeek globals when no profile is configured.
//
//  Pure value + injected-fake logic: no network, no real Keychain, no real providers.json, no librime.
//

import Foundation
import XCTest
@testable import Famo

@MainActor
final class CloudRoutingTests: XCTestCase {

  private func makeProfile(
    endpoint: String,
    model: String,
    secretName: String = "famo.provider.unit.apiKey"
  ) -> FamoProviderProfile {
    FamoProviderProfile(
      id: "unit",
      displayName: "unit",
      endpoint: URL(string: endpoint)!,
      model: model,
      secretName: secretName,
      isDefault: true
    )
  }

  override func setUp() async throws {
    try await super.setUp()
    FamoCloudPreferences.resetForTesting()
    FamoCloudUsageTelemetry.resetForTesting()
    FamoSnapshotRegistry.shared.update(nil)
    FamoCandidateStore.shared.clearForSnapshotChange()
  }

  override func tearDown() async throws {
    FamoCloudPreferences.resetForTesting()
    FamoCloudUsageTelemetry.resetForTesting()
    FamoSnapshotRegistry.shared.update(nil)
    FamoCandidateStore.shared.clearForSnapshotChange()
    try await super.tearDown()
  }

  // MARK: - Routing resolution (pure)

  func testRoutingResolvesFromActiveProfile() {
    let profile = makeProfile(endpoint: "https://api.openai.com/v1/chat/completions", model: "gpt-4o")
    let routing = FamoCloudRouting.resolve(profile: profile)
    XCTAssertEqual(routing.providerID, "openai")
    XCTAssertEqual(routing.endpoint, URL(string: "https://api.openai.com/v1/chat/completions"))
    XCTAssertEqual(routing.model, "gpt-4o")
    XCTAssertEqual(routing.secretName, profile.secretName)
    XCTAssertEqual(routing.authHeaderStyle, .bearer)
  }

  func testRoutingFallsBackToLegacyGlobalsWhenNoProfile() {
    FamoCloudPreferences.deepSeekModel = "deepseek-v4-flash"
    let routing = FamoCloudRouting.resolve(profile: nil)
    XCTAssertEqual(routing.providerID, "deepseek")
    XCTAssertEqual(routing.endpoint, FamoCloudPreferences.deepSeekEndpoint)
    XCTAssertEqual(routing.model, FamoCloudPreferences.deepSeekModel)
    XCTAssertNil(routing.secretName, "legacy fallback uses the global DeepSeek key, not a per-profile secretName")
    XCTAssertEqual(routing.authHeaderStyle, .bearer)
  }

  func testRoutingEmptyProfileModelFallsBackToFlash() {
    let profile = makeProfile(endpoint: "https://example.com/v1/chat/completions", model: "")
    let routing = FamoCloudRouting.resolve(profile: profile)
    XCTAssertEqual(routing.model, FamoCloudPreferences.deepSeekModel, "an empty profile model must not send an empty model")
  }

}
