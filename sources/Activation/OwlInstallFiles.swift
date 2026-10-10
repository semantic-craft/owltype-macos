import Foundation
import Darwin
import Security

/// Privileged file phase shared by GUI and package installers through --commit-install.
/// It never touches TIS, user processes, preferences, dictionaries or launchd.
enum OwlInstallFiles {
  private static let root = URL(fileURLWithPath: "/Library/Input Methods", isDirectory: true)
  private static let bundleID = "im.owltype.inputmethod.Owltype"

  static func commit(source: URL) throws {
    guard geteuid() == 0 else { throw POSIXError(.EPERM) }
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    let lock = root.appendingPathComponent(".Owltype.install-lock")
    guard mkdir(lock.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { _ = rmdir(lock.path) }
    let work = root.appendingPathComponent(".Owltype.prepared-\(UUID().uuidString)")
    try manager.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let prepared = work.appendingPathComponent("Owltype.app")
    let live = root.appendingPathComponent("Owltype.app")
    let retired = root.appendingPathComponent(".Owltype.retired-\(UUID().uuidString)")
    // Validate the root-owned copy before executing any operation on the live bundle.
    try manager.copyItem(at: source, to: prepared)
    guard prepared.resolvingSymlinksInPath().path == prepared.path else { throw POSIXError(.ELOOP) }
    try verify(prepared)
    let metadata = try info(prepared)
    guard metadata["CFBundleIdentifier"] as? String == bundleID,
          metadata["InputMethodConnectionName"] as? String == "Owltype_Connection" else { throw CocoaError(.fileReadCorruptFile) }
    if manager.fileExists(atPath: live.path) {
      let old = try info(live)
      for key in ["CFBundleIdentifier", "InputMethodConnectionName", "ComponentInputModeDict"] {
        guard let before = old[key] as? NSObject, let after = metadata[key] as? NSObject, before == after else {
          throw CocoaError(.fileReadCorruptFile)
        }
      }
    }
    // New files are created by root; normalize group without following framework symlinks.
    let staff = getgrnam("staff")?.pointee.gr_gid ?? 20
    guard lchown(prepared.path, 0, staff) == 0 else { throw POSIXError(.EPERM) }
    if let entries = manager.enumerator(at: prepared, includingPropertiesForKeys: nil) {
      for case let entry as URL in entries {
        guard lchown(entry.path, 0, staff) == 0 else { throw POSIXError(.EPERM) }
      }
    }
    try OwlBundleSwap.commitPreparedApp(prepared, to: live, retired: retired) { candidate in
      try verify(candidate)
      guard NSDictionary(dictionary: try info(candidate)).isEqual(to: metadata) else { throw CocoaError(.fileReadCorruptFile) }
    }
    // Work contains only this invocation's empty wrapper after an update, or is empty on first install.
    try? manager.removeItem(at: work)
    print("INSTALL_FILES_OK retired=\(retired.path)")
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
