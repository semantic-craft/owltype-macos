//
//  FamoCandidatePanelView.swift
//  法墨输入法 (Famo) — SwiftUI candidate panel
//
//  Visual spec: the Claude Design handoff "Famo Candidate Window" (claude.ai/design).
//  Implements the three forms it specified — ① compact horizontal pill bar (default),
//  ② expanded vertical list, ③ law-citation candidate with the 「法」 badge + source line —
//  in 深大红 (light/dark via colorScheme), honoring Reduce Motion / Reduce Transparency.
//
//  Color source of truth stays `packages/rime-law-config/skins/colors.md` (shenda):
//  the 8 palette tokens come from there; the design's extra structural tints (subtle
//  border, hairline divider, badge fill, selected-pill shadow) are DERIVED from those
//  tokens here rather than hardcoded, so colors.md remains authoritative.
//
//  Boundary (ADR-0001 / 0002): this view renders candidates only; key events, marked
//  text, and commit stay on the native IMK hot path (FamoInputController).
//

import SwiftUI

struct FamoCandidatePanelView: View {
  @Bindable var state: CandidatePanelState
  /// Click-to-select callback (row index on the current page).
  let onSelect: (Int) -> Void
  /// Paging callback (up == true → previous page). Wired to `page(up:)`; reached via the
  /// page-dot affordances in the compact bar.
  let onPage: (Bool) -> Void
  /// Called after the expand chevron toggles `state.isExpanded`, so the hosting panel
  /// can re-fit its frame to the new content size. Optional (default nil) so the
  /// settings skin-preview call site is unaffected. NEEDS REAL-MACHINE VERIFICATION:
  /// the async reframe timing in a non-activating panel.
  var onToggleExpand: (() -> Void)? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme

  /// Resolved 深大红 palette for the active color scheme.
  private var palette: FamoCandidatePalette { state.theme.palette(for: colorScheme) }

  /// True when candidates lay out top-to-bottom (Rime vertical mode or the user
  /// expanded the compact pill bar). Compact single-row pill bar otherwise.
  private var showsFullList: Bool { state.isVertical || state.isExpanded }

  /// The expand/collapse affordance lives in the header for the horizontal form, so
  /// the user can switch the compact bar into the full vertical list and back. Shown
  /// whenever there is more than one candidate (matches the design's always-on chevron).
  private var showsExpandChevron: Bool { !state.isVertical && state.candidates.count > 1 }

  /// Header (preedit + caret + chevron) is only meaningful while composing, and only
  /// when the user keeps the in-panel 输入串 on (off → host inline marked text only).
  private var showsHeader: Bool { state.showPreedit && !state.preedit.isEmpty }

  /// G8: candidate-bar animations run only when the user enabled them AND Reduce Motion
  /// is off (Reduce Motion always wins).
  private var animateOK: Bool { state.animationsEnabled && !reduceMotion }

  // Structural tints derived from the canonical tokens (relationships per the design).
  private var panelBorder: Color { palette.accentDeep.opacity(0.16) }
  private var divider: Color { palette.ink.opacity(0.09) }
  private var badgeFill: Color { palette.accent.opacity(0.14) }

