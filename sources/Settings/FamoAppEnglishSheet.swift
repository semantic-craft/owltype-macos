//
//  FamoAppEnglishSheet.swift
//  法墨输入法 (Famo) — 指定「应用」默认使用英文 管理面板
//
//  The 「管理…」 sheet opened from the 键盘输入 page's app-default-English card. Replaces
//  the old comma-separated bundle-ID TextField with a WeChat-style picker: a list of
//  apps (icon + name) you 添加…/移除, resolved from bundle IDs via NSWorkspace.
//
//  Backend is unchanged: edits write through `FamoSettingsActions.setAppEnglishBundleIDsText`
//  (the single home for `FamoKeyboardPreferences.appEnglishBundleIDs`), which librime turns
//  into `app_options/<bundle>/ascii_mode: true`. The parent page applies the Rime patch
//  once on dismiss (FamoKeyboardPage `.sheet(onDismiss:)`).
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI settings layer only — never the IMK hot path.
//
//  Concurrency: not `@MainActor`-isolated (matches the rest of the settings UI).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Resolves a bundle ID to a display name + icon, and runs the system app picker. All
/// AppKit, no new dependency. Unresolvable IDs (uninstalled / hand-typed from the old
/// text field) degrade to the raw ID + a generic icon so they stay visible and removable.
enum FamoAppEnglishCatalog {
  static func appURL(for bundleID: String) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
  }

  static func displayName(for bundleID: String) -> String {
    guard let url = appURL(for: bundleID) else { return bundleID }
    let name = FileManager.default.displayName(atPath: url.path)
    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
  }

  static func icon(for bundleID: String) -> NSImage {
    if let url = appURL(for: bundleID) {
      return NSWorkspace.shared.icon(forFile: url.path)
    }
    return NSWorkspace.shared.icon(for: .applicationBundle)
  }

  /// System open panel scoped to /Applications, .app only. Returns the picked app's
  /// bundle identifier, or nil if cancelled / unreadable.
  static func pickApplicationBundleID() -> String? {
    let panel = NSOpenPanel()
    panel.message = "选择一个应用，下次使用它时默认英文输入"
    panel.prompt = "选择"
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return Bundle(url: url)?.bundleIdentifier
  }
}

/// 指定「应用」默认使用英文 的管理弹窗。`@State` 持本地列表，每次增删 write-through 到
/// `FamoKeyboardPreferences.appEnglishBundleIDs`（经 onChange）；昂贵的 Rime apply 由父页在
/// 关闭时一次性做。Presented from `FamoKeyboardPage`'s `.sheet`.
struct FamoAppEnglishSheet: View {
  let palette: FamoCandidatePalette
  let theme: FamoCandidateTheme
  let reduceTransparency: Bool

  @Environment(\.dismiss) private var dismiss
  @State private var bundleIDs: [String]
  let onChange: ([String]) -> Void

  init(
    palette: FamoCandidatePalette,
    theme: FamoCandidateTheme,
    reduceTransparency: Bool,
    bundleIDs: [String],
    onChange: @escaping ([String]) -> Void
  ) {
    self.palette = palette
    self.theme = theme
    self.reduceTransparency = reduceTransparency
    _bundleIDs = State(initialValue: bundleIDs)
    self.onChange = onChange
  }

  var body: some View {
    VStack(spacing: 14) {
      Text("指定「应用」默认使用英文")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(palette.ink)
      listArea
      footer
    }
    .padding(20)
    .frame(width: 460, height: 520)
    .background(palette.card)
  }

  @ViewBuilder private var listArea: some View {
    if bundleIDs.isEmpty {
      VStack {
        Spacer()
        Text("添加应用后，下次使用该应用时默认为英文输入状态")
          .font(.system(size: 13))
          .foregroundStyle(palette.ink3)
          .multilineTextAlignment(.center)
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
          .strokeBorder(palette.ink.opacity(0.1), lineWidth: 1)
      }
    } else {
      ScrollView {
        VStack(spacing: 0) {
          ForEach(Array(bundleIDs.enumerated()), id: \.element) { index, id in
            if index > 0 { SettingsCardDivider(palette: palette) }
            row(id)
          }
        }
        .padding(.vertical, 2)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
          .fill(reduceTransparency ? palette.card : palette.card.opacity(0.92))
      }
      .overlay {
        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
          .strokeBorder(palette.ink.opacity(0.07), lineWidth: 1)
      }
    }
  }

  private func row(_ id: String) -> some View {
    // ponytail: re-resolve icon/name per render; list is a handful of apps, cache if it grows.
    HStack(spacing: 10) {
      Image(nsImage: FamoAppEnglishCatalog.icon(for: id))
        .resizable()
        .frame(width: 28, height: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text(FamoAppEnglishCatalog.displayName(for: id))
          .font(.system(size: 14))
          .foregroundStyle(palette.ink)
        Text(id)
          .font(.system(size: 11))
          .foregroundStyle(palette.ink3)
      }
      Spacer(minLength: 0)
      Button(action: { remove(id) }) {
        Image(systemName: "minus.circle.fill")
          .font(.system(size: 16))
          .foregroundStyle(palette.ink3)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("移除")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Spacer(minLength: 0)
      Button(action: { add() }) {
        Text("添加…")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(palette.accent)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(palette.accent.opacity(0.6), lineWidth: 1)
          }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("添加…")

      Button(action: { dismiss() }) {
        Text("完成")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(palette.onAccent)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(palette.accent)
          }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("完成")
    }
  }

  private func add() {
    guard let id = FamoAppEnglishCatalog.pickApplicationBundleID() else { return }
    guard !bundleIDs.contains(id) else { return }
    bundleIDs.append(id)
    onChange(bundleIDs)
  }

  private func remove(_ id: String) {
    bundleIDs.removeAll { $0 == id }
    onChange(bundleIDs)
  }
}
