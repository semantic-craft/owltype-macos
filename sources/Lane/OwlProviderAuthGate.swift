//
//  OwlProviderAuthGate.swift
//  法墨输入法 (Owltype) — provider auth gate (task 07-06-owl-selection-auth-gate)
//
//  The single seam that turns "the active provider profile" into a usable call configuration —
//  resolved routing (endpoint / model / auth-header / secretName) + a non-empty API key — applying
//  the profile-secret-or-legacy-fallback policy and classifying the not-ready states so callers can
//  react (prompt setup vs prompt for a key). Extracted from three services that each re-derived this
//  ladder verbatim: OwlStreamingChatService (任意提问/AI 窗), OwlSelectionPolishService (划词润色),
//  OwlSourceVerificationService (来源核验).
//
//  Purely value-resolving: no request is issued. The only side effects are the injected Keychain
//  reads, whose failures are swallowed into `.unconfigured`/`.missingKey` (never thrown, never a
//  crash) — mirroring the streaming service's "never crash the AI window" contract.
//

import Foundation

/// The outcome of resolving the active provider into a usable call configuration.
///
/// `Equatable` for test assertions; `: Error` so it can be a `Result` failure type — the streaming
/// service returns it as `Result<Stream, OwlStreamingReadiness>` (see the typealias by the streaming
/// service). `.ready` is the success payload; the other two say why a call can't be made yet.
enum OwlProviderAuthOutcome: Error, Equatable {
  /// Ready to call: resolved routing + a non-empty API key.
  case ready(routing: OwlCloudRouting, apiKey: String)
  /// No active profile AND no usable legacy key — nothing to talk to. Prompt setup.
  case unconfigured
  /// A routing resolved (profile or legacy) but no API key is stored for it yet. Prompt for a key.
  case missingKey
}

/// Resolves the active provider profile into a `OwlProviderAuthOutcome`. A `struct` of injected
/// closures (matching the existing services' DI idiom — not a protocol; there is one implementation
/// with a test-fake seam via the closures). Deep: one method behind which routing resolution, the
/// secret-vs-legacy fallback, Keychain-error swallowing, the empty-key guard, and the
/// unconfigured-vs-missingKey classification all live — logic that was copy-pasted across the three
/// consumers above.
@MainActor
struct OwlProviderAuthGate {
  /// The active provider profile, or nil → legacy globals. Default = live store.
  var profileProvider: () -> OwlProviderProfile?
  /// Reads the per-profile API key by `secretName`. Default = live Keychain.
  var profileSecretProvider: (String) throws -> String?
  /// Reads the legacy DeepSeek key when there is no per-profile `secretName`. `nil` disables the
  /// legacy fallback entirely — source verification passes nil because it requires a configured
  /// modern provider (a legacy DeepSeek key can't do web-search source verification).
  var legacyKeyProvider: (() throws -> String?)?

  init(
    profileProvider: @escaping () -> OwlProviderProfile?,
    profileSecretProvider: @escaping (String) throws -> String?,
    legacyKeyProvider: (() throws -> String?)?
  ) {
    self.profileProvider = profileProvider
    self.profileSecretProvider = profileSecretProvider
    self.legacyKeyProvider = legacyKeyProvider
  }

  /// Resolve the active profile into a call configuration. No network. A Keychain read failure is
  /// treated as "no usable key" (swallowed into `.unconfigured`/`.missingKey`), never thrown.
  /// Deterministic given the injected closures.
  func resolve() -> OwlProviderAuthOutcome {
    let profile = profileProvider()
    let routing = OwlCloudRouting.resolve(profile: profile)

    let rawKey: String?
    do {
      if let secretName = routing.secretName {
        rawKey = try profileSecretProvider(secretName)
      } else if let legacyKeyProvider {
        rawKey = try legacyKeyProvider()
      } else {
        rawKey = nil                                   // no secretName and no legacy fallback (来源核验)
      }
    } catch {
      // A Keychain read failure is "no usable key" — never crash the caller (mirrors streaming).
      return profile == nil ? .unconfigured : .missingKey
    }

    let key = rawKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let apiKey = key, !apiKey.isEmpty else {
      // No profile AND no key → unconfigured; a profile with no key yet → missingKey.
      return profile == nil ? .unconfigured : .missingKey
    }
    return .ready(routing: routing, apiKey: apiKey)
  }
}
