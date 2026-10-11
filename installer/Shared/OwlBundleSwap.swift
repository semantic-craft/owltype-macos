import Darwin
import Foundation

/// File replacement only. Callers own signature/identity checks, staging, session restart,
/// and removal of retired contents after acceptance. Never falls back to two moves or copy.
/// The caller must serialize installers and keep these directories protected from other writers.
enum OwlBundleSwap {
  struct Exchange {
    let installedContents: URL
    let retiredContents: URL
  }

  /// Keeps the App directory itself (including its permissions and extended attributes).
  /// On success old files remain at .Contents.update; open descriptors still refer to old inodes.
  /// Calling again exchanges them back. On syscall failure neither directory is changed.
  @discardableResult
  static func exchangeContents(in app: URL) throws -> Exchange {
    try requireCanonicalDirectory(app)
    let live = app.appendingPathComponent("Contents", isDirectory: true)
    let staged = app.appendingPathComponent(".Contents.update", isDirectory: true)
    let liveInfo = try directoryInfo(live)
    let stagedInfo = try directoryInfo(staged)
    guard liveInfo.st_dev == stagedInfo.st_dev else { throw failure(EXDEV, path: staged.path) }
    try rename(live, to: staged, flags: UInt32(RENAME_SWAP))
    return Exchange(installedContents: live, retiredContents: staged)
  }

  /// First installation publishes a complete staged App without replacing an existing destination.
  /// Stage on the destination volume; a competing install or cross-volume move fails closed.
  static func publishFirstInstall(from stagedApp: URL, to destination: URL) throws {
    try requireCanonicalDirectory(stagedApp)
    try requireCanonicalDirectory(destination.deletingLastPathComponent())
    _ = try directoryInfo(stagedApp.appendingPathComponent("Contents", isDirectory: true))
    try rename(stagedApp, to: destination, flags: UInt32(RENAME_EXCL))
  }

  /// Commits an already copied/validated candidate. Retire the old Contents outside the App
  /// before strict validation; a hidden sibling inside the bundle is unsealed content.
  /// On validation failure exchange back and keep the failed candidate for diagnosis.
  static func commitPreparedApp(_ prepared: URL, to live: URL, retired: URL,
                                validate: (URL) throws -> Void) throws {
    let manager = FileManager.default
    try validate(prepared)
    guard !manager.fileExists(atPath: retired.path) else { throw failure(EEXIST, path: retired.path) }
    if !manager.fileExists(atPath: live.path) {
      try publishFirstInstall(from: prepared, to: live)
      do { try validate(live) } catch {
        try publishFirstInstall(from: live, to: prepared)
        throw error
      }
      return
    }
    try requireCanonicalDirectory(live)
    let staged = live.appendingPathComponent(".Contents.update", isDirectory: true)
    let candidateContents = prepared.appendingPathComponent("Contents", isDirectory: true)
    // RENAME_EXCL also rejects a dangling symlink, unlike fileExists alone.
    try rename(candidateContents, to: staged, flags: UInt32(RENAME_EXCL))
    var exchanged = false
    var parked = false
    do {
      try exchangeContents(in: live)
      exchanged = true
      try rename(staged, to: retired, flags: UInt32(RENAME_EXCL))
      parked = true
      try validate(live)
    } catch {
      // No deletion and no guessed fallback. If recovery itself fails, preserve its error and
      // both locations; the caller must stop instead of starting another installation.
      if exchanged {
        if parked { try rename(retired, to: staged, flags: UInt32(RENAME_EXCL)) }
        try exchangeContents(in: live)
      }
      try rename(staged, to: candidateContents, flags: UInt32(RENAME_EXCL))
      throw error
    }
  }

  private static func requireCanonicalDirectory(_ url: URL) throws {
    guard url.isFileURL,
          url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
      throw failure(ELOOP, path: url.path)
    }
    _ = try directoryInfo(url)
  }

  private static func directoryInfo(_ url: URL) throws -> stat {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw failure(errno, path: url.path) }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
      throw failure(info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) ? ELOOP : ENOTDIR, path: url.path)
    }
    return info
  }

  private static func rename(_ source: URL, to destination: URL, flags: UInt32) throws {
    guard renamex_np(source.path, destination.path, flags) == 0 else {
      throw failure(errno, path: source.path)
    }
  }

  private static func failure(_ code: Int32, path: String) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
  }
}
