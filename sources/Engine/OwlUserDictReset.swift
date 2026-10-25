//
//  OwlUserDictReset.swift
//  Owltype
//
//  「重置用户词典…」的 Rust 用户数据部分：完整备份 → 删除 → 失败时恢复。
//
//  只处理 `msime-user/msime_user.db*` 与 `msime-user/dictionaries/`。旧版 Rime
//  `*.userdb`、`sync/*.userdb.txt`、设置和置顶词属于迁移原件或独立设置，本动作不碰。
//  引擎侧顺序约束由唯一调用者 `OwlApplicationDelegate.resetUserDict()` 负责：先关闭
//  Rust 会话与缓存数据库，再运行这里，最后重新启动引擎。
//

import Darwin
import Foundation

/// 一次重置的结果：清了哪些 Rust 数据项、备份落在哪。
struct OwlUserDictResetOutcome: Equatable {
  /// 逻辑项名，例如 `msime_user.db`、`msime_user.db-wal`、`dictionaries`。
  let removedItems: [String]
  /// 备份目录；没有可重置数据时为 nil。
  let backupDir: URL?
}

enum OwlUserDictResetError: LocalizedError, Equatable {
  case inspectionFailed(item: String, reason: String)
  case backupFailed(item: String, reason: String)
  case removeFailed(
    item: String,
    reason: String,
    restored: Bool,
    restoreReason: String?
  )

  var errorDescription: String? {
    switch self {
    case .inspectionFailed(let item, let reason):
      return "检查 Rust 用户数据 \(item) 失败：\(reason)"
    case .backupFailed(let item, let reason):
      return "备份 Rust 用户数据 \(item) 失败：\(reason)"
    case .removeFailed(let item, let reason, let restored, let restoreReason):
      var message = "删除 Rust 用户数据 \(item) 失败：\(reason)"
      if restored {
        message += "；已从备份恢复"
      } else if let restoreReason {
        message += "；恢复也失败：\(restoreReason)"
      } else {
        message += "；恢复失败"
      }
      return message
    }
  }
}

enum OwlUserDictReset {
  static let rustDirectoryName = "msime-user"
  static let journalName = "msime_user.db"
  static let dictionariesName = "dictionaries"
  static let backupDirPrefix = "rust-userdict-reset-"

  private struct Item {
    let name: String
    let url: URL
  }

  /// root 下 Rust 用户数据中应由「重置」清空的项目，顺序固定。
  static func resetItemNames(
    in root: URL,
    fileManager fm: FileManager = .default
  ) throws -> [String] {
    try items(in: root, fileManager: fm).map(\.name)
  }

  /// 备份 → 删除。删除前的 checkpoint 只用于测试故障注入，正常调用为空操作。
  @discardableResult
  static func run(
    root: URL,
    timestamp: String,
    fileManager fm: FileManager = .default,
    removeCheckpoint: (String) throws -> Void = { _ in }
  ) throws -> OwlUserDictResetOutcome {
    let items = try items(in: root, fileManager: fm)
    guard !items.isEmpty else {
      return OwlUserDictResetOutcome(removedItems: [], backupDir: nil)
    }

    let backupDir = uniqueBackupDirectory(
      root: root,
      timestamp: timestamp,
      fileManager: fm
    )
    var currentItem = items[0].name
    do {
      try OwlPrivateStorage.prepareDirectory(backupDir, fileManager: fm)
      for item in items {
        currentItem = item.name
        try fm.copyItem(
          at: item.url,
          to: backupDir.appendingPathComponent(item.name)
        )
      }
    } catch {
      try? fm.removeItem(at: backupDir)
      throw OwlUserDictResetError.backupFailed(
        item: currentItem,
        reason: error.localizedDescription
      )
    }

    for item in items {
      do {
        try removeCheckpoint(item.name)
        try fm.removeItem(at: item.url)
      } catch {
        let restoration = restore(
          items,
          rustRoot: rustRoot(in: root),
          backupDir: backupDir,
          fileManager: fm
        )
        throw OwlUserDictResetError.removeFailed(
          item: item.name,
          reason: error.localizedDescription,
          restored: restoration == nil,
          restoreReason: restoration
        )
      }
    }

    return OwlUserDictResetOutcome(
      removedItems: items.map(\.name),
      backupDir: backupDir
    )
  }

