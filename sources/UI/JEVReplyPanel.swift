import AppKit
import SwiftUI
import Darwin

// Optional local protocol v1. This client never reads credentials or inserts text.
enum JEVTransport {
  static func request(_ payload: Data) throws -> Data {
    let path = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Jarvis Phone/replies.sock").path
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.unavailable }
    withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure.unavailable }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 120, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    timeout.tv_sec = 5
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw Failure.unavailable }
    let body = payload + Data([10])
    try body.withUnsafeBytes { buffer in
      var offset = 0
      while offset < body.count {
        let sent = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), body.count - offset, 0)
        guard sent > 0 else { throw Failure.unavailable }
        offset += sent
      }
    }
    var response = Data()
    var chunk = [UInt8](repeating: 0, count: 8192)
    while response.count <= 256_000 {
      let count = Darwin.recv(fd, &chunk, chunk.count, 0)
      guard count > 0 else { throw Failure.unavailable }
      response.append(contentsOf: chunk.prefix(count))
      if response.last == 10 { return response }
    }
    throw Failure.invalid
  }
  enum Failure: Error, Equatable {
    case unavailable
    case invalid
    case remote(SafeReason)
  }

  enum SafeReason: String, Sendable, Equatable {
    case paused
    case scenarioDisabled = "scenario_disabled"
    case requestInvalidated = "request_invalidated"
    case modelQuotaExhausted = "model_quota_exhausted"
    case modelRateLimited = "model_rate_limited"
    case serviceUnavailable = "service_unavailable"

    var message: String {
      switch self {
      case .paused:
        return "Kotone 已全局暂停；原选区和本次要求已保留，不会自动调用其他服务。"
      case .scenarioDisabled:
        return "Kotone 回复与表达场景已停用；原选区和本次要求已保留，不会自动调用其他服务。"
      case .requestInvalidated:
        return "等待期间 Kotone 场景状态已变化，旧请求已失效；原选区和本次要求已保留。"
      case .modelQuotaExhausted:
        return "模型可用配额不足；原选区和本次要求已保留，未自动重试。"
      case .modelRateLimited:
        return "模型服务暂时限流；原选区和本次要求已保留，未自动重试。"
      case .serviceUnavailable:
        return "未能取得候选。请检查本地服务和完整选区后重试。"
      }
    }
  }
}

struct JEVStyle: Codable, Equatable {
  var approach = "nvc"
  var relationship = "朋友"
  var purpose = "接住对方情绪，自然回应"
  var tone = "轻松、简洁，不说教"
  var length = "每条一到两句"
  var constraints = "不虚构事实，不替我承诺，不使用表情符号"
}

@MainActor
final class JEVReplyModel: ObservableObject {
  @Published var style = JEVStyle()
  @Published var instructions = ""
  @Published var status = "正在连接本地回复服务…"
  @Published var candidates: [String] = []
  @Published var busy = false
  @Published var ready = false
  let text: String
  let source: String
  private let transport: @Sendable (Data) throws -> Data
  private var revision = UUID()
  private var job: Task<Void, Never>?

  init(text: String, source: String,
       transport: @escaping @Sendable (Data) throws -> Data = { try JEVTransport.request($0) }) {
    self.text = text; self.source = source; self.transport = transport
  }

  func invalidate() {
    revision = UUID()
    job?.cancel()
    candidates = []
    busy = false
  }

  func userEdited() {
    invalidate()
    status = "要求已修改，请重新生成候选。"
  }

