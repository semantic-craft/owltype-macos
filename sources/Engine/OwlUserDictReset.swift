//
//  OwlUserDictReset.swift
//  Owltype
//
//  「重置用户词典…」的纯文件系统部分 (#37)：备份 → 删除 `*.userdb`，让下一次
//  `start_maintenance` 重建空库。
//
//  由来：1.4.23 → 1.5.0 那三天种子是 Unihan 全汉字表，用户上屏过的繁体被学进
//  `<schema>.userdb`；换上干净词库后 userdb 里的旧词频仍把繁体排在第一。已否决静默净化
//  (#34)——改用户数据必须是用户自己按的、看得见、可撤销的动作。
//
//  只碰 `*.userdb`，一个字节都不碰方案 / 设置 / 词库。注意 `OwlConfigWriter` 把
//  `*.userdb*` 列为 `neverTouch`：那条守卫管的是**配置写入层**（猫头鹰自动改用户文件时永不
//  波及学习数据），本模块是它唯一的、由用户显式发起的例外，故是独立类型而不是给写入层
//  开后门。
//
//  纯 Foundation：无 librime、无 AppKit、无单例，root / timestamp / FileManager 全注入，
//  测试可在临时目录里跑完整链路。引擎侧的顺序约束（LevelDB 独占锁 → 必须先 `finalize()`）
//  由唯一调用者 `OwlApplicationDelegate.resetUserDict()` 负责。
//

import Foundation

/// 一次重置的结果：清了哪些方案、备份落在哪。
struct OwlUserDictResetOutcome: Equatable {
  /// 被清掉的方案 id（目录名去掉 `.userdb` 后缀），按字典序。空 = 本机没有用户词典。
  let schemaIDs: [String]
  /// 备份目录；`schemaIDs` 为空时没有创建备份，故为 nil。
  let backupDir: URL?
}

/// 重置过程中的失败。两支都保证**已经从备份还原**，不留中间态。
enum OwlUserDictResetError: LocalizedError, Equatable {
  /// 备份阶段失败。此时一个 userdb 都还没删。
  case backupFailed(schemaID: String, reason: String)
  /// 删除阶段失败，已删的部分已从备份还原回去。
  case removeFailed(schemaID: String, reason: String)

  var errorDescription: String? {
    switch self {
    case .backupFailed(let schemaID, let reason):
      return "备份 \(schemaID) 的用户词典失败：\(reason)"
    case .removeFailed(let schemaID, let reason):
      return "删除 \(schemaID) 的用户词典失败：\(reason)"
    }
  }
}

enum OwlUserDictReset {
  /// 备份目录名前缀，`.owl-backup/userdb-reset-<ts>/`（与配置写入层的
  /// `.owl-backup/<ts>/` 同一个根，靠前缀区分来源）。
  static let backupDirPrefix = "userdb-reset-"
  static let userDBSuffix = ".userdb"

  /// root 下所有 `*.userdb`，按名字排序（顺序固定，便于断言与日志阅读）。
  /// 不递归：`sync/` 里的 `<schema>.userdb.txt` 同步快照是另一台机器也在读的数据，不在本
  /// 动作范围内（见 #37「只做一个按钮」）。
  static func userDatabases(in root: URL, fileManager fm: FileManager = .default) -> [URL] {
    let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return entries
      .filter { $0.lastPathComponent.hasSuffix(userDBSuffix) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  static func schemaID(of database: URL) -> String {
    String(database.lastPathComponent.dropLast(userDBSuffix.count))
  }

  /// 备份 → 删除。两段式的顺序是刻意的：**先把每一个 userdb 都备份完**再开始删，所以
  /// 备份阶段失败时磁盘还原封不动；删除阶段失败才需要还原，且还原源必定齐全。
  ///
  /// 无 userdb（全新机器）时安静返回空 outcome，不建备份目录、不报错。
  @discardableResult
  static func run(
    root: URL,
    timestamp: String,
    fileManager fm: FileManager = .default
  ) throws -> OwlUserDictResetOutcome {
    let databases = userDatabases(in: root, fileManager: fm)
    guard !databases.isEmpty else {
      return OwlUserDictResetOutcome(schemaIDs: [], backupDir: nil)
    }

    let backupDir = root
      .appendingPathComponent(".owl-backup", isDirectory: true)
      .appendingPathComponent(backupDirPrefix + timestamp, isDirectory: true)
    try OwlPrivateStorage.prepareDirectory(backupDir, fileManager: fm)

    for database in databases {
      do {
        try fm.copyItem(at: database, to: backupDir.appendingPathComponent(database.lastPathComponent))
      } catch {
        throw OwlUserDictResetError.backupFailed(
          schemaID: schemaID(of: database),
          reason: error.localizedDescription
        )
      }
    }

    var removed: [URL] = []
    for database in databases {
      do {
        try fm.removeItem(at: database)
        removed.append(database)
      } catch {
        restore(removed, from: backupDir, fileManager: fm)
        throw OwlUserDictResetError.removeFailed(
          schemaID: schemaID(of: database),
          reason: error.localizedDescription
        )
      }
    }

    return OwlUserDictResetOutcome(
      schemaIDs: databases.map(schemaID(of:)),
      backupDir: backupDir
    )
  }

  /// best-effort 还原：单个还原失败不中断其余，尽量把磁盘拉回动作前的样子。
  private static func restore(_ databases: [URL], from backupDir: URL, fileManager fm: FileManager) {
    for database in databases {
      let backup = backupDir.appendingPathComponent(database.lastPathComponent)
      guard fm.fileExists(atPath: backup.path), !fm.fileExists(atPath: database.path) else { continue }
      try? fm.copyItem(at: backup, to: database)
    }
  }

  // MARK: - 状态行文案（回到「维护与诊断」卡的 statusLine）

  static func statusMessage(outcome: OwlUserDictResetOutcome, redeployed: Bool) -> String {
    guard let backupDir = outcome.backupDir, !outcome.schemaIDs.isEmpty else {
      return "本机还没有用户词典，无需重置。"
    }
    let schemas = outcome.schemaIDs.joined(separator: "、")
    let cleared = "已重置 \(outcome.schemaIDs.count) 个方案的用户词典（\(schemas)）；原词典已备份到 \(backupDir.path)。"
    return redeployed ? cleared : "\(cleared)但重新部署失败，请查看诊断日志。"
  }

  static func failureMessage(error: Error, redeployed: Bool) -> String {
    let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    let head = "重置用户词典失败，已还原原词典：\(reason)"
    return redeployed ? head : "\(head)重新部署也失败了，请查看诊断日志。"
  }
}
