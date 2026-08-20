//
//  OwlConfigWriter.swift
//  猫头鹰输入法 (Owltype) — Rime 配置写入层（托管块 + 备份 + manifest + 回滚）
//
//  v0.5 (OwlConfigWriter, ChatGPT Pro 回包 Q13 / spec `owl-rime-config-law.md` 写入层):
//  把 `OwlRimePatchBuilder` 生成的 patch 文本 **安全** 地写进 Owltype 自己的 user_data_dir。策略
//  来自回包：**不重写用户整个文件**，而是在 `patch:` 下插入/替换一段带标记的「托管块」
//  (`# >>> OWL MANAGED <marker> ... # <<< <marker>`)，做到幂等；写入前时间戳备份 + sha256，
//  同目录 temp + `FileManager.replaceItemAt` 原子替换，写 `owltype/rollback-manifest.json`，
//  一键回滚按 manifest 还原。
//
//  分层契约：
//  - `renderManagedBlock(_:block:)` 是 **纯函数**（value→string，零 IO）——回包的
//    `replaceOrInsertBlock`。`managedBlock(fromGeneratedYAML:marker:)` 也是纯 helper，把
//    `owlDefaultCustomYAML` / `owlRimeIceCustomYAML` 的输出转成 `ManagedPatchBlock`。
//    这两条逻辑由 `#if DEBUG` 的 `owlConfigWriterSelfCheck()` 自检。
//  - `dryRun(fileName:block:)` 读当前文件（或缺省 `"patch:\n"`），返回 (before, after)，**不写**。
//    这是设置 UI 默认、安全的动作。
//  - `apply(fileName:block:timestamp:)` 是 **唯一** 真正触碰磁盘的方法：备份 → 原子写 →
//    追加 manifest。页内 Rime 开关现在会经 `applyKeyboardSnapshot` 自动调用它（track-2 快速
//    config_file 部署）；也仍由 UI 上明确标注「需真机」的按钮触发。本方法只写文件、不部署。
//  - `rollback()` 读最新 manifest 条目，best-effort 还原每个文件。
//
//  边界（spec 总边界 / ADR-0001..0003）：配置写入层，**绝不** 触碰 IMK 热路径
//  (OwlInputController / process_key / commit)。部署（reload/deploy）不在本 writer 内，
//  也绝不在 IMK key event 中执行——留给 Owltype 既有 reload 路径，本文件只写文件、不部署。
//
//  并发：非 `@MainActor`，纯值类型 + 无状态实例方法，可在任意线程调用。
//  沙盒：v0.4 不沙盒，非沙盒 IMK app 可直接写 Owltype user_data_dir；若未来沙盒化需 security-scoped
//  bookmark（回包注记），本文件不处理。
//

import CryptoKit
import Foundation

// MARK: - 值类型

/// 一段「托管块」：标记名 + 已经按 `patch:` 下 2 空格缩进的若干 YAML 行。
/// `yamlLinesIndentedUnderPatch` 不含 `patch:` 行、不含标记注释——只是块内的键。
struct ManagedPatchBlock {
  let marker: String
  let yamlLinesIndentedUnderPatch: [String]
}

/// Stable markers for Owltype-owned managed blocks. Kept outside SwiftUI so settings UI,
/// CLI smoke commands, and tests all build the same patch plan.
enum OwlManagedMarker {
  static let defaultPatch = "OWL MANAGED DEFAULT PATCH v1"
  static let owlAppOptions = "OWL MANAGED OWLTYPE_CUSTOM APP_OPTIONS v1"
  static let rimeIce = "OWL MANAGED RIME_ICE PATCH v1"
  static let wubiJidian = "OWL MANAGED WUBI86_JIDIAN PATCH v1"
  static let quickSendFile = "OWL MANAGED QUICK_SEND FILE v1"
  static let quickSendJSONFile = "OWL MANAGED QUICK_SEND JSON FILE v1"
  static let quickSendRimeIce = "OWL MANAGED QUICK_SEND RIME_ICE PATCH v1"
  static let promptsFile = "OWL MANAGED PROMPTS FILE v1"
  static let promptsDictFile = "OWL MANAGED PROMPTS DICT FILE v1"
  static let promptsRimeIce = "OWL MANAGED PROMPTS RIME_ICE PATCH v1"
}

