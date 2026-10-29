//
//  OwlAgentBridge.swift
//  Owltype
//
//  The App end of the Owl Agent Bridge (rust/shared/contracts/agent-bridge): a Unix domain socket
//  that owltype-mcp connects to. Everything here runs on one background queue; nothing is called
//  from the IMK key path (scripts/check-ai-off-hot-path.sh keeps the controller and engine from
//  naming it). Requests reach the App only through `OwlAgentBridgeService`, which hops to the main
//  thread itself when it needs UI or input state.
//
//  Each connection is admitted only after the peer is proven to be this user (`getpeereid`) and
//  Owltype's own helper (`OwlAgentPeerVerifier`, by code signature). `hello` must come first and
//  within `helloTimeout`; an idle connection closes after `idleTimeout`. Closing a connection
//  cancels whatever request it still has in flight.
//

import Darwin
import Foundation

/// What a request is answered with: a result for the contract's success message, or an error.
typealias OwlAgentBridgeReply = Result<OwlJSONValue, OwlAgentBridgeProtocol.ErrorObject>

/// Cancels a request whose connection went away. Calling it more than once is harmless.
final class OwlAgentBridgeCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var handlers: [() -> Void] = []
  private var cancelled = false

  var isCancelled: Bool { lock.withLock { cancelled } }

  /// Runs `handler` on cancellation, at once when already cancelled.
  func onCancel(_ handler: @escaping () -> Void) {
    let runNow = lock.withLock { () -> Bool in
      if cancelled { return true }
      handlers.append(handler)
      return false
    }
    if runNow { handler() }
  }

  func cancel() {
    let pending = lock.withLock { () -> [() -> Void] in
      guard !cancelled else { return [] }
      cancelled = true
      defer { handlers = [] }
      return handlers
    }
    pending.forEach { $0() }
  }
}

/// Who is on the other end, after `hello`.
struct OwlAgentBridgeClient: Equatable, Sendable {
  var helper: OwlAgentBridgeProtocol.Component
  var agentClient: OwlAgentBridgeProtocol.Component?
  var processID: pid_t
}

/// The App behind the bridge. Each method answers exactly once through `reply`, on any thread.
protocol OwlAgentBridgeService: AnyObject {
  var appBuild: OwlAgentBridgeProtocol.AppBuild { get }
  func handle(_ call: OwlAgentBridgeProtocol.Call, from client: OwlAgentBridgeClient,
              cancellation: OwlAgentBridgeCancellation, reply: @escaping (OwlAgentBridgeReply) -> Void)
}

final class OwlAgentBridge {
  typealias Wire = OwlAgentBridgeProtocol

  enum StartError: Error, Equatable {
    case pathTooLong
    case unsafeDirectory(String)
    case socket(String)
  }

  /// `~/Library/Application Support/Owltype/AgentBridge/bridge.sock`; owltype-mcp computes the same.
  static var defaultSocketURL: URL {
    OwlApp.userDir.appendingPathComponent("AgentBridge", isDirectory: true)
      .appendingPathComponent("bridge.sock", isDirectory: false)
  }

  let socketURL: URL
  let queue = DispatchQueue(label: "im.owltype.agent-bridge", qos: .utility)
  var helloTimeout: DispatchTimeInterval = .seconds(5)
  var idleTimeout: DispatchTimeInterval = .seconds(60)

  private let verifier: OwlAgentPeerVerifying
  private weak var service: OwlAgentBridgeService?
  private var listener: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private var connections: [ObjectIdentifier: Connection] = [:]

  init(socketURL: URL = OwlAgentBridge.defaultSocketURL, verifier: OwlAgentPeerVerifying, service: OwlAgentBridgeService) {
    self.socketURL = socketURL
    self.verifier = verifier
    self.service = service
  }

  deinit { stopOnQueue() }

  var isListening: Bool { queue.sync { listener >= 0 } }

  func start() throws { try queue.sync { try startOnQueue() } }

  func stop() { queue.sync { stopOnQueue() } }

  // MARK: Listening

