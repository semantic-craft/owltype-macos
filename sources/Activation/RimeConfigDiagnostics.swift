//
//  RimeConfigDiagnostics.swift
//  法墨输入法 (Owltype) — schema 配置一致性只读诊断 (task 07-07-schema-consistency-guard)
//
//  `--diagnose-rime-config` reports whether the schema the app will `select_schema` at runtime
//  (`OwlKeyboardPreferences.preferredSchemaID`) is actually reachable across the four layers that
//  must agree, and flags a common support trap:
//
//    prefs (拼音默认 = rime_ice)
//      → seed          (running bundle SharedSupport 是否带 <preferred>.schema.yaml)
//      → user build    (~/Library/Application Support/Owltype/build 是否已编译 <preferred>)
//      → user schema_list (default.custom.yaml 的 schema_list 是否列 <preferred>)
//      → shadow        (用户目录是否有完整 default.yaml 遮蔽共享层)
//      → foreignDir    (建议：~/Library/Rime 是系统 Rime/Squirrel 目录，法墨按 ADR-0004 不读它)
//
//  Mirrors `OwlTISDiagnostics`: a PURE classifier over synthetic value inputs (unit-tested with no
//  IO) + an impure `buildReport()` shell that does the filesystem reads. Read-only — never mutates
//  config, never deploys. Privacy (backend/logging-guidelines.md): the report is schema ids /
//  booleans / counts / paths ONLY — never user dictionary content or input text.
//

import Foundation

/// One read-only observation of the schema-consistency picture. PURE value — the classifier is
/// unit-testable with synthetic observations, no filesystem access. Privacy: ids / bools / paths only.
struct RimeConfigObservation: Equatable, Codable {
  let preferredSchemaID: String        // Swift prefs — the runtime source of truth
  let userSchemaList: [String]         // schema ids in the user default.custom.yaml `schema_list`
  let userBuiltSchemas: [String]       // compiled schema ids in the user `build/` (*.schema.yaml basenames)
  let seedSchemas: [String]            // schema ids the running bundle's SharedSupport seed carries
  let seedManifestBase: String?        // FAMO-SEED-MANIFEST "Base =" line (informational)
  let userDefaultYamlShadow: Bool      // user_data_dir has a full `default.yaml` shadowing shared
  let foreignRimeDirPresent: Bool      // ~/Library/Rime (system Rime/Squirrel dir) exists
  let foreignRimeHasPreferred: Bool?   // whether ~/Library/Rime's schema_list lists preferred (advisory)
}

enum RimeConfigLayer: String, Codable, CaseIterable {
  case prefs, seed, userBuild, userSchemaList, shadow, foreignDir
}

/// One layer's verdict. `ok == nil` = a layer that is informational / advisory only (`prefs` is the
/// source of truth; `foreignDir` is a "don't confuse the two dirs" note) — never scored as a failure.
struct RimeConfigLayerResult: Equatable, Codable {
  let layer: RimeConfigLayer
  let ok: Bool?
  let code: String?
  let detail: String
}

struct RimeConfigDiagnosis: Equatable, Codable {
  let layers: [RimeConfigLayerResult]
  let firstFailingLayer: RimeConfigLayer?
  let code: String?
}

enum OwlRimeConfigDiagnostics {
  /// User-facing message per FAMO-SCHEMA-* code (developer meaning stays in each layer's `detail`).
  static let userMessage: [String: String] = [
    "FAMO-SCHEMA-001": "用户方案清单不含当前拼音方案。",
    "FAMO-SCHEMA-002": "当前方案尚未在用户目录编译。",
    "FAMO-SCHEMA-003": "随附种子不含当前方案（安装物陈旧）。",
    "FAMO-SCHEMA-004": "用户目录存在遮蔽共享层的 default.yaml。",
    "FAMO-SCHEMA-005": "检测到系统 Rime 目录（非法墨所用）。",
  ]

  /// Short remediation line per code (condensed).
  static func actionText(for code: String) -> String {
    switch code {
    case "FAMO-SCHEMA-001": return "用户 default.custom.yaml 的 schema_list 不含当前拼音方案 —— 在设置里「应用配置改动」重写 schema_list 并重部署。"
    case "FAMO-SCHEMA-002": return "用户 build/ 未编译当前方案 —— 启动法墨部署一次，或在设置里「应用配置改动」触发 build。"
    case "FAMO-SCHEMA-003": return "随附种子（SharedSupport）不含当前方案，多为陈旧构建 —— 重跑 make famo-seed 后重装。"
    case "FAMO-SCHEMA-004": return "用户目录的 default.yaml 会遮蔽共享层 —— 删除它，法墨只用 default.custom.yaml 打补丁。"
    case "FAMO-SCHEMA-005": return "~/Library/Rime 是系统 Rime/Squirrel 目录，法墨不读它（用 ~/Library/Application Support/Owltype）—— 勿把它当法墨配置排查。"
    default: return userMessage[code] ?? code
    }
  }

