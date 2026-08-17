//
//  FamoClientCapabilityPolicy.swift
//  Famo
//
//  Pure host-client capability policy for risky macOS text clients. Decisions carry safe
//  diagnostic reasons only; they never include user text or host document content.
//

import Carbon
import Foundation

enum FamoClientCapability: String, CaseIterable, Sendable {
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

enum FamoClientCapabilityReason: String, Sendable {
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

struct FamoClientCapabilityDecision: Equatable, Sendable {
  let allowed: Bool
  let reason: FamoClientCapabilityReason

  var diagnosticReason: String { reason.rawValue }
}

struct FamoClientCapabilities: Equatable, Sendable {
  let selectedRange: FamoClientCapabilityDecision
  let replacementRange: FamoClientCapabilityDecision
  let surroundingText: FamoClientCapabilityDecision
  let caretAttributes: FamoClientCapabilityDecision
  let nonzeroCharacterIndexAttributes: FamoClientCapabilityDecision
  let inputModeSwitch: FamoClientCapabilityDecision
  let contextMenu: FamoClientCapabilityDecision
  let delayedCandidatePositioning: FamoClientCapabilityDecision
  let privacyComposition: FamoClientCapabilityDecision

  func decision(for capability: FamoClientCapability) -> FamoClientCapabilityDecision {
    switch capability {
    case .selectedRange: return selectedRange
    case .replacementRange: return replacementRange
    case .surroundingText: return surroundingText
    case .caretAttributes: return caretAttributes
    case .nonzeroCharacterIndexAttributes: return nonzeroCharacterIndexAttributes
    case .inputModeSwitch: return inputModeSwitch
    case .contextMenu: return contextMenu
    case .delayedCandidatePositioning: return delayedCandidatePositioning
    case .privacyComposition: return privacyComposition
    }
  }
}

struct FamoClientHostIdentity: Equatable, Sendable {
  var bundleID: String?
  var appName: String?
  var fieldRole: String?
  var fieldIdentifierSignal: String?
  var windowTitle: String?
  var urlHost: String?
  /// Runtime fact from `FamoElectronHostDetector`: the host app's bundle ships an
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

struct FamoClientPrivacyState: Equatable, Sendable {
  var isSecureInputEnabled: Bool
  var isPasswordLike: Bool
  var isPrivacyModeRequested: Bool

  init(isSecureInputEnabled: Bool = false, isPasswordLike: Bool = false, isPrivacyModeRequested: Bool = false) {
    self.isSecureInputEnabled = isSecureInputEnabled
    self.isPasswordLike = isPasswordLike
    self.isPrivacyModeRequested = isPrivacyModeRequested
  }

  static func current(isPasswordLike: Bool = false, isPrivacyModeRequested: Bool = false) -> FamoClientPrivacyState {
    FamoClientPrivacyState(
      isSecureInputEnabled: IsSecureEventInputEnabled(),
      isPasswordLike: isPasswordLike,
      isPrivacyModeRequested: isPrivacyModeRequested
    )
  }
}

struct FamoClientWorkaroundSettings: Equatable, Sendable {
  var forceDeniedCapabilitiesByBundleID: [String: Set<FamoClientCapability>]
  var forceAllowedCapabilitiesByBundleID: [String: Set<FamoClientCapability>]

  init(
    forceDeniedCapabilitiesByBundleID: [String: Set<FamoClientCapability>] = [:],
    forceAllowedCapabilitiesByBundleID: [String: Set<FamoClientCapability>] = [:]
  ) {
    self.forceDeniedCapabilitiesByBundleID = Self.normalized(forceDeniedCapabilitiesByBundleID)
    self.forceAllowedCapabilitiesByBundleID = Self.normalized(forceAllowedCapabilitiesByBundleID)
  }

  private static func normalized(_ values: [String: Set<FamoClientCapability>]) -> [String: Set<FamoClientCapability>] {
    Dictionary(uniqueKeysWithValues: values.map { ($0.key.lowercased(), $0.value) })
  }
}

struct FamoClientCapabilityInput: Equatable, Sendable {
  var host: FamoClientHostIdentity
  var privacy: FamoClientPrivacyState
  var workarounds: FamoClientWorkaroundSettings

  init(
    host: FamoClientHostIdentity,
    privacy: FamoClientPrivacyState = .init(),
    workarounds: FamoClientWorkaroundSettings = .init()
  ) {
    self.host = host
    self.privacy = privacy
    self.workarounds = workarounds
  }
}

struct FamoClientCapabilityPolicy: Equatable, Sendable {
  func evaluate(_ input: FamoClientCapabilityInput) -> FamoClientCapabilities {
    let facts = ClientFacts(input: input)
    return FamoClientCapabilities(
      selectedRange: selectedRange(facts),
      replacementRange: replacementRange(facts),
      surroundingText: surroundingText(facts),
      caretAttributes: caretAttributes(facts),
      nonzeroCharacterIndexAttributes: deny(.deniedNonzeroCharacterIndexHotPath),
      inputModeSwitch: inputModeSwitch(facts),
      contextMenu: contextMenu(facts),
      delayedCandidatePositioning: delayedCandidatePositioning(facts),
      privacyComposition: privacyComposition(facts)
    )
  }

