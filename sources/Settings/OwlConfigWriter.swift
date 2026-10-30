//
//  OwlConfigWriter.swift
//  猫头鹰输入法 (Owltype) — Rime 配置写入层（托管块 + 备份 + manifest + 回滚）
//
//  v0.5 (OwlConfigWriter, ChatGPT Pro 回包 Q13 / spec `owl-rime-config-law.md` 写入层):
//  把 `OwlConfigPatchBuilder` 生成的 patch 文本 **安全** 地写进 Owltype 自己的 user_data_dir。策略
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
struct ManagedPatchBlock: Decodable {
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
struct OwlManagedPatchFile: Decodable {
  let fileName: String
  let block: ManagedPatchBlock
}

/// Shared keyboard patch plan used by the preview sheet and the CLI smoke command.
enum OwlManagedKeyboardPatchPlan {
  static func files(from snapshot: OwlKeyboardSnapshot) -> [OwlManagedPatchFile] {
    OwlAppCore.required(["operation": "keyboard_export_plan", "snapshot": OwlAppCore.payload(snapshot)])
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

/// Rime 配置写入器。`dataDir` 可注入（测试 / dry-run 用临时目录），默认
/// Owltype 自己的 `~/Library/Application Support/Owltype`。非 `@MainActor`。
final class OwlConfigWriter {
  /// 目标 Rime 目录。可注入以便测试；默认 Owltype 自己的 user_data_dir。
  let dataDir: URL

  let writeCheckpoint: (String) throws -> Void

  init(dataDir: URL = OwlApp.userDir, writeCheckpoint: @escaping (String) throws -> Void = { _ in }) {
    self.dataDir = dataDir
    self.writeCheckpoint = writeCheckpoint
  }

  // MARK: - 白名单（spec 写入层 / 回包 Q13）

  /// **可由猫头鹰管理** 的文件。`apply` 只应被这些文件名调用（UI 侧约束）；列在这里也是
  /// 文档化的「猫头鹰托管面」。两个 custom.yaml 用托管块合并，其余由生成器整文件产出。
  static func isNeverTouch(_ fileName: String) -> Bool {
    OwlAppCore.required(["operation": "writer_never_touch", "name": fileName])
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
    do {
      return try OwlAppCore.call(["operation": "keyboard_render_managed", "original": original,
                                 "marker": block.marker, "lines": block.yamlLinesIndentedUnderPatch])
    } catch let failure as OwlAppCore.Failure where failure.code == "invalid_patch" {
      throw OwlConfigWriteError.fileHasNoPatchAndCannotCreate
    }
  }

  /// **PURE** helper：把一段 `owlDefaultCustomYAML` / `owlRimeIceCustomYAML` 的生成结果转成
  /// `ManagedPatchBlock`。丢掉开头的 `#` 头部注释行与 `patch:` 行，保留其余（已在 `patch:`
  /// 下 2 空格缩进的）行作为 `yamlLinesIndentedUnderPatch`。尾随空行被裁掉。
  ///
  /// 注意：只丢「文件头部」的连续 `#` 行（在遇到第一个 `patch:` 之前），块内部的注释行
  /// （如 `  # 候选翻页…`）会被保留——它们是 2 空格缩进的，属于块内容。
  static func managedBlock(fromGeneratedYAML yaml: String, marker: String) -> ManagedPatchBlock {
    OwlAppCore.required(["operation": "keyboard_managed_block", "yaml": yaml, "marker": marker])
  }

  // MARK: - dry-run（默认、安全；UI 用）

  /// 读 `dataDir/fileName`（缺省 `"patch:\n"`），返回 (before, after = 渲染后文本)。**不写**。
  /// 这是设置 UI 的默认动作；`after` 包含完整托管块标记，供用户预览将写入的内容。
  func dryRun(fileName: String, block: ManagedPatchBlock) -> (before: String, after: String) {
    struct Preview: Decodable { let before: String; let after: String }
    let value: Preview = try! OwlStorageHost(dataDir: dataDir).call("writer_preview", ["fileName": fileName, "marker": block.marker, "lines": block.yamlLinesIndentedUnderPatch])
    return (value.before, value.after)
  }
  func apply(fileName: String, block: ManagedPatchBlock, timestamp: String = "00000000-000000") throws {
    let _: Bool = try OwlStorageHost(dataDir: dataDir, writerCheckpoint: writeCheckpoint).call("writer_apply", ["fileName": fileName, "marker": block.marker, "lines": block.yamlLinesIndentedUnderPatch, "timestamp": timestamp])
  }
  static func removingBareDefaultPatchKeys(from text: String, managedMarker: String) -> String {
    OwlTemplateStore.core("writer_remove_bare", ["text": text, "marker": managedMarker])
  }

  func applyTextFile(
    fileName: String,
    contents updated: String,
    marker: String,
    timestamp: String = "00000000-000000"
  ) throws {
    let _: Bool = try OwlStorageHost(dataDir: dataDir, writerCheckpoint: writeCheckpoint).call("writer_apply_text", ["fileName": fileName, "contents": updated, "marker": marker, "timestamp": timestamp])
  }

  func rollback() throws {
    let _: Bool = try OwlStorageHost(dataDir: dataDir).call("writer_rollback")
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