/// One file that Owltype can merge into its own Rime user_data_dir.
struct OwlManagedPatchFile {
  let fileName: String
  let block: ManagedPatchBlock
}

/// Shared keyboard patch plan used by the preview sheet and the CLI smoke command.
enum OwlManagedKeyboardPatchPlan {
  static func files(from snapshot: OwlKeyboardSnapshot) -> [OwlManagedPatchFile] {
    var out: [OwlManagedPatchFile] = []

    let defaultYAML = owlDefaultCustomYAML(from: snapshot)
    out.append(OwlManagedPatchFile(
      fileName: "default.custom.yaml",
      block: OwlConfigWriter.managedBlock(
        fromGeneratedYAML: defaultYAML,
        marker: OwlManagedMarker.defaultPatch
      )
    ))

    // App 默认英文 — per-app `app_options` MUST target the OWLTYPE domain (owltype.custom.yaml),
    // the only domain OwlConfig.getAppOptions reads. Empty list → empty managed block
    // (clears any app_options Owltype wrote before). This is what makes user-added apps take effect.
    let owlAppOptionsYAML = owlAppOptionsCustomYAML(from: snapshot)
    out.append(OwlManagedPatchFile(
      fileName: "owltype.custom.yaml",
      block: OwlConfigWriter.managedBlock(
        fromGeneratedYAML: owlAppOptionsYAML,
        marker: OwlManagedMarker.owlAppOptions
      )
    ))

    // Always include the schema-level fuzzy file. When all pairs are off the generated
    // YAML has no `patch:` body, so the managed block becomes empty and clears any older
    // fuzzy rules previously written by Owltype.
    let rimeIceYAML = owlRimeIceCustomYAML(from: snapshot)
    out.append(OwlManagedPatchFile(
      fileName: "rime_ice.custom.yaml",
      block: OwlConfigWriter.managedBlock(
        fromGeneratedYAML: rimeIceYAML,
        marker: OwlManagedMarker.rimeIce
      )
    ))

    for target in owlWubiPatchTargets {
      let wubiYAML = owlWubiCustomYAML(from: snapshot, target: target)
      out.append(OwlManagedPatchFile(
        fileName: target.fileName,
        block: OwlConfigWriter.managedBlock(
          fromGeneratedYAML: wubiYAML,
          marker: OwlManagedMarker.wubiJidian
        )
      ))
    }

    return out
  }

  static func apply(
    snapshot: OwlKeyboardSnapshot,
    writer: OwlConfigWriter = OwlConfigWriter(),
    timestamp: String? = nil
  ) throws -> [String] {
    let ts = timestamp ?? timestampNow()
    var written: [String] = []
    for file in files(from: snapshot) {
      try writer.apply(fileName: file.fileName, block: file.block, timestamp: ts)
      written.append(file.fileName)
    }
    return written
  }

  private static func timestampNow() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
  }
}

/// 写入层错误。`renderManagedBlock` 只会抛 `fileHasNoPatchAndCannotCreate`；
/// `apply` 额外会抛 `refusedNeverTouch` / `refusedUnmanagedFile`；`duplicatePatchKeyOutsideManagedBlock` 预留给
/// 后续冲突检测（同一 patch key 出现在托管块外）。
enum OwlConfigWriteError: Error {
  case duplicatePatchKeyOutsideManagedBlock(String)
  case fileHasNoPatchAndCannotCreate
  case refusedNeverTouch(String)
  case refusedUnmanagedFile(String)
}

// MARK: - OwlConfigWriter

