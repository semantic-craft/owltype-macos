import Foundation
import Observation

struct OwlPinnedWord: Codable, Equatable, Identifiable {
  let code: String
  let text: String
  let traditional: Bool
  var id: String { "\(code)\t\(traditional)\t\(text)" }
}

struct OwlTraditionalPinSource: Codable, Equatable {
  let code: String
  let text: String
  let source: String
  var actionPayload: [String: String] { ["code": code, "text": text, "source": source] }
}

/// Small local library; engine properties carry a cached copy to Lua, so typing does no file IO.
@Observable
final class OwlPinnedWords {
  static let shared = OwlPinnedWords(defaults: OwlDefaults.standard)
  static let property = "owl_pinned_words"
  private static let key = "OwlPinnedWordsV1"
  private let defaults: UserDefaults
  private let core: OwlAppSession
  private(set) var words: [OwlPinnedWord]
  private(set) var revision: UInt64 = 0
  private(set) var engineValue: String = ""

  init(defaults: UserDefaults) {
    self.defaults = defaults
    let initial = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([OwlPinnedWord].self, from: $0) } ?? []
    core = try! OwlAppSession("pins", args: OwlAppCore.payload(initial))
    words = []
    apply(core.call("snapshot"), persist: false)
  }

  private struct Snapshot: Decodable {
    let words: [OwlPinnedWord]
    let revision: UInt64
    let engineValue: String
    let inserted: Bool
  }

  @discardableResult
  func toggle(_ word: OwlPinnedWord) -> Bool {
    let snapshot: Snapshot = core.call("toggle", OwlAppCore.payload(word) as! [String: Any])
    apply(snapshot, persist: true)
    return snapshot.inserted
  }

  func remove(_ word: OwlPinnedWord) {
    apply(core.call("remove", OwlAppCore.payload(word) as! [String: Any]), persist: true)
  }

  private func apply(_ snapshot: Snapshot, persist: Bool) {
    words = snapshot.words
    revision = snapshot.revision
    engineValue = snapshot.engineValue
    if persist, let data = try? JSONEncoder().encode(words) { defaults.set(data, forKey: Self.key) }
  }

  static func hansToHant(_ text: String) -> String {
    guard let input = try? JSONEncoder().encode(text),
          let json = String(data: input, encoding: .utf8),
          let converted = json.withCString({ owl_msime_simplified_to_traditional_json($0) }) else {
      return text
    }
    defer { owl_msime_string_free(converted) }
    return (try? JSONDecoder().decode(String.self, from: Data(String(cString: converted).utf8))) ?? text
  }

  static func hantToHans(_ text: String) -> String {
    (text as NSString).applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
  }

  static func traditionalSources(engineValue: String) -> [OwlTraditionalPinSource] {
    struct Request: Decodable { let code: String; let text: String }
    let requests: [Request] = OwlAppCore.required(["operation": "user_data_rule", "rule": "pin_source_requests", "args": ["engineValue": engineValue]])
    let facts = requests.map { request -> [String: String] in
      let source = hantToHans(request.text)
      return ["code": request.code, "text": request.text, "source": source, "roundtrip": hansToHant(source)]
    }
    return OwlAppCore.required(["operation": "user_data_rule", "rule": "pin_sources", "args": ["facts": facts]])
  }

  /// Require a complete, unconfirmed full-pinyin composition. Initials, completions,
  /// partially selected sentences, non-Han candidates and other schemas are excluded.
  static func target(schema: String, input: String, composition: EngineComposition,
                     candidate: String, traditional: Bool, caret: Int) -> OwlPinnedWord? {
    struct Reply: Decodable { let word: OwlPinnedWord? }
    let reply: Reply = OwlAppCore.required(["operation": "user_data_rule", "rule": "pin_target", "args": [
      "schema": schema, "input": input, "preedit": composition.preedit, "selStart": composition.selStart,
      "candidate": candidate, "traditional": traditional, "caret": caret,
    ]])
    return reply.word
  }
}