  private func call(_ object: [String: Any]) async throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: object)
    let transport = self.transport
    let response = try await Task.detached(priority: .userInitiated) {
      try transport(data)
    }.value
    try Task.checkCancellation()
    guard let value = try JSONSerialization.jsonObject(with: response) as? [String: Any],
          let versionNumber = value["version"] as? NSNumber,
          CFGetTypeID(versionNumber) != CFBooleanGetTypeID(),
          versionNumber.intValue == 1,
          let okNumber = value["ok"] as? NSNumber, CFGetTypeID(okNumber) == CFBooleanGetTypeID() else {
      throw JEVTransport.Failure.invalid
    }
    if !okNumber.boolValue {
      if let rawCode = value["code"] {
        guard let codeString = rawCode as? String else {
          throw JEVTransport.Failure.invalid
        }
        if let safe = JEVTransport.SafeReason(rawValue: codeString), safe != .serviceUnavailable {
          throw JEVTransport.Failure.remote(safe)
        }
      }
      throw JEVTransport.Failure.remote(.serviceUnavailable)
    }
    return value
  }

  static func validateAndExtractCandidates(from value: [String: Any], expectedSource: String) throws -> (needsClarification: Bool, candidates: [String]) {
    if let rawSource = value["source"] {
      guard let sourceString = rawSource as? String, sourceString == expectedSource else {
        throw JEVTransport.Failure.invalid
      }
    }
    if let rawStatus = value["status"] {
      guard let statusString = rawStatus as? String else {
        throw JEVTransport.Failure.invalid
      }
      if statusString == "needs_clarification" {
        guard let rawCandidates = value["candidates"] as? [Any], rawCandidates.isEmpty else {
          throw JEVTransport.Failure.invalid
        }
        return (true, [])
      }
      guard statusString == "ready" else {
        throw JEVTransport.Failure.invalid
      }
    }
    guard let rawRows = value["candidates"] as? [Any], (2...3).contains(rawRows.count) else {
      throw JEVTransport.Failure.invalid
    }
    var trimmedTexts: [String] = []
    var seen: Set<String> = []
    for item in rawRows {
      guard let row = item as? [String: Any],
            let rawText = row["text"] as? String else {
        throw JEVTransport.Failure.invalid
      }
      let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 2000, !seen.contains(trimmed) else {
        throw JEVTransport.Failure.invalid
      }
      seen.insert(trimmed)
      trimmedTexts.append(trimmed)
    }
    return (false, trimmedTexts)
  }

  func load() {
    invalidate()
    ready = false
    busy = true
    let token = revision
    job = Task {
      do {
        let value = try await call(["version": 1, "operation": "preferences"])
        guard revision == token else { return }
        guard let replyStyle = value["reply_style"] as? [String: Any],
              JSONSerialization.isValidJSONObject(replyStyle) else { throw JEVTransport.Failure.invalid }
        style = try JSONDecoder().decode(JEVStyle.self,
          from: JSONSerialization.data(withJSONObject: replyStyle))
        ready = true
        status = "已载入保存的风格。选区仅作为待回复材料，不推断消息方向。"
      } catch {
        guard revision == token else { return }
        status = "本地 Kotone 服务未连接。请启动服务后重试；不需要在输入法中配置密钥。"
      }
      busy = false
    }
  }

  var canGenerate: Bool { instructions.unicodeScalars.count <= 1000 && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.unicodeScalars.count <= 10000 }

  func generate() {
    invalidate()
    guard ready else { load(); return }
    guard canGenerate else { status = "请选择完整的待回复消息。"; return }
    busy = true
    status = "正在判断、按风格拟稿并排序…"
    let token = revision
    let currentStyle = style
    let currentInstructions = instructions
    let currentText = text
    job = Task {
      do {
        let styleValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(currentStyle))
        let value = try await call(["version": 1, "operation": "recommend",
          "request_id": token.uuidString, "source": source, "text": currentText,
          "reply_style": styleValue, "instructions": currentInstructions])
        guard revision == token else { return }
        guard style == currentStyle, instructions == currentInstructions, text == currentText,

              value["request_id"] as? String == token.uuidString else { throw JEVTransport.Failure.invalid }
        let validated = try Self.validateAndExtractCandidates(from: value, expectedSource: source)
        if validated.needsClarification {
          candidates = []
          status = "请补充这次想怎么回复，再重新生成候选。"
          busy = false
          return
        }
        candidates = validated.candidates
        let verdict = value["verdict"] as? [String: Any]
        status = "判断：\(verdict?["intent"] as? String ?? "已完成") · 候选仅供阅读"
      } catch let JEVTransport.Failure.remote(reason) {
        guard revision == token else { return }
        candidates = []
        status = reason.message
      } catch {
        guard revision == token else { return }
        candidates = []
        status = "未能取得候选。请检查本地服务和完整选区后重试。"
      }
      if revision == token { busy = false }
    }
  }
}

@MainActor
private struct JEVReplyView: View {
  @ObservedObject var model: JEVReplyModel
  private func styleBinding(_ key: WritableKeyPath<JEVStyle, String>) -> Binding<String> {
    Binding(get: { model.style[keyPath: key] }, set: { model.style[keyPath: key] = $0; model.userEdited() })
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Kotone 回复建议").font(.title2)
      Text("只展示候选，不填入、不发送；风格调整仅用于本次").font(.caption).foregroundStyle(.secondary)
      ScrollView { Text(model.text).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 90)
      Form {
        TextField("关系", text: styleBinding(\.relationship))
        TextField("目标", text: styleBinding(\.purpose))
        TextField("语气", text: styleBinding(\.tone))
        TextField("长度", text: styleBinding(\.length))
        TextField("限制", text: styleBinding(\.constraints))
        Toggle("非暴力沟通（保留你的表达风格）", isOn: Binding(
          get: { model.style.approach == "nvc" },
          set: { model.style.approach = $0 ? "nvc" : "standard"; model.userEdited() }))
        TextField("这次我想怎么回", text: Binding(get: { model.instructions }, set: { model.instructions = $0; model.userEdited() }))
      }.disabled(model.busy)
      HStack {
        Button(model.ready ? "判断并生成候选" : "重新连接") { model.generate() }.disabled(model.busy || (model.ready && !model.canGenerate))
        if model.busy { ProgressView().controlSize(.small) }
      }
      Text(model.status).font(.callout)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(Array(model.candidates.enumerated()), id: \.offset) { index, candidate in
            Text("\(index + 1). \(candidate)").frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }.frame(minHeight: 120)
    }.padding(20).frame(width: 560, height: 620)
  }
}

@MainActor
final class JEVReplyPanel: NSObject, NSWindowDelegate {
  static let shared = JEVReplyPanel()
  private var window: NSWindow?
  private var model: JEVReplyModel?

  func show(text: String, source: String) {
    model?.invalidate()
    window?.delegate = nil
    window?.close()
    let model = JEVReplyModel(text: text, source: source)
    self.model = model
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 660),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Kotone 回复建议"
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.contentView = NSHostingView(rootView: JEVReplyView(model: model))
    self.window = window
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    model.load()
  }

  func windowWillClose(_ notification: Notification) {
    guard (notification.object as? NSWindow) === window else { return }
    model?.invalidate()
  }
}
