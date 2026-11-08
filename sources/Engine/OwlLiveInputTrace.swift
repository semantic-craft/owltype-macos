//
//  OwlLiveInputTrace.swift
//  Owltype
//
//  Lazy dev-only trace sink for live input debugging. Disabled tracing must not build strings
//  or call Session status just to discard the result.
//

import Darwin
import Foundation

enum OwlLiveInputTrace {
  static let defaultsKey = "OwlDebugLiveInputTrace"

  static var defaultURL: URL {
    FileManager.default.temporaryDirectory.appending(component: "owl-live-input-trace.log", directoryHint: .notDirectory)
  }

  static func isEnabled(defaults: UserDefaults = OwlDefaults.standard) -> Bool {
    defaults.bool(forKey: defaultsKey)
  }

  static func write(
    _ message: () -> String,
    defaults: UserDefaults = OwlDefaults.standard,
    fileURL: URL = defaultURL,
    now: () -> Date = Date.init,
    fileManager: FileManager = .default
  ) {
    _ = fileManager
    guard isEnabled(defaults: defaults) else { return }
    let line = "\(now()) \(message())\n"
    guard let data = line.data(using: .utf8) else { return }
    // Debug traces contain metadata only; open with O_NOFOLLOW and 0600 permissions so
    // temporary-directory symlinks are rejected and the file is never world-readable.
    let descriptor = fileURL.path.withCString { cPath in
      open(cPath, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    }
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    var fileStat = stat()
    guard fstat(descriptor, &fileStat) == 0,
          (fileStat.st_mode & S_IFMT) == S_IFREG,
          fileStat.st_uid == geteuid() else {
      return
    }
    _ = fchmod(descriptor, mode_t(0o600))
    data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress, buffer.count > 0 else { return }
      _ = Darwin.write(descriptor, base, buffer.count)
    }
  }
}
