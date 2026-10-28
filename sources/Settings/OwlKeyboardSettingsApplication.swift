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

  let engine: RimeEngine
  let directory: URL
  let refresh: () -> Void

  init(
    engine: RimeEngine,
    directory: URL,
    refresh: @escaping () -> Void
  ) {
    self.engine = engine
    self.directory = directory
    self.refresh = refresh
  }

  /// The engine reads keyboard preferences from defaults, so applying writes no Rime files:
  /// `written` is always empty and `snapshot` is not read.
  func apply(_ snapshot: OwlKeyboardSnapshot, mode: Mode) throws -> Outcome {
    // Do not overwrite migration inputs while their rollback journal is unresolved.
    guard !OwlTemplateMigration.hasPendingRecovery(rimeDir: directory) else {
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
    let succeeded: Bool
    switch mode {
    case .config:
      succeeded = engine.deployConfigFile("default.yaml", versionKey: "config_version")
    case .fuzzy:
      succeeded = engine.startMaintenance(fullCheck: false)
      // The prism must be ready before a live session reads it.
      if succeeded { engine.joinMaintenance() }
    }
    refresh()
    return Outcome(written: [], succeeded: succeeded)
  }
}
