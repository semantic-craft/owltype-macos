//
//  OwlVoiceSettings.swift
//  Owltype — Voice Input Subsystem
//

import Darwin
import Foundation

enum OwlVoiceASRAuthMode: String, Equatable, Sendable {
  case apiKey
  case openAILogin
}

struct OwlVoiceASRPreset: Identifiable, Equatable, Sendable {
  let id: String
  let displayName: String
  let endpoint: String
  let defaultModel: String
  let curatedModels: [String]
  let keyLabel: String
  let keyHint: String
  let sharesProviderProfileKey: Bool
  let authMode: OwlVoiceASRAuthMode

  init(
    id: String,
    displayName: String,
    endpoint: String,
    defaultModel: String,
    curatedModels: [String],
    keyLabel: String,
    keyHint: String,
    sharesProviderProfileKey: Bool,
    authMode: OwlVoiceASRAuthMode = .apiKey
  ) {
    self.id = id
    self.displayName = displayName
    self.endpoint = endpoint
    self.defaultModel = defaultModel
    self.curatedModels = curatedModels
    self.keyLabel = keyLabel
    self.keyHint = keyHint
    self.sharesProviderProfileKey = sharesProviderProfileKey
    self.authMode = authMode
  }

  var requiresAPIKey: Bool { authMode == .apiKey }
  var isOpenAILogin: Bool { authMode == .openAILogin }
}

enum OwlVoiceASRCatalog {
  static let openai = OwlVoiceASRPreset(
    id: "openai",
    displayName: "OpenAI",
    endpoint: OwlVoiceSettings.defaultASREndpoint,
    defaultModel: OwlVoiceSettings.defaultASRModel,
    curatedModels: ["gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"],
    keyLabel: "OpenAI API Key",
    keyHint: "sk-…",
    sharesProviderProfileKey: true,
    authMode: .apiKey
  )

  static let gemini = OwlVoiceASRPreset(
    id: "gemini",
    displayName: "Google Gemini",
    endpoint: "https://generativelanguage.googleapis.com/v1beta/models",
    defaultModel: "gemini-3.5-transcribe",
    curatedModels: ["gemini-3.5-transcribe", "gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite"],
    keyLabel: "Gemini API Key",
    keyHint: "AIza…",
    sharesProviderProfileKey: true,
    authMode: .apiKey
  )

  static let openaiLogin = OwlVoiceASRPreset(
    id: "openai-login",
    displayName: "OpenAI 账号登录（ChatGPT 听写）",
    endpoint: "https://chatgpt.com/backend-api/transcribe",
    defaultModel: "chatgpt-dictation",
    curatedModels: ["chatgpt-dictation"],
    keyLabel: "ChatGPT 账号登录",
    keyHint: "codex login",
    sharesProviderProfileKey: false,
    authMode: .openAILogin
  )

  /// 语音识别预设目录：OpenAI API Key、Google Gemini API Key 与 OpenAI 账号登录（ChatGPT 听写）。
  static let presets: [OwlVoiceASRPreset] = [openai, gemini, openaiLogin]

  static func preset(id: String) -> OwlVoiceASRPreset {
    presets.first { $0.id == id } ?? openai
  }
}

/// OpenAI 账号登录（Codex CLI ChatGPT 听写）的本机登录态模型，对齐 Responsay `ChatGPTDictationAccountStatus`。
enum OwlVoiceOpenAILoginStatus: Equatable, Sendable {
  case unchecked
  case checking
  case signedIn(plan: String?)
  case cliMissing
  case signedOut
  case notChatGPT(method: String)
  case unavailable(message: String)

