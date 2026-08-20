//
//  OwlLiveInputTrace.swift
//  Owltype
//
//  Lazy dev-only trace sink for live input debugging. Disabled tracing must not build strings
//  or call Session status just to discard the result.
//

import Foundation

enum OwlLiveInputTrace {
  static let defaultsKey = "OwlDebugLiveInputTrace"

  static var defaultURL: URL {
    FileManager.default.temporaryDirectory.appending(component: "famo-live-input-trace.log", directoryHint: .notDirectory)
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
    guard isEnabled(defaults: defaults) else { return }
    let line = "\(now()) \(message())\n"
    guard let data = line.data(using: .utf8) else { return }
    if fileManager.fileExists(atPath: fileURL.path),
       let handle = try? FileHandle(forWritingTo: fileURL) {
      defer { try? handle.close() }
      try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: fileURL)
    }
    // Debug traces contain metadata only, but still keep them private to the current macOS user.
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }
}
