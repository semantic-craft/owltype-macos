//
//  OwlWritePreviewSheet.swift
//  猫头鹰输入法 (Owltype) — settings: 写入改动预览 (dry-run) sheet
//
//  v0.5 (OwlConfigWriter UI hook): a dry-run preview of what the managed-block merge
//  would write into Owltype's own `~/Library/Application Support/Owltype`. Builds
//  `ManagedPatchBlock`s from the current
//  snapshot's `owlDefaultCustomYAML` (marker "OWL MANAGED DEFAULT PATCH v1") and —
//  when ≥1 fuzzy pair is on — `owlRimeIceCustomYAML` (marker "OWL MANAGED RIME_ICE
//  PATCH v1"), runs `OwlConfigWriter.dryRun`, and shows the `after` text (the file as it
//  WOULD look after the merge, with the OWL MANAGED markers) in a monospaced box.
//
//  Default / safe action is the dry-run preview — nothing is written. There is also a
//  clearly-labeled 「写入并应用配置（需真机）」 button that is the ONLY caller of
//  `OwlConfigWriter.apply`. It is wired but must never run on a default/build path:
//  it is gated behind an explicit user tap + a confirmation toggle, and even then only
//  writes Owltype's real user_data_dir on a real machine before calling the existing deploy
//  callback.
//
//  Boundary (ADR-0001 / 0002 / 0003): settings UI layer only — never touches the IMK
//  key-event hot path. Not `@MainActor`-isolated (matches the rest of the settings UI).
//

import AppKit
import SwiftUI

/// One previewed file: its name + the `after` text from `dryRun`.
private struct OwlDryRunResult: Identifiable {
  let id: String          // fileName, stable
  let fileName: String
  let block: ManagedPatchBlock
  let after: String
}

/// 写入改动预览 (dry-run) sheet. Shows the managed-block-merged `after` text for
/// `default.custom.yaml` (+ `rime_ice.custom.yaml` when fuzzy on), built from the live
/// snapshot. Default action is preview-only. The 「写入并应用配置（需真机）」 button is the
/// sole `apply` caller and is gated behind an explicit confirm toggle.
struct OwlWritePreviewSheet: View {
  let palette: OwlCandidatePalette
  let theme: OwlCandidateTheme
  let onRedeploy: () -> Bool

  @Environment(\.dismiss) private var dismiss

  /// The dry-run results (after text per managed file), snapshotted once at init.
  private let results: [OwlDryRunResult]
  /// Combined preview text shown in the box.
  private let previewText: String

  /// Gates the real-machine apply button: the user must explicitly confirm before the
  /// (real-machine-only) write can fire. Default OFF, so `apply` is never reachable on a
  /// default path.
  @State private var confirmRealMachineWrite = false
  /// Last apply outcome message (real-machine), shown inline. nil until the user taps.
  @State private var applyStatus: String? = nil

  init(palette: OwlCandidatePalette, theme: OwlCandidateTheme, onRedeploy: @escaping () -> Bool) {
    self.palette = palette
    self.theme = theme
    self.onRedeploy = onRedeploy
    #if DEBUG
    // Debug-only pure-logic self-check; compiled out of Release.
    owlConfigWriterSelfCheck()
    #endif
    let built = Self.buildDryRun(from: .current())
    self.results = built
    self.previewText = Self.combinedText(from: built)
  }

  /// Build the dry-run results from a snapshot. PURE (no disk write): `dryRun` only READS
  /// the current file (or the `"patch:\n"` default) and renders — it never writes. Called
  /// once at init so the view stays non-`@MainActor`.
  private static func buildDryRun(from snapshot: OwlKeyboardSnapshot) -> [OwlDryRunResult] {
    let writer = OwlConfigWriter()
    return OwlManagedKeyboardPatchPlan.files(from: snapshot).map { file in
      let run = writer.dryRun(fileName: file.fileName, block: file.block)
      return OwlDryRunResult(
        id: file.fileName,
        fileName: file.fileName,
        block: file.block,
        after: run.after
      )
    }
  }

