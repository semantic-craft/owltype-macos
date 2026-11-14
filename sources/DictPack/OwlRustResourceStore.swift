//
//  OwlRustResourceStore.swift
//  Owltype
//
//  Direct bundled SQLite resource store. Resolves immutable dictionary and model
//  assets directly under `Bundle.main.sharedSupportURL/msime` and prepares the
//  user's mutable `msime-user` and `msime-cache` directories without staging copies
//  or per-session file leases.
//

import Foundation

struct OwlRustResourceStore: Sendable {
  let userRoot: URL
  let sharedSupportURL: URL?

  init(
    userRoot: URL = OwlApp.userDir,
    sharedSupportURL: URL? = Bundle.main.sharedSupportURL
  ) {
    self.userRoot = userRoot
    self.sharedSupportURL = sharedSupportURL
  }

  var mutableUserDir: URL {
    userRoot.appendingPathComponent("msime-user", isDirectory: true)
  }

  var mutableCacheDir: URL {
    userRoot.appendingPathComponent("msime-cache", isDirectory: true)
  }

  func prepareMutableDirectories() throws {
    for dir in [mutableUserDir, mutableCacheDir] {
      do {
        try FileManager.default.createDirectory(
          at: dir,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
      } catch {
        throw OwlRustResourceError.fileOperationFailed(
          path: dir.path,
          message: error.localizedDescription
        )
      }
    }
  }

  func resolveBundledGeneration() throws -> OwlRustResourceGeneration {
    let generation = try OwlRustCompatibleResources.validateBundledResources(
      sharedSupport: sharedSupportURL
    )
    try prepareMutableDirectories()
    return generation
  }
}
