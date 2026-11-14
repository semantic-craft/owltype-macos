//
//  OwlUserDictReset.swift
//  Owltype
//
//  「重置用户词典…」的 Rust 用户数据部分：完整备份 → 删除 → 失败时恢复。
//
//  只处理 `msime-user/msime_user.db*` 与 `msime-user/dictionaries/`。旧版 Rime
//  `*.userdb`、`sync/*.userdb.txt`、设置和置顶词属于迁移原件或独立设置，本动作不碰。
//  引擎侧顺序约束由唯一调用者 `EngineRuntime.resetUserDict()`（经 `whileStopped`）负责：先关闭
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
  private struct Reply: Decodable {
    struct Failure: Decodable {
      let kind: String
      let item: String
      let reason: String
      let restored: Bool?
      let restoreReason: String?
    }
    let removedItems: [String]?
    let backupDir: String?
    let error: Failure?
  }

  @discardableResult
  static func run(root: URL, timestamp: String,
                  removeCheckpoint: (String) throws -> Void = { _ in }) throws -> OwlUserDictResetOutcome {
    try withoutActuallyEscaping(removeCheckpoint) { checkpoint in
      try execute(root: root, timestamp: timestamp, checkpoint: checkpoint)
    }
  }

  private static func execute(root: URL, timestamp: String,
                              checkpoint: @escaping (String) throws -> Void = { _ in }) throws -> OwlUserDictResetOutcome {
    let host = OwlStorageHost(dataDir: root, checkpoint: checkpoint)
    let reply: Reply = try host.call("user_reset", ["timestamp": timestamp])
    if let error = reply.error {
      func reason(_ token: String) -> String {
        token == "not_directory" ? "不是普通目录" : (host.errors[token]?.localizedDescription ?? token)
      }
      switch error.kind {
      case "inspection": throw OwlUserDictResetError.inspectionFailed(item: error.item, reason: reason(error.reason))
      case "backup": throw OwlUserDictResetError.backupFailed(item: error.item, reason: reason(error.reason))
      default: throw OwlUserDictResetError.removeFailed(item: error.item, reason: reason(error.reason),
        restored: error.restored ?? false, restoreReason: error.restoreReason.map(reason))
      }
    }
    return OwlUserDictResetOutcome(removedItems: reply.removedItems ?? [], backupDir: reply.backupDir.map { URL(fileURLWithPath: $0) })
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