  /// Combined preview: each file under a clear header, showing the merged `after` text.
  private static func combinedText(from results: [OwlDryRunResult]) -> String {
    var sections: [String] = []
    for r in results {
      sections.append("# ===== \(r.fileName)（写入后预览，dry-run，未写入）=====")
      sections.append(r.after)
    }
    return sections.joined(separator: "\n")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      previewBox
      realMachineRow
      footer
    }
    .padding(20)
    .frame(width: 560, height: 520)
    .background(palette.card)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("预览写入改动 · dry-run（未写入磁盘）")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(palette.ink)
      Text("以下是把猫头鹰「托管块」合并进 ~/Library/Application Support/Owltype 后该文件的样子（不触碰系统 Rime 目录，只替换 OWL MANAGED 标记内的块）。当前仅预览，未写入、未应用配置。")
        .font(.system(size: 12))
        .foregroundStyle(palette.ink3)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var previewBox: some View {
    ScrollView {
      Text(previewText)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(palette.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
    .background {
      RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        .fill(palette.card2)
    }
    .overlay {
      RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        .strokeBorder(palette.accentDeep.opacity(0.25), lineWidth: 1)
    }
  }

  /// The real-machine confirm toggle + status line. The toggle gates the apply button so
  /// `apply` is never reachable without an explicit, deliberate user opt-in.
  private var realMachineRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(isOn: $confirmRealMachineWrite) {
        Text("我已了解：写入会修改 ~/Library/Application Support/Owltype（需真机；备份+manifest 已就绪，可回滚）")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink2)
      }
      .toggleStyle(.checkbox)
      .tint(palette.accent)

      if let applyStatus {
        Text(applyStatus)
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var footer: some View {
    HStack(spacing: 10) {
      // The real-machine apply button — the ONLY caller of `apply`. Disabled until the
      // user explicitly confirms; never fires on a default path.
      Button(action: applyRealMachine) {
        HStack(spacing: 6) {
          Image(systemName: "square.and.arrow.down.on.square")
          Text("写入并应用配置（需真机）")
            .font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(confirmRealMachineWrite ? palette.onAccent : palette.ink3)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(confirmRealMachineWrite ? palette.accentDeep : palette.card2)
        }
      }
      .buttonStyle(.plain)
      .disabled(!confirmRealMachineWrite)
      .accessibilityLabel("写入并应用配置（需真机）")

      Button(action: rollbackRealMachine) {
        HStack(spacing: 6) {
          Image(systemName: "arrow.uturn.backward")
          Text("回滚最近写入")
            .font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(confirmRealMachineWrite ? palette.accentDeep : palette.ink3)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(palette.accentDeep.opacity(0.5), lineWidth: 1)
        }
      }
      .buttonStyle(.plain)
      .disabled(!confirmRealMachineWrite)
      .accessibilityLabel("回滚最近写入")

      Spacer(minLength: 0)

      Button(action: { dismiss() }) {
        Text("关闭")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(palette.ink2)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(palette.ink3.opacity(0.4), lineWidth: 1)
          }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("关闭")
    }
  }

  /// The ONLY caller of `OwlConfigWriter.apply`. Guarded so it can never run on a
  /// default/build path: it returns immediately unless the user has flipped the confirm
  /// toggle (which defaults OFF and the apply button is disabled while it is OFF).
  ///
  /// On a real machine this writes Owltype's user_data_dir (with backup + manifest + rollback)
  /// and then calls the existing apply-configuration path.
  private func applyRealMachine() {
    let writer = OwlConfigWriter()
    if let status = OwlSettingsActions.applyWritePreview(
      confirmed: confirmRealMachineWrite,
      files: results.map { OwlManagedPatchFile(fileName: $0.fileName, block: $0.block) },
      timestamp: Self.timestampNow(),
      apply: { file, timestamp in
        try writer.apply(fileName: file.fileName, block: file.block, timestamp: timestamp)
      },
      redeploy: onRedeploy
    ) {
      applyStatus = status
    }
  }

  private func rollbackRealMachine() {
    let writer = OwlConfigWriter()
    if let status = OwlSettingsActions.rollbackWritePreview(
      confirmed: confirmRealMachineWrite,
      rollback: { try writer.rollback() },
      redeploy: onRedeploy
    ) {
      applyStatus = status
    }
  }

  /// A filesystem-safe timestamp for the backup dir name. Only called on the user's
  /// explicit apply tap (never on a default path), so calling `Date()` here is fine.
  private static func timestampNow() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
  }

  static func applyStatusMessage(written: [String], deploySucceeded: Bool) -> String {
    let files = written.joined(separator: "、")
    if deploySucceeded {
      return "已写入并应用配置 \(files)（备份+manifest 已记录，可回滚）。"
    }
    return "已写入 \(files)，但应用配置失败；备份+manifest 已记录，可回滚，请查看诊断日志。"
  }
}
