import Foundation

/// The complete managed-settings application, shared by settings and onboarding.
/// The Rime adapter and temporary directory are the same seams used by behaviour tests.
struct OwlKeyboardSettingsApplication {
  enum Mode { case config, fuzzy }

  struct Outcome {
    let written: [String]
    let succeeded: Bool
  }

  enum Failure: LocalizedError {
    case recoveryPending
    var errorDescription: String? { "快捷片段恢复尚未完成，请先完成恢复再应用配置。" }
  }

  let engine: OwlRustEngine
  let refresh: () -> Void

  init(
    engine: OwlRustEngine,
    directory _: URL,
    refresh: @escaping () -> Void
  ) {
    self.engine = engine
    self.refresh = refresh
  }

  /// The engine reads keyboard preferences from defaults, so applying writes no Rime files:
  /// `written` is always empty.
  func apply(mode: Mode) throws -> Outcome {
    let plan: OwlAppCore.KeyboardApplication = OwlAppCore.required([
      "operation": "keyboard_application", "mode": mode == .config ? "config" : "fuzzy",
      "recovery_pending": false])
    guard !plan.blocked else {
      throw Failure.recoveryPending
    }
    // Keep the existing activation-only diagnostics; persistence precedes this interval.
    let traceName: StaticString = mode == .config ? "deploy.fast.config" : "deploy.fast.fuzzy"
    let trace = OwlLatencyTrace.begin(traceName)
    let performance = OwlPerf.mark()
    defer {
      OwlPerf.since(performance, mode == .config ? "fastapply.config" : "fastapply.fuzzy")
      OwlLatencyTrace.end(traceName, trace)
    }
    var succeeded = true
    for effect in plan.effects {
      switch effect {
      case "deploy": succeeded = engine.deployConfigFile("default.yaml", versionKey: "config_version")
      case "maintenance": succeeded = engine.startMaintenance(fullCheck: false)
      case "join_if_succeeded": if succeeded { engine.joinMaintenance() }
      case "refresh": refresh()
      default: preconditionFailure("Incompatible keyboard application plan")
      }
    }
    return Outcome(written: [], succeeded: succeeded)
  }
}