  /// PURE classifier. No IO. `o` is the already-observed value picture. Layer order is root→downstream
  /// so the headline code names the most UPSTREAM failure (seed feeds build feeds schema_list).
  static func classify(_ o: RimeConfigObservation) -> RimeConfigDiagnosis {
    var layers: [RimeConfigLayerResult] = []
    let preferred = o.preferredSchemaID

    // 0. prefs — the runtime source of truth. Informational (ok:nil).
    layers.append(RimeConfigLayerResult(
      layer: .prefs, ok: nil, code: nil,
      detail: "运行时目标方案（OwlKeyboardPreferences.preferredSchemaID）= \(preferred.isEmpty ? "<空>" : preferred)"))

    // 1. seed — the running bundle's SharedSupport must carry <preferred>.schema.yaml.
    let seedOK = o.seedSchemas.contains(preferred)
    layers.append(RimeConfigLayerResult(
      layer: .seed, ok: seedOK, code: seedOK ? nil : "FAMO-SCHEMA-003",
      detail: seedOK
        ? "随附种子含 \(preferred).schema.yaml（Base=\(o.seedManifestBase ?? "?")；共 \(o.seedSchemas.count) 方案）"
        : "随附种子无 \(preferred).schema.yaml —— 安装物陈旧（Base=\(o.seedManifestBase ?? "?")；见 \(o.seedSchemas)）"))

    // 2. userBuild — the user's build/ must have compiled <preferred>.schema.yaml.
    let buildOK = o.userBuiltSchemas.contains(preferred)
    layers.append(RimeConfigLayerResult(
      layer: .userBuild, ok: buildOK, code: buildOK ? nil : "FAMO-SCHEMA-002",
      detail: buildOK
        ? "用户 build/ 已编译 \(preferred)（共 \(o.userBuiltSchemas.count) 方案）"
        : "用户 build/ 未编译 \(preferred)（运行时 select_schema 会失败；见 \(o.userBuiltSchemas)）"))

    // 3. userSchemaList — default.custom.yaml schema_list must list <preferred>.
    let listOK = o.userSchemaList.contains(preferred)
    layers.append(RimeConfigLayerResult(
      layer: .userSchemaList, ok: listOK, code: listOK ? nil : "FAMO-SCHEMA-001",
      detail: listOK
        ? "用户 schema_list 含 \(preferred)（\(o.userSchemaList)）"
        : "用户 schema_list 不含 \(preferred)（漂移；\(o.userSchemaList)）"))

    // 4. shadow — a full default.yaml in the user dir shadows the shared layer's config.
    layers.append(RimeConfigLayerResult(
      layer: .shadow, ok: !o.userDefaultYamlShadow, code: o.userDefaultYamlShadow ? "FAMO-SCHEMA-004" : nil,
      detail: o.userDefaultYamlShadow
        ? "用户目录存在完整 default.yaml，遮蔽共享层（应只留 default.custom.yaml 补丁）"
        : "用户目录无 default.yaml 遮蔽（仅 default.custom.yaml 补丁）"))

    // 5. foreignDir — ADVISORY ONLY (ok:nil, never firstFailing). ~/Library/Rime is the system
    //    Rime/Squirrel dir; Owltype (ADR-0004) never reads it. Surfaces the two-directory confusion.
    let foreignDetail: String
    if o.foreignRimeDirPresent {
      let has = o.foreignRimeHasPreferred == true
      foreignDetail = "检测到 ~/Library/Rime（系统 Rime/Squirrel 目录，非法墨所用；法墨用 ~/Library/Application Support/Owltype）"
        + (has ? "；其 schema_list 恰含 \(preferred)，勿据此误判" : "；其 schema_list 不含 \(preferred)，与法墨无关")
    } else {
      foreignDetail = "无 ~/Library/Rime（无系统 Rime 目录混淆源）"
    }
    layers.append(RimeConfigLayerResult(
      layer: .foreignDir, ok: nil, code: o.foreignRimeDirPresent ? "FAMO-SCHEMA-005" : nil, detail: foreignDetail))

    let firstFailing = layers.first { $0.ok == false }
    return RimeConfigDiagnosis(layers: layers, firstFailingLayer: firstFailing?.layer, code: firstFailing?.code)
  }

  // MARK: - Impure report shell (the only IO: filesystem reads; never mutates)

