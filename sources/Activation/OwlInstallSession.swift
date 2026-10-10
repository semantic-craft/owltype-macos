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

  var isUserSession: Bool {
    var console = stat()
    return geteuid() != 0 && getuid() == geteuid()
      && stat("/dev/console", &console) == 0 && console.st_uid == getuid()
  }
  var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

  init(mode: String) {
    self.mode = mode
    oldProcesses = NSRunningApplication.runningApplications(withBundleIdentifier: Self.parentID)
      .filter { $0.processIdentifier != getpid() && !$0.isTerminated && $0.bundleURL?.path == Self.appPath }
  }

  static func finish(firstInstall: Bool, sourceBefore: String, version: String) throws {
    guard Bundle.main.bundleURL.standardizedFileURL.path == appPath,
          Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == version else {
      throw CocoaError(.executableNotLoadable)
    }
    let request = OwlSessionRestart.Request(firstInstall: firstInstall, sourceBefore: sourceBefore, expectedVersion: version)
    let session = OwlInstallSession(mode: request.selectionTarget ?? OwlSessionRestart.primarySource)
    let server = try OwlSessionRestart.run(request, effects: session)
    print("INSTALL_SESSION_OK pid=\(server.pid) version=\(server.version)")
  }

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
    return try JSONDecoder().decode(OwlSessionRestart.Observation.self, from: Data(output.utf8))
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
    let output = try command("/usr/bin/pgrep", ["-U", "\(getuid())", "-x", "Owltype"], acceptedStatuses: [0, 1])
    let pids = output.split(whereSeparator: \.isNewline).compactMap { Int32($0) }.filter { $0 != driver && $0 != getpid() }
    let attributes = try FileManager.default.attributesOfItem(atPath: OwlSessionRestart.installedExecutable)
    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    var servers: [OwlSessionRestart.Server] = []
    // Multiple servers already fail the self-check; avoid an unbounded per-PID command loop.
    if pids.count == 1, let pid = pids.first {
      let mapping = try command("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "txt", "-F", "fin"], acceptedStatuses: [0, 1])
      let info = try command("/usr/bin/lsappinfo", ["info", "-only", "executablepath,CFBundleVersion", "\(pid)"])
      func value(_ key: String) -> String {
        guard let range = info.range(of: key + "=\"") else { return "" }
        return String(info[range.upperBound...].prefix { $0 != "\"" })
      }
      servers = [.init(pid: pid, executable: value("executable path"), version: value("Version"),
                       mapsInstalledExecutable: inode != 0 && OwlSessionRestart.mapsInstalledExecutable(mapping, inode: inode))]
    } else {
      servers = pids.map { .init(pid: $0, executable: "", version: "", mapsInstalledExecutable: false) }
    }
    let observation = OwlSessionRestart.Observation(parentEnabled: parentEnabled, modeEnabled: source(mode, all: false) != nil,
      selectedSource: OwlInstaller.currentInputSourceID() ?? "", servers: servers)
    return String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
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

  /// A file-backed stdout prevents pipe deadlocks. Commands contain no credentials and have
  /// bounded runtimes; timeout never becomes a successful probe.
  private static func command(_ path: String, _ arguments: [String], timeout: TimeInterval = 2,
                              acceptedStatuses: Set<Int32> = [0]) throws -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owl-install-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("output")
    FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = handle
    process.standardError = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    guard finished.wait(timeout: .now() + timeout) == .success else {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      _ = finished.wait(timeout: .now() + 1)
      throw CocoaError(.executableRuntimeMismatch)
    }
    guard acceptedStatuses.contains(process.terminationStatus) else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(process.terminationStatus), userInfo: [NSFilePathErrorKey: path])
    }
    return try String(contentsOf: output, encoding: .utf8)
  }
}