/// Rime 配置写入器。`rimeDir` 可注入（测试 / dry-run 用临时目录），默认
/// Owltype 自己的 `~/Library/Application Support/Owltype`。非 `@MainActor`。
final class OwlConfigWriter {
  /// 目标 Rime 目录。可注入以便测试；默认 Owltype 自己的 user_data_dir。
  let rimeDir: URL

  init(rimeDir: URL = OwlApp.userDir) {
    self.rimeDir = rimeDir
  }

  // MARK: - 白名单（spec 写入层 / 回包 Q13）

  /// **可由猫头鹰管理** 的文件。`apply` 只应被这些文件名调用（UI 侧约束）；列在这里也是
  /// 文档化的「猫头鹰托管面」。两个 custom.yaml 用托管块合并，其余由生成器整文件产出。
  static let owlManagedFiles: Set<String> = [
    "default.custom.yaml",       // 托管块：键位 / 翻页 / 标点 / schema_list
    "owltype.custom.yaml",          // 托管块：per-app app_options（owltype 域，getAppOptions 实读）
    "rime_ice.custom.yaml",      // 托管块：全拼方案级模糊音
    "wubi86_jidian.custom.yaml", // 托管块：五笔编码提示 / 单字 / 清码
    "wubi86_jidian_pinyin.custom.yaml",
    "wubi86_jidian_trad.custom.yaml",
    "wubi86_jidian_trad_pinyin.custom.yaml",
    "owl_quick_send.json",      // 快捷短语 source of truth（text·code）
    "owl_quick_send.txt",       // 快捷短语派生 Rime 表（Owltype-owned, not user's custom_phrase.txt）
    "owl_prompts.json",         // 提示词 source of truth（code·title·body·category）
    "owl_prompts.txt",          // 提示词派生 Rime 表（只含 📝title \t code \t score，正文不进表）
    "law_phrase.txt",            // 法律短码表
    "owl_law_terms_pinyin.dict.yaml",  // 法律词拼音 wrapper dict
    "owl_law_terms_wubi86.dict.yaml",  // 法律词五笔 wrapper dict
    "wubi86_law.schema.yaml",    // 派生五笔法学 schema
    "wubi86_law.dict.yaml",      // 五笔法学 dict
    "lua/law_citation.lua",      // 引注 Lua translator
    "lua/law_data.lua",          // 引注静态数据
    "lua/law_num.lua",           // 中文数字（千/万）
    "lua/law_forms.lua",         // 引注三形式纯生成层
  ]

  /// **必须保留 / 默认绝不碰** 的文件 —— 用户私有数据、用户自定义、运行时状态。`apply`
  /// 在写入前先 guard 这个集合，命中则 `throw refusedNeverTouch`。`*.userdb*` 用前缀/后缀
  /// 规则匹配（见 `isNeverTouch`），其余精确匹配。
  static let neverTouch: Set<String> = [
    "user.yaml",          // 用户运行时选项状态
    "installation.yaml",  // 安装标识 / 同步配置
    "custom_phrase.txt",  // 用户自造词短语
  ]

  /// 是否落在 `neverTouch`：精确命中 `neverTouch`，或匹配「`*.userdb*`」用户词典数据
  /// （含 `.userdb/`、`.userdb.txt`、`.userdb.bin` 等前缀/后缀形态）。lua/ 等子目录文件
  /// 取其末段比对，与 `owlManagedFiles` 的 key 形态无关——这里只防误伤用户数据。
  static func isNeverTouch(_ fileName: String) -> Bool {
    let last = (fileName as NSString).lastPathComponent
    if neverTouch.contains(fileName) || neverTouch.contains(last) { return true }
    // `*.userdb*`：用户词典目录 / 导出文本 / 二进制，任何形态都不碰。
    if last.contains(".userdb") { return true }
    return false
  }

  // MARK: - 纯托管块渲染（回包 replaceOrInsertBlock）

