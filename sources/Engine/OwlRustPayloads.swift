// JSON transport contracts shared by the Rust engine and session adapters.

import Foundation

// MARK: - FFI JSON Payloads

struct OwlRustCandidateDTO: Decodable {
  let text: String
  let comment: String?
}

struct OwlRustSnapshotDTO: Decodable {
  let isOK: Bool
  let consumed: Bool?
  let committedText: String?
  let rawInput: String
  let preedit: String
  let page: Int
  let pageSize: Int
  let highlightedIndex: Int
  let hasMorePages: Bool
  let generation: UInt64?
  let caretPosition: Int?
  let preeditCaretByte: Int?
  let localMode: String
  let spellingSymbols: String
  let candidates: [OwlRustCandidateDTO]

  enum CodingKeys: String, CodingKey {
    case isOK = "ok", consumed, preedit, page, generation, candidates
    case committedText = "committed_text", rawInput = "raw_input"
    case pageSize = "page_size", highlightedIndex = "highlighted_index"
    case hasMorePages = "has_more_pages", caretPosition = "caret_position"
    case preeditCaretByte = "preedit_caret_byte", localMode = "local_mode"
    case spellingSymbols = "spelling_symbols"
  }
}

struct OwlRustRerankModelStatusDTO: Decodable {
  let enabled: Bool?
  let state: String
  let attached: Bool?
  let error: String?
}

struct OwlRustRerankStatusDTO: Decodable {
  let keyboard: OwlRustRerankModelStatusDTO?
  let settled: OwlRustRerankModelStatusDTO?
}

struct OwlRustSettledRerankResponseDTO: Decodable {
  let status: String
  let token: UInt64?
  let current: Bool?
  let moved: Bool?
  let error: String?
}

struct OwlRerankConfiguration: Codable, Equatable {
  struct Model: Codable, Equatable {
    let enabled: Bool
    let path: String
    let source: String
    let version: String
    let expectedSHA256: String

    enum CodingKeys: String, CodingKey {
      case enabled
      case path
      case source
      case version
      case expectedSHA256 = "expected_sha256"
    }
  }

  let keyboard: Model
  let settled: Model

  static func current(sharedSupportURL: URL?, resourcesURL: URL? = nil) -> Self {
    func model(for kind: OwlRerankModelKind) -> Model {
      let descriptor = OwlRerankModelDescriptor.descriptor(for: kind)
      return Model(
        enabled: OwlExperimentalPreferences.rerankEnabled(for: kind),
        path: resourcesURL?.appendingPathComponent("models/" + descriptor.fileName).path
          ?? descriptor.url(sharedSupportURL: sharedSupportURL)?.path ?? "",
        source: descriptor.source,
        version: descriptor.version,
        expectedSHA256: descriptor.expectedSHA256
      )
    }
    return Self(keyboard: model(for: .keyboard), settled: model(for: .settled))
  }

  func serialized() -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
