import Foundation

/// Runs only after the installed App has been exchanged, retired contents moved out, and
/// its signature checked. File operations belong to the privileged caller, never this sequence.
/// Both installer front ends supply user-session effects; tests supply a simulated session.
enum OwlSessionRestart {
  static let primarySource = "im.owltype.inputmethod.Owltype.Hans"
  static let installedExecutable = "/Library/Input Methods/Owltype.app/Contents/MacOS/Owltype"

  struct Request {
    let firstInstall: Bool
    let sourceBefore: String
    let expectedVersion: String

    var selectionTarget: String? {
      if firstInstall { return OwlSessionRestart.primarySource }
      return sourceBefore == "im.owltype.inputmethod.Owltype.Hans"
        || sourceBefore == "im.owltype.inputmethod.Owltype.Hant" ? sourceBefore : nil
    }

    var expectedSource: String { selectionTarget ?? sourceBefore }
  }

  struct Server: Equatable, Codable {
    let pid: Int32
    let executable: String
    let version: String
    let mapsInstalledExecutable: Bool
  }

  struct Observation: Codable {
    let parentEnabled: Bool
    let modeEnabled: Bool
    let selectedSource: String
    let servers: [Server]
  }

  enum Failure: Error, Equatable {
    case notUserSession
    case missingContext
    case oldProcessDidNotExit
    case selfCheckTimedOut
  }

  static func mapsInstalledExecutable(_ lsof: String, inode: UInt64) -> Bool {
    lsof.components(separatedBy: "ftxt\n").dropFirst().contains { record in
      let fields = record.components(separatedBy: .newlines)
      return fields.contains("n\(installedExecutable)") && fields.contains("i\(inode)")
    }
  }

  /// All effects must be bounded. stopOldProcesses checks identity/ownership before signaling;
  /// observations exclude the probing CLI itself and read fresh TIS/runtime state.
  protocol Effects {
    var isUserSession: Bool { get }
    var uptime: TimeInterval { get }
    func pause()
    func stopOldProcesses(force: Bool) throws
    func oldProcessesRemain() throws -> Bool
    func registerAndEnableParentAndMode() throws
    func observe() throws -> Observation
    func selectSource(_ source: String) throws
    func refreshTextInputServices() throws
    func launchInstalledApp() throws
  }

  /// Successful self-check is process/TIS evidence only; real host typing remains a native test.
  @discardableResult
  static func run(_ request: Request, effects: Effects, timeout: TimeInterval = 45) throws -> Server {
    guard effects.isUserSession else { throw Failure.notUserSession }
    guard !request.expectedVersion.isEmpty,
          request.firstInstall || !request.sourceBefore.isEmpty else { throw Failure.missingContext }
    let started = effects.uptime
    let deadline = started + timeout
    try effects.stopOldProcesses(force: false)
    var forced = false
    while try effects.oldProcessesRemain() {
      guard effects.uptime < min(started + 5, deadline) else { throw Failure.oldProcessDidNotExit }
      if !forced, effects.uptime >= started + 2 {
        try effects.stopOldProcesses(force: true)
        forced = true
      }
      effects.pause()
    }
    if request.firstInstall { try effects.registerAndEnableParentAndMode() }

    var refreshed = false
    while effects.uptime < deadline {
      let observation = try effects.observe()
      guard effects.uptime < deadline else { throw Failure.selfCheckTimedOut }
      if observation.parentEnabled && observation.modeEnabled {
        if let target = request.selectionTarget, observation.selectedSource != target {
          try effects.selectSource(target)
          // Selection's return status is not a readback. Wait for a fresh observation.
        } else if !refreshed {
          try effects.refreshTextInputServices()
          try effects.launchInstalledApp()
          refreshed = true
        } else if observation.selectedSource == request.expectedSource,
                  observation.servers.count == 1,
                  let server = observation.servers.first,
                  server.pid > 0,
                  server.executable == installedExecutable,
                  server.version == request.expectedVersion,
                  server.mapsInstalledExecutable {
          return server
        }
      }
      effects.pause()
    }
    throw Failure.selfCheckTimedOut
  }
}
