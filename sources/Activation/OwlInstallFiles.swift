import Foundation
import Darwin
import Security

/// Privileged file phase shared by GUI and package installers through --commit-install.
/// It never touches TIS, user processes, preferences, dictionaries or launchd.
enum OwlInstallFiles {
  /// Where the live App goes and where intermediate copies wait. LaunchServices and the input
  /// menu register bundles they find under Input Methods, including hidden `.Owltype.*`
  /// directories, so candidates and retired contents live in a root-only directory next to
  /// the installer markers instead. It must share the live App's volume for the renames.
  struct Layout {
    let inputMethods: URL
    let work: URL

    static let system = Layout(
      inputMethods: URL(fileURLWithPath: "/Library/Input Methods", isDirectory: true),
      work: URL(fileURLWithPath: "/private/var/db/im.owltype.inputmethod.Owltype-installer/work", isDirectory: true))
  }

  private static let bundleID = "im.owltype.inputmethod.Owltype"

  static func commit(source: URL) throws {
    guard geteuid() == 0 else { throw POSIXError(.EPERM) }
    // New files are created by root; normalize group without following framework symlinks.
    let staff = getgrnam("staff")?.pointee.gr_gid ?? 20
    try commit(source: source, layout: .system, verify: verify) { prepared in
      guard lchown(prepared.path, 0, staff) == 0 else { throw POSIXError(.EPERM) }
      if let entries = FileManager.default.enumerator(at: prepared, includingPropertiesForKeys: nil) {
        for case let entry as URL in entries {
          guard lchown(entry.path, 0, staff) == 0 else { throw POSIXError(.EPERM) }
        }
      }
    }
  }

  /// Validates and commits `source`. On success removes this run's candidate wrapper and the
  /// retired contents; on any failure leaves both under `layout.work` for inspection.
  static func commit(source: URL, layout: Layout, verify: (URL) throws -> Void,
                     normalizeOwnership: (URL) throws -> Void) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: layout.inputMethods, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o755])
    try privateDirectory(layout.work.deletingLastPathComponent(), mode: 0o711)
    try privateDirectory(layout.work, mode: 0o700)
    try requireSameVolume(layout.work, layout.inputMethods)
    let lock = layout.work.appendingPathComponent("install-lock")
    guard mkdir(lock.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { _ = rmdir(lock.path) }
    let job = layout.work.appendingPathComponent("prepared-\(UUID().uuidString)")
    try manager.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let prepared = job.appendingPathComponent("Owltype.app")
    let live = layout.inputMethods.appendingPathComponent("Owltype.app")
    let retired = layout.work.appendingPathComponent("retired-\(UUID().uuidString)")
    // Validate the root-owned copy before executing any operation on the live bundle.
    try manager.copyItem(at: source, to: prepared)
    guard OwlBundleSwap.isCanonical(prepared) else { throw POSIXError(.ELOOP) }
    try verify(prepared)
    let metadata = try info(prepared)
    guard metadata["CFBundleIdentifier"] as? String == bundleID,
          metadata["InputMethodConnectionName"] as? String == "Owltype_Connection" else { throw CocoaError(.fileReadCorruptFile) }
    if manager.fileExists(atPath: live.path), !hasInfo(live) {
      try retainIncomplete(live, layout: layout)
    }
    if manager.fileExists(atPath: live.path) {
      let old = try info(live)
      for key in ["CFBundleIdentifier", "InputMethodConnectionName", "ComponentInputModeDict"] {
        guard let before = old[key] as? NSObject, let after = metadata[key] as? NSObject, before == after else {
          throw CocoaError(.fileReadCorruptFile)
        }
      }
    }
    try normalizeOwnership(prepared)
    try OwlBundleSwap.commitPreparedApp(prepared, to: live, retired: retired) { candidate in
      try verify(candidate)
      guard NSDictionary(dictionary: try info(candidate)).isEqual(to: metadata) else { throw CocoaError(.fileReadCorruptFile) }
    }
    // The commit is validated: old files are only reachable through open descriptors, which
    // keep their inodes. The job holds an empty wrapper after an update, nothing on first install.
    for leftover in [retired, job] where manager.fileExists(atPath: leftover.path) {
      do { try manager.removeItem(at: leftover) } catch {
        fputs("INSTALL_FILES_WARNING: cannot remove \(leftover.path): \(error)\n", stderr)
      }
    }
    print("INSTALL_FILES_OK work=\(layout.work.path)")
  }

  /// Creates `url` if missing; refuses a symlink, a non-directory or another owner.
  private static func privateDirectory(_ url: URL, mode: mode_t) throws {
    if mkdir(url.path, mode) != 0, errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid() else { throw POSIXError(.ELOOP) }
    guard chmod(url.path, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  /// RENAME_SWAP and RENAME_EXCL never cross volumes; fail before touching the live App.
  static func requireSameVolume(_ first: URL, _ second: URL) throws {
    var firstInfo = stat(), secondInfo = stat()
    guard stat(first.path, &firstInfo) == 0, stat(second.path, &secondInfo) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard firstInfo.st_dev == secondInfo.st_dev else { throw POSIXError(.EXDEV) }
  }

  /// GUI and preinstall classify first install versus update with the same test.
  private static func hasInfo(_ app: URL) -> Bool {
    FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path)
  }

  /// A live App without Contents/Info.plist (an app cleaner or a partial manual removal) has
  /// nothing to compare or swap. Keep it for inspection outside Input Methods, never delete it,
  /// and continue as a first install. A symlinked live path is left for the swap to refuse.
  private static func retainIncomplete(_ live: URL, layout: Layout) throws {
    guard OwlBundleSwap.isCanonical(live) else { throw POSIXError(.ELOOP) }
    let retained = layout.work.deletingLastPathComponent().appendingPathComponent("retained")
    try privateDirectory(retained, mode: 0o700)
    try requireSameVolume(retained, layout.inputMethods)
    let target = retained.appendingPathComponent("incomplete-Owltype-\(UUID().uuidString)")
    guard renamex_np(live.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    fputs("INSTALL_FILES_WARNING: moved incomplete \(live.path) to \(target.path)\n", stderr)
  }

  private static func info(_ app: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return result
  }

  private static func verify(_ app: URL) throws {
    var code: SecStaticCode?
    var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
    guard status == errSecSuccess, let code else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil)
    guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
  }
}