  private func selectedRange(_ facts: ClientFacts) -> FamoClientCapabilityDecision {
    if let override = facts.override(.selectedRange) { return override }
    if facts.secureInput { return deny(.deniedSecureInput) }
    if facts.passwordLike { return deny(.deniedPasswordLikeContext) }
    if facts.office { return deny(.deniedOfficeRange) }
    if facts.googleDocs { return deny(.deniedGoogleDocsClient) }
    if facts.chromium { return deny(.deniedChromiumClient) }
    if facts.electron { return deny(.deniedElectronClient) }
    if facts.safariAddressBar { return deny(.deniedSafariAddressBar) }
    if facts.launcherSearch { return deny(.deniedLauncherSearchClient) }
    return allow(.allowedDefault)
  }

  private func replacementRange(_ facts: ClientFacts) -> FamoClientCapabilityDecision {
    if let override = facts.override(.replacementRange) { return override }
    if facts.secureInput { return deny(.deniedSecureInput) }
    if facts.passwordLike { return deny(.deniedPasswordLikeContext) }
    if facts.office { return deny(.deniedOfficeRange) }
    if facts.googleDocs { return deny(.deniedGoogleDocsClient) }
    if facts.chromium { return deny(.deniedChromiumClient) }
    if facts.electron { return deny(.deniedElectronClient) }
    if facts.safariAddressBar { return deny(.deniedSafariAddressBar) }
    if facts.launcherSearch { return deny(.deniedLauncherSearchClient) }
    return facts.appKitFriendly ? allow(.allowedAppKitClient) : allow(.allowedDefault)
  }

  private func surroundingText(_ facts: ClientFacts) -> FamoClientCapabilityDecision {
    if let override = facts.override(.surroundingText) { return override }
    if facts.secureInput { return deny(facts.terminal ? .deniedTerminalSecureInput : .deniedSecureInput) }
    if facts.passwordLike { return deny(.deniedPasswordLikeContext) }
    if facts.googleDocs { return deny(.deniedGoogleDocsClient) }
    if facts.chromium { return deny(.deniedChromiumClient) }
    if facts.electron { return deny(.deniedElectronClient) }
    if facts.safariAddressBar { return deny(.deniedSafariAddressBar) }
    if facts.launcherSearch { return deny(.deniedLauncherSearchClient) }
    return allow(.allowedDefault)
  }

  private func caretAttributes(_ facts: ClientFacts) -> FamoClientCapabilityDecision {
    if let override = facts.override(.caretAttributes) { return override }
    if facts.secureInput { return deny(.deniedSecureInput) }
    if facts.passwordLike { return deny(.deniedPasswordLikeContext) }
    if facts.launcherSearch { return deny(.deniedLauncherSearchClient) }
    return allow(.allowedDefault)
  }

  private func inputModeSwitch(_ facts: ClientFacts) -> FamoClientCapabilityDecision {
    if let override = facts.override(.inputModeSwitch) { return override }
    if facts.word { return deny(.deniedOfficeInputMode) }
    if facts.launcherSearch { return deny(.deniedLauncherSearchClient) }
    return allow(.allowedDefault)
  }

  private func contextMenu(_ facts: ClientFacts) -> FamoClientCapabilityDecision {
    if let override = facts.override(.contextMenu) { return override }
    if facts.secureInput { return deny(.deniedSecureInput) }
    if facts.passwordLike { return deny(.deniedPasswordLikeContext) }
    if facts.launcherSearch { return deny(.deniedLauncherSearchClient) }
    if facts.safariAddressBar { return deny(.deniedSafariAddressBar) }
    return allow(.allowedDefault)
  }

  private func delayedCandidatePositioning(_ facts: ClientFacts) -> FamoClientCapabilityDecision {
    if let override = facts.override(.delayedCandidatePositioning) { return override }
    if facts.googleDocs { return allow(.delayedForGoogleDocsClient) }
    if facts.chromium { return allow(.delayedForChromiumClient) }
    if facts.electron { return allow(.delayedForElectronClient) }
    if facts.safariAddressBar { return allow(.delayedForSafariAddressBar) }
    return deny(.notNeeded)
  }

  private func privacyComposition(_ facts: ClientFacts) -> FamoClientCapabilityDecision {
    if let override = facts.override(.privacyComposition) { return override }
    if facts.secureInput || facts.passwordLike || facts.input.privacy.isPrivacyModeRequested {
      return allow(.allowedPrivacyComposition)
    }
    return deny(.notNeeded)
  }

  private func allow(_ reason: FamoClientCapabilityReason) -> FamoClientCapabilityDecision {
    FamoClientCapabilityDecision(allowed: true, reason: reason)
  }