  var statusText: String {
    switch self {
    case .unchecked:
      return "尚未检查 Codex 登录"
    case .checking:
      return "正在检查 Codex 登录状态…"
    case .signedIn(let plan):
      if let plan, !plan.isEmpty {
        return "Codex 已用 ChatGPT 账号登录 · \(plan)"
      }
      return "Codex 已用 ChatGPT 账号登录"
    case .cliMissing:
      return "未找到 Codex CLI，安装后在终端登录"
    case .signedOut:
      return "Codex 未登录"
    case .notChatGPT(let method):
      return "Codex 当前不是用 ChatGPT 账号登录（\(method)）"
    case .unavailable(let message):
      return message
    }
  }

  var isReady: Bool {
    if case .signedIn = self { return true }
    return false
  }

  var needsTerminalLogin: Bool {
    switch self {
    case .cliMissing, .signedOut, .notChatGPT:
      return true
    case .unchecked, .checking, .signedIn, .unavailable:
      return false
    }
  }

  static let loginCommand = "codex login"
}

/// 仅驻留内存的 ChatGPT 听写凭据（从 `codex app-server` `getAuthStatus` 提取 JWT 的 `chatgpt_account_id` 与 `chatgpt_plan_type`）。
struct OwlVoiceOpenAILoginCredential: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  private let accessToken: String
  private let accountId: String
  let planType: String?
  let expiresAt: Date?

  init(
    accessToken: String,
    accountId: String,
    planType: String? = nil,
    expiresAt: Date? = nil
  ) {
    self.accessToken = accessToken
    self.accountId = accountId
    self.planType = planType
    self.expiresAt = expiresAt
  }

  init?(accessToken: String) {
    let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
          accessToken.utf8.allSatisfy({
            ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z"))
              || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z"))
              || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
              || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: ".")
          }),
          let payload = Self.base64URLDecoded(parts[1]),
          let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
          let auth = claims["https://api.openai.com/auth"] as? [String: Any],
          let accountId = auth["chatgpt_account_id"] as? String,
          !accountId.isEmpty else {
      return nil
    }
    self.accessToken = accessToken
    self.accountId = accountId
    self.planType = auth["chatgpt_plan_type"] as? String
    self.expiresAt = (claims["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
  }

  func isFresh(at now: Date = Date(), margin: TimeInterval = 300) -> Bool {
    guard let expiresAt else { return true }
    return expiresAt.timeIntervalSince(now) > margin
  }

  func withBearerRouting<R>(_ body: (_ accessToken: String, _ accountId: String) throws -> R) rethrows -> R {
    try body(accessToken, accountId)
  }

  var description: String { "OwlVoiceOpenAILoginCredential(<redacted>)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

  private static func base64URLDecoded(_ value: Substring) -> Data? {
    var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    text += String(repeating: "=", count: (4 - text.count % 4) % 4)
    return Data(base64Encoded: text)
  }
}

/// 与 `codex app-server` (stdio) 通信的按行 JSON-RPC 通道抽象，使握手协议可脱离真实子进程做确定性单测。
protocol OwlCodexAppServerChannel: AnyObject {
  func send(_ message: Data) throws
  func receiveLine() throws -> Data
}

enum OwlCodexLoginResult: Equatable, Sendable {
  case signedOut
  case otherMethod(String)
  case chatGPT(OwlVoiceOpenAILoginCredential)
}

enum OwlCodexAppServerError: Error, Equatable, Sendable {
  case codexMissing
  case incompatibleCodex
  case codexUnavailable
  case invalidCredential

  var loginStatus: OwlVoiceOpenAILoginStatus {
    switch self {
    case .codexMissing:
      return .cliMissing
    case .incompatibleCodex:
      return .unavailable(message: "当前 Codex 版本不支持登录状态查询")
    case .codexUnavailable:
      return .unavailable(message: "无法从 Codex 读取登录状态（启动失败或超时）")
    case .invalidCredential:
      return .unavailable(message: "Codex 返回的登录凭据无法识别，请运行 codex login 重新登录")
    }
  }
}

final class OwlCodexAppServerProcess: OwlCodexAppServerChannel {
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let deadline: Date
  private var buffer = Data()
  private var receivedBytes = 0
  private var isClosed = false

  init(executable: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, timeout: TimeInterval = 10) throws {
    self.deadline = Date().addingTimeInterval(timeout)
    process.executableURL = executable
    process.arguments = ["app-server"]
    process.environment = [
      "HOME": home.path,
      "PATH": executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
      "TMPDIR": FileManager.default.temporaryDirectory.path,
      "NO_COLOR": "1",
    ]
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      throw OwlCodexAppServerError.codexUnavailable
    }
    let writer = input.fileHandleForWriting.fileDescriptor
    _ = fcntl(writer, F_SETFL, fcntl(writer, F_GETFL) | O_NONBLOCK)
    _ = fcntl(writer, F_SETNOSIGPIPE, 1)
    let reader = output.fileHandleForReading.fileDescriptor
    _ = fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) | O_NONBLOCK)
  }

  deinit {
    close()
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    let pid = process.processIdentifier
    if pid > 0 && process.isRunning {
      kill(pid, SIGTERM)
      let limit = Date().addingTimeInterval(0.5)
      while process.isRunning && Date() < limit {
        Thread.sleep(forTimeInterval: 0.01)
      }
      if process.isRunning {
        kill(pid, SIGKILL)
      }
      process.waitUntilExit()
    }
    try? input.fileHandleForWriting.close()
    try? output.fileHandleForReading.close()
  }

  func send(_ message: Data) throws {
    try message.withUnsafeBytes { raw in
      guard let start = raw.baseAddress else { return }
      var offset = 0
      while offset < message.count {
        try checkActive()
        let count = Darwin.write(
          input.fileHandleForWriting.fileDescriptor,
          start.advanced(by: offset),
          message.count - offset
        )
        if count > 0 {
          offset += count
        } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
          Thread.sleep(forTimeInterval: 0.01)
        } else {
          throw OwlCodexAppServerError.codexUnavailable
        }
      }
    }
  }

  func receiveLine() throws -> Data {
    while true {
      try checkActive()
      if let newline = buffer.firstIndex(of: 10) {
        let line = Data(buffer[..<newline])
        buffer.removeSubrange(...newline)
        return line
      }
      var bytes = [UInt8](repeating: 0, count: 8192)
      let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
      if count > 0 {
        receivedBytes += count
        guard receivedBytes <= 2_000_000 else {
          throw OwlCodexAppServerError.codexUnavailable
        }
        buffer.append(contentsOf: bytes.prefix(count))
      } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
        throw OwlCodexAppServerError.codexUnavailable
      } else {
        Thread.sleep(forTimeInterval: 0.01)
      }
    }
  }

  private func checkActive() throws {
    if Date() >= deadline {
      throw OwlCodexAppServerError.codexUnavailable
    }
  }
}

