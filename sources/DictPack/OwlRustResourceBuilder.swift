//
//  OwlRustResourceBuilder.swift
//  Owltype
//
//  Builds the SQLite payload and manifest consumed by the Rust resource store.
//  The builder reads the pinned dict-pack staging tree only; it never writes
//  into the Rime user directory.
//

import Foundation
import SQLite3

enum OwlRustResourceBuildError: Error, LocalizedError, Equatable {
  case missingInput(String)
  case unsafeImport(String)
  case invalidDictionary(String)
  case sqlite(String)
  case outputNotEmpty(String)

  var errorDescription: String? {
    switch self {
    case .missingInput(let path):
      return "资源生成输入缺失：\(path)"
    case .unsafeImport(let path):
      return "词典 import_tables 路径不安全：\(path)"
    case .invalidDictionary(let message):
      return "词典格式无效：\(message)"
    case .sqlite(let message):
      return "生成资源 SQLite 失败：\(message)"
    case .outputNotEmpty(let path):
      return "资源生成输出目录已被占用：\(path)"
    }
  }
}

struct OwlRustResourceBuildStats: Codable, Equatable, Sendable {
  // Accepted entries before SQLite deduplication. Row counts belong to the
  // generated databases and are checked separately by the resource report.
  let pinyinEntries: Int
  let wubiEntries: Int
  let englishEntries: Int
  let rejectedPinyinEntries: Int
  let rejectedWubiEntries: Int
  let rejectedEnglishEntries: Int
}

struct OwlRustResourcePackageBuild: Equatable, Sendable {
  let root: URL
  let manifest: OwlRustResourceManifest
  let stats: OwlRustResourceBuildStats
}

struct OwlRustResourcePackageBuilder: Sendable {
  static let packageId = "owltype-dictpack"
  static let builderVersion = 1

  let dictionaryRoot: URL
  let packageVersion: Int
  let engine: OwlRustEngineIdentity

  init(
    dictionaryRoot: URL,
    packageVersion: Int,
    engine: OwlRustEngineIdentity = .owlRustResourceV1
  ) {
    self.dictionaryRoot = dictionaryRoot
    self.packageVersion = packageVersion
    self.engine = engine
  }

