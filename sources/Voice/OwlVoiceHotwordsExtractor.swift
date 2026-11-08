//
//  OwlVoiceHotwordsExtractor.swift
//  Owltype — Voice Input Subsystem
//

import Foundation
import SQLite3

// MARK: - Protocol Definition

public protocol OwlVoiceHotwordsExtracting: Sendable {
  /// Extracts sanitized, deduplicated hotwords ordered by priority (Pinned > Custom > Bigrams), filtered of noise.
  func extractHotwords(limit: Int) -> [String]

  /// Assembles pre-context and hotwords into an ASR prompt strictly within maxBytes UTF-8 without token truncation.
  func buildPrompt(preContext: String?, hotwords: [String]?, maxBytes: Int) -> String
}

public extension OwlVoiceHotwordsExtracting {
  func extractHotwords() -> [String] {
    extractHotwords(limit: 100)
  }

  func buildPrompt(preContext: String?, hotwords: [String]? = nil, maxBytes: Int = 800) -> String {
    buildPrompt(preContext: preContext, hotwords: hotwords, maxBytes: maxBytes)
  }

  func buildPrompt(preContext: String?) -> String {
    buildPrompt(preContext: preContext, hotwords: nil, maxBytes: 800)
  }

  func buildPrompt(preContext: String?, hotwords: [String], maxBytes: Int) -> String {
    buildPrompt(preContext: preContext, hotwords: Optional(hotwords), maxBytes: maxBytes)
  }
}

public typealias OwlVoiceHotwordsExtractorProtocol = OwlVoiceHotwordsExtracting

// MARK: - Concrete Implementation

public final class OwlVoiceHotwordsExtractor: OwlVoiceHotwordsExtracting, @unchecked Sendable {
  public static let shared = OwlVoiceHotwordsExtractor()

  public let databaseURL: URL?
  public let inMemoryPinnedWordsProvider: (@Sendable () -> [String])?
  public let fileManager: FileManager

  public var defaultDatabaseURL: URL {
    OwlApp.userDir.appendingPathComponent("msime-user/msime_user.db")
  }

  public init(
    databaseURL: URL? = nil,
    fileManager: FileManager = .default,
    inMemoryPinnedWordsProvider: (@Sendable () -> [String])? = nil
  ) {
    self.databaseURL = databaseURL
    self.fileManager = fileManager
    self.inMemoryPinnedWordsProvider = inMemoryPinnedWordsProvider
  }

  // MARK: - Hotword Extraction

  public func extractHotwords(limit: Int = 100) -> [String] {
    guard limit > 0 else { return [] }

    let resolvedURL = databaseURL ?? defaultDatabaseURL
    let inMemoryPins = inMemoryPinnedWordsProvider?() ?? OwlPinnedWords.shared.words.map(\.text)

    // Fallback when SQLite database file is absent
    guard fileManager.fileExists(atPath: resolvedURL.path) else {
      return mergeAndDeduplicate(
        pinned: inMemoryPins,
        custom: [],
        bigrams: [],
        limit: limit
      )
    }

    // Open read-only SQLite connection
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
    guard sqlite3_open_v2(resolvedURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      if let db {
        sqlite3_close(db)
      }
      return mergeAndDeduplicate(
        pinned: inMemoryPins,
        custom: [],
        bigrams: [],
        limit: limit
      )
    }
    defer { sqlite3_close(db) }

    sqlite3_busy_timeout(db, 1000)

    // Query 1: Pinned Candidates
    let dbPins = fetchColumnStrings(
      db: db,
      sql: "SELECT value FROM pinned_candidates ORDER BY updated_at DESC LIMIT ?",
      limit: Int32(limit)
    )

    // Query 2: User Custom Words
    let dbCustom = fetchColumnStrings(
      db: db,
      sql: """
      SELECT value FROM user_dictionary_operations
      WHERE operation = 'upsert'
      ORDER BY user_inserted DESC, weight DESC, updated_at DESC
      LIMIT ?
      """,
      limit: Int32(limit)
    )

    // Query 3: Personal High-Frequency Bigrams
    let dbBigrams = fetchBigramStrings(
      db: db,
      sql: """
      SELECT (CASE WHEN previous = char(1) OR length(previous) = 0 THEN word ELSE previous || word END) AS phrase, count
      FROM personal_bigram
      ORDER BY count DESC
      LIMIT ?
      """,
      limit: Int32(limit)
    )

    // Merge with strict priority: Pinned (In-Memory + DB) > Custom > Bigram
    return mergeAndDeduplicate(
      pinned: inMemoryPins + dbPins,
      custom: dbCustom,
      bigrams: dbBigrams,
      limit: limit
    )
  }

  // MARK: - Prompt Assembly (800 UTF-8 Bytes Token-Safe)