enum OwlVoiceOpenAILoginInspector {
  private static let cacheLock = NSLock()
  private nonisolated(unsafe) static var cachedCredential: OwlVoiceOpenAILoginCredential?
  private nonisolated(unsafe) static var cachedStatus: OwlVoiceOpenAILoginStatus = .unchecked

  static var lastKnownStatus: OwlVoiceOpenAILoginStatus {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    return cachedStatus
  }

  static func clearCachedCredential() {
    cacheLock.lock()
    cachedCredential = nil
    cacheLock.unlock()
  }

  /// 在抽象通道上执行 `initialize` -> `initialized` -> `getAuthStatus` 握手，跳过通知并拒绝服务端请求。
  static func readLogin(
    over channel: OwlCodexAppServerChannel,
    refreshToken: Bool,
    clientVersion: String = "2.4.1"
  ) throws -> OwlCodexLoginResult {
    try sendFrame([
      "id": 1,
      "method": "initialize",
      "params": [
        "clientInfo": ["name": "owltype", "version": clientVersion],
        "capabilities": ["experimentalApi": true],
      ],
    ], over: channel)
    _ = try receiveResult(for: 1, from: channel)
    try sendFrame(["method": "initialized"], over: channel)
    try sendFrame([
      "id": 2,
      "method": "getAuthStatus",
      "params": [
        "includeToken": true,
        "refreshToken": refreshToken,
      ],
    ], over: channel)
    let status = try receiveResult(for: 2, from: channel)
    guard let rawMethod = status["authMethod"] as? String, !rawMethod.isEmpty else {
      return .signedOut
    }
    guard rawMethod == "chatgpt" || rawMethod == "chatgptAuthTokens" else {
      return .otherMethod(rawMethod)
    }
    guard let token = status["authToken"] as? String,
          let credential = OwlVoiceOpenAILoginCredential(accessToken: token) else {
      throw OwlCodexAppServerError.invalidCredential
    }
    return .chatGPT(credential)
  }