  /// Assemble the full read-only report. Honours `FAMO_TEST_USER_DIR` (via `OwlApp.userDir`) so the
  /// diagnosis can be pointed at a drift sample without installing anything.
  static func buildReport() -> RimeConfigReport {
    let preferred = OwlKeyboardPreferences.preferredSchemaID
    let userDir = OwlApp.userDir
    let userSchemaList = parseSchemaList(at: userDir.appendingPathComponent("default.custom.yaml"))
    let userBuilt = schemaBasenames(in: userDir.appendingPathComponent("build"))
    let sharedSupport = OwlApp.appDir.appending(components: "Contents", "SharedSupport")
    let seedSchemas = schemaBasenames(in: sharedSupport)
    let manifestBase = parseManifestBase(at: sharedSupport.appendingPathComponent("FAMO-SEED-MANIFEST.txt"))
    let shadow = FileManager.default.fileExists(atPath: userDir.appendingPathComponent("default.yaml").path)
    let foreignDir = systemRimeDir()
    let foreignPresent = FileManager.default.fileExists(atPath: foreignDir.path)
    let foreignHasPreferred = foreignPresent
      ? parseSchemaList(at: foreignDir.appendingPathComponent("default.custom.yaml")).contains(preferred)
      : nil

    let obs = RimeConfigObservation(
      preferredSchemaID: preferred, userSchemaList: userSchemaList, userBuiltSchemas: userBuilt,
      seedSchemas: seedSchemas, seedManifestBase: manifestBase, userDefaultYamlShadow: shadow,
      foreignRimeDirPresent: foreignPresent, foreignRimeHasPreferred: foreignHasPreferred)
    let diag = classify(obs)

    // Break the summary assembly into explicitly-typed locals (the type-checker times out on the
    // combined optional-map + string-interpolation expression otherwise).
    let headlineCode: String? = diag.code
    let headlineMsg: String? = headlineCode.flatMap { userMessage[$0] }
    let actionable: String
    if let headlineCode {
      actionable = actionText(for: headlineCode)
    } else {
      actionable = "四层（seed/build/schema_list/shadow）一致，运行时方案「\(preferred)」可达。"
    }
    // The FAMO-SCHEMA-005 advisory is independent of pass/fail — surface it in the summary either way.
    let foreignLayer: RimeConfigLayerResult? = diag.layers.first { $0.layer == RimeConfigLayer.foreignDir && $0.code != nil }
    let advisory: String? = foreignLayer.map { "FAMO-SCHEMA-005: " + $0.detail }

    let summary = RimeConfigReport.Summary(
      code: headlineCode, userMessage: headlineMsg, firstFailingLayer: diag.firstFailingLayer,
      actionable: actionable, advisory: advisory,
      userDir: userDir.path, sharedSupportDir: sharedSupport.path)
    return RimeConfigReport(observation: obs, layers: diag.layers, summary: summary)
  }

  /// Parse schema ids from a Rime `default(.custom).yaml` `schema_list`. Line scan (no full YAML
  /// parser needed): collects the id after each `schema:` key, rejecting suffix matches like
  /// `previously_selected_schema:`. Returns [] on an unreadable file.
  static func parseSchemaList(at url: URL) -> [String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var ids: [String] = []
    for line in text.split(whereSeparator: \.isNewline) {
      guard let r = line.range(of: "schema:") else { continue }
      // reject `..._schema:` suffix matches — require a word boundary before "schema:".
      if r.lowerBound > line.startIndex {
        let before = line[line.index(before: r.lowerBound)]
        if before.isLetter || before.isNumber || before == "_" { continue }
      }
      let token = line[r.upperBound...]
        .drop { $0 == " " || $0 == "{" }
        .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
      if !token.isEmpty { ids.append(String(token)) }
    }
    return ids
  }

  /// Basenames (without `.schema.yaml`) of compiled schemas in a dir. [] if the dir is unreadable.
  static func schemaBasenames(in dir: URL) -> [String] {
    guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
    let suffix = ".schema.yaml"
    return items.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) }.sorted()
  }

  /// The "Base = ..." token from FAMO-SEED-MANIFEST (informational). nil if unreadable/absent.
  static func parseManifestBase(at url: URL) -> String? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("Base =") {
      return line.dropFirst("Base =".count).trimmingCharacters(in: .whitespaces)
    }
    return nil
  }

  /// The system Rime/Squirrel user dir (~/Library/Rime) — NOT Owltype's dir. Resolved the same way Owltype
  /// resolves its own library dir (honours sandbox redirection). Advisory-only surface.
  static func systemRimeDir() -> URL {
    let lib = (try? FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
    return lib.appendingPathComponent("Rime", isDirectory: true)
  }
}

struct RimeConfigReport: Codable {
  struct Summary: Codable {
    let code: String?
    let userMessage: String?
    let firstFailingLayer: RimeConfigLayer?
    let actionable: String
    let advisory: String?          // FAMO-SCHEMA-005 note when ~/Library/Rime is present (pass or fail)
    let userDir: String            // resolved Owltype user_data_dir (honours FAMO_TEST_USER_DIR)
    let sharedSupportDir: String   // running bundle's SharedSupport (the seed under test)
  }
  let observation: RimeConfigObservation
  let layers: [RimeConfigLayerResult]
  let summary: Summary
}
