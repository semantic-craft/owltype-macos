//
//  FamoProviderAuthGateTests.swift
//  FamoTests — provider auth gate (task 07-06-famo-selection-auth-gate)
//
//  Pure: injects fake profile / secret / legacy closures. No real store, Keychain, or network.
//  Mirrors the streaming-service readiness contract (the gate is that logic, generalized) and adds
//  the gate-specific branches: legacy fallback, Keychain-throw swallowing, and legacy = nil
//  (the 来源核验 policy — no legacy fallback).
//

import XCTest
@testable import Famo

@MainActor
final class FamoProviderAuthGateTests: XCTestCase {
  private func profile() -> FamoProviderProfile {
    FamoProviderProfile(
      id: "unit",
      displayName: "unit",
      endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
      model: "gpt-4o",
      secretName: "famo.provider.unit.apiKey",
      isDefault: true
    )
  }

  struct BoomError: Error {}

  // MARK: - ready

  func testReadyWithActiveProfileAndKey() {
    let gate = FamoProviderAuthGate(
      profileProvider: { self.profile() },
      profileSecretProvider: { _ in "sk-profile-key" },
      legacyKeyProvider: { XCTFail("active profile must not read the legacy key"); return nil }
    )
    guard case let .ready(routing, apiKey) = gate.resolve() else {
      return XCTFail("a profile with a stored key must be .ready")
    }
    XCTAssertEqual(routing.model, "gpt-4o")
    XCTAssertEqual(apiKey, "sk-profile-key")
  }

  func testReadyViaLegacyWhenNoProfile() {
    let gate = FamoProviderAuthGate(
      profileProvider: { nil },
      profileSecretProvider: { _ in XCTFail("no profile → per-profile secret reader unused"); return nil },
      legacyKeyProvider: { "sk-legacy-key" }
    )
    guard case let .ready(_, apiKey) = gate.resolve() else {
      return XCTFail("no profile but a legacy key must be .ready")
    }
    XCTAssertEqual(apiKey, "sk-legacy-key")
  }

  func testReadyTrimsWhitespaceKey() {
    let gate = FamoProviderAuthGate(
      profileProvider: { self.profile() },
      profileSecretProvider: { _ in "  sk-padded  " },
      legacyKeyProvider: { nil }
    )
    guard case let .ready(_, apiKey) = gate.resolve() else {
      return XCTFail("a padded but non-empty key must be .ready after trim")
    }
    XCTAssertEqual(apiKey, "sk-padded")
  }

  // MARK: - missingKey (profile present, no usable key)

  func testMissingKeyWhenProfileHasNoStoredSecret() {
    let gate = FamoProviderAuthGate(
      profileProvider: { self.profile() },
      profileSecretProvider: { _ in nil },
      legacyKeyProvider: { XCTFail("active profile must not read the legacy key"); return nil }
    )
    XCTAssertEqual(gate.resolve(), .missingKey)
  }

  func testMissingKeyWhenProfileSecretIsWhitespaceOnly() {
    let gate = FamoProviderAuthGate(
      profileProvider: { self.profile() },
      profileSecretProvider: { _ in "   " },
      legacyKeyProvider: { nil }
    )
    XCTAssertEqual(gate.resolve(), .missingKey)
  }

  func testKeychainThrowWithProfileSwallowedToMissingKey() {
    let gate = FamoProviderAuthGate(
      profileProvider: { self.profile() },
      profileSecretProvider: { _ in throw BoomError() },
      legacyKeyProvider: { nil }
    )
    XCTAssertEqual(gate.resolve(), .missingKey)
  }

  // MARK: - unconfigured (no profile, no usable legacy)

  func testUnconfiguredWhenNoProfileAndNoLegacyKey() {
    let gate = FamoProviderAuthGate(
      profileProvider: { nil },
      profileSecretProvider: { _ in XCTFail("no profile → per-profile secret reader unused"); return nil },
      legacyKeyProvider: { nil }
    )
    XCTAssertEqual(gate.resolve(), .unconfigured)
  }

  func testKeychainThrowWithoutProfileSwallowedToUnconfigured() {
    let gate = FamoProviderAuthGate(
      profileProvider: { nil },
      profileSecretProvider: { _ in nil },
      legacyKeyProvider: { throw BoomError() }
    )
    XCTAssertEqual(gate.resolve(), .unconfigured)
  }

  // MARK: - legacyKeyProvider == nil (来源核验 policy: no legacy fallback)

  func testLegacyNilNoProfileIsUnconfigured() {
    // 来源核验 path: no legacy fallback. No profile → routing.secretName nil → no key → unconfigured.
    let gate = FamoProviderAuthGate(
      profileProvider: { nil },
      profileSecretProvider: { _ in XCTFail("no secretName → secret reader unused"); return nil },
      legacyKeyProvider: nil
    )
    XCTAssertEqual(gate.resolve(), .unconfigured)
  }

  func testLegacyNilProfileNoSecretIsMissingKey() {
    // 来源核验 path with a configured profile but no stored key → missingKey (never falls back).
    let gate = FamoProviderAuthGate(
      profileProvider: { self.profile() },
      profileSecretProvider: { _ in nil },
      legacyKeyProvider: nil
    )
    XCTAssertEqual(gate.resolve(), .missingKey)
  }
}