  private static func items(
    in root: URL,
    fileManager fm: FileManager
  ) throws -> [Item] {
    let rustRoot = rustRoot(in: root)
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: rustRoot.path, isDirectory: &isDirectory) else {
      return []
    }
    guard isDirectory.boolValue, isRealDirectory(rustRoot) else {
      throw OwlUserDictResetError.inspectionFailed(
        item: rustDirectoryName,
        reason: "不是普通目录"
      )
    }

    let names: [String]
    do {
      names = try fm.contentsOfDirectory(atPath: rustRoot.path)
    } catch {
      throw OwlUserDictResetError.inspectionFailed(
        item: rustDirectoryName,
        reason: error.localizedDescription
      )
    }

    var items = names
      .filter(isJournalArtifact)
      .sorted()
      .map {
        Item(
          name: $0,
          url: rustRoot.appendingPathComponent($0, isDirectory: false)
        )
      }
    let dictionaries = rustRoot.appendingPathComponent(
      dictionariesName,
      isDirectory: true
    )
    if fm.fileExists(atPath: dictionaries.path) {
      items.append(Item(name: dictionariesName, url: dictionaries))
    }
    return items
  }

  private static func isJournalArtifact(_ name: String) -> Bool {
    name == journalName
      || name.hasPrefix(journalName + "-")
      || name.hasPrefix(journalName + ".corrupt-")
  }

  private static func rustRoot(in root: URL) -> URL {
    root.appendingPathComponent(rustDirectoryName, isDirectory: true)
  }

  private static func uniqueBackupDirectory(
    root: URL,
    timestamp: String,
    fileManager fm: FileManager
  ) -> URL {
    let backups = root.appendingPathComponent(".owl-backup", isDirectory: true)
    let baseName = backupDirPrefix + timestamp
    var candidate = backups.appendingPathComponent(baseName, isDirectory: true)
    var suffix = 2
    while fm.fileExists(atPath: candidate.path) {
      candidate = backups.appendingPathComponent(
        "\(baseName)-\(suffix)",
        isDirectory: true
      )
      suffix += 1
    }
    return candidate
  }

  /// 恢复整组 Rust 数据。先移除中途残留，再从完整备份重建，避免半个目录留在原位。
  /// 成功返回 nil；失败返回首个错误说明。
  private static func restore(
    _ items: [Item],
    rustRoot: URL,
    backupDir: URL,
    fileManager fm: FileManager
  ) -> String? {
    do {
      try OwlPrivateStorage.prepareDirectory(rustRoot, fileManager: fm)
      for item in items where fm.fileExists(atPath: item.url.path) {
        try fm.removeItem(at: item.url)
      }
      for item in items {
        try fm.copyItem(
          at: backupDir.appendingPathComponent(item.name),
          to: item.url
        )
      }
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  private static func isRealDirectory(_ url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return false }
    return info.st_mode & S_IFMT == S_IFDIR
  }

  // MARK: - 状态行文案

  static func statusMessage(
    outcome: OwlUserDictResetOutcome,
    redeployed: Bool
  ) -> String {
    guard let backupDir = outcome.backupDir, !outcome.removedItems.isEmpty else {
      return "本机还没有 Rust 用户词典数据，无需重置。"
    }
    let items = outcome.removedItems.joined(separator: "、")
    let cleared = "已重置 Rust 用户词典数据（\(items)）；原数据已备份到 \(backupDir.path)。"
    return redeployed ? cleared : "\(cleared)但重新启动 Rust 引擎失败，请查看诊断日志。"
  }

  static func failureMessage(error: Error, redeployed: Bool) -> String {
    let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    let head = "重置 Rust 用户词典数据失败：\(reason)"
    return redeployed ? head : "\(head)重新启动 Rust 引擎也失败了，请查看诊断日志。"
  }
}