  /// **PURE**：把托管块插入/替换进 `original`，返回新文本。零 IO、零副作用——这是回包的
  /// `replaceOrInsertBlock`，也是被 `owlConfigWriterSelfCheck()` 自检的核心逻辑。
  ///
  /// - 标记：`  # >>> <marker>` … `  # <<< <marker>`（`patch:` 下 2 空格缩进）。
  /// - 若 begin/end 标记**都**存在：替换它们之间（含标记本身）的范围，幂等。
  /// - 否则若 `original` 含 `patch:`：在末尾追加 `\n\n` + 托管块 + `\n`。
  /// - 否则（无 `patch:`，无法安全创建）：`throw fileHasNoPatchAndCannotCreate`。
  func renderManagedBlock(_ original: String, block: ManagedPatchBlock) throws -> String {
    let begin = "  # >>> \(block.marker)"
    let end = "  # <<< \(block.marker)"
    let managed = ([begin] + block.yamlLinesIndentedUnderPatch + [end])
      .joined(separator: "\n")

    if let beginRange = original.range(of: begin),
       let endRange = original.range(of: end) {
      let replaceRange = beginRange.lowerBound..<endRange.upperBound
      return original.replacingCharacters(in: replaceRange, with: managed)
    }

    guard original.contains("patch:") else {
      throw OwlConfigWriteError.fileHasNoPatchAndCannotCreate
    }
    return original.trimmingCharacters(in: .newlines) + "\n\n" + managed + "\n"
  }