  private static func sendFrame(_ message: [String: Any], over channel: OwlCodexAppServerChannel) throws {
    var data = try JSONSerialization.data(withJSONObject: message)
    data.append(10)
    try channel.send(data)
  }

  private static func receiveResult(for id: Int, from channel: OwlCodexAppServerChannel) throws -> [String: Any] {
    for _ in 0..<128 {
      let line = try channel.receiveLine()
      guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        continue
      }
      if frame["method"] != nil {
        if let requestId = frame["id"] {
          try sendFrame([
            "id": requestId,
            "error": ["code": -32601, "message": "not supported by Owltype"],
          ], over: channel)
        }
        continue
      }
      guard (frame["id"] as? Int) == id else {
        continue
      }
      if frame["error"] != nil {
        throw OwlCodexAppServerError.incompatibleCodex
      }
      guard let result = frame["result"] as? [String: Any] else {
        throw OwlCodexAppServerError.codexUnavailable
      }
      return result
    }
    throw OwlCodexAppServerError.codexUnavailable
  }

  static func fetchCredential(
    forceRefresh: Bool = false,
    now: Date = Date(),
    reader: (@Sendable (_ refreshToken: Bool) throws -> OwlCodexLoginResult)? = nil
  ) async throws -> OwlVoiceOpenAILoginCredential {
    if forceRefresh {
      clearCachedCredential()
    } else {
      cacheLock.lock()
      let cached = cachedCredential
      cacheLock.unlock()
      if let cached, cached.isFresh(at: now) {
        return cached
      }
    }

    let performRead: @Sendable (Bool) throws -> OwlCodexLoginResult
    if let reader {
      performRead = reader
    } else {
      guard let executable = resolveCodexExecutable() else {
        recordStatus(.cliMissing, credential: nil)
        throw OwlVoiceError.invalidToken(status: 401, message: OwlVoiceOpenAILoginStatus.cliMissing.statusText)
      }
      performRead = { refresh in
        let channel = try OwlCodexAppServerProcess(executable: executable)
        defer { channel.close() }
        return try readLogin(over: channel, refreshToken: refresh)
      }
    }

    return try await Task.detached(priority: .userInitiated) {
      var refreshing = forceRefresh
      while true {
        let loginResult: OwlCodexLoginResult
        do {
          loginResult = try performRead(refreshing)
        } catch let error as OwlCodexAppServerError {
          let status = error.loginStatus
          recordStatus(status, credential: nil)
          throw OwlVoiceError.invalidToken(status: 401, message: status.statusText)
        } catch {
          let status = OwlVoiceOpenAILoginStatus.unavailable(message: "无法从 Codex 读取登录状态（启动失败或超时）")
          recordStatus(status, credential: nil)
          throw OwlVoiceError.invalidToken(status: 401, message: status.statusText)
        }

        switch loginResult {
        case .signedOut:
          recordStatus(.signedOut, credential: nil)
          throw OwlVoiceError.invalidToken(status: 401, message: OwlVoiceOpenAILoginStatus.signedOut.statusText)
        case .otherMethod(let method):
          let status = OwlVoiceOpenAILoginStatus.notChatGPT(method: method)
          recordStatus(status, credential: nil)
          throw OwlVoiceError.invalidToken(status: 401, message: status.statusText)
        case .chatGPT(let credential):
          if !refreshing && !credential.isFresh(at: now) {
            refreshing = true
            continue
          }
          recordStatus(.signedIn(plan: credential.planType), credential: credential)
          return credential
        }
      }
    }.value
  }

  static func resolveCodexExecutable(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL? {
    let home = fileManager.homeDirectoryForCurrentUser.path
    let pathEntries = (environment["PATH"] ?? "")
      .split(separator: ":")
      .map(String.init)
    let candidates = [
      "\(home)/.local/bin",
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "\(home)/.codex/packages/standalone/current/bin",
      "\(home)/.npm-global/bin",
      "\(home)/.cargo/bin",
    ] + pathEntries
    for dir in candidates where !dir.isEmpty {
      let fullPath = (dir as NSString).appendingPathComponent("codex")
      if fileManager.isExecutableFile(atPath: fullPath) {
        return URL(fileURLWithPath: fullPath)
      }
    }
    return nil
  }

  /// 通过 `codex app-server` stdio JSON-RPC 读取本机 ChatGPT 登录态（不直接读取 `~/.codex/auth.json`）。
  static func inspectStatus() async -> (status: OwlVoiceOpenAILoginStatus, credential: OwlVoiceOpenAILoginCredential?) {
    if OwlDefaults.isRunningUnitTests {
      return (.unchecked, nil)
    }
    guard let executable = resolveCodexExecutable() else {
      recordStatus(.cliMissing, credential: nil)
      return (.cliMissing, nil)
    }
    return await Task.detached(priority: .userInitiated) {
      let result = queryCodexAppServer(executable: executable, refreshToken: false)
      recordStatus(result.status, credential: result.credential)
      return result
    }.value
  }

  /// 发送 0.2 秒静音 WAV 到 ChatGPT 听写接口验证真实端到端连通性。
  static func verifyConnection(
    transport: OwlVoiceNetworkTransport = OwlURLSessionVoiceTransport(),
    loginCredentialProvider: (@Sendable (_ forceRefresh: Bool) async throws -> OwlVoiceOpenAILoginCredential)? = nil
  ) async -> (succeeded: Bool, message: String, status: OwlVoiceOpenAILoginStatus) {
    if OwlDefaults.isRunningUnitTests && loginCredentialProvider == nil {
      return (true, "✓ 已连接 · ChatGPT 听写接口已响应（静音测试）", .signedIn(plan: "plus"))
    }
    let silentPCM = Data(repeating: 0, count: 6400) // 0.2s @ 16kHz mono 16-bit PCM
    let silentWAV = OwlWAVPacker.pack16kMono(pcmData: silentPCM)
    let client = OwlVoiceGrokASRClient(
      providerID: OwlVoiceASRCatalog.openaiLogin.id,
      endpoint: URL(string: OwlVoiceASRCatalog.openaiLogin.endpoint)!,
      model: OwlVoiceASRCatalog.openaiLogin.defaultModel,
      transport: transport,
      requestTimeout: 15.0,
      loginCredentialProvider: loginCredentialProvider ?? { forceRefresh in
        try await fetchCredential(forceRefresh: forceRefresh)
      }
    )
    do {
      _ = try await client.recognizeViaOpenAILogin(audioWavData: silentWAV)
      try Task.checkCancellation()
      let currentStatus = lastKnownStatus == .unchecked ? .signedIn(plan: nil) : lastKnownStatus
      return (true, "✓ 已连接 · ChatGPT 听写接口已响应（静音测试）", currentStatus)
    } catch is CancellationError {
      return (false, "已取消验证", lastKnownStatus)
    } catch let error as OwlVoiceError {
      switch error {
      case .invalidToken(let status, let message):
        let resolvedStatus: OwlVoiceOpenAILoginStatus = status == 401 && lastKnownStatus == .unchecked
          ? .signedOut
          : lastKnownStatus
        return (false, message ?? error.localizedDescription, resolvedStatus)
      case .badHTTPStatus(_, let message):
        return (false, message ?? error.localizedDescription, lastKnownStatus)
      default:
        return (false, error.localizedDescription, lastKnownStatus)
      }
    } catch {
      return (false, "ChatGPT 网络请求失败，请稍后重试。", lastKnownStatus)
    }
  }

  private static func recordStatus(_ status: OwlVoiceOpenAILoginStatus, credential: OwlVoiceOpenAILoginCredential?) {
    cacheLock.lock()
    cachedStatus = status
    cachedCredential = credential
    cacheLock.unlock()
  }

  private static func queryCodexAppServer(
    executable: URL,
    refreshToken: Bool
  ) -> (status: OwlVoiceOpenAILoginStatus, credential: OwlVoiceOpenAILoginCredential?) {
    do {
      let channel = try OwlCodexAppServerProcess(executable: executable)
      defer { channel.close() }
      let login = try readLogin(over: channel, refreshToken: refreshToken)
      switch login {
      case .signedOut:
        return (.signedOut, nil)
      case .otherMethod(let method):
        return (.notChatGPT(method: method), nil)
      case .chatGPT(let credential):
        return (.signedIn(plan: credential.planType), credential)
      }
    } catch let error as OwlCodexAppServerError {
      return (error.loginStatus, nil)
    } catch {
      return (.unavailable(message: "无法从 Codex 读取登录状态（启动失败或超时）"), nil)
    }
  }
}

