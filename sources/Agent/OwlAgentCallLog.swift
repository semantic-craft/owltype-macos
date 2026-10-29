//
//  OwlAgentCallLog.swift
//  Owltype
//
//  The redacted record of agent calls shown in 设置 → Agent 接入 (#208): when, which agent
//  client, which tool and how it ended. It never stores arguments, template text, delivered text
//  or anything typed. Kept in `AgentBridge/calls.json` (0600), newest first, at most `limit`.
//

import Foundation

struct OwlAgentCallRecord: Codable, Equatable, Sendable {
  var at: Date
  /// The agent client named in `hello` (for example "grok 1.0.70"), else the helper.
  var client: String
  var method: String
  /// "ok", a `deliver_text` status ("delivered", "cancelled", …) or a bridge error code name.
  var outcome: String
}

final class OwlAgentCallLog: @unchecked Sendable {
  typealias Wire = OwlAgentBridgeProtocol

  static let limit = 200
  static let shared = OwlAgentCallLog(fileURL: OwlAgentBridge.defaultSocketURL.deletingLastPathComponent()
    .appendingPathComponent("calls.json", isDirectory: false))
  /// Posted on the main thread after the log changed.
  static let didChange = Notification.Name("OwlAgentCallLogDidChange")

  private let fileURL: URL?
  private let lock = NSLock()
  private var cached: [OwlAgentCallRecord]?
  private let writer = DispatchQueue(label: "im.owltype.agent-call-log", qos: .utility)

  /// `fileURL` nil keeps the log in memory only.
  init(fileURL: URL?) {
    self.fileURL = fileURL
  }

  var records: [OwlAgentCallRecord] {
    lock.withLock { loadedLocked() }
  }

  func record(_ call: Wire.Call, from client: OwlAgentBridgeClient, reply: OwlAgentBridgeReply, at: Date = Date()) {
    let component = client.agentClient ?? client.helper
    let entry = OwlAgentCallRecord(at: at, client: "\(component.name) \(component.version)",
                                   method: call.method.rawValue, outcome: Self.outcome(reply))
    // Enqueue the write under the lock, so writes reach the disk in the order of the changes.
    lock.withLock {
      var next = loadedLocked()
      next.insert(entry, at: 0)
      if next.count > Self.limit { next.removeLast(next.count - Self.limit) }
      cached = next
      persist(next)
    }
  }

  func clear() {
    lock.withLock {
      cached = []
      persist([])
    }
  }

  /// Waits until every change so far is on disk (tests).
  func flush() { writer.sync {} }

  static func outcome(_ reply: OwlAgentBridgeReply) -> String {
    switch reply {
    case .success(let value):
      if case .string(let status)? = value["status"] { return status }
      return "ok"
    case .failure(let error):
      return error.code.name
    }
  }

  private func loadedLocked() -> [OwlAgentCallRecord] {
    if let cached { return cached }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = fileURL.flatMap { try? Data(contentsOf: $0) }
    let loaded = data.flatMap { try? decoder.decode([OwlAgentCallRecord].self, from: $0) } ?? []
    cached = loaded
    return loaded
  }

  /// Called with `lock` held; the serial writer keeps that order.
  private func persist(_ records: [OwlAgentCallRecord]) {
    writer.async { [fileURL] in
      if let fileURL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
          try OwlAgentBridge.preparePrivateDirectory(fileURL.deletingLastPathComponent())
          try encoder.encode(records).write(to: fileURL, options: .atomic)
          _ = chmod(fileURL.path, 0o600)
        } catch {
          NSLog("Owltype agent call log not saved: \(error)")
        }
      }
      DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
  }
}