  private func deny(_ reason: FamoClientCapabilityReason) -> FamoClientCapabilityDecision {
    FamoClientCapabilityDecision(allowed: false, reason: reason)
  }
}

private struct ClientFacts {
  let input: FamoClientCapabilityInput
  let bundle: String
  let appName: String
  let fieldRole: String
  let fieldSignal: String
  let windowTitle: String
  let urlHost: String

  init(input: FamoClientCapabilityInput) {
    self.input = input
    bundle = input.host.bundleID?.lowercased() ?? ""
    appName = input.host.appName?.lowercased() ?? ""
    fieldRole = input.host.fieldRole?.lowercased() ?? ""
    fieldSignal = input.host.fieldIdentifierSignal?.lowercased() ?? ""
    windowTitle = input.host.windowTitle?.lowercased() ?? ""
    urlHost = input.host.urlHost?.lowercased() ?? ""
  }

  var secureInput: Bool { input.privacy.isSecureInputEnabled }
  var passwordLike: Bool { input.privacy.isPasswordLike || fieldSignal.contains("password") || fieldRole.contains("secure") }

  var word: Bool { bundle == "com.microsoft.word" }
  var office: Bool {
    word ||
      bundle == "com.microsoft.excel" ||
      bundle == "com.microsoft.powerpoint" ||
      bundle == "com.microsoft.powerpoint.mac" ||
      bundle == "com.microsoft.outlook"
  }

  var chromium: Bool {
    [
      "com.google.chrome",
      "com.google.chrome.canary",
      "org.chromium.chromium",
      "com.microsoft.edgemac",
      "com.brave.browser",
      "com.vivaldi.vivaldi",
      "com.operasoftware.opera"
    ].contains(bundle)
  }

  var googleDocs: Bool {
    urlHost == "docs.google.com" ||
      urlHost.hasSuffix(".docs.google.com") ||
      windowTitle.contains("google docs") ||
      windowTitle.contains("google 文档") ||
      windowTitle.contains("google 試算表")
  }

  var electron: Bool {
    // 08-17 真机实锤（Cursor 候选窗不跟随光标）：手工名单永远追不上新 Electron App，判定
    // 改为三层——① 运行时事实：宿主包里真的带 Electron Framework（FamoElectronHostDetector
    // 探测，经 host.linksElectronFramework 喂进来）；② ToDesktop 打包的 App bundle ID 一律是
    // `com.todesktop.<随机串>`（Cursor = com.todesktop.230313mzl4w4u92），前缀整族覆盖；
    // ③ 原名单只作兜底，供探测拿不到 bundle URL 的场景。
    input.host.linksElectronFramework ||
      bundle.hasPrefix("com.todesktop.") ||
      [
        "com.tinyspeck.slackmacgap",
        "com.hnc.discord",
        "com.microsoft.vscode",
        "com.github.githubclient",
        "com.openai.chat",
        // 07-21 真机实锤（Famo `<` 菜单 → `<<>`）：Claude Code / Codex 桌面端也是 Electron，
        // insertText(replacementRange:) 只认位置不删除范围——自替换退化成插入、内容损坏。
        "com.anthropic.claudefordesktop",
        "com.openai.codex",
        "notion.id"
      ].contains(bundle) ||
      fieldSignal.contains("electron") ||
      appName.contains("electron")
  }

  var safariAddressBar: Bool {
    bundle == "com.apple.safari" &&
      (fieldRole.contains("search") ||
       fieldSignal.contains("address") ||
       fieldSignal.contains("url") ||
       fieldSignal.contains("search"))
  }

  var terminal: Bool {
    bundle == "com.apple.terminal" ||
      bundle == "com.googlecode.iterm2" ||
      bundle == "dev.warp.warp-stable" ||
      bundle == "com.github.wez.wezterm"
  }

  var launcherSearch: Bool {
    bundle == "com.apple.spotlight" ||
      bundle == "com.raycast.macos" ||
      bundle == "com.runningwithcrayons.alfred" ||
      appName.contains("spotlight") ||
      appName.contains("raycast")
  }

  var appKitFriendly: Bool {
    [
      "com.apple.textedit",
      "com.apple.notes",
      "com.apple.mail",
      "com.apple.stickies"
    ].contains(bundle)
  }

  func override(_ capability: FamoClientCapability) -> FamoClientCapabilityDecision? {
    guard !bundle.isEmpty else { return nil }
    if input.workarounds.forceDeniedCapabilitiesByBundleID[bundle]?.contains(capability) == true {
      return FamoClientCapabilityDecision(allowed: false, reason: .userForcedDeny)
    }
    if input.workarounds.forceAllowedCapabilitiesByBundleID[bundle]?.contains(capability) == true {
      return FamoClientCapabilityDecision(allowed: true, reason: .userForcedAllow)
    }
    return nil
  }
}