enum OwlVoiceSettings {
  static let enabledKey = "OwlVoiceInputEnabled"
  static let holdRightOptionKey = "OwlVoiceHoldRightOption"
  static let asrProviderIDKey = "OwlVoiceASRProviderID"
  static let asrEndpointKey = "OwlVoiceASREndpoint"
  static let asrModelKey = "OwlVoiceASRModel"
  static let polishEnabledKey = "OwlVoicePolishEnabled"
  static let deepSeekModelKey = "OwlVoiceDeepSeekModel"

  static let defaultASREndpoint = "https://api.openai.com/v1/audio/transcriptions"
  static let defaultASRModel = "gpt-transcribe"

  static var isEnabled: Bool {
    get {
      OwlDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }
    set {
      OwlDefaults.standard.set(newValue, forKey: enabledKey)
    }
  }

  /// 上游 `msime` 默认语音激活手势：按住右 Option（keyCode 61）说话，松手即上屏，组合键自动退让（ChordCancel）。
  static var holdRightOptionEnabled: Bool {
    get {
      OwlDefaults.standard.object(forKey: holdRightOptionKey) as? Bool ?? true
    }
    set {
      OwlDefaults.standard.set(newValue, forKey: holdRightOptionKey)
    }
  }

  /// Resolves the active ASR provider ID. When the user has not explicitly configured a dedicated
  /// ASR preset with a valid key, automatically follows a configured Gemini or OpenAI provider
  /// profile from `OwlProviderProfileStore` (preferring the default profile).
  static func resolvedASRProviderID(
    defaults: UserDefaults = OwlDefaults.standard,
    store: OwlProviderProfileStore = .shared,
    secrets: OwlSecretStoring = OwlProviderKeychain()
  ) -> String {
    let raw = defaults.string(forKey: asrProviderIDKey)
    let explicitPreset = raw.flatMap { id in OwlVoiceASRCatalog.presets.first(where: { $0.id == id }) }

    if let explicitPreset {
      if explicitPreset.isOpenAILogin {
        return explicitPreset.id
      }
      if OwlVoiceKeychain.isASRKeyConfigured(forProviderID: explicitPreset.id, store: store, secrets: secrets) {
        return explicitPreset.id
      }
      if OwlDefaults.isRunningUnitTests && store === OwlProviderProfileStore.shared {
        return explicitPreset.id
      }
    }

    if !(OwlDefaults.isRunningUnitTests && store === OwlProviderProfileStore.shared) {
      let profiles = store.profiles()
      let defaultID = store.defaultProfile?.id
      let ordered = profiles.sorted { lhs, rhs in
        (lhs.id == defaultID ? 0 : 1) < (rhs.id == defaultID ? 0 : 1)
      }
      let supportedIDs: Set<String> = [OwlVoiceASRCatalog.gemini.id, OwlVoiceASRCatalog.openai.id]
      for profile in ordered {
        let inferred = OwlLLMProviderCatalog.inferredProviderID(for: profile)
        if supportedIDs.contains(inferred),
           OwlVoiceKeychain.isASRKeyConfigured(forProviderID: inferred, store: store, secrets: secrets) {
          return inferred
        }
      }
      for profile in ordered {
        let inferred = OwlLLMProviderCatalog.inferredProviderID(for: profile)
        if supportedIDs.contains(inferred) {
          return inferred
        }
      }
    }

    return explicitPreset?.id ?? OwlVoiceASRCatalog.openai.id
  }