  public func buildPrompt(preContext: String?, hotwords: [String]?, maxBytes: Int = 800) -> String {
    guard maxBytes > 0 else { return "" }

    // 1. Process pre-context with character-safe suffix slicing
    let rawContext = preContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let cleanContext: String
    if !rawContext.isEmpty {
      let maxContextBytes = min(300, max(0, maxBytes / 2))
      cleanContext = tokenSafeSuffix(rawContext, maxBytes: maxContextBytes)
    } else {
      cleanContext = ""
    }

    let hasContext = !cleanContext.isEmpty
    let contextPart = hasContext ? "前文：\(cleanContext)" : ""

    // 2. Resolve hotwords (default to live extraction if nil)
    let wordsToUse = hotwords ?? extractHotwords(limit: 100)

    // If no hotwords available, return context part or empty
    if wordsToUse.isEmpty {
      return (hasContext && contextPart.utf8.count <= maxBytes) ? contextPart : ""
    }

    // 3. Prepare prefix header
    let header = hasContext ? "\(contextPart)\n热词：" : "热词："
    let headerBytes = header.utf8.count

    if headerBytes >= maxBytes {
      return (hasContext && contextPart.utf8.count <= maxBytes) ? contextPart : ""
    }

    // 4. Token-safe hotwords appending
    var addedWords: [String] = []
    var currentBytes = headerBytes
    let separator = "，"
    let separatorBytes = separator.utf8.count

    for word in wordsToUse {
      let wordBytes = word.utf8.count
      let needed = addedWords.isEmpty ? wordBytes : (separatorBytes + wordBytes)
      if currentBytes + needed <= maxBytes {
        addedWords.append(word)
        currentBytes += needed
      } else {
        // Over budget! Terminate immediately to avoid chopping words or corrupting multi-byte UTF-8
        break
      }
    }

    if addedWords.isEmpty {
      return (hasContext && contextPart.utf8.count <= maxBytes) ? contextPart : ""
    }

    return header + addedWords.joined(separator: separator)
  }

  // MARK: - Character-Safe Suffix Slicing

  public func tokenSafeSuffix(_ string: String, maxBytes: Int) -> String {
    guard string.utf8.count > maxBytes else { return string }
    guard maxBytes > 0 else { return "" }

    var accumulatedBytes = 0
    var startIndex = string.endIndex

    for idx in string.indices.reversed() {
      let charBytes = String(string[idx]).utf8.count
      if accumulatedBytes + charBytes > maxBytes {
        break
      }
      accumulatedBytes += charBytes
      startIndex = idx
    }

    return String(string[startIndex...])
  }

  // MARK: - Sanitization & Filtering

  public func sanitizeToken(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    // Filter tokens where count <= 1 (single-character noise suppression)
    guard trimmed.count > 1 else { return nil }

    // Reject control characters or internal newlines
    guard !trimmed.contains(where: { $0.isNewline || $0.unicodeScalars.contains(where: { $0.value < 0x20 || ($0.value >= 0x7F && $0.value <= 0x9F) }) }) else {
      return nil
    }

    // Clean internal commas to prevent conflict with delimiter
    let cleaned = trimmed
      .replacingOccurrences(of: "，", with: " ")
      .replacingOccurrences(of: ",", with: " ")
      .trimmingCharacters(in: .whitespaces)

    guard cleaned.count > 1 else { return nil }

    // Filter pure punctuation/symbols: must contain at least one alphanumeric or letter character
    guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else {
      return nil
    }

    return cleaned
  }

  // MARK: - Private SQLite Query Helpers

  private func fetchColumnStrings(db: OpaquePointer, sql: String, limit: Int32) -> [String] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      if let stmt { sqlite3_finalize(stmt) }
      return []
    }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_int(stmt, 1, limit)

    var results: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      if let cStr = sqlite3_column_text(stmt, 0) {
        results.append(String(cString: cStr))
      }
    }
    return results
  }

  private func fetchBigramStrings(db: OpaquePointer, sql: String, limit: Int32) -> [String] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      if let stmt { sqlite3_finalize(stmt) }
      return []
    }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_int(stmt, 1, limit)

    var results: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let count = sqlite3_column_int(stmt, 1)
      guard count > 1 else { continue } // Occurrence count <= 1 filtered
      if let cStr = sqlite3_column_text(stmt, 0) {
        results.append(String(cString: cStr))
      }
    }
    return results
  }

  private func mergeAndDeduplicate(
    pinned: [String],
    custom: [String],
    bigrams: [String],
    limit: Int
  ) -> [String] {
    var seen = Set<String>()
    var output: [String] = []

    func appendCandidates(_ list: [String]) {
      for raw in list {
        guard let sanitized = sanitizeToken(raw) else { continue }
        if !seen.contains(sanitized) {
          seen.insert(sanitized)
          output.append(sanitized)
          if output.count >= limit {
            return
          }
        }
      }
    }

    appendCandidates(pinned)
    if output.count < limit { appendCandidates(custom) }
    if output.count < limit { appendCandidates(bigrams) }

    return output
  }
}
