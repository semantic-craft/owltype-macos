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
  enum Failure: Error { case unavailable, invalid }
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

  private func call(_ object: [String: Any]) async throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: object)
    let transport = self.transport
    let response = try await Task.detached(priority: .userInitiated) {
      try transport(data)
    }.value
    try Task.checkCancellation()
    guard let value = try JSONSerialization.jsonObject(with: response) as? [String: Any],
          value["ok"] as? Bool == true else { throw JEVTransport.Failure.invalid }
    return value
  }

  func load() {
    invalidate()
    busy = true
    let token = revision
    job = Task {
      do {
        let value = try await call(["version": 1, "operation": "preferences"])
        guard revision == token else { return }
        style = try JSONDecoder().decode(JEVStyle.self,
          from: JSONSerialization.data(withJSONObject: value["reply_style"] as Any))
        ready = true
        status = "已载入保存的风格。选区仅作为待回复材料，不推断消息方向。"
      } catch {
        guard revision == token else { return }
        status = "本地 JEV 服务未连接。请启动服务后重试；不需要在输入法中配置密钥。"
      }
      busy = false
    }
  }

  var canGenerate: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 10000 }

  func generate() {
    invalidate()
    guard ready else { load(); return }
    guard canGenerate else { status = "请选择完整的待回复消息。"; return }
    busy = true
    status = "正在判断、按风格拟稿并排序…"
    let token = revision
    let currentStyle = style
    let currentInstructions = instructions
    job = Task {
      do {
        let styleValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(currentStyle))
        let value = try await call(["version": 1, "operation": "recommend",
          "request_id": token.uuidString, "source": source, "text": text,
          "reply_style": styleValue, "instructions": currentInstructions])
        guard revision == token else { return }
        guard style == currentStyle, instructions == currentInstructions,
              value["request_id"] as? String == token.uuidString else { throw JEVTransport.Failure.invalid }
        guard let rows = value["candidates"] as? [[String: Any]],
              !rows.isEmpty, rows.allSatisfy({ ($0["text"] as? String)?.isEmpty == false }) else {
          throw JEVTransport.Failure.invalid
        }
        candidates = rows.compactMap { $0["text"] as? String }
        let verdict = value["verdict"] as? [String: Any]
        status = "判断：\(verdict?["intent"] as? String ?? "已完成") · 候选仅供阅读"
      } catch {
        guard revision == token else { return }
        status = "未能取得候选。请检查本地服务和完整选区后重试。"
      }
      if revision == token { busy = false }
    }
  }
}

private struct JEVReplyView: View {
  @ObservedObject var model: JEVReplyModel
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("JEV 回复建议").font(.title2)
      Text("只展示候选，不填入、不发送；风格调整仅用于本次").font(.caption).foregroundStyle(.secondary)
      ScrollView { Text(model.text).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 90)
      Form {
        TextField("关系", text: $model.style.relationship)
        TextField("目标", text: $model.style.purpose)
        TextField("语气", text: $model.style.tone)
        TextField("长度", text: $model.style.length)
        TextField("限制", text: $model.style.constraints)
        Toggle("非暴力沟通（保留你的表达风格）", isOn: Binding(
          get: { model.style.approach == "nvc" },
          set: { model.style.approach = $0 ? "nvc" : "standard" }))
        TextField("这次我想怎么回", text: $model.instructions)
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
      .onChange(of: model.style) { if !model.busy { model.invalidate() } }
      .onChange(of: model.instructions) { model.invalidate() }
  }
}

@MainActor
final class JEVReplyPanel: NSObject, NSWindowDelegate {
  static let shared = JEVReplyPanel()
  private var window: NSWindow?
  private var model: JEVReplyModel?

  func show(text: String, source: String) {
    model?.invalidate()
    window?.close()
    let model = JEVReplyModel(text: text, source: source)
    self.model = model
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 660),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "JEV 回复建议"
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.contentView = NSHostingView(rootView: JEVReplyView(model: model))
    self.window = window
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    model.load()
  }

  func windowWillClose(_ notification: Notification) { model?.invalidate() }
}