  static var asrProviderID: String {
    get {
      resolvedASRProviderID()
    }
    set {
      OwlDefaults.standard.set(OwlVoiceASRCatalog.preset(id: newValue).id, forKey: asrProviderIDKey)
    }
  }

  static var asrEndpoint: String {
    get {
      let activePreset = OwlVoiceASRCatalog.preset(id: asrProviderID)
      if activePreset.isOpenAILogin {
        return activePreset.endpoint
      }
      let explicitProviderID = OwlDefaults.standard.string(forKey: asrProviderIDKey)
      guard explicitProviderID == activePreset.id,
            let raw = OwlDefaults.standard.string(forKey: asrEndpointKey)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let url = URL(string: raw),
            OwlProviderRegistry.isHTTPS(url),
            !(url.host?.lowercased().hasSuffix("x.ai") ?? false) else {
        return activePreset.endpoint
      }
      return raw
    }
    set {
      let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        OwlDefaults.standard.removeObject(forKey: asrEndpointKey)
      } else {
        OwlDefaults.standard.set(trimmed, forKey: asrEndpointKey)
      }
    }
  }

  static var asrEndpointURL: URL {
    URL(string: asrEndpoint) ?? URL(string: defaultASREndpoint)!
  }

  static var asrModel: String {
    get {
      let activePreset = OwlVoiceASRCatalog.preset(id: asrProviderID)
      if activePreset.isOpenAILogin {
        return activePreset.defaultModel
      }
      let explicitProviderID = OwlDefaults.standard.string(forKey: asrProviderIDKey)
      guard explicitProviderID == activePreset.id,
            let raw = OwlDefaults.standard.string(forKey: asrModelKey)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
        return activePreset.defaultModel
      }
      return raw
    }
    set {
      let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        OwlDefaults.standard.removeObject(forKey: asrModelKey)
      } else {
        OwlDefaults.standard.set(trimmed, forKey: asrModelKey)
      }
    }
  }

  static var isPolishEnabled: Bool {
    get {
      OwlDefaults.standard.object(forKey: polishEnabledKey) as? Bool ?? false
    }
    set {
      OwlDefaults.standard.set(newValue, forKey: polishEnabledKey)
    }
  }

  static var deepSeekModel: String {
    get {
      OwlDefaults.standard.string(forKey: deepSeekModelKey) ?? "deepseek-chat"
    }
    set {
      OwlDefaults.standard.set(newValue, forKey: deepSeekModelKey)
    }
  }
}
