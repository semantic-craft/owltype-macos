import AppKit
import Carbon
import Darwin

/// CLI session driver in the installed, signed IME. The GUI and PKG launch this as the
/// console user after file validation. Fresh subprocesses prevent cached TIS readbacks.
final class OwlInstallSession: OwlSessionRestart.Effects {
  private static let appPath = "/Library/Input Methods/Owltype.app"
  private static let parentID = "im.owltype.inputmethod.Owltype"
  private let oldProcesses: [NSRunningApplication]
  private let mode: String
  /// #207: the step in progress and the last probe result, so a failure can say what it saw.
  private(set) var stage: OwlSessionRestart.Stage = .stopOldProcesses
  private(set) var lastObservation: OwlSessionRestart.Observation?

  /// The sequence's error together with its diagnosis. `description` stays the bare error so the
  /// first `INSTALL_SESSION_FAILED` line keeps the form the GUI and the lessons match on.
  struct SessionFailure: Error, CustomStringConvertible {
    let error: Error
    let diagnosis: OwlSessionRestart.Diagnosis
    var description: String { "\(error)" }
  }

  /// How a helper command failed: it did not finish, or it exited outside its accepted statuses.
  enum CommandFailure {
    case timedOut(seconds: TimeInterval)
    case exited(status: Int32)
  }

  /// Names the command and carries its stderr so the diagnosis says which step broke, not just
  /// that one did.
  struct CommandError: Error, CustomStringConvertible {
    let command: String
    let failure: CommandFailure
    let stderr: String

    var description: String {
      switch failure {
      case .timedOut(let seconds): return "\(command) 超过 \(Int(seconds)) 秒未结束"
      case .exited(let status): return "\(command) 退出码 \(status)" + (stderr.isEmpty ? "" : "：\(stderr)")
      }
    }
  }

  var isUserSession: Bool {
    var console = stat()
    return geteuid() != 0 && getuid() == geteuid()
      && stat("/dev/console", &console) == 0 && console.st_uid == getuid()
  }
  var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

  init(mode: String) {
    self.mode = mode
    // Any copy claiming the id counts as old, including one left by an incomplete removal;
    // the probe counts every Owltype process, so a survivor elsewhere would fail the check.
    oldProcesses = NSRunningApplication.runningApplications(withBundleIdentifier: Self.parentID)
      .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
  }

  static func finish(firstInstall: Bool, sourceBefore: String, version: String) throws {
    guard Bundle.main.bundleURL.standardizedFileURL.path == appPath,
          Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == version else {
      throw CocoaError(.executableNotLoadable)
    }
    let request = OwlSessionRestart.Request(firstInstall: firstInstall, sourceBefore: sourceBefore, expectedVersion: version)
    let session = OwlInstallSession(mode: request.probeMode)
    guard session.isUserSession else { throw OwlSessionRestart.Failure.notUserSession }
    // Discard a previous attempt's pending guidance before launching the new server.
    Self.reportSelfCheck(current: version, passed: true, diagnosis: nil)
    do {
      let server = try OwlSessionRestart.run(request, effects: session)
      Self.reportSelfCheck(current: version, passed: true, diagnosis: nil)
      print("INSTALL_SESSION_OK pid=\(server.pid) version=\(server.version)")
    } catch {
      let diagnosis = OwlSessionRestart.diagnose(error, request: request, stage: session.stage,
                                                 lastObservation: session.lastObservation)
      Self.reportSelfCheck(current: version, passed: false, diagnosis: diagnosis)
      throw SessionFailure(error: error, diagnosis: diagnosis)
    }
  }

  private static func reportSelfCheck(current: String, passed: Bool, diagnosis: OwlSessionRestart.Diagnosis?) {
    OwlUpdateLogoutPrompt.recordSelfCheck(current: current, passed: passed, diagnosis: diagnosis)
    DistributedNotificationCenter.default().postNotificationName(OwlUpdateLogoutPrompt.selfCheckNotification,
      object: current, userInfo: nil, deliverImmediately: true)
  }

  /// The App's re-check before recovery guidance (#207): the same probe and the same server
  /// conditions as the installer's self-check, minus the selection requirement, which the user
  /// may have changed on purpose since. Runs a subprocess; call it off the main thread.
  static func recheck(expectedVersion: String, mode: String) throws -> (unmet: [OwlSessionRestart.Unmet],
                                                                          observation: OwlSessionRestart.Observation) {
    let output = try command(OwlSessionRestart.installedExecutable, ["--install-session-probe", "0", mode], timeout: 8)
    let observation = try JSONDecoder().decode(OwlSessionRestart.Observation.self, from: Data(output.utf8))
    return (OwlSessionRestart.unmetServerConditions(observation, expectedVersion: expectedVersion), observation)
  }

  func didEnter(_ stage: OwlSessionRestart.Stage) { self.stage = stage }

