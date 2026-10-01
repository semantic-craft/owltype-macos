import Foundation
import Observation

/// Persists language choices only. Initial app options are fallbacks, never a forced mode.
@Observable
final class OwlAppInputMemory {
  static let shared = OwlAppInputMemory(defaults: OwlDefaults.standard)
  private let defaults: UserDefaults
  private static let enabledKey = "OwlRememberAppInputMode"
  private static let modesKey = "OwlAppInputModes"
  var enabled: Bool {
    didSet { defaults.set(enabled, forKey: Self.enabledKey) }
  }
  private(set) var modes: [String: Bool]

  init(defaults: UserDefaults) {
    self.defaults = defaults
    enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    modes = defaults.dictionary(forKey: Self.modesKey) as? [String: Bool] ?? [:]
  }

  func initialMode(app: String, fallback: Bool) -> Bool {
    enabled ? modes[app] ?? fallback : fallback
  }

  func remember(app: String, ascii: Bool) {
    guard enabled, app.contains("."), !app.hasPrefix("UnknownApp"), modes[app] != ascii else { return }
    modes[app] = ascii
    defaults.set(modes, forKey: Self.modesKey)
  }

  func forget(_ app: String) {
    modes.removeValue(forKey: app)
    defaults.set(modes, forKey: Self.modesKey)
  }
}

/// A controller records actual mode changes, not the fallback used to seed a session.
struct OwlAppModeObservation {
  private(set) var last: Bool?
  mutating func seed(_ ascii: Bool) { last = ascii }
  mutating func changed(to ascii: Bool) -> Bool {
    defer { last = ascii }
    return last != nil && last != ascii
  }
}
