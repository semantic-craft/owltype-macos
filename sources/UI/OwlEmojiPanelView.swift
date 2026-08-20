//
//  OwlEmojiPanelView.swift
//  法墨输入法 (Owltype) — 表情/符号面板 view
//
//  The Claude Design "Owltype Emoji Panel" handoff in SwiftUI: a glass floating panel with
//  top category tabs (最近/表情/符号/颜文字/标点), a tiled grid (颜文字 take
//  full-width rows), an optional 最近 row, and keyword search across all categories.
//  深大红 themed via the chosen candidate-panel skin, reusing the candidate panel's
//  glass language. Picking a glyph inserts through the active IMK client when present,
//  otherwise copies to the pasteboard, and updates 最近.
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI UI layer only; the IMK key-event hot path
//  is untouched.
//

import SwiftUI

struct OwlEmojiPanelView: View {
  /// A glyph was picked → host inserts it or falls back to the pasteboard.
  let onPick: (String) -> Void
  /// The ✕ / Esc closed the panel.
  let onClose: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme

  @State private var category: OwlEmojiCategory = .recent
  @State private var query = ""
  @State private var picked = ""
  @State private var copiedToast = ""
  @State private var recents = OwlEmojiRecents.current()

  /// Theme follows the chosen 皮肤 (read live, like the candidate panel).
  private var theme: OwlCandidateTheme { OwlCandidatePanelSettings.live.currentSkin().theme }
  private var palette: OwlCandidatePalette { theme.palette(for: colorScheme) }

  private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

  /// Items shown for the current view (search results / recent / a fixed category).
  private var items: [OwlGlyph] {
    if searching { return OwlEmojiData.search(query) }
    if category == .recent { return OwlEmojiRecents.glyphs() }
    return OwlEmojiData.items(for: category)
  }

  var body: some View {
    VStack(spacing: 0) {
      headerRow
      tabBar
      ScrollView { gridBody.padding(.horizontal, 12).padding(.vertical, 10) }
      if showsRecentRow { recentRow }
    }
    .frame(width: 372, height: 318)
    .background { glass }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(palette.accentDeep.opacity(0.16), lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.18), radius: 22, y: 8)
    .overlay(alignment: .bottom) { toast }
    .onExitCommand(perform: onClose)
  }

  @ViewBuilder private var glass: some View {
    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    if reduceTransparency {
      shape.fill(palette.card)
    } else {
      ZStack { shape.fill(.regularMaterial); shape.fill(palette.card.opacity(0.86)) }
    }
  }

  // MARK: Header row

  /// Slim title + close. (In-panel keyboard search is dropped — the panel is non-key so a
  /// text field can't focus; users browse by category. See task 06-16-imk-client-insert Q3.)
  private var headerRow: some View {
    HStack(spacing: 8) {
      Text("表情符号")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(palette.ink2)
      Spacer(minLength: 0)
      Button(action: onClose) {
        Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.ink3)
          .frame(width: 26, height: 26)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("关闭")
    }
    .padding(.horizontal, 12)
    .padding(.top, 11)
    .padding(.bottom, 8)
  }

  // MARK: Tab bar

  private var tabBar: some View {
    HStack(spacing: 2) {
      ForEach(OwlEmojiCategory.allCases) { tab in
        tabButton(tab)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .overlay(alignment: .bottom) { Rectangle().fill(palette.ink.opacity(0.08)).frame(height: 1) }
  }

  private func tabButton(_ tab: OwlEmojiCategory) -> some View {
    let selected = !searching && category == tab
    return Button {
      category = tab
      query = ""
    } label: {
      HStack(spacing: 5) {
        Text(tab.glyph).font(.system(size: 13))
        Text(tab.label).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
      }
      .foregroundStyle(selected ? palette.accent : palette.ink2)
      .padding(.horizontal, 9)
      .padding(.vertical, 8)
      .overlay(alignment: .bottom) {
        Rectangle().fill(selected ? palette.accent : Color.clear).frame(height: 2)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(tab.label)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }

  // MARK: Grid

  @ViewBuilder private var gridBody: some View {
    let list = items
    if list.isEmpty {
      emptyState
    } else {
      let narrow = list.filter { !$0.wide }
      let wide = list.filter { $0.wide }
      VStack(alignment: .leading, spacing: 6) {
        if !narrow.isEmpty {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 3)], spacing: 3) {
            ForEach(narrow) { glyphCell($0) }
          }
        }
        if !wide.isEmpty {
          VStack(spacing: 3) { ForEach(wide) { wideRow($0) } }
        }
      }
    }
  }

  private func glyphCell(_ glyph: OwlGlyph) -> some View {
    let selected = glyph.char == picked
    let size: CGFloat = glyph.char.count > 1 ? 17 : 21
    return Text(glyph.char)
      .font(.system(size: size))
      .frame(maxWidth: .infinity)
      .frame(height: 40)
      .background { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? palette.accent.opacity(0.14) : Color.clear) }
      .overlay {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(selected ? palette.accent : Color.clear, lineWidth: 1.5)
      }
      .contentShape(Rectangle())
      .onTapGesture { pick(glyph.char) }
      .help(glyph.keywords.isEmpty ? glyph.char : glyph.keywords)
      .accessibilityLabel(glyph.keywords.isEmpty ? glyph.char : glyph.keywords)
  }

  private func wideRow(_ glyph: OwlGlyph) -> some View {
    let selected = glyph.char == picked
    return Text(glyph.char)
      .font(.system(size: 13, design: .monospaced))
      .foregroundStyle(palette.ink)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .frame(height: 32)
      .background { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? palette.accent.opacity(0.14) : Color.clear) }
      .overlay {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(selected ? palette.accent : Color.clear, lineWidth: 1.5)
      }
      .contentShape(Rectangle())
      .onTapGesture { pick(glyph.char) }
      .accessibilityLabel(glyph.keywords.isEmpty ? glyph.char : glyph.keywords)
  }

  private var emptyState: some View {
    Text(searching ? "没有匹配「\(query)」的符号" : "最近还没有用过的符号")
      .font(.system(size: 12.5))
      .foregroundStyle(palette.ink3)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 40)
  }

  // MARK: Recent row

  private var showsRecentRow: Bool { !searching && category != .recent }

  private var recentRow: some View {
    HStack(spacing: 7) {
      Text("最近").font(.system(size: 10.5)).foregroundStyle(palette.ink3)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 2) {
          ForEach(recents.filter { $0.count <= 3 }.prefix(12), id: \.self) { char in
            Text(char)
              .font(.system(size: 16))
              .frame(width: 26, height: 26)
              .contentShape(Rectangle())
              .onTapGesture { pick(char) }
          }
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .overlay(alignment: .top) { Rectangle().fill(palette.ink.opacity(0.08)).frame(height: 1) }
  }

  // MARK: Toast

  @ViewBuilder private var toast: some View {
    if !copiedToast.isEmpty {
      Text("已选择 \(copiedToast)")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(palette.onAccent)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background { Capsule().fill(palette.accent) }
        .padding(.bottom, 14)
        .transition(.opacity)
    }
  }

  // MARK: Pick

  private func pick(_ char: String) {
    picked = char
    recents = OwlEmojiRecents.push(char)
    onPick(char)
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { copiedToast = char }
    let token = char
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
      if copiedToast == token {
        withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) { copiedToast = "" }
      }
    }
  }
}
