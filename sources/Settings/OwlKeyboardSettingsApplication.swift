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
  let activeSchema: () -> String
  let refresh: () -> Void

  func apply(_ snapshot: OwlKeyboardSnapshot, mode: Mode) throws -> Outcome {
    // Do not overwrite migration inputs while their rollback journal is unresolved.
    guard !OwlTemplateMigration.hasPendingRecovery(rimeDir: directory) else {
      throw Failure.recoveryPending
    }
    let written = try OwlManagedKeyboardPatchPlan.apply(
      snapshot: snapshot, writer: OwlConfigWriter(rimeDir: directory)
    )
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
      // Config tasks complete synchronously, including the untracked frontend config.
      var deployed = engine.deployConfigFile("default.yaml", versionKey: "config_version")
      deployed = engine.deployConfigFile(OwlRimeIdentity.configFile, versionKey: "config_version") && deployed
      let schema = activeSchema()
      if !schema.isEmpty, schema.first != "." {
        deployed = engine.deployConfigFile("\(schema).schema.yaml", versionKey: "schema/version") && deployed
      }
      succeeded = deployed
    case .fuzzy:
      succeeded = engine.startMaintenance(fullCheck: false)
      // The prism must be ready before a live session reads it.
      if succeeded { engine.joinMaintenance() }
    }
    refresh()
    return Outcome(written: written, succeeded: succeeded)
  }
}