  func build(at packageRoot: URL) throws -> OwlRustResourcePackageBuild {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: packageRoot.path) {
      let attributes = try fileManager.attributesOfItem(atPath: packageRoot.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory else {
        throw OwlRustResourceBuildError.outputNotEmpty(packageRoot.path)
      }
      guard try fileManager.contentsOfDirectory(atPath: packageRoot.path).isEmpty else {
        throw OwlRustResourceBuildError.outputNotEmpty(packageRoot.path)
      }
    }
    let filesRoot = packageRoot.appendingPathComponent("files", isDirectory: true)
    try fileManager.createDirectory(
      at: filesRoot, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    let pinyinURL = filesRoot.appendingPathComponent("msime-pinyin.db")
    let englishURL = filesRoot.appendingPathComponent("msime-english.db")
    let pinyinStats = try makePinyinDatabase(at: pinyinURL)
    let englishStats = try makeEnglishDatabase(at: englishURL)

    var licenses: [OwlRustResourceLicense] = []
    var payloadFiles: [(source: URL, destination: String, role: OwlRustResourceFileRole)] = [
      (pinyinURL, "files/msime-pinyin.db", .mainDictionary),
      (englishURL, "files/msime-english.db", .englishDictionary),
    ]
    try appendLicense(
      source: dictionaryRoot.appendingPathComponent("rime-ice.LICENSE"),
      destination: "files/rime-ice.LICENSE",
      identifier: "GPL-3.0-only",
      attribution: "rime-ice, pinned by OwlDictPackManifest.current",
      packageRoot: packageRoot,
      licenses: &licenses,
      payloadFiles: &payloadFiles
    )
    try appendLicense(
      source: dictionaryRoot.appendingPathComponent("wubi86-jidian.LICENSE"),
      destination: "files/wubi86-jidian.LICENSE",
      identifier: "Apache-2.0",
      attribution: "rime-wubi86-jidian, pinned by OwlDictPackManifest.current",
      packageRoot: packageRoot,
      licenses: &licenses,
      payloadFiles: &payloadFiles
    )
    try appendLicense(
      source: dictionaryRoot.appendingPathComponent("octagram-data.LICENSE"),
      destination: "files/octagram-data.LICENSE",
      identifier: "LicenseRef-lotem-octagram",
      attribution: "rime-octagram-data, pinned by OwlDictPackManifest.current",
      packageRoot: packageRoot,
      licenses: &licenses,
      payloadFiles: &payloadFiles
    )

    let requiredPinyinTables = Self.pinyinTableNames + [
      "wubi86", "wubi98", "quick_parases",
    ]
    let requiredEnglishTables = ["english_words", "en_zh_glosses", "zh_en_glosses"]
    var resourceFiles: [OwlRustResourceFile] = []
    for payload in payloadFiles {
      let attributes = try fileManager.attributesOfItem(atPath: payload.source.path)
      let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
      guard size > 0 else {
        throw OwlRustResourceBuildError.missingInput(payload.source.path)
      }
      let tables: [String]?
      switch payload.role {
      case .mainDictionary:
        tables = requiredPinyinTables
      case .englishDictionary:
        tables = requiredEnglishTables
      default:
        tables = nil
      }
      resourceFiles.append(OwlRustResourceFile(
        path: payload.destination,
        role: payload.role,
        mediaType: payload.role == .license
          ? "text/plain"
          : "application/vnd.sqlite3",
        size: size,
        digest: try OwlRustResourceVerifier.digestOfFile(payload.source),
        requiredTables: tables
      ))
    }
    resourceFiles.sort { $0.path < $1.path }
    licenses.sort { $0.identifier < $1.identifier }

    let unsigned = OwlRustResourceManifest(
      schemaVersion: OwlRustResourceManifest.schemaVersionV1,
      packageId: Self.packageId,
      inputKind: .pinyinWubi,
      version: packageVersion,
      digest: OwlRustResourceManifest.zeroDigest,
      license: licenses,
      engineCompatibility: OwlRustResourceEngineCompatibility(
        minimumContractVersion: 1,
        maximumContractVersion: 1,
        requiredCapabilities: ["pinyin-wubi-v1", "persistent-user-journal-v1"]
      ),
      files: resourceFiles
    )
    let manifest = OwlRustResourceManifest(
      schemaVersion: unsigned.schemaVersion,
      packageId: unsigned.packageId,
      inputKind: unsigned.inputKind,
      version: unsigned.version,
      digest: try unsigned.calculatedDigest(),
      license: unsigned.license,
      engineCompatibility: unsigned.engineCompatibility,
      files: unsigned.files
    )
    try manifest.validateDigest()
    try OwlRustResourceVerifier.verifyEngineCompatibility(
      manifest: manifest, engine: engine
    )
    try manifest.canonicalData().write(
      to: packageRoot.appendingPathComponent("manifest.json"), options: .atomic
    )
    let stats = OwlRustResourceBuildStats(
      pinyinEntries: pinyinStats.accepted,
      wubiEntries: pinyinStats.wubi,
      englishEntries: englishStats.accepted,
      rejectedPinyinEntries: pinyinStats.rejected,
      rejectedWubiEntries: pinyinStats.rejectedWubi,
      rejectedEnglishEntries: englishStats.rejected
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(stats).write(
      to: packageRoot.appendingPathComponent("build-stats.json"), options: .atomic
    )
    return OwlRustResourcePackageBuild(root: packageRoot, manifest: manifest, stats: stats)
  }

  private struct PinyinBuildStats {
    var accepted = 0
    var rejected = 0
    var wubi = 0
    var rejectedWubi = 0
  }

  private struct EnglishBuildStats {
    var accepted = 0
    var rejected = 0
  }

  private func appendLicense(
    source: URL,
    destination: String,
    identifier: String,
    attribution: String,
    packageRoot: URL,
    licenses: inout [OwlRustResourceLicense],
    payloadFiles: inout [(source: URL, destination: String, role: OwlRustResourceFileRole)]
  ) throws {
    guard FileManager.default.fileExists(atPath: source.path) else {
      throw OwlRustResourceBuildError.missingInput(source.path)
    }
    try FileManager.default.copyItem(
      at: source, to: packageRoot.appendingPathComponent(destination)
    )
    payloadFiles.append((source: source, destination: destination, role: .license))
    licenses.append(
      OwlRustResourceLicense(
        identifier: identifier,
        attribution: attribution,
        files: [destination]
      )
    )
  }

  private func makePinyinDatabase(at url: URL) throws -> PinyinBuildStats {
    var stats = PinyinBuildStats()
    let database = try OwlRustSQLiteBuilder(url: url)
    try database.execute("PRAGMA journal_mode = OFF")
    try database.execute("PRAGMA synchronous = OFF")
    for table in Self.pinyinTableNames {
      try database.execute(
        """
        CREATE TABLE "\(table)" (
          "key" TEXT NOT NULL,
          "jp" TEXT NOT NULL,
          "value" TEXT NOT NULL,
          "weight" INTEGER NOT NULL DEFAULT 0,
          UNIQUE("key", "value")
        )
        """
      )
      try database.execute("CREATE INDEX \"idx_key_\(table)\" ON \"\(table)\" (\"key\")")
      try database.execute("CREATE INDEX \"idx_jp_\(table)\" ON \"\(table)\" (\"jp\")")
    }
    try database.execute(
      """
      CREATE TABLE "wubi86" (
        "key" TEXT NOT NULL, "value" TEXT NOT NULL,
        "weight" INTEGER NOT NULL DEFAULT 0, UNIQUE("key", "value")
      )
      """
    )
    try database.execute(
      "CREATE INDEX \"idx_wubi86_key_weight\" ON \"wubi86\" (\"key\", \"weight\" DESC)"
    )
    try database.execute("CREATE INDEX \"idx_wubi86_value\" ON \"wubi86\" (\"value\")")
    try database.execute(
      """
      CREATE TABLE "wubi98" (
        "key" TEXT NOT NULL, "value" TEXT NOT NULL,
        "weight" INTEGER NOT NULL DEFAULT 0, UNIQUE("key", "value")
      )
      """
    )
    try database.execute(
      "CREATE INDEX \"idx_wubi98_key_weight\" ON \"wubi98\" (\"key\", \"weight\" DESC)"
    )
    try database.execute("CREATE INDEX \"idx_wubi98_value\" ON \"wubi98\" (\"value\")")
    try database.execute(
      """
      CREATE TABLE "quick_parases" (
        "key" TEXT NOT NULL, "value" TEXT NOT NULL,
        "weight" INTEGER NOT NULL DEFAULT 0
      )
      """
    )
    try database.execute(
      "CREATE INDEX \"idx_quick_parases_key_weight\" "
        + "ON \"quick_parases\" (\"key\", \"weight\" DESC)"
    )

    var pinyinStatements: [String: OwlRustSQLiteStatement] = [:]
    for table in Self.pinyinTableNames {
      pinyinStatements[table] = try database.statement(
        """
        INSERT INTO "\(table)" ("key", "jp", "value", "weight")
        VALUES (?, ?, ?, ?)
        ON CONFLICT("key", "value") DO UPDATE SET
          "jp" = excluded."jp",
          "weight" = excluded."weight"
        WHERE excluded."weight" > "weight"
        """
      )
    }
    let wubiStatement = try database.statement(
      """
      INSERT INTO "wubi86" ("key", "value", "weight")
      VALUES (?, ?, ?)
      ON CONFLICT("key", "value") DO UPDATE SET
        "weight" = excluded."weight"
      WHERE excluded."weight" > "weight"
      """
    )

    try database.transaction {
      try Self.forEachDictionaryEntry(
        root: dictionaryRoot,
        topLevel: "rime_ice.dict.yaml"
      ) { entry in
        guard let parsed = Self.parsePinyinEntry(entry),
              let statement = pinyinStatements[parsed.table] else {
          stats.rejected += 1
          return
        }
        try statement.bind(
          parsed.key, parsed.jp, parsed.value, Int64(parsed.weight)
        )
        try statement.step()
        try statement.reset()
        stats.accepted += 1
      }
      try Self.forEachDictionaryEntry(
        root: dictionaryRoot,
        topLevel: "wubi86_jidian.dict.yaml"
      ) { entry in
        guard let parsed = Self.parseWubiEntry(entry) else {
          stats.rejectedWubi += 1
          return
        }
        try wubiStatement.bind(parsed.code, parsed.value, Int64(parsed.weight))
        try wubiStatement.step()
        try wubiStatement.reset()
        stats.wubi += 1
      }
    }
    for statement in pinyinStatements.values { statement.finalize() }
    wubiStatement.finalize()
    try database.close()
    return stats
  }

  private func makeEnglishDatabase(at url: URL) throws -> EnglishBuildStats {
    var stats = EnglishBuildStats()
    let database = try OwlRustSQLiteBuilder(url: url)
    try database.execute("PRAGMA journal_mode = OFF")
    try database.execute("PRAGMA synchronous = OFF")
    try database.execute("PRAGMA user_version = 3")
    try database.execute(
      """
      CREATE TABLE "english_words" (
        "word" TEXT NOT NULL, "display" TEXT NOT NULL,
        "weight" INTEGER NOT NULL DEFAULT 0, "phonetic" TEXT NOT NULL DEFAULT '',
        PRIMARY KEY ("word", "display")
      )
      """
    )
    try database.execute(
      "CREATE INDEX \"idx_english_words_word_weight\" "
        + "ON \"english_words\" (\"word\", \"weight\" DESC)"
    )
    try database.execute(
      """
      CREATE TABLE "en_zh_glosses" (
        "word" TEXT NOT NULL, "translation" TEXT NOT NULL,
        "rank" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("word", "rank")
      )
      """
    )
    try database.execute(
      """
      CREATE TABLE "zh_en_glosses" (
        "word" TEXT NOT NULL, "translation" TEXT NOT NULL,
        "rank" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("word", "rank")
      )
      """
    )
    let statement = try database.statement(
      """
      INSERT INTO "english_words" ("word", "display", "weight", "phonetic")
      VALUES (?, ?, ?, '')
      ON CONFLICT("word", "display") DO UPDATE SET
        "weight" = excluded."weight"
      WHERE excluded."weight" > "weight"
      """
    )
    try database.transaction {
      for file in ["en_dicts/en.dict.yaml", "en_dicts/en_ext.dict.yaml"] {
        try Self.forEachDictionaryEntry(root: dictionaryRoot, topLevel: file) { entry in
          guard let parsed = Self.parseEnglishEntry(entry) else {
            stats.rejected += 1
            return
          }
          try statement.bind(parsed.word, parsed.display, Int64(parsed.weight))
          try statement.step()
          try statement.reset()
          stats.accepted += 1
        }
      }
    }
    statement.finalize()
    try database.close()
    return stats
  }

  struct DictionaryEntry {
    let file: String
    let order: Int
    let fields: [String]
  }

  static func forEachDictionaryEntry(
    root: URL,
    topLevel: String,
    body: (DictionaryEntry) throws -> Void
  ) throws {
    var visited = Set<String>()
    var order = 0
    try walkDictionary(
      root: root,
      relativePath: topLevel,
      visited: &visited,
      order: &order,
      body: body
    )
  }

  private static func walkDictionary(
    root: URL,
    relativePath: String,
    visited: inout Set<String>,
    order: inout Int,
    body: (DictionaryEntry) throws -> Void
  ) throws {
    try OwlRustResourceManifest.validateRelativePath(relativePath)
    guard visited.insert(relativePath).inserted else { return }
    let url = root.appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw OwlRustResourceBuildError.missingInput(url.path)
    }
    let text: String
    do {
      text = try String(contentsOf: url, encoding: .utf8)
    } catch {
      throw OwlRustResourceBuildError.invalidDictionary(
        "\(relativePath)：\(error.localizedDescription)"
      )
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard let headerStart = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
          let bodyStart = lines[headerStart...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "..."
          }) else {
      throw OwlRustResourceBuildError.invalidDictionary(
        "\(relativePath) 缺少 YAML `---`/`...` 分界"
      )
    }
    for imported in parseImports(
      lines: lines[headerStart..<bodyStart].map(String.init)
    ) {
      try OwlRustResourceManifest.validateRelativePath(imported)
      let child = imported.hasSuffix(".dict.yaml")
        ? imported
        : imported + ".dict.yaml"
      try walkDictionary(
        root: root, relativePath: child, visited: &visited, order: &order, body: body
      )
    }
    for rawLine in lines[(bodyStart + 1)...] {
      let line = String(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
      let fields = line.split(
        separator: "\t", omittingEmptySubsequences: false
      ).map(String.init)
      guard fields.count >= 2 else { continue }
      order += 1
      try body(DictionaryEntry(file: relativePath, order: order, fields: fields))
    }
  }

  private static func parseImports(lines: [String]) -> [String] {
    var imports: [String] = []
    var inImports = false
    var importIndent = 0
    for line in lines {
      let withoutComment = stripComment(line)
      let trimmed = withoutComment.trimmingCharacters(in: .whitespaces)
      if trimmed == "import_tables:" {
        inImports = true
        importIndent = line.prefix { $0 == " " || $0 == "\t" }.count
        continue
      }
      guard inImports else { continue }
      let indent = line.prefix { $0 == " " || $0 == "\t" }.count
      if !trimmed.hasPrefix("-"), indent <= importIndent {
        inImports = false
        continue
      }
      if trimmed.hasPrefix("-") {
        let value = trimmed.dropFirst()
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if !value.isEmpty { imports.append(value) }
      }
    }
    return imports
  }

  private static func stripComment(_ line: String) -> String {
    guard let hash = line.firstIndex(of: "#") else { return line }
    return String(line[..<hash])
  }

  struct ParsedPinyin {
    let table: String
    let key: String
    let jp: String
    let value: String
    let weight: Int
  }

  static func parsePinyinEntry(_ entry: DictionaryEntry) -> ParsedPinyin? {
    guard entry.fields.count >= 2 else { return nil }
    let value = entry.fields[0].trimmingCharacters(in: .whitespaces)
    let code = entry.fields[1].trimmingCharacters(in: .whitespaces).lowercased()
    guard !value.isEmpty, !code.isEmpty else { return nil }
    let syllables = code.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !syllables.isEmpty,
          syllables.allSatisfy({ token in
            !token.isEmpty && token.unicodeScalars.allSatisfy {
              $0.value >= 97 && $0.value <= 122
            }
          }),
          let initial = syllables[0].first,
          initialWeights.contains(initial) else {
      return nil
    }
    let bucket = (1...7).contains(syllables.count)
      ? String(syllables.count)
      : "others"
    let weight = parseWeight(entry.fields, default: 1)
    return ParsedPinyin(
      table: "tbl_\(bucket)_\(initial)",
      key: syllables.joined(separator: "'"),
      jp: syllables.compactMap(\.first).map(String.init).joined(),
      value: value,
      weight: weight
    )
  }

  struct ParsedWubi {
    let code: String
    let value: String
    let weight: Int
  }

  static func parseWubiEntry(_ entry: DictionaryEntry) -> ParsedWubi? {
    guard entry.fields.count >= 2 else { return nil }
    let value = entry.fields[0].trimmingCharacters(in: .whitespaces)
    let code = entry.fields[1].trimmingCharacters(in: .whitespaces).lowercased()
    guard !value.isEmpty, !code.isEmpty,
          code.unicodeScalars.allSatisfy({
            $0.value >= 97 && $0.value <= 122
          }) else {
      return nil
    }
    return ParsedWubi(
      code: code,
      value: value,
      weight: parseWeight(entry.fields, default: 1)
    )
  }

  struct ParsedEnglish {
    let word: String
    let display: String
    let weight: Int
  }

  static func parseEnglishEntry(_ entry: DictionaryEntry) -> ParsedEnglish? {
    guard entry.fields.count >= 2 else { return nil }
    let display = entry.fields[0].trimmingCharacters(in: .whitespaces)
    let word = entry.fields[1].trimmingCharacters(in: .whitespaces).lowercased()
    guard !word.isEmpty, !display.isEmpty else { return nil }
    return ParsedEnglish(
      word: word,
      display: display,
      weight: parseWeight(entry.fields, default: 1)
    )
  }

  private static func parseWeight(_ fields: [String], default fallback: Int) -> Int {
    guard fields.count >= 3 else { return fallback }
    let raw = fields[2].trimmingCharacters(in: .whitespaces)
    guard !raw.isEmpty else { return fallback }
    let parsed = Int(raw) ?? Double(raw).map(Int.init)
    guard let parsed, parsed >= 0 else {
      return fallback
    }
    return parsed
  }

  private static let initialWeights = Set("abcdefghjklmnopqrstwxyz")

  static let pinyinTableNames: [String] = {
    var names: [String] = []
    for count in 1...7 {
      for initial in initialWeights.sorted() {
        names.append("tbl_\(count)_\(initial)")
      }
    }
    for initial in initialWeights.sorted() {
      names.append("tbl_others_\(initial)")
    }
    return names
  }()
}

extension OwlRustEngineIdentity {
  static let owlRustResourceV1 = OwlRustEngineIdentity(
    contractVersion: 1,
    capabilities: ["dictionary-contract-v1", "pinyin-wubi-v1", "persistent-user-journal-v1"],
    sqliteRequirements: [
      OwlRustResourceSQLiteRequirement(
        role: .mainDictionary,
        tables: [
          OwlRustResourceSQLiteTableRequirement(
            table: "tbl_1_n", columns: ["key", "jp", "value", "weight"]
          ),
          OwlRustResourceSQLiteTableRequirement(
            table: "wubi86", columns: ["key", "value", "weight"]
          ),
          OwlRustResourceSQLiteTableRequirement(
            table: "quick_parases", columns: ["key", "value", "weight"]
          ),
        ]
      ),
      OwlRustResourceSQLiteRequirement(
        role: .englishDictionary,
        tables: [
          OwlRustResourceSQLiteTableRequirement(
            table: "english_words", columns: ["word", "display", "weight", "phonetic"]
          ),
        ]
      ),
    ]
  )
}

private final class OwlRustSQLiteBuilder {
  private var database: OpaquePointer?

  init(url: URL) throws {
    var handle: OpaquePointer?
    let result = sqlite3_open_v2(
      url.path, &handle,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX,
      nil
    )
    guard result == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) }
        ?? String(cString: sqlite3_errstr(result))
      if let handle { sqlite3_close(handle) }
      throw OwlRustResourceBuildError.sqlite(message)
    }
    database = handle
    if chmod(url.path, 0o600) != 0 {
      sqlite3_close(handle)
      database = nil
      throw OwlRustResourceBuildError.sqlite(String(cString: strerror(errno)))
    }
  }

  deinit { closeIgnoringError() }

  func execute(_ sql: String) throws {
    guard let database else {
      throw OwlRustResourceBuildError.sqlite("database is closed")
    }
    var error: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &error)
    guard result == SQLITE_OK else {
      let message = error.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(database))
      sqlite3_free(error)
      throw OwlRustResourceBuildError.sqlite(message)
    }
  }

  func statement(_ sql: String) throws -> OwlRustSQLiteStatement {
    guard let database else {
      throw OwlRustResourceBuildError.sqlite("database is closed")
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
      throw OwlRustResourceBuildError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    return OwlRustSQLiteStatement(statement: statement)
  }

  func transaction(_ body: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE")
    do {
      try body()
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func close() throws {
    guard let database else { return }
    self.database = nil
    let result = sqlite3_close(database)
    guard result == SQLITE_OK else {
      throw OwlRustResourceBuildError.sqlite(String(cString: sqlite3_errstr(result)))
    }
  }

  private func closeIgnoringError() {
    guard let database else { return }
    self.database = nil
    sqlite3_close(database)
  }
}

private final class OwlRustSQLiteStatement {
  private let statement: OpaquePointer
  private var finalized = false
  private static let transient = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self
  )

  init(statement: OpaquePointer) {
    self.statement = statement
  }

  deinit { finalize() }

  func finalize() {
    guard !finalized else { return }
    finalized = true
    sqlite3_finalize(statement)
  }

  func bind(_ values: CustomStringConvertible...) throws {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      if let int = value as? Int64 {
        result = sqlite3_bind_int64(statement, index, int)
      } else if let int = value as? Int {
        result = sqlite3_bind_int64(statement, index, Int64(int))
      } else {
        result = sqlite3_bind_text(
          statement, index, String(describing: value), -1, Self.transient
        )
      }
      guard result == SQLITE_OK else {
        throw OwlRustResourceBuildError.sqlite("bind failed with \(result)")
      }
    }
  }

  func step() throws {
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE || result == SQLITE_ROW else {
      throw OwlRustResourceBuildError.sqlite(
        String(cString: sqlite3_errstr(result))
      )
    }
  }

  func reset() throws {
    guard sqlite3_reset(statement) == SQLITE_OK,
          sqlite3_clear_bindings(statement) == SQLITE_OK else {
      throw OwlRustResourceBuildError.sqlite("statement reset failed")
    }
  }
}
