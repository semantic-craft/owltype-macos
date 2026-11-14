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