  /// Base candidate point size; smaller roles derive from it so 小/中/大 scales the whole panel.
  private var base: CGFloat { state.fontSize }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if showsHeader { header }
      if showsFullList {
        verticalList
      } else if state.isFlow {
        flowRow
      } else {
        compactRow
      }
    }
    // 竖排让内容/输入串撑宽度（仿搜狗的窄竖排，原 244 强制留白过宽）；横排维持 210。
    .frame(minWidth: showsFullList ? 150 : 210, alignment: .leading)
    .background { glass }
    .overlay {
      RoundedRectangle(cornerRadius: state.theme.cornerRadius, style: .continuous)
        .strokeBorder(panelBorder, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: state.theme.cornerRadius, style: .continuous))
    .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.16),
            radius: state.theme.shadowRadius, x: 0, y: 7)
    .animation(animateOK ? .snappy(duration: 0.08) : nil, value: state.highlightedIndex)
    .animation(animateOK ? .snappy(duration: 0.12) : nil, value: state.isExpanded)
  }

  /// Half-transparent glass: a material under a card tint (design panelBg ≈ card @ 0.85),
  /// falling back to an opaque card fill when Reduce Transparency is on.
  @ViewBuilder private var glass: some View {
    let shape = RoundedRectangle(cornerRadius: state.theme.cornerRadius, style: .continuous)
    if reduceTransparency {
      shape.fill(palette.card)
    } else {
      ZStack {
        shape.fill(.regularMaterial)
        shape.fill(palette.card.opacity(0.85))
      }
    }
  }

  // MARK: Header — preedit (dotted underline) + blinking caret + expand chevron

  private var header: some View {
    let mono = state.preedit.hasPrefix("\\")
    return HStack(spacing: 8) {
      // preedit rendered as pieces: 音节 runs (the active one tinted accent) separated by faint
      // interpunct delimiters, with the blinking caret spliced in at cursor_pos. Arrow keys move
      // both cursor_pos and the highlight span, so the bar and the tint slide through the pinyin.
      HStack(alignment: .bottom, spacing: 0) {
        ForEach(Array(preeditPieces().enumerated()), id: \.offset) { _, piece in
          preeditPieceView(piece, mono: mono)
        }
      }
      Spacer(minLength: 8)
    }
    .padding(.leading, 14)
    .padding(.trailing, 10)
    .padding(.top, 9)
    .padding(.bottom, 5)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("输入串 \(state.preedit)")
  }

  private enum PreeditPiece {
    case run(String, highlighted: Bool)  // a maximal same-tint text run
    case delimiter                       // a syllable-boundary space, shown as a faint ·
    case caret                           // the blinking bar at cursor_pos
  }

  @ViewBuilder private func preeditPieceView(_ piece: PreeditPiece, mono: Bool) -> some View {
    switch piece {
    case .run(let text, let highlighted):
      Text(text)
        .font(.system(size: base - 3, design: mono ? .monospaced : .default))
        .kerning(0.4)
        .foregroundStyle(highlighted ? palette.accent : palette.ink2)
        .lineLimit(1)
    case .delimiter:
      Text("·")
        .font(.system(size: base - 3))
        .foregroundStyle(palette.ink3.opacity(0.55))
        .padding(.horizontal, 2)
    case .caret:
      FamoCaret(color: palette.accent, height: base - 3, animated: !reduceMotion)
        .padding(.horizontal, 0.5)
    }
  }

  /// Break `state.preedit` into styled pieces: syllable runs (the active [selStart, selEnd) run
  /// tinted accent), boundary spaces as faint · delimiters, and the caret spliced in at
  /// `state.cursor`. All offsets are UTF-16; iterating by Character keeps the caret/selection
  /// comparisons off surrogate boundaries. Empty preedit → no pieces (header hidden upstream).
  private func preeditPieces() -> [PreeditPiece] {
    let s = state.preedit
    guard !s.isEmpty else { return [] }
    let caret = max(0, min(state.cursor, s.utf16.count))
    var pieces: [PreeditPiece] = []
    var buffer = ""
    var bufferHighlighted = false
    var u16 = 0
    func flush() {
      if !buffer.isEmpty { pieces.append(.run(buffer, highlighted: bufferHighlighted)); buffer = "" }
    }
    for ch in s {
      if u16 == caret { flush(); pieces.append(.caret) }
      if ch == " " {
        flush(); pieces.append(.delimiter)
      } else {
        let highlighted = u16 >= state.selStart && u16 < state.selEnd
        if highlighted != bufferHighlighted { flush(); bufferHighlighted = highlighted }
        buffer.append(ch)
      }
      u16 += String(ch).utf16.count
    }
    if u16 == caret { flush(); pieces.append(.caret) }
    flush()
    return pieces
  }

  // MARK: Compact horizontal pill bar (default form)

  private var compactRow: some View {
    HStack(spacing: 6) {   // 字↔字：候选之间留白（仿搜狗的舒展间距；原 1 太挤）
      ForEach(state.candidates) { candidate in
        compactPill(candidate)
      }
      // Feature 4: the paging-arrow group (divider + dots) is the only mouse-paging
      // affordance; gate both on the 候选条翻页箭头 pref so they hide together.
      if state.showPaging && (state.hasPrevPage || state.hasNextPage) {
        Rectangle()
          .fill(divider)
          .frame(width: 1, height: base * 0.9)
          .padding(.horizontal, 5)
        pageDots
      }
      if showsExpandChevron {
        expandChevron.padding(.leading, 4)
      }
    }
    .padding(.horizontal, 8)
    .padding(.top, 4)
    .padding(.bottom, 9)
  }

  // MARK: Flow row (横排折行 — 多行矩形)

  /// 折行换行的目标行宽：候选累计超过它就折到下一行，堆成矩形（鼠鬚管 0.15.0「候选折行」同款）。
  /// 随字号缩放。单个超宽候选（长词/法条）仍整体独占一行、绝不截断——`compactPill` 是 `.fixedSize()`，
  /// 而 `FamoFlowLayout` 只在「行首之后」才换行。首个可暴露为「行宽/每行候选数」偏好的旋钮。
  private var flowMaxWidth: CGFloat { base * 16 }

  /// Multi-row rectangle: the same page of `compactPill`s, wrapped at `flowMaxWidth` via a
  /// custom `Layout`. Reuses `compactPill` / `pageDots` / `expandChevron` verbatim (the flow
  /// merely changes how they are arranged); the expand chevron still switches to `verticalList`.
  private var flowRow: some View {
    FamoFlowLayout(maxWidth: flowMaxWidth, hSpacing: 6, vSpacing: 6) {
      ForEach(state.candidates) { candidate in
        compactPill(candidate)
      }
      if state.showPaging && (state.hasPrevPage || state.hasNextPage) {
        pageDots
      }
      if showsExpandChevron {
        expandChevron
      }
    }
    .padding(.horizontal, 8)
    .padding(.top, 4)
    .padding(.bottom, 9)
  }

  /// Expand/collapse affordance — lives in the candidate row (not the preedit header,
  /// which is empty under inline preedit) so it's always reachable.
  private var expandChevron: some View {
    Image(systemName: state.isExpanded ? "chevron.up" : "chevron.down")
      .font(.system(size: base - 5, weight: .semibold))
      .foregroundStyle(palette.ink3)
      .padding(4)
      .contentShape(Rectangle())
      .onTapGesture { state.isExpanded.toggle(); onToggleExpand?() }
      .accessibilityLabel(state.isExpanded ? "收起候选" : "展开候选")
  }

  /// A compact pill: number + word. Highlighted → filled accent pill, onAccent text,
  /// plus a soft accent shadow (shape + shadow + inverted ink = three-way distinction).
  private func compactPill(_ candidate: CandidateViewModel) -> some View {
    let selected = candidate.id == state.highlightedIndex
    // 字↔数字：序号与词之间的间距（仿搜狗，序号更贴近词、成组；5pt，原 7 偏散）。
    return HStack(spacing: 5) {
      // Feature 7: 仅候选 preset hides the序号/字母 label.
      if state.candidateFormat.showsLabel {
        Text(candidate.label.isEmpty ? "\(candidate.id + 1)" : candidate.label)
          .font(.system(size: base * 0.72, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(selected ? palette.onAccent.opacity(0.85) : palette.ink2)
      }
      Text(candidate.text)
        .font(state.fontDesign.candidateFont(size: base + 1))
        .foregroundStyle(selected ? palette.onAccent : palette.ink)
      if state.showsCompactComment(for: candidate), let note = candidate.comment {
        Text(note)
          .font(.system(size: base * 0.72))
          .monospacedDigit()
          .foregroundStyle(selected ? palette.onAccent.opacity(0.82) : palette.ink3)
      }
      if let prov = candidate.provenance {
        provenanceTag(prov, selected: selected)
      }
    }
    // Never compress/truncate a candidate to "…" — take the ideal width and let the
    // bar grow to fit (the top octagram candidates are wider than the later ones).
    .fixedSize()
    // Capsule padding 8 (was 11): trims the space to the LEFT of the index, so the highlighted
    // pill no longer carries a wide accent margin before the number ("序号左边比较宽").
    .padding(.horizontal, 8)
    .padding(.vertical, 7)   // 窗口高度：候选更舒展（原 6）
    .background {
      if selected {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(palette.accent)
          .shadow(color: palette.accent.opacity(0.22), radius: 3, y: 2)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    .contentShape(Rectangle())
    .onTapGesture { onSelect(candidate.id) }
    .accessibilityElement(children: .combine)
  }

  /// Page indicator: a dim prev-dot, the accent current-dot, a dim next-dot — each
  /// present only when that page exists. The dim dots are tappable for mouse paging.
  private var pageDots: some View {
    HStack(spacing: 0) {
      if state.hasPrevPage {
        pageDotButton(palette.ink3.opacity(0.5), label: "上一页") { onPage(true) }
      }
      dot(palette.accent)
        .frame(width: 18, height: 18)
        .accessibilityLabel("当前页")
      if state.hasNextPage {
        pageDotButton(palette.ink3.opacity(0.5), label: "下一页") { onPage(false) }
      }
    }
    .padding(.trailing, 4)
  }

  private func pageDotButton(_ color: Color, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      dot(color)
        .frame(width: 18, height: 18)
        .contentShape(.interaction, Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(label))
  }

  private func dot(_ color: Color) -> some View {
    Circle().fill(color).frame(width: 5, height: 5)
  }

  /// G3 来源小标签：复用「法」徽章的小药丸语法（圆角 5、横 4 纵 3、base*0.68）。
  /// 颜色取自 provenance token（`FamoProvenance.color`）；选中态与 badge 同款反白。
  /// 仅 `provenance != nil`（smart/cloud/法库候选）才渲染；普通拼音候选不调用。
  private func provenanceTag(_ prov: FamoProvenance, selected: Bool) -> some View {
    Text(prov.displayName)
      .font(.system(size: base * 0.68, weight: .semibold))
      .padding(.horizontal, 4)
      .padding(.vertical, 3)
      .background {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(selected ? palette.onAccent.opacity(0.2) : prov.color.opacity(0.16))
      }
      .foregroundStyle(selected ? palette.onAccent : prov.color)
      .accessibilityLabel("来源 \(prov.displayName)\(prov.needsConfirmation ? "，需确认" : "")")
  }

  // MARK: Vertical list (expanded / Rime vertical / citation)

  private var verticalList: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(state.candidates) { candidate in
        listRow(candidate)
      }
    }
    .padding(.horizontal, 6)
    .padding(.top, 4)
    .padding(.bottom, 5)
    .overlay(alignment: .top) {
      // Hairline between the header and the list (the design's list border-top).
      if showsHeader {
        Rectangle().fill(divider).frame(height: 1)
      }
    }
    .overlay(alignment: .topTrailing) {
      // Collapse affordance when expanded from the compact bar (not Rime-native vertical).
      if showsExpandChevron {
        expandChevron.padding(.trailing, 6).padding(.top, 2)
      }
    }
  }

  /// A list row: number + optional 「法」 badge + word + reading/释义 note; a citation
  /// candidate adds a muted source line beneath, indented under the word.
  private func listRow(_ candidate: CandidateViewModel) -> some View {
    let selected = candidate.id == state.highlightedIndex
    return VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {   // 数字↔汉字：序号贴近词、成组（仿搜狗；原 11 偏散）
        // Feature 7: 仅候选 preset hides the序号/字母 label.
        if state.candidateFormat.showsLabel {
          Text(candidate.label.isEmpty ? "\(candidate.id + 1)" : candidate.label)
            .font(.system(size: base * 0.72, weight: .medium))
            .monospacedDigit()
            .frame(width: base, alignment: .center)
            .foregroundStyle(selected ? palette.onAccent.opacity(0.85) : palette.ink2)
        }
        if candidate.badge {
          Text("法")
            .font(.system(size: base * 0.68, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background {
              RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selected ? palette.onAccent.opacity(0.2) : badgeFill)
            }
            .foregroundStyle(selected ? palette.onAccent : palette.accent)
        }
        Text(candidate.text)
          .font(state.fontDesign.candidateFont(size: base))
          .frame(maxWidth: .infinity, alignment: .leading)
          .foregroundStyle(selected ? palette.onAccent : palette.ink)
        // Feature 7: 隐藏注释 / 仅候选 presets drop the reading / 释义 comment.
        if state.candidateFormat.showsComment, let note = candidate.comment, !note.isEmpty {
          Text(note)
            .font(.system(size: base * 0.8))
            .monospacedDigit()
            .foregroundStyle(selected ? palette.onAccent.opacity(0.82) : palette.ink3)
        }
        if let prov = candidate.provenance {
          provenanceTag(prov, selected: selected)
        }
      }
      if let source = candidate.source, !source.isEmpty {
        Text(source)
          .font(.system(size: base * 0.78))
          .foregroundStyle(selected ? palette.onAccent.opacity(0.82) : palette.ink3)
          .padding(.leading, base + 6)   // 对齐词首 = 序号框宽(base) + 上面 HStack 间距(6)
      }
    }
    .padding(.horizontal, 10)   // 框体↔内容：高亮条内边距（仿搜狗稍紧；原 12）
    .padding(.vertical, 8)
    .background {
      if selected {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(palette.accent)
          .shadow(color: palette.accent.opacity(0.22), radius: 3, y: 2)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    .contentShape(Rectangle())
    .onTapGesture { onSelect(candidate.id) }
    .accessibilityElement(children: .combine)
  }
}

/// The composing caret in the preedit header: a thin accent bar that blinks unless
/// Reduce Motion is on (then it stays solid).
private struct FamoCaret: View {
  let color: Color
  let height: CGFloat
  let animated: Bool
  @State private var visible = true

  var body: some View {
    RoundedRectangle(cornerRadius: 1, style: .continuous)
      .fill(color)
      .frame(width: 1.5, height: max(8, height))
      .opacity(visible ? 1 : 0)
      .onAppear {
        guard animated else { return }
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
          visible = false
        }
      }
  }
}

/// 横排折行布局（多行矩形）：把候选从左到右摆放，累计宽度超过 `maxWidth` 就折到下一行，
/// 形成一个矩形候选块（鼠鬚管 0.15.0「候选折行」的 SwiftUI 版；`Layout` 协议需 macOS 13+，
/// 本工程部署目标 14.0）。放同一文件而非独立文件，是为了免动非同步的 `.xcodeproj`（逐文件登记）。
///
/// 换行宽度取 `min(提议宽, maxWidth)`：面板测量 `fittingSize` 时提议宽为 nil，于是按 `maxWidth`
/// 折行，并返回**紧致**包围盒（最宽行 × 总高），让 `NSHostingView.fittingSize` 得到真实矩形尺寸。
/// 只在「行首之后」才换行，故单个超过 `maxWidth` 的候选整体独占一行、绝不被压缩截断。
struct FamoFlowLayout: Layout {
  /// 触发折行的目标行宽（上限）。
  var maxWidth: CGFloat
  /// 同行候选之间的水平间距。
  var hSpacing: CGFloat = 6
  /// 行与行之间的垂直间距。
  var vSpacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> CGSize {
    let width = min(proposal.width ?? maxWidth, maxWidth)
    return arrange(subviews: subviews, width: width).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
    let width = min(proposal.width ?? maxWidth, maxWidth)
    let positions = arrange(subviews: subviews, width: width).positions
    for (index, position) in positions.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
        anchor: .topLeading,
        proposal: .unspecified
      )
    }
  }

  /// 一次遍历同时算出每个子视图的左上角坐标与整体紧致包围盒。子视图取其理想尺寸
  /// (`sizeThatFits(.unspecified)`)，与 `placeSubviews` 的 `.unspecified` 放置一致。
  private func arrange(subviews: Subviews, width: CGFloat) -> (size: CGSize, positions: [CGPoint]) {
    var positions: [CGPoint] = []
    positions.reserveCapacity(subviews.count)
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var widest: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      // 仅在行首之后换行：保证单个超宽候选也能整体独占一行（不截断）。
      if x > 0 && x + size.width > width {
        widest = max(widest, x - hSpacing)
        x = 0
        y += rowHeight + vSpacing
        rowHeight = 0
      }
      positions.append(CGPoint(x: x, y: y))
      x += size.width + hSpacing
      rowHeight = max(rowHeight, size.height)
    }
    widest = max(widest, x - hSpacing)   // 收尾最后一行
    return (CGSize(width: max(0, widest), height: y + rowHeight), positions)
  }
}