  func pause() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25)) }

  func stopOldProcesses(force: Bool) throws {
    for process in oldProcesses where !process.isTerminated {
      // NSRunningApplication retains the process instance in the current user's workspace.
      // The sequence rejects root before reaching these methods.
      if force { _ = process.forceTerminate() } else { _ = process.terminate() }
    }
  }

  func oldProcessesRemain() throws -> Bool { oldProcesses.contains { !$0.isTerminated } }

  func registerAndEnableParentAndMode() throws {
    _ = try Self.command(OwlSessionRestart.installedExecutable, ["--install-session-enable"], timeout: 5)
  }

  func observe() throws -> OwlSessionRestart.Observation {
    let output = try Self.command(OwlSessionRestart.installedExecutable,
                                  ["--install-session-probe", "\(getpid())", mode], timeout: 8)
    let observation = try JSONDecoder().decode(OwlSessionRestart.Observation.self, from: Data(output.utf8))
    lastObservation = observation
    return observation
  }

  func selectSource(_ source: String) throws {
    _ = try Self.command(OwlSessionRestart.installedExecutable, ["--select-input-source", source])
  }

  func refreshTextInputServices() throws {
    _ = try Self.command("/usr/bin/killall", ["-u", NSUserName(), "-9", "TextInputMenuAgent", "TextInputSwitcher"],
                         acceptedStatuses: [0, 1])
  }

  func launchInstalledApp() throws {
    _ = try Self.command("/usr/bin/open", ["-g", Self.appPath])
  }

  static func enableForFirstInstall() throws {
    let session = OwlInstallSession(mode: OwlSessionRestart.primarySource)
    guard session.isUserSession, Bundle.main.bundleURL.standardizedFileURL.path == appPath else {
      throw OwlSessionRestart.Failure.notUserSession
    }
    try check(TISRegisterInputSource(URL(fileURLWithPath: appPath) as CFURL))
    let deadline = session.uptime + 3
    while source(parentID, all: true) == nil || source(OwlSessionRestart.primarySource, all: true) == nil {
      guard session.uptime < deadline else { throw OwlSessionRestart.Failure.selfCheckTimedOut }
      session.pause()
    }
    guard let parent = source(parentID, all: true) else { throw OwlSessionRestart.Failure.missingContext }
    try check(TISEnableInputSource(parent))
    guard let mode = source(OwlSessionRestart.primarySource, all: true) else { throw OwlSessionRestart.Failure.missingContext }
    try check(TISEnableInputSource(mode))
  }

  /// Read-only child process. Exclude both the driver and this probe from the server list.
  static func probe(excluding driver: Int32, mode: String) throws -> String {
    let parent = source(parentID, all: true)
    let parentEnabled = parent.flatMap { TISGetInputSourceProperty($0, kTISPropertyInputSourceIsEnabled) }
      .map { CFBooleanGetValue(unsafeBitCast($0, to: CFBoolean.self)) } ?? false
    let output = try command("/usr/bin/pgrep", OwlSessionRestart.serverQuery(uid: getuid()), acceptedStatuses: [0, 1])
    let pids = output.split(whereSeparator: \.isNewline).compactMap { Int32($0) }.filter { $0 != driver && $0 != getpid() }
    let attributes = try FileManager.default.attributesOfItem(atPath: OwlSessionRestart.installedExecutable)
    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    var servers: [OwlSessionRestart.Server] = []
    // Multiple servers already fail the self-check; avoid an unbounded per-PID command loop.
    if pids.count == 1, let pid = pids.first {
      let mapping = try command("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "txt", "-F", "fin"], acceptedStatuses: [0, 1])
      servers = [OwlSessionRestart.server(pid: pid, mapping: mapping, installedInode: inode)]
    } else {
      servers = pids.map { .init(pid: $0, executable: "", version: "", mapsInstalledExecutable: false) }
    }
    let observation = OwlSessionRestart.Observation(parentEnabled: parentEnabled, modeEnabled: source(mode, all: false) != nil,
      selectedSource: OwlInstaller.currentInputSourceID() ?? "", servers: servers)
    guard let json = String(data: try JSONEncoder().encode(observation), encoding: .utf8) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return json
  }

  private static func source(_ identifier: String, all: Bool) -> TISInputSource? {
    guard let list = TISCreateInputSourceList(nil, all)?.takeRetainedValue() as? [TISInputSource] else { return nil }
    return list.first { item in
      guard let value = TISGetInputSourceProperty(item, kTISPropertyInputSourceID) else { return false }
      return unsafeBitCast(value, to: CFString.self) as String == identifier
    }
  }

  private static func check(_ result: OSStatus) throws {
    if result != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
  }

  /// File-backed stdout and stderr prevent pipe deadlocks. Commands contain no credentials and
  /// have bounded runtimes; timeout never becomes a successful probe. A failure names the command
  /// and keeps the start of its stderr for the diagnosis.
  private static func command(_ path: String, _ arguments: [String], timeout: TimeInterval = 2,
                              acceptedStatuses: Set<Int32> = [0]) throws -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owl-install-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("output")
    let errors = directory.appendingPathComponent("stderr")
    for file in [output, errors] {
      FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    let outputHandle = try FileHandle(forWritingTo: output)
    let errorHandle = try FileHandle(forWritingTo: errors)
    defer {
      try? outputHandle.close()
      try? errorHandle.close()
    }
    let name = (path as NSString).lastPathComponent + (arguments.first.map { " \($0)" } ?? "")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = outputHandle
    process.standardError = errorHandle
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    guard finished.wait(timeout: .now() + timeout) == .success else {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      _ = finished.wait(timeout: .now() + 1)
      throw CommandError(command: name, failure: .timedOut(seconds: timeout), stderr: "")
    }
    guard acceptedStatuses.contains(process.terminationStatus) else {
      let stderr = (try? String(contentsOf: errors, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines).prefix(300) ?? ""
      throw CommandError(command: name, failure: .exited(status: process.terminationStatus), stderr: String(stderr))
    }
    return try String(contentsOf: output, encoding: .utf8)
  }
}