  private func startOnQueue() throws {
    guard listener < 0 else { return }
    let path = socketURL.path
    guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw StartError.pathTooLong }
    try Self.preparePrivateDirectory(socketURL.deletingLastPathComponent())
    try Self.removeStaleSocket(at: path)

    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw StartError.socket(Self.errnoText("socket")) }
    var address = Self.address(path)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
      let why = Self.errnoText("bind/listen")
      close(descriptor)
      unlink(path)
      throw StartError.socket(why)
    }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    listener = descriptor
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    source.setEventHandler { [weak self] in self?.acceptPending() }
    source.setCancelHandler { close(descriptor) }
    acceptSource = source
    source.resume()
  }

  private func stopOnQueue() {
    guard listener >= 0 else { return }
    acceptSource?.cancel()
    acceptSource = nil
    listener = -1
    unlink(socketURL.path)
    connections.values.forEach { $0.close() }
    connections = [:]
  }

  /// Creates the directory 0700 or tightens it; refuses one owned by someone else or a symlink.
  static func preparePrivateDirectory(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    var info = stat()
    guard lstat(directory.path, &info) == 0 else { throw StartError.unsafeDirectory(errnoText("lstat")) }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
      throw StartError.unsafeDirectory("not a directory owned by this user")
    }
    guard chmod(directory.path, 0o700) == 0 else { throw StartError.unsafeDirectory(errnoText("chmod")) }
  }

  private static func removeStaleSocket(at path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0 else { return }
    guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
      throw StartError.unsafeDirectory("something other than our socket is at the socket path")
    }
    unlink(path)
  }

  private static func address(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
    }
    return address
  }

  static func errnoText(_ call: String) -> String { "\(call): \(String(cString: strerror(errno)))" }

  private func acceptPending() {
    while true {
      let descriptor = accept(listener, nil, nil)
      guard descriptor >= 0 else { return }
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
      var noSigPipe: Int32 = 1
      setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
      guard let peer = verifier.admit(descriptor) else {
        close(descriptor)
        continue
      }
      let connection = Connection(descriptor: descriptor, processID: peer, bridge: self)
      connections[ObjectIdentifier(connection)] = connection
      connection.open()
    }
  }

  fileprivate func closed(_ connection: Connection) {
    connections[ObjectIdentifier(connection)] = nil
  }

  // MARK: Connections

  fileprivate final class Connection {
    private let descriptor: Int32
    private let processID: pid_t
    private unowned let bridge: OwlAgentBridge
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var client: OwlAgentBridgeClient?
    private var inFlight: [Wire.RequestID: OwlAgentBridgeCancellation] = [:]
    private var timer: DispatchSourceTimer?
    private var isClosed = false

    init(descriptor: Int32, processID: pid_t, bridge: OwlAgentBridge) {
      self.descriptor = descriptor
      self.processID = processID
      self.bridge = bridge
    }

    func open() {
      _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
      let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: bridge.queue)
      let descriptor = descriptor
      source.setEventHandler { [weak self] in self?.readAvailable() }
      source.setCancelHandler { Darwin.close(descriptor) }
      readSource = source
      source.resume()
      arm(bridge.helloTimeout)
    }

    /// Closes the connection when nothing arrives in `interval` and no request is waiting.
    private func arm(_ interval: DispatchTimeInterval) {
      timer?.cancel()
      let timer = DispatchSource.makeTimerSource(queue: bridge.queue)
      timer.schedule(deadline: .now() + interval)
      timer.setEventHandler { [weak self] in
        guard let self, self.inFlight.isEmpty else { return }
        self.close()
      }
      self.timer = timer
      timer.resume()
    }

    private func readAvailable() {
      var chunk = [UInt8](repeating: 0, count: 64 * 1024)
      let count = read(descriptor, &chunk, chunk.count)
      if count < 0, errno == EAGAIN || errno == EINTR { return }
      guard count > 0 else { return close() }
      buffer.append(contentsOf: chunk[0..<count])
      while let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<newline]
        buffer.removeSubrange(buffer.startIndex...newline)
        // A complete line can arrive in the same read that crosses the limit; check each one.
        guard line.count <= Wire.maxLineBytes else { return refuseLongLine() }
        receive(Data(line))
        if isClosed { return }
      }
      if buffer.count > Wire.maxLineBytes { refuseLongLine() }
    }

    private func refuseLongLine() {
      send(.failure(.init(id: nil, error: .init(code: .invalidRequest, message: "Line longer than 1 MiB"))))
      close()
    }

    /// The request on `line`, or nil after answering why it is not one.
    private func parse(_ line: Data) -> (Wire.RequestID, Wire.Call)? {
      guard let value = try? JSONDecoder().decode(OwlJSONValue.self, from: line) else {
        send(.failure(.init(id: nil, error: .init(code: .parseError, message: "Parse error"))))
        return nil
      }
      guard let request = try? Wire.decodeStrict(Wire.Request.self, from: value), request.jsonrpc == "2.0" else {
        send(.failure(.init(id: nil, error: .init(code: .invalidRequest, message: "Invalid request"))))
        return nil
      }
      do {
        return (request.id, try request.call())
      } catch Wire.ContractError.unknownMethod {
        fail(request.id, .methodNotFound, "Method not found")
      } catch Wire.ContractError.invalidParams(let field) {
        fail(request.id, .invalidParams, "Invalid params", Wire.ErrorData(field: field))
      } catch {
        fail(request.id, .invalidRequest, "Invalid request")
      }
      return nil
    }

    private func receive(_ line: Data) {
      arm(bridge.idleTimeout)
      guard let (requestID, call) = parse(line) else { return }
      let request = (id: requestID, call: call)
      guard inFlight[request.id] == nil else { return fail(request.id, .invalidRequest, "Request id already in use") }

      if case .hello(let hello) = call { return answerHello(hello, id: request.id) }
      guard let client else { return fail(request.id, .helloRequired, "hello must be the first request") }
      guard let service = bridge.service else { return fail(request.id, .internalError, "Owltype is shutting down") }

      let cancellation = OwlAgentBridgeCancellation()
      inFlight[request.id] = cancellation
      let id = request.id
      service.handle(call, from: client, cancellation: cancellation) { [weak self] reply in
        guard let self else { return }
        self.bridge.queue.async {
          guard self.inFlight.removeValue(forKey: id) != nil, !self.isClosed else { return }
          switch reply {
          case .success(let result): self.send(.success(.init(id: id, result: result)))
          case .failure(let error): self.send(.failure(.init(id: id, error: error)))
          }
          self.arm(self.bridge.idleTimeout)
        }
      }
    }

    private func answerHello(_ hello: Wire.HelloParams, id: Wire.RequestID) {
      guard client == nil else { return fail(id, .invalidRequest, "hello was already sent") }
      guard hello.protocolVersion == Wire.protocolVersion else {
        return fail(id, .unsupportedProtocolVersion, "Unsupported protocol version",
                    Wire.ErrorData(supportedProtocolVersions: [Wire.protocolVersion]))
      }
      guard let service = bridge.service else { return fail(id, .internalError, "Owltype is shutting down") }
      client = OwlAgentBridgeClient(helper: hello.helper, agentClient: hello.agentClient, processID: processID)
      send(.success(.init(id: id, result: OwlJSONValue(encoding: Wire.HelloResult(
        protocolVersion: Wire.protocolVersion, app: service.appBuild)))))
    }

    private func fail(_ id: Wire.RequestID, _ code: Wire.ErrorCode, _ message: String, _ data: Wire.ErrorData? = nil) {
      send(.failure(.init(id: id, error: .init(code: code, message: message, data: data))))
    }

    private func send(_ response: Wire.Response) {
      var line = response.value.data
      line.append(0x0A)
      let sent = line.withUnsafeBytes { bytes -> Bool in
        var offset = 0
        var stalls = 0
        while offset < bytes.count {
          let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
          if written > 0 {
            offset += written
          } else if written < 0, errno == EAGAIN, stalls < 200 {
            stalls += 1
            usleep(5_000)
          } else if written < 0, errno == EINTR {
            continue
          } else {
            return false
          }
        }
        return true
      }
      if !sent { close() }
    }

    func close() {
      guard !isClosed else { return }
      isClosed = true
      timer?.cancel()
      readSource?.cancel()
      let pending = inFlight.values
      inFlight = [:]
      pending.forEach { $0.cancel() }
      bridge.closed(self)
    }
  }
}
