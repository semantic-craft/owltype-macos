//
//  OwlVoiceNetworkTransport.swift
//  Owltype — Voice Input Subsystem
//

import Foundation

public protocol OwlVoiceNetworkTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

public struct OwlURLSessionVoiceTransport: OwlVoiceNetworkTransport {
  private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }

  private static let noRedirectDelegate = NoRedirectDelegate()
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request, delegate: Self.noRedirectDelegate)
  }
}

public final class OwlStubVoiceTransport: OwlVoiceNetworkTransport, @unchecked Sendable {
  private let lock = NSLock()
  public private(set) var recordedRequests: [URLRequest] = []
  public var handler: (@Sendable (URLRequest) throws -> (Data, URLResponse))?

  public init(handler: (@Sendable (URLRequest) throws -> (Data, URLResponse))? = nil) {
    self.handler = handler
  }

  public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    lock.lock()
    recordedRequests.append(request)
    let currentHandler = handler
    lock.unlock()

    if let currentHandler {
      return try currentHandler(request)
    }

    let body = Data("{\"text\":\"默认测试转写结果\"}".utf8)
    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "https://api.x.ai/v1/audio/transcriptions")!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    return (body, response)
  }
}
