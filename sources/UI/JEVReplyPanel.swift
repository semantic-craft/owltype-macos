import AppKit
import SwiftUI
import Darwin

// Optional local protocol v1. This client never reads credentials or inserts text.
final class JEVRequestCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
  func check() throws {
    lock.lock()
    let value = cancelled
    lock.unlock()
    if value { throw CancellationError() }
  }
}

enum JEVTransport {
  static var defaultSocketPath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Jarvis Phone/replies.sock").path
  }

  // Nonblocking I/O keeps one monotonic deadline across connect, send and receive.
  // The cancellation flag is checked at most 100 ms apart, including a stalled service.
  static func request(_ payload: Data, socketPath: String = defaultSocketPath,
                      timeout: TimeInterval = 120,
                      cancellation: JEVRequestCancellation = JEVRequestCancellation()) throws -> Data {
    guard timeout > 0, timeout <= 120, payload.count < 100_000 else { throw Failure.invalid }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.unavailable }
    withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw Failure.unavailable }
    defer { Darwin.close(descriptor) }
    guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw Failure.unavailable }
    var noSignal: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

    func wait(_ events: Int16) throws {
      while true {
        try cancellation.check()
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw Failure.timedOut }
        var item = pollfd(fd: descriptor, events: events, revents: 0)
        let result = poll(&item, 1, Int32(min(100, max(1, remaining * 1000))))
        if result > 0 { return }
        if result < 0 && errno != EINTR { throw Failure.unavailable }
      }
    }

    try cancellation.check()
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if connected != 0 {
      guard errno == EINPROGRESS else { throw Failure.unavailable }
      try wait(Int16(POLLOUT))
      var error: Int32 = 0
      var size = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw Failure.unavailable }
    }
    let body = payload + Data([10])
    try body.withUnsafeBytes { buffer in
      var offset = 0
      while offset < body.count {
        try wait(Int16(POLLOUT))
        let sent = Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), body.count - offset, 0)
        if sent < 0 && (errno == EAGAIN || errno == EINTR) { continue }
        guard sent > 0 else { throw Failure.unavailable }
        offset += sent
      }
    }
    var response = Data()
    var chunk = [UInt8](repeating: 0, count: 8192)
    while true {
      try wait(Int16(POLLIN))
      let count = Darwin.recv(descriptor, &chunk, chunk.count, 0)
      if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
      guard count > 0 else { throw Failure.unavailable }
      response.append(contentsOf: chunk.prefix(count))
      guard response.count <= 256_000 else { throw Failure.invalid }
      if let end = response.firstIndex(of: 10) {
        guard end == response.index(before: response.endIndex) else { throw Failure.invalid }
        try cancellation.check()
        return response
      }
    }
  }
  enum Failure: Error, Equatable { case unavailable, invalid, timedOut }
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
  private let transport: (@Sendable (Data) throws -> Data)?
  private var activeRequest: JEVRequestCancellation?
  private var revision = UUID()
  private var job: Task<Void, Never>?

  init(text: String, source: String,
       transport: (@Sendable (Data) throws -> Data)? = nil) {
    self.text = text; self.source = source; self.transport = transport
  }

  func invalidate() {
    revision = UUID()
    job?.cancel()
    activeRequest?.cancel()
    activeRequest = nil
    candidates = []
    busy = false
  }

  @discardableResult
  func copyCandidate(at index: Int, to pasteboard: NSPasteboard = .general) -> Bool {
    guard !busy, candidates.indices.contains(index) else { return false }
    pasteboard.clearContents()
    let copied = pasteboard.setString(candidates[index], forType: .string)
    status = copied ? "已复制候选 \(index + 1)；未填入、未发送。" : "复制失败，请重试。"
    return copied
  }

  func cancel() {
    invalidate()
    status = "已取消；原选区和本次要求已保留，可重新生成。"
  }

  func userEdited() {
    invalidate()
    status = "要求已修改，请重新生成候选。"
  }

  private func call(_ object: [String: Any]) async throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: object)
    let transport = self.transport
    try Task.checkCancellation()
    let cancellation = JEVRequestCancellation()
    activeRequest = cancellation
    let timeout: TimeInterval = object["operation"] as? String == "preferences" ? 5 : 120
    let response = try await withTaskCancellationHandler {
      try await Task.detached(priority: .userInitiated) {
        if let transport { return try transport(data) }
        return try JEVTransport.request(data, timeout: timeout, cancellation: cancellation)
      }.value
    } onCancel: {
      cancellation.cancel()
    }
    try Task.checkCancellation()
    guard let value = try JSONSerialization.jsonObject(with: response) as? [String: Any],
          value["ok"] as? Bool == true, value["version"] as? Int == 1 else { throw JEVTransport.Failure.invalid }
    return value
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
        status = Self.offlineGuidance
      }
      busy = false
    }
  }

  static let offlineGuidance = "请在琴音服务目录运行 scripts/reply-service，再点重新连接或重新生成。服务需配置 OPENAI_API_KEY；输入法无需密钥，也无需打开 Pallas 或录音。普通输入不受影响。"

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
        if value["status"] as? String == "needs_clarification" {
          status = "请补充这次想怎么回复，再重新生成候选。"
          busy = false
          return
        }
        guard value["status"] == nil || value["status"] as? String == "ready" else { throw JEVTransport.Failure.invalid }
        guard let rows = value["candidates"] as? [[String: Any]],
              (2...3).contains(rows.count), rows.allSatisfy({
                guard let text = $0["text"] as? String else { return false }
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.unicodeScalars.count <= 2000
              }), Set(rows.compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }).count == rows.count else {
          throw JEVTransport.Failure.invalid
        }
        candidates = rows.compactMap { $0["text"] as? String }
        let verdict = value["verdict"] as? [String: Any]
        status = "判断：\(verdict?["intent"] as? String ?? "已完成") · 候选仅供阅读"
      } catch {
        guard revision == token else { return }
        status = error as? JEVTransport.Failure == .timedOut
          ? "请求超时；原选区和本次要求已保留，请重试或关闭面板继续输入。"
          : "未能取得候选。" + Self.offlineGuidance
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
      Text("只展示和复制候选，不填入、不发送；本次要求优先于冲突的保存风格").font(.caption).foregroundStyle(.secondary)
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
      }.disabled(!model.ready)
      HStack {
        Button(model.ready ? "判断并生成候选" : "重新连接") { model.generate() }.disabled(model.busy || (model.ready && !model.canGenerate))
        if model.busy {
          Button("取消") { model.cancel() }
          ProgressView().controlSize(.small)
        }
      }
      Text(model.status).font(.callout)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(Array(model.candidates.enumerated()), id: \.offset) { index, candidate in
            HStack(alignment: .top) {
              Text("\(index + 1). \(candidate)").frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
              Button("复制") { model.copyCandidate(at: index) }
                .accessibilityLabel("复制候选 \(index + 1)")
            }
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
