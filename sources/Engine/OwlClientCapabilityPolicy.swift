//
//  OwlClientCapabilityPolicy.swift
//  Owltype
//
//  Pure host-client capability policy for risky macOS text clients. Decisions carry safe
//  diagnostic reasons only; they never include user text or host document content.
//

import Carbon
import Foundation

enum OwlClientCapability: String, CaseIterable, Codable, Sendable {
  case selectedRange
  case replacementRange
  case surroundingText
  case caretAttributes
  case nonzeroCharacterIndexAttributes
  case inputModeSwitch
  case contextMenu
  case delayedCandidatePositioning
  case privacyComposition
}

enum OwlClientCapabilityReason: String, Codable, Sendable {
  case allowedDefault
  case allowedAppKitClient
  case deniedSecureInput
  case deniedPasswordLikeContext
  case deniedOfficeRange
  case deniedOfficeInputMode
  case deniedChromiumClient
  case deniedGoogleDocsClient
  case deniedElectronClient
  case deniedSafariAddressBar
  case deniedTerminalSecureInput
  case deniedLauncherSearchClient
  case deniedNonzeroCharacterIndexHotPath
  case delayedForChromiumClient
  case delayedForGoogleDocsClient
  case delayedForElectronClient
  case delayedForSafariAddressBar
  case allowedPrivacyComposition
  case notNeeded
  case userForcedAllow
  case userForcedDeny
}

struct OwlClientCapabilityDecision: Equatable, Codable, Sendable {
  let allowed: Bool
  let reason: OwlClientCapabilityReason

  var diagnosticReason: String { reason.rawValue }
}

struct OwlClientCapabilities: Equatable, Codable, Sendable {
  let selectedRange: OwlClientCapabilityDecision
  let replacementRange: OwlClientCapabilityDecision
  let surroundingText: OwlClientCapabilityDecision
  let caretAttributes: OwlClientCapabilityDecision
  let nonzeroCharacterIndexAttributes: OwlClientCapabilityDecision
  let inputModeSwitch: OwlClientCapabilityDecision
  let contextMenu: OwlClientCapabilityDecision
  let delayedCandidatePositioning: OwlClientCapabilityDecision
  let privacyComposition: OwlClientCapabilityDecision
}

struct OwlClientHostIdentity: Equatable, Codable, Sendable {
  var bundleID: String?
  var appName: String?
  var fieldRole: String?
  var fieldIdentifierSignal: String?
  var windowTitle: String?
  var urlHost: String?
  /// Runtime fact from `OwlElectronHostDetector`: the host app's bundle ships an
  /// `Electron Framework.framework`. Kept as a plain input so this policy stays pure.
  var linksElectronFramework: Bool

  init(
    bundleID: String? = nil,
    appName: String? = nil,
    fieldRole: String? = nil,
    fieldIdentifierSignal: String? = nil,
    windowTitle: String? = nil,
    urlHost: String? = nil,
    linksElectronFramework: Bool = false
  ) {
    self.bundleID = bundleID
    self.appName = appName
    self.fieldRole = fieldRole
    self.fieldIdentifierSignal = fieldIdentifierSignal
    self.windowTitle = windowTitle
    self.urlHost = urlHost
    self.linksElectronFramework = linksElectronFramework
  }
}

struct OwlClientPrivacyState: Equatable, Codable, Sendable {
  var isSecureInputEnabled: Bool
  var isPasswordLike: Bool
  var isPrivacyModeRequested: Bool

  init(isSecureInputEnabled: Bool = false, isPasswordLike: Bool = false, isPrivacyModeRequested: Bool = false) {
    self.isSecureInputEnabled = isSecureInputEnabled
    self.isPasswordLike = isPasswordLike
    self.isPrivacyModeRequested = isPrivacyModeRequested
  }

  static func current(isPasswordLike: Bool = false, isPrivacyModeRequested: Bool = false) -> OwlClientPrivacyState {
    OwlClientPrivacyState(
      isSecureInputEnabled: IsSecureEventInputEnabled(),
      isPasswordLike: isPasswordLike,
      isPrivacyModeRequested: isPrivacyModeRequested
    )
  }
}

struct OwlClientWorkaroundSettings: Equatable, Codable, Sendable {
  var forceDeniedCapabilitiesByBundleID: [String: Set<OwlClientCapability>]
  var forceAllowedCapabilitiesByBundleID: [String: Set<OwlClientCapability>]

  init(
    forceDeniedCapabilitiesByBundleID: [String: Set<OwlClientCapability>] = [:],
    forceAllowedCapabilitiesByBundleID: [String: Set<OwlClientCapability>] = [:]
  ) {
    self.forceDeniedCapabilitiesByBundleID = forceDeniedCapabilitiesByBundleID
    self.forceAllowedCapabilitiesByBundleID = forceAllowedCapabilitiesByBundleID
  }
}

struct OwlClientCapabilityInput: Equatable, Codable, Sendable {
  var host: OwlClientHostIdentity
  var privacy: OwlClientPrivacyState
  var workarounds: OwlClientWorkaroundSettings

  init(
    host: OwlClientHostIdentity,
    privacy: OwlClientPrivacyState = .init(),
    workarounds: OwlClientWorkaroundSettings = .init()
  ) {
    self.host = host
    self.privacy = privacy
    self.workarounds = workarounds
  }
}

/// Native transport and a bounded projection cache. All capability rules live in Rust.
struct OwlClientCapabilityPolicy: Equatable, Sendable {
  private static let lock = NSLock()
  private static var cache: [(OwlClientCapabilityInput, OwlClientCapabilities)] = []

  func evaluate(_ input: OwlClientCapabilityInput) -> OwlClientCapabilities {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    if let cached = Self.cache.first(where: { $0.0 == input }) { return cached.1 }
    let value: OwlClientCapabilities = OwlAppCore.required([
      "operation": "client_capabilities", "input": OwlAppCore.payload(input)
    ])
    // Cache only native fact/value projections; no second business state or invalidation policy.
    if Self.cache.count == 8 { Self.cache.removeFirst() }
    Self.cache.append((input, value))
    return value
  }
}
