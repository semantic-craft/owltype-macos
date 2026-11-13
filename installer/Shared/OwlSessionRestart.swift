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

    /// The mode whose enabled bit the probe reads: the selection target, else the primary mode.
    var probeMode: String { selectionTarget ?? OwlSessionRestart.primarySource }
  }

  struct Server: Equatable, Codable {
    let pid: Int32
    let executable: String
    let version: String
    let mapsInstalledExecutable: Bool
  }

  struct Observation: Equatable, Codable {
    let parentEnabled: Bool
    let modeEnabled: Bool
    let selectedSource: String
    let servers: [Server]
  }

  enum Failure: Error, Equatable {
    case notUserSession
    case missingContext
    case oldProcessDidNotExit
    case inputSourceNotEnabled
    case selfCheckTimedOut
  }

  /// The step the sequence is executing. Effects learn each transition through `didEnter`, so an
  /// error thrown by any step can be attributed to it afterwards (#207).
  enum Stage: String, Codable {
    case stopOldProcesses
    case enable
    case select
    case launch
    case verify
  }

  /// One condition of the self-check that an observation did not meet.
  enum Unmet: String, Codable, Equatable {
    case sourceNotEnabled
    case selectedSourceDiffers
    case noServer
    case multipleServers
    case serverOutsideInstalledApp
    case serverVersionDiffers
    case serverMapsOtherExecutable
  }

  /// What a failed sequence leaves behind: the step that threw, the error, and the conditions the
  /// last observation missed, so a timeout says which evidence never arrived. The installer log,
  /// the App's recovery guidance and the support bundle all read this.
  struct Diagnosis: Codable, Equatable {
    let stage: Stage
    let reason: String
    let unmet: [Unmet]
    let lastObservation: Observation?
    let firstInstall: Bool
    let expectedSource: String
    let expectedVersion: String
    let probeMode: String

    var summary: String {
      var text = "阶段「\(OwlSessionRestart.label(stage))」失败：\(OwlSessionRestart.label(reason: reason))"
      if !unmet.isEmpty {
        text += "；未满足：" + OwlSessionRestart.describe(unmet: unmet, observation: lastObservation,
                                                      expectedSource: expectedSource, expectedVersion: expectedVersion)
      }
      return text
    }
  }

  /// pgrep arguments for this user's server processes. pgrep leaves out its own ancestors unless
  /// given `-a`, and the App re-checking itself before recovery guidance is the probe's parent
  /// (#207); the probe drops the driver and itself from the result.
  static func serverQuery(uid: uid_t, name: String = "Owltype") -> [String] {
    ["-a", "-U", "\(uid)", "-x", name]
  }

  static func mapsInstalledExecutable(_ lsof: String, inode: UInt64) -> Bool {
    maps(lsof, path: installedExecutable, inode: inode)
  }

  /// True when one text record of `lsof -F fin` names both this path and this inode.
  static func maps(_ lsof: String, path: String, inode: UInt64) -> Bool {
    lsof.components(separatedBy: "ftxt\n").dropFirst().contains { record in
      let fields = record.components(separatedBy: .newlines)
      return fields.contains("n\(path)") && fields.contains("i\(inode)")
    }
  }

  /// One server as the kernel and its bundle describe it. No LaunchServices text (#207): on a
  /// tester's Mac `lsappinfo info -only` gave neither path nor version in the layout macOS 27
  /// prints, so a healthy update failed its self-check.
  static func server(pid: Int32, mapping: String, installedInode: UInt64) -> Server {
    let executable = executablePath(of: pid)
    return Server(pid: pid, executable: executable, version: bundleVersion(of: executable, mapping: mapping),
                  mapsInstalledExecutable: installedInode != 0 && mapsInstalledExecutable(mapping, inode: installedInode))
  }

  /// proc_pidpath; empty once the process has exited.
  static func executablePath(of pid: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
    return String(cString: buffer)
  }

  /// CFBundleVersion of the bundle around `executable`, read only while the process maps the file
  /// now at that path: a bundle replaced since launch describes some other binary.
  static func bundleVersion(of executable: String, mapping: String) -> String {
    var file = stat()
    guard !executable.isEmpty, stat(executable, &file) == 0,
          maps(mapping, path: executable, inode: UInt64(file.st_ino)) else { return "" }
    let contents = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent()
    return NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist"))?["CFBundleVersion"] as? String ?? ""
  }

  /// Conditions the running server must meet whatever is selected. The App re-checks exactly
  /// these before it shows recovery guidance, with the same probe the installer used.
  static func unmetServerConditions(_ observation: Observation, expectedVersion: String) -> [Unmet] {
    var unmet: [Unmet] = []
    if !(observation.parentEnabled && observation.modeEnabled) { unmet.append(.sourceNotEnabled) }
    switch observation.servers.count {
    case 0:
      unmet.append(.noServer)
    case 1:
      let server = observation.servers[0]
      if server.pid <= 0 { unmet.append(.noServer) }
      if server.executable != installedExecutable { unmet.append(.serverOutsideInstalledApp) }
      if server.version != expectedVersion { unmet.append(.serverVersionDiffers) }
      if !server.mapsInstalledExecutable { unmet.append(.serverMapsOtherExecutable) }
    default:
      unmet.append(.multipleServers)
    }
    return unmet
  }

  /// Every condition the self-check requires; an empty result is a passed check.
  static func unmetConditions(_ observation: Observation, request: Request) -> [Unmet] {
    let server = unmetServerConditions(observation, expectedVersion: request.expectedVersion)
    guard observation.selectedSource != request.expectedSource else { return server }
    return server.filter { $0 == .sourceNotEnabled } + [.selectedSourceDiffers]
      + server.filter { $0 != .sourceNotEnabled }
  }

  /// Attribute a thrown error to the stage that was running. Before the launch step no server is
  /// expected, so only the enable condition is reported there.
  static func diagnose(_ error: Error, request: Request, stage: Stage,
                       lastObservation: Observation?) -> Diagnosis {
    var unmet = lastObservation.map { unmetConditions($0, request: request) } ?? []
    switch stage {
    case .stopOldProcesses: unmet = []
    case .enable: unmet = unmet.filter { $0 == .sourceNotEnabled }
    case .select, .launch, .verify: break
    }
    return Diagnosis(stage: stage, reason: "\(error)", unmet: unmet, lastObservation: lastObservation,
                     firstInstall: request.firstInstall, expectedSource: request.expectedSource,
                     expectedVersion: request.expectedVersion, probeMode: request.probeMode)
  }

  static func label(_ stage: Stage) -> String {
    switch stage {
    case .stopOldProcesses: return "结束旧进程"
    case .enable: return "等待启用输入源"
    case .select: return "恢复选中的输入法"
    case .launch: return "启动已安装的法墨"
    case .verify: return "核验会话"
    }
  }

  static func label(reason: String) -> String {
    switch reason {
    case "notUserSession": return "不在用户登录会话中（notUserSession）"
    case "missingContext": return "缺少安装上下文（missingContext）"
    case "oldProcessDidNotExit": return "旧进程没有退出（oldProcessDidNotExit）"
    case "inputSourceNotEnabled": return "等待启用超时（inputSourceNotEnabled）"
    case "selfCheckTimedOut": return "自检超时（selfCheckTimedOut）"
    default: return reason
    }
  }

  /// Chinese, one clause per condition, with the observed value beside the expected one.
  static func describe(unmet: [Unmet], observation: Observation?, expectedSource: String,
                       expectedVersion: String) -> String {
    guard !unmet.isEmpty else { return "全部条件已满足" }
    let server = observation?.servers.count == 1 ? observation?.servers[0] : nil
    return unmet.map { condition -> String in
      switch condition {
      case .sourceNotEnabled:
        let parent = observation?.parentEnabled == true ? "已" : "未"
        let mode = observation?.modeEnabled == true ? "已" : "未"
        return "输入源未启用（父源\(parent)启用，模式\(mode)启用）"
      case .selectedSourceDiffers:
        return "选中的输入法与安装前不同（预期 \(expectedSource)，实际 \(observation?.selectedSource ?? "?")）"
      case .noServer:
        return "没有运行中的法墨进程"
      case .multipleServers:
        let pids = (observation?.servers ?? []).map { String($0.pid) }.joined(separator: "、")
        return "法墨进程不止一个（pid \(pids)）"
      case .serverOutsideInstalledApp:
        return "运行中的法墨不在 /Library/Input Methods（\(server?.executable ?? "?")）"
      case .serverVersionDiffers:
        return "运行中的版本为 \(server?.version ?? "?")，预期 \(expectedVersion)"
      case .serverMapsOtherExecutable:
        return "进程映射的不是刚安装的可执行文件"
      }
    }.joined(separator: "；")
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
    /// Called at every stage transition, before that stage's first effect.
    func didEnter(_ stage: Stage)
  }

  /// Successful self-check is process/TIS evidence only; real host typing remains a native test.
  /// Waiting for the user's enable consent spends `consentTimeout`, not the self-check budget.
  /// An update that finds the source disabled (an earlier first install whose consent never
  /// arrived) requests enabling once, so retrying the installer can recover.
  @discardableResult
  static func run(_ request: Request, effects: Effects, timeout: TimeInterval = 45,
                  consentTimeout: TimeInterval = 120) throws -> Server {
    guard effects.isUserSession else { throw Failure.notUserSession }
    guard !request.expectedVersion.isEmpty,
          request.firstInstall || !request.sourceBefore.isEmpty else { throw Failure.missingContext }
    let started = effects.uptime
    effects.didEnter(.stopOldProcesses)
    try effects.stopOldProcesses(force: false)
    var forced = false
    while try effects.oldProcessesRemain() {
      guard effects.uptime < started + 5 else { throw Failure.oldProcessDidNotExit }
      if !forced, effects.uptime >= started + 2 {
        try effects.stopOldProcesses(force: true)
        forced = true
      }
      effects.pause()
    }
    effects.didEnter(.enable)
    if request.firstInstall { try effects.registerAndEnableParentAndMode() }

    var enableRequested = request.firstInstall
    let consentDeadline = effects.uptime + consentTimeout
    var observation = try effects.observe()
    while !(observation.parentEnabled && observation.modeEnabled) {
      if !enableRequested {
        try effects.registerAndEnableParentAndMode()
        enableRequested = true
      }
      guard effects.uptime < consentDeadline else { throw Failure.inputSourceNotEnabled }
      effects.pause()
      observation = try effects.observe()
    }

    let deadline = effects.uptime + timeout
    var refreshed = false
    while effects.uptime < deadline {
      if let target = request.selectionTarget, observation.selectedSource != target {
        effects.didEnter(.select)
        try effects.selectSource(target)
        // Selection's return status is not a readback. Wait for a fresh observation.
      } else if !refreshed {
        effects.didEnter(.launch)
        try effects.refreshTextInputServices()
        try effects.launchInstalledApp()
        refreshed = true
      } else {
        effects.didEnter(.verify)
        if unmetConditions(observation, request: request).isEmpty, let server = observation.servers.first {
          return server
        }
      }
      effects.pause()
      observation = try effects.observe()
    }
    throw Failure.selfCheckTimedOut
  }
}

extension OwlSessionRestart.Effects {
  func didEnter(_ stage: OwlSessionRestart.Stage) {}
}