  /// **PURE** helper：把一段 `owlDefaultCustomYAML` / `owlRimeIceCustomYAML` 的生成结果转成
  /// `ManagedPatchBlock`。丢掉开头的 `#` 头部注释行与 `patch:` 行，保留其余（已在 `patch:`
  /// 下 2 空格缩进的）行作为 `yamlLinesIndentedUnderPatch`。尾随空行被裁掉。
  ///
  /// 注意：只丢「文件头部」的连续 `#` 行（在遇到第一个 `patch:` 之前），块内部的注释行
  /// （如 `  # 候选翻页…`）会被保留——它们是 2 空格缩进的，属于块内容。
  static func managedBlock(fromGeneratedYAML yaml: String, marker: String) -> ManagedPatchBlock {
    let rawLines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var body: [String] = []
    var seenPatch = false
    for line in rawLines {
      if !seenPatch {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "patch:" {
          seenPatch = true
          continue
        }
        // 头部 `#` 注释行 / 空行：在 patch: 之前的，丢弃。
        if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
        // 兜底：patch: 之前出现非头部行（理论上不该发生），保留之。
        body.append(line)
        continue
      }
      body.append(line)
    }
    // 裁掉尾随空行，避免块尾多出空白。
    while let last = body.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      body.removeLast()
    }
    return ManagedPatchBlock(marker: marker, yamlLinesIndentedUnderPatch: body)
  }

  // MARK: - dry-run（默认、安全；UI 用）

  /// 读 `rimeDir/fileName`（缺省 `"patch:\n"`），返回 (before, after = 渲染后文本)。**不写**。
  /// 这是设置 UI 的默认动作；`after` 包含完整托管块标记，供用户预览将写入的内容。
  func dryRun(fileName: String, block: ManagedPatchBlock) -> (before: String, after: String) {
    let url = rimeDir.appendingPathComponent(fileName)
    let original = (try? String(contentsOf: url, encoding: .utf8)) ?? "patch:\n"
    let source = sourceForManagedBlock(original, fileName: fileName, block: block)
    let after = (try? renderManagedBlock(source, block: block)) ?? original
    return (before: original, after: after)
  }

  // MARK: - apply（真机；唯一磁盘写入路径）

  // NEEDS REAL-MACHINE VERIFICATION: writes Owltype's user_data_dir.
  // 这是唯一真正写磁盘的方法。备份 → 同目录 temp → `replaceItemAt` 原子替换 → 追加 manifest。
  // **绝不在任何 build / 默认 / IMK 路径上调用**；只由 UI 上明确标注「需真机」的按钮触发。
  // 部署（reload/deploy）不在此处——本方法只落文件。`timestamp` 由调用方注入（默认占位串），
  // 不在内部调用 `Date()`，保证可测、可复现。
  func apply(
    fileName: String,
    block: ManagedPatchBlock,
    timestamp: String = "00000000-000000"
  ) throws {
    // 1. 白名单 guard：neverTouch / 非托管文件一律拒绝。
    guard !Self.isNeverTouch(fileName) else {
      throw OwlConfigWriteError.refusedNeverTouch(fileName)
    }
    guard Self.owlManagedFiles.contains(fileName) else {
      throw OwlConfigWriteError.refusedUnmanagedFile(fileName)
    }

    let url = rimeDir.appendingPathComponent(fileName)
    let original = (try? String(contentsOf: url, encoding: .utf8)) ?? "patch:\n"
    let source = sourceForManagedBlock(original, fileName: fileName, block: block)
    let updated = try renderManagedBlock(source, block: block)
    try writeManagedFile(fileName: fileName, original: original, updated: updated, marker: block.marker, timestamp: timestamp)
  }

  private func sourceForManagedBlock(_ original: String, fileName: String, block: ManagedPatchBlock) -> String {
    guard fileName == "default.custom.yaml", block.marker == OwlManagedMarker.defaultPatch else {
      return original
    }
    return Self.removingBareDefaultPatchKeys(from: original, managedMarker: block.marker)
  }

  static func removingBareDefaultPatchKeys(from text: String, managedMarker: String) -> String {
    let begin = "# >>> \(managedMarker)"
    let end = "# <<< \(managedMarker)"
    var inManagedBlock = false
    var droppingBlockIndent: Int?
    var out: [String] = []

    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      if line.contains(begin) {
        droppingBlockIndent = nil
        inManagedBlock = true
        out.append(line)
        continue
      }
      if line.contains(end) {
        droppingBlockIndent = nil
        inManagedBlock = false
        out.append(line)
        continue
      }

      if let blockIndent = droppingBlockIndent {
        if line.trimmingCharacters(in: .whitespaces).isEmpty || Self.leadingSpaceCount(line) > blockIndent {
          continue
        }
        droppingBlockIndent = nil
      }

      if !inManagedBlock,
         let item = Self.yamlMapItem(in: line),
         Self.isDefaultPatchManagedKey(item.key) {
        if item.valueAfterColon.trimmingCharacters(in: .whitespaces).isEmpty {
          droppingBlockIndent = item.indent
        }
        continue
      }

      out.append(line)
    }

    return out.joined(separator: "\n")
  }

  private static func isDefaultPatchManagedKey(_ key: String) -> Bool {
    // app_options/*/ascii_mode now lives in the owltype domain (owltype.custom.yaml, task 07-08). Owltype no
    // longer WRITES it into default.custom.yaml, but we keep it as a PURGE rule: any stray/legacy
    // app_options in default is dead (getAppOptions reads owltype) — strip it so default stays clean.
    if key.hasPrefix("app_options/"), key.hasSuffix("/ascii_mode") {
      return true
    }
    return [
      "schema_list",
      "menu/page_size",
      "menu/alternative_select_keys",
      "ascii_composer/switch_key/Shift_L",
      "ascii_composer/switch_key/Shift_R",
      "ascii_composer/switch_key/Caps_Lock",
      "ascii_composer/good_old_caps_lock",
      "key_binder/select_first_character",
      "key_binder/select_last_character",
      "punctuator/half_shape/+",
      "punctuator/full_shape/+",
      "key_binder/bindings/+",
      "switcher/save_options/+",
    ].contains(key)
  }

  private static func yamlMapItem(in line: String) -> (indent: Int, key: String, valueAfterColon: String)? {
    let indent = leadingSpaceCount(line)
    let trimmed = line.dropFirst(indent)
    guard !trimmed.hasPrefix("#"), !trimmed.isEmpty else { return nil }

    if trimmed.hasPrefix("\"") {
      guard let close = trimmed.dropFirst().firstIndex(of: "\"") else { return nil }
      let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
      let afterQuote = trimmed[trimmed.index(after: close)...].drop { $0 == " " || $0 == "\t" }
      guard afterQuote.hasPrefix(":") else { return nil }
      return (indent, key, String(afterQuote.dropFirst()))
    }

    guard let colon = trimmed.firstIndex(of: ":") else { return nil }
    let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { return nil }
    return (indent, key, String(trimmed[trimmed.index(after: colon)...]))
  }

  private static func leadingSpaceCount(_ line: String) -> Int {
    line.prefix { $0 == " " || $0 == "\t" }.count
  }

  func applyTextFile(
    fileName: String,
    contents updated: String,
    marker: String,
    timestamp: String = "00000000-000000"
  ) throws {
    let url = rimeDir.appendingPathComponent(fileName)
    let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    try writeManagedFile(fileName: fileName, original: original, updated: updated, marker: marker, timestamp: timestamp)
  }

  private func writeManagedFile(
    fileName: String,
    original: String,
    updated: String,
    marker: String,
    timestamp: String
  ) throws {
    guard !Self.isNeverTouch(fileName) else {
      throw OwlConfigWriteError.refusedNeverTouch(fileName)
    }
    guard Self.owlManagedFiles.contains(fileName) else {
      throw OwlConfigWriteError.refusedUnmanagedFile(fileName)
    }

    // No-op when nothing actually changed. The launch-time apply (OwlApplicationDelegate)
    // re-runs on EVERY launch; without this it would back up + rewrite + append a rollback
    // manifest entry + force a redeploy every time. The rendered block is timestamp-free
    // (timestamp only names the backup dir), so `updated == original` whenever prefs are
    // unchanged and the bare keys are already stripped → skip all disk work.
    guard updated != original else { return }

    let fm = FileManager.default
    let url = rimeDir.appendingPathComponent(fileName)
    let beforeSha = Self.sha256Hex(of: original)
    let afterSha = Self.sha256Hex(of: updated)
    // 2. 备份原文件到 `.owl-backup/<timestamp>/<fileName>`（保留子目录结构）。
    let backupDir = rimeDir
      .appendingPathComponent(".owl-backup", isDirectory: true)
      .appendingPathComponent(timestamp, isDirectory: true)
    let backupFile = backupDir.appendingPathComponent(fileName)
    try OwlPrivateStorage.prepareDirectory(rimeDir, fileManager: fm)
    try OwlPrivateStorage.prepareDirectory(backupFile.deletingLastPathComponent(), fileManager: fm)
    try original.write(to: backupFile, atomically: true, encoding: .utf8)
    try OwlPrivateStorage.hardenFile(backupFile, fileManager: fm)

    // 3. 同目录 temp 写入，4. 原子替换。
    try OwlPrivateStorage.prepareDirectory(url.deletingLastPathComponent(), fileManager: fm)
    let tmp = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).owl.tmp")
    try updated.write(to: tmp, atomically: true, encoding: .utf8)
    if fm.fileExists(atPath: url.path) {
      _ = try fm.replaceItemAt(url, withItemAt: tmp)
    } else {
      try fm.moveItem(at: tmp, to: url)
    }
    try OwlPrivateStorage.hardenFile(url, fileManager: fm)

    // 5. 追加 rollback manifest 条目。
    let entry = OwlRollbackEntry(
      path: url.path,
      beforeSha256: beforeSha,
      afterSha256: afterSha,
      managedBlock: marker,
      backupDir: backupDir.path,
      ts: timestamp
    )
    try appendManifest(entry)
  }

  // MARK: - rollback（best-effort）

  /// 读最新 manifest 批次，按其 `backupDir` 还原对应文件。best-effort：单个文件还原失败不
  /// 中断其余。无 manifest / 空 manifest 时安静返回。
  func rollback() throws {
    let manifestURL = manifestFileURL
    guard let data = try? Data(contentsOf: manifestURL) else { return }
    let manifest = try JSONDecoder().decode(OwlRollbackManifest.self, from: data)
    guard let latest = manifest.files.last else { return }

    let batch = manifest.files.reversed().prefix {
      $0.ts == latest.ts && $0.backupDir == latest.backupDir
    }.reversed()
    let fm = FileManager.default
    for entry in batch {
      restore(entry, fileManager: fm)
    }
  }

  private func restore(_ entry: OwlRollbackEntry, fileManager fm: FileManager) {
    let target = URL(fileURLWithPath: entry.path)
    let backupFile = URL(fileURLWithPath: entry.backupDir)
      .appendingPathComponent(relativePath(for: target))
    guard fm.fileExists(atPath: backupFile.path) else { return }
    let restored = (try? String(contentsOf: backupFile, encoding: .utf8)) ?? ""
    // 还原同样走 temp + 原子替换，避免半截文件。
    let tmp = target.deletingLastPathComponent()
      .appendingPathComponent(".\(target.lastPathComponent).owl.rollback.tmp")
    try? restored.write(to: tmp, atomically: true, encoding: .utf8)
    if fm.fileExists(atPath: target.path) {
      _ = try? fm.replaceItemAt(target, withItemAt: tmp)
    } else {
      try? fm.moveItem(at: tmp, to: target)
    }
    try? OwlPrivateStorage.hardenFile(target, fileManager: fm)
  }

  private func relativePath(for target: URL) -> String {
    let root = rimeDir.standardizedFileURL.path
    let path = target.standardizedFileURL.path
    guard path.hasPrefix(root + "/") else { return target.lastPathComponent }
    return String(path.dropFirst(root.count + 1))
  }

  // MARK: - manifest IO

  private var manifestFileURL: URL {
    rimeDir
      .appendingPathComponent("owltype", isDirectory: true)
      .appendingPathComponent("rollback-manifest.json")
  }

  /// 读现有 manifest（缺省空），追加一条，原子写回。
  private func appendManifest(_ entry: OwlRollbackEntry) throws {
    let fm = FileManager.default
    let url = manifestFileURL
    try OwlPrivateStorage.prepareDirectory(rimeDir, fileManager: fm)
    try OwlPrivateStorage.prepareDirectory(url.deletingLastPathComponent(), fileManager: fm)
    var manifest: OwlRollbackManifest
    if let data = try? Data(contentsOf: url),
       let decoded = try? JSONDecoder().decode(OwlRollbackManifest.self, from: data) {
      manifest = decoded
    } else {
      manifest = OwlRollbackManifest(version: 1, files: [])
    }
    manifest.files.append(entry)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let out = try encoder.encode(manifest)
    try out.write(to: url, options: .atomic)
    try OwlPrivateStorage.hardenFile(url, fileManager: fm)
  }

  // MARK: - sha256

  /// 文本的 SHA256 十六进制摘要（写入前后校验、回滚一致性）。
  static func sha256Hex(of text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

// MARK: - manifest 模型

/// `owltype/rollback-manifest.json` 的一条文件记录（回包 Q13 JSON 形态）。
struct OwlRollbackEntry: Codable {
  let path: String
  let beforeSha256: String
  let afterSha256: String
  let managedBlock: String
  let backupDir: String
  let ts: String
}

/// `owltype/rollback-manifest.json` 顶层结构。
struct OwlRollbackManifest: Codable {
  let version: Int
  var files: [OwlRollbackEntry]
}

#if DEBUG
/// Debug-only 自检：纯托管块逻辑的正确性。Release 整个编译掉，非致命（用 `assert`）。
/// 由写入预览 sheet 的呈现处调用一次。
///
/// 三条断言：
/// (1) `renderManagedBlock` 把块插到 `"patch:\n  \"menu/page_size\": 8\n"` 之后（含标记）。
/// (2) 用同一 marker 再次渲染是 **替换**，不是追加——marker 计数仍为 1。
/// (3) `renderManagedBlock` 在无 `patch:` 的文本上 `throw fileHasNoPatchAndCannotCreate`。
func owlConfigWriterSelfCheck() {
  let writer = OwlConfigWriter()
  let marker = "OWL MANAGED SELFCHECK v1"
  let block = ManagedPatchBlock(
    marker: marker,
    yamlLinesIndentedUnderPatch: [
      "  \"key_binder/bindings/+\":",
      "    - { when: has_menu, accept: semicolon, send: 2 }",
    ]
  )

  // (1) 插入：原文有 patch:，块被追加，标记 begin/end 都出现。
  let original = "patch:\n  \"menu/page_size\": 8\n"
  guard let inserted = try? writer.renderManagedBlock(original, block: block) else {
    assertionFailure("Owltype config writer: renderManagedBlock threw on a patch: file")
    return
  }
  assert(inserted.contains("# >>> \(marker)"), "Owltype config writer: missing begin marker")
  assert(inserted.contains("# <<< \(marker)"), "Owltype config writer: missing end marker")
  assert(inserted.contains("\"menu/page_size\": 8"), "Owltype config writer: clobbered user patch")
  assert(inserted.contains("accept: semicolon"), "Owltype config writer: missing managed body")

  // (2) 幂等：用同一 marker 再渲染一次 = 替换，标记仍只出现 1 次。
  guard let rerendered = try? writer.renderManagedBlock(inserted, block: block) else {
    assertionFailure("Owltype config writer: renderManagedBlock threw on re-render")
    return
  }
  let beginCount = rerendered.components(separatedBy: "# >>> \(marker)").count - 1
  let endCount = rerendered.components(separatedBy: "# <<< \(marker)").count - 1
  assert(beginCount == 1, "Owltype config writer: duplicate begin marker after re-render (\(beginCount))")
  assert(endCount == 1, "Owltype config writer: duplicate end marker after re-render (\(endCount))")

  // (3) 无 patch:：抛 fileHasNoPatchAndCannotCreate。
  do {
    _ = try writer.renderManagedBlock("# no patch here\n", block: block)
    assertionFailure("Owltype config writer: expected throw on a no-patch file")
  } catch OwlConfigWriteError.fileHasNoPatchAndCannotCreate {
    // 预期路径。
  } catch {
    assertionFailure("Owltype config writer: wrong error on no-patch file: \(error)")
  }

  // managedBlock(fromGeneratedYAML:): 头部 # 行与 patch: 行被丢，块内键保留。
  let gen = "# 猫头鹰生成（草案）\n# 写入说明\npatch:\n  \"menu/page_size\": 8\n"
  let mb = OwlConfigWriter.managedBlock(fromGeneratedYAML: gen, marker: marker)
  assert(!mb.yamlLinesIndentedUnderPatch.contains(where: { $0.contains("猫头鹰生成") }),
         "Owltype config writer: header leaked into managed block")
  assert(mb.yamlLinesIndentedUnderPatch.contains(where: { $0.contains("menu/page_size") }),
         "Owltype config writer: lost body line from generated YAML")

  // neverTouch: 用户私有 / 运行时数据一律拒绝。
  assert(OwlConfigWriter.isNeverTouch("user.yaml"), "Owltype config writer: user.yaml must be neverTouch")
  assert(OwlConfigWriter.isNeverTouch("custom_phrase.txt"), "Owltype config writer: custom_phrase.txt must be neverTouch")
  assert(OwlConfigWriter.isNeverTouch("rime_ice.userdb.txt"), "Owltype config writer: *.userdb* must be neverTouch")
  assert(!OwlConfigWriter.isNeverTouch("default.custom.yaml"), "Owltype config writer: managed file wrongly blocked")
}
#endif
