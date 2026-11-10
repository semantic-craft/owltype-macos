//
//  OwlCandidatePanelView.swift
//  猫头鹰输入法 (Owltype) — SwiftUI candidate panel
//
//  Visual spec: the Claude Design handoff "Owltype Candidate Window" (claude.ai/design).
//  Implements the two forms it specified — ① compact horizontal pill bar (default) and
//  ② expanded vertical list — in 深大红 (light/dark via colorScheme), honoring Reduce Motion /
//  Reduce Transparency.
//
//  Color source of truth stays `packages/rime-law-config/skins/colors.md` (shenda):
//  the 8 palette tokens come from there; the design's extra structural tints (subtle
//  border, hairline divider, selected-pill shadow) are DERIVED from those
//  tokens here rather than hardcoded, so colors.md remains authoritative.
//
//  Boundary (ADR-0001 / 0002): this view renders candidates only; key events, marked
//  text, and commit stay on the native IMK hot path (OwlInputController).
//

import AppKit
import SwiftUI

/// 序号槽的宽度量算（纯函数，可单测）。多行的前/后页行留出与主行序号同宽的空槽，
/// 各行候选文字才落在同一条左边界上——而槽里不画数字，因为数字键只选得中主行。
enum OwlCandidateLabelSlot {
  /// `labels` 里最宽的一个（向上取整到整点）。空数组 / 不显示序号 → 0。
  /// 字体与 `compactPill` 的序号一致：system(size:weight:.medium) + monospacedDigit。
  static func width(labels: [String], fontSize: CGFloat) -> CGFloat {
    guard !labels.isEmpty, fontSize > 0 else { return 0 }
    let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
    let widest = labels.reduce(CGFloat.zero) { widest, label in
      max(widest, (label as NSString).size(withAttributes: [.font: font]).width)
    }
    return widest.rounded(.up)
  }
}

struct OwlCandidatePanelView: View {
  @Bindable var state: CandidatePanelState
  /// Click-to-select callback (row index on the current page).
  let onSelect: (Int) -> Void
  /// Paging callback (up == true → previous page). Wired to `page(up:)`; reached via the
  /// page-dot affordances in the compact bar.
  let onPage: (Bool) -> Void
  /// Click-to-select for a 多行后页行 candidate, by **absolute** index into the whole candidate
  /// list. Separate from `onSelect` (which is a current-page offset) because the two land on
  /// different engine calls. Optional so the settings skin-preview call site is unaffected.
  var onSelectAbsolute: ((Int) -> Void)? = nil
  /// Unified token-based candidate selection callback (#264). When set, current-page and
  /// scroll-row taps pass `candidate.token` here instead of separate `onSelect` / `onSelectAbsolute`.
  var onSelectToken: ((OwlCandidateToken) -> Void)? = nil
  /// Called after the expand chevron toggles `state.isExpanded`, so the hosting panel
  /// can re-fit its frame to the new content size. Optional (default nil) so the
  /// settings skin-preview call site is unaffected. NEEDS REAL-MACHINE VERIFICATION:
  /// the async reframe timing in a non-activating panel.
  var onToggleExpand: (() -> Void)? = nil
  var canPin: ((String) -> Bool)? = nil
  var onPin: ((String) -> Void)? = nil
  var onRemove: ((OwlCandidateToken) -> Void)? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme


  /// Resolved 深大红 palette for the active color scheme.
  private var palette: OwlCandidatePalette { state.theme.palette(for: colorScheme) }

  /// True when candidates lay out top-to-bottom (Rime vertical mode or the user
  /// expanded the compact pill bar). Compact single-row pill bar otherwise.
  private var showsFullList: Bool { state.isVertical || state.isExpanded }

  /// The expand/collapse affordance lives in the header for the horizontal form, so
  /// the user can switch the compact bar into the full vertical list and back. Shown
  /// whenever there is more than one candidate (matches the design's always-on chevron).
  private var showsExpandChevron: Bool { !state.isVertical && state.candidates.count > 1 }

  /// Header (preedit + caret + chevron) is only meaningful while composing, and only
  /// when the user keeps the in-panel 输入串 on (off → host inline marked text only).
  ///
  /// 竖排两形态（07-26 grilling 定案）：开 = 搜狗式「输入条 + 通栏候选」（header 在
  /// 竖排下带 card2 底色成独立条带）；关 = 参照图式纯候选铺满。两形态行都通栏到面板边。
  private var showsHeader: Bool { state.showPreedit && !state.preedit.isEmpty }

  /// G8: candidate-bar animations run only when the user enabled them AND Reduce Motion
  /// is off (Reduce Motion always wins).
  private var animateOK: Bool { state.animationsAllowed(reduceMotion: reduceMotion) }

  // Structural tints derived from the canonical tokens (relationships per the design).
  private var panelBorder: Color { palette.accentDeep.opacity(0.16) }
  private var divider: Color { palette.ink.opacity(0.09) }

  /// 所有候选形态都消费一次解析完成的 geometry。
  private var resolvedGeometry: OwlCandidatePanelGeometry {
    OwlCandidatePanelGeometry(
      candidateFontSize: state.fontSize,
      panelCornerRadius: state.theme.cornerRadius,
      labelSlotWidth: OwlCandidateLabelSlot.width(
        labels: state.candidateFormat.showsLabel ? state.candidates.map(labelText) : [],
        fontSize: state.fontSize * 0.72
      )
    )
  }

  /// 主行序号的显示文本：schema 给了就用 schema 的，否则用页内位次。
  private func labelText(for candidate: CandidateViewModel) -> String {
    candidate.label.isEmpty ? "\(candidate.id + 1)" : candidate.label
  }

  var body: some View {
    let geometry = resolvedGeometry
    return VStack(alignment: .leading, spacing: geometry.panel.spacing) {
      if showsHeader { header(geometry: geometry) }
      if showsFullList {
        verticalList(geometry: geometry)
      } else if state.isScroll && !state.visibleScrollRows.isEmpty {
        scrollStack(geometry: geometry)
      } else {
        compactRow(geometry: geometry)
      }
    }
    // 竖排让内容/输入串撑宽度（仿鼠鬚管 stacked / 搜狗竖排：以最宽候选贴边 + 对称边距）。
    // 原 150 强制下限在单字候选页留出 ~80pt 右侧空白（「左右不平衡」），改为随字号的
    // 小下限（geometry 内的 base*4 ≈ 64/76/92），仅防单候选无序号时面板过窄，
    // 正常内容都由内容撑宽。
    // 横排维持 210（中档；随尺寸档缩放为 177 / 210 / 254 / 298，否则小档会拖一截空尾巴）。
    .frame(
      minWidth: showsFullList ? geometry.verticalList.minimumWidth : geometry.minimumWidth,
      alignment: .leading
    )
    .background { glass(geometry: geometry.panel) }
    .overlay {
      RoundedRectangle(cornerRadius: geometry.panel.cornerRadius, style: .continuous)
        .strokeBorder(panelBorder, lineWidth: geometry.panel.strokeWidth)
    }
    .overlay {
      // 薄雾玻璃的顶部内侧高光（R4 mist：inset 0 1px 0 白）——受光面在上。
      RoundedRectangle(cornerRadius: geometry.panel.cornerRadius, style: .continuous)
        .strokeBorder(
          LinearGradient(
            stops: [.init(color: .white.opacity(colorScheme == .dark ? 0.08 : 0.30), location: 0),
                    .init(color: .clear, location: 0.25)],
            startPoint: .top, endPoint: .bottom),
          lineWidth: geometry.panel.strokeWidth)
    }
    .clipShape(RoundedRectangle(cornerRadius: geometry.panel.cornerRadius, style: .continuous))
    // 面板投影不在这里画：SwiftUI 的 .shadow 不撑布局，而窗口尺寸 = contentView.fittingSize，
    // 模糊没有落点。改由 NSPanel 的 `hasShadow` 按内容 alpha 画（OwlSwiftUICandidatePanel）。
    .animation(animateOK ? .snappy(duration: 0.08) : nil, value: state.highlightedIndex)
    .animation(animateOK ? .snappy(duration: 0.12) : nil, value: state.isExpanded)
    // 多行的「上滚一行」。仅多行下挂动画：其余形态传 nil，翻页仍是既有的瞬时替换，
    // 已发布行为零变化。窗口 frame 本身不参与动画（`setFrameAndShadow` 是直接 setFrame），
    // 靠多行行数恒定来保证高度不跳；宽度仍会随候选变化瞬时吸附。
    .animation(animateOK && state.isScroll ? .snappy(duration: 0.18) : nil, value: state.page)
  }

  /// 薄雾玻璃（07-26 grilling R4 定案，HIG Materials）：material 上叠 card @ 0.72 ——
  /// 比原 0.85 更透，让 vibrancy 模糊透出来；Reduce Transparency 回退不透明 card。
  /// 横排/竖排共用（面板外壳是同一层材质，两种排布才协调）。
  @ViewBuilder private func glass(geometry: OwlCandidatePanelGeometry.Panel) -> some View {
    let shape = RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
    if reduceTransparency {
      shape.fill(palette.card)
    } else {
      ZStack {
        shape.fill(.regularMaterial)
        shape.fill(palette.card.opacity(0.72))
      }
    }
  }

  /// 选中块（横竖共用）——纯 accent 平色 + 同心圆角，四边按 resolved inset 等距内嵌。
  ///
  /// 07-26 R4 的三层立体（顶部白渐变顶光、内侧 1px 白描边、accent 外投影）依旧不要：面板本身
  /// 已经是玻璃层，Liquid Glass 的「avoid glass on glass」意味着选中态不该再是一个自带材质的
  /// 物件，只该是面板内的一块 tint——浮起来的是整块面板（NSPanel `hasShadow`），行只是分区。
  ///
  /// 但同时也不走 rime-ice `hilited_corner_radius: 0` 那套直角出血：HIG 明确 macOS 选中态用
  /// rounded-corner appearance，且色块与容器之间要有留白（菜单高亮、侧栏选中都是内嵌的）。
  @ViewBuilder private func selectionFill(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(palette.accent)
  }

  @ViewBuilder private func pinBadge(_ candidate: CandidateViewModel) -> some View {
    if candidate.comment == "置顶" {
      Image(systemName: "pin.fill")
        .font(.system(size: 10))
        .foregroundStyle(candidate.id == state.highlightedIndex ? palette.onAccent : palette.accent)
        .accessibilityLabel("已置顶")
    }
  }

  @ViewBuilder private func pinMenu(_ candidate: CandidateViewModel) -> some View {
    if canPin?(candidate.text) == true {
      Button(candidate.comment == "置顶" ? "取消置顶" : "置顶此候选") { onPin?(candidate.text) }
    }
    if !candidate.token.isAbsolute, candidate.text.unicodeScalars.count > 1 {
      Button("删除候选", role: .destructive) { onRemove?(candidate.token) }
    }
  }

  // MARK: Header — preedit (dotted underline) + blinking caret + expand chevron

  private func header(geometry: OwlCandidatePanelGeometry) -> some View {
    let mono = state.preedit.hasPrefix("\\")
    // 竖排「输入条」形态：与候选行文字对齐的左边距（中档 14pt；横排维持原样）。
    let vertical = showsFullList
    let resolved = vertical ? geometry.verticalHeader : geometry.header
    return HStack(spacing: resolved.spacing) {
      // preedit rendered as pieces: 音节 runs (the active one tinted accent) separated by faint
      // interpunct delimiters, with the blinking caret spliced in at cursor_pos. Arrow keys move
      // both cursor_pos and the highlight span, so the bar and the tint slide through the pinyin.
      HStack(alignment: .bottom, spacing: resolved.pieceSpacing) {
        ForEach(Array(preeditPieces().enumerated()), id: \.offset) { _, piece in
          preeditPieceView(
            piece,
            mono: mono,
            geometry: resolved
          )
        }
      }
      Spacer(minLength: resolved.spacerMinimumLength)
    }
    // 输入串与**第一个候选的文字**左对齐：竖排由 verticalList inset + listRow 内边推出，
    // 横排由 compactRow inset + compactPill 内边推出；两条组合都在 geometry 内一次解析。
    .padding(.leading, resolved.leadingPadding)
    .padding(.trailing, resolved.trailingPadding)
    .padding(.top, resolved.topPadding)
    .padding(.bottom, resolved.bottomPadding)
    // 竖排「输入条」：mist 规格为透明底 + 底部细分隔线（verticalList 顶部 hairline），
    // 不再用 card2 色带——玻璃面板上叠实色条会压住 vibrancy（HIG Materials）。
    .frame(maxWidth: vertical ? .infinity : nil, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("输入串 \(state.preedit)")
  }

  private enum PreeditPiece {
    case run(String, highlighted: Bool)  // a maximal same-tint text run
    case delimiter                       // a syllable-boundary space, shown as a faint ·
    case caret                           // the blinking bar at cursor_pos
  }

  @ViewBuilder private func preeditPieceView(
    _ piece: PreeditPiece,
    mono: Bool,
    geometry: OwlCandidatePanelGeometry.Header
  ) -> some View {
    switch piece {
    case .run(let text, let highlighted):
      Text(text)
        .font(.system(size: geometry.preeditFontSize, design: mono ? .monospaced : .default))
        .kerning(geometry.kerning)
        .foregroundStyle(highlighted ? palette.accent : palette.ink2)
        .lineLimit(1)
    case .delimiter:
      Text("·")
        .font(.system(size: geometry.preeditFontSize))
        .foregroundStyle(palette.ink3.opacity(0.55))
        .padding(.horizontal, geometry.delimiterHorizontalPadding)
    case .caret:
      OwlCaret(
        color: palette.accent,
        height: geometry.preeditFontSize,
        geometry: geometry.caret,
        animated: !reduceMotion
      )
      .padding(.horizontal, geometry.caretHorizontalPadding)
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

  /// 容器内边 = resolved selection inset：首/末候选的选中块离四壁都是这一个值。
  /// 原来是横 8 / 上 4 / 下 9 再让选中块负 padding 出血把上下吃干净，于是色块直接坐在面板下沿。
  private func compactRow(geometry: OwlCandidatePanelGeometry) -> some View {
    mainRow(geometry: geometry)
      .padding(.horizontal, geometry.compactRow.inset)
      .padding(.vertical, geometry.compactRow.inset)
  }

  /// 单行横排：候选间距与翻页控件间距分别解析。
  private func mainRow(geometry: OwlCandidatePanelGeometry) -> some View {
    HStack(spacing: geometry.mainRow.pagerSpacing) {
      HStack(spacing: geometry.mainRow.spacing) {
        ForEach(state.candidates) { candidate in
          compactPill(candidate, geometry: geometry)
        }
      }
      pagerControls(geometry: geometry)
    }
  }

  /// 单行接在候选后面；多行放在独立页脚，不占任何候选列。
  @ViewBuilder private func pagerControls(
    geometry: OwlCandidatePanelGeometry, includesDivider: Bool = true
  ) -> some View {
    // Feature 4: the paging-arrow group (divider + dots) is the only mouse-paging
    // affordance; gate both on the 候选条翻页箭头 pref so they hide together.
    if state.showPaging && (state.hasPrevPage || state.hasNextPage) {
      if includesDivider {
        Rectangle()
          .fill(divider)
          .frame(width: geometry.mainRow.dividerWidth, height: geometry.mainRow.dividerHeight)
          .padding(.horizontal, geometry.mainRow.dividerHorizontalPadding)
      }
      pageDots(geometry: geometry.pageDots)
    }
    if showsExpandChevron {
      expandChevron(geometry: geometry.expandChevron)
        .padding(.leading, geometry.mainRow.expandChevronLeadingPadding)
    }
  }

  // MARK: 多行（共享候选列 + 独立翻页页脚）

  /// 多行的行集合：主行（引擎当前页）与预取的前/后页行按**页号排序**合并——前页行
  /// （页号 = 主行 − 1）自然落在主行上方，后页行跟在下方。
  ///
  /// 所有行必须放进**同一个** `ForEach`、以页号为身份：翻一页后集合从 [p−1, p, p+1, …]
  /// 变成 [p, p+1, p+2, …]，页号不变的行身份不变，SwiftUI 于是把它们各自动画挪一格
  /// ——观感即「整块上滚一行」（旧主行退成前页行、原后页行升为主行）。拆成多个 ForEach
  /// 就没有这个跨格身份，只会得到逐行的交叉淡化。
  private var scrollPages: [OwlScrollRow] {
    ([OwlScrollRow(id: state.page, candidates: state.candidates)] + state.visibleScrollRows)
      .sorted { $0.id < $1.id }
  }

  /// 没翻过页时 `scrollRows` 为空，多行就是单行——展开是翻页动作换来的（2026-07-28）。
  /// 末页没有后页可取，只剩前页行 + 主行——这是「到底了」的诚实表达，不拿空行凑高度。
  private func scrollStack(geometry: OwlCandidatePanelGeometry) -> some View {
    VStack(alignment: .leading, spacing: geometry.scrollStack.spacing) {
      Grid(alignment: .leading,
           horizontalSpacing: geometry.scrollRow.spacing,
           verticalSpacing: geometry.scrollStack.spacing) {
        ForEach(scrollPages) { row in
          GridRow {
            ForEach(row.candidates) { candidate in
              if row.id == state.page {
                compactPill(candidate, geometry: geometry)
              } else {
                scrollPill(candidate, geometry: geometry.scrollPill, labelSlot: geometry.labelSlotWidth)
                  .opacity(0.75)
              }
            }
          }
        }
      }
      if (state.showPaging && (state.hasPrevPage || state.hasNextPage)) || showsExpandChevron {
        HStack(spacing: geometry.mainRow.pagerSpacing) {
          pagerControls(geometry: geometry, includesDivider: false)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .padding(.horizontal, geometry.scrollStack.inset)
    .padding(.vertical, geometry.scrollStack.inset)
  }

  /// 预览页保留序号空槽，但不显示数字：数字键只选择当前页。
  /// 候选保持自然宽度、不截断；Grid 按完整内容（含注释）解析跨行列宽。
  private func scrollPill(
    _ candidate: CandidateViewModel,
    geometry: OwlCandidatePanelGeometry.ScrollPill,
    labelSlot: CGFloat
  ) -> some View {
    HStack(spacing: geometry.contentSpacing) {
      // 主行序号的空槽：只占宽、不画字（0 = 本次不显示序号，两侧都没有槽，照样对齐）。
      if labelSlot > 0 {
        Color.clear.frame(width: labelSlot, height: 0)
      }
      pinBadge(candidate)
      Text(candidate.text)
        .font(state.candidateFont.font(size: geometry.candidateFontSize))
        .foregroundStyle(palette.ink)
      if state.showsCompactComment(for: candidate), let note = candidate.comment, note != "置顶" {
        Text(note)
          .font(.system(size: geometry.secondaryFontSize))
          .monospacedDigit()
          .foregroundStyle(palette.ink3)
      }
    }
    .fixedSize()
    .padding(.horizontal, geometry.horizontalPadding)
    .padding(.vertical, geometry.verticalPadding)
    .contentShape(Rectangle())
    // `candidate.id` 在前/后页行里是整张候选列表的绝对下标（见 `OwlScrollRow`）。
    .onTapGesture {
      if let onSelectToken {
        onSelectToken(candidate.token)
      } else {
        onSelectAbsolute?(candidate.id)
      }
    }
    .contextMenu { pinMenu(candidate) }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(candidate.text))
    .accessibilityIdentifier("scroll-candidate-\(candidate.id)")
  }

  /// Expand/collapse affordance — lives in the candidate row (not the preedit header,
  /// which is hidden when the 显示输入串 toggle is off) so it's always reachable.
  private func expandChevron(
    geometry: OwlCandidatePanelGeometry.ExpandChevron
  ) -> some View {
    Image(systemName: state.isExpanded ? "chevron.up" : "chevron.down")
      .font(.system(size: geometry.fontSize, weight: .semibold))
      .foregroundStyle(palette.ink3)
      .padding(geometry.hitPadding)
      .contentShape(Rectangle())
      .onTapGesture { state.isExpanded.toggle(); onToggleExpand?() }
      .accessibilityLabel(state.isExpanded ? "收起候选" : "展开候选")
  }

  /// A compact pill: number + word. Highlighted → filled accent pill, onAccent text,
  /// plus a soft accent shadow (shape + shadow + inverted ink = three-way distinction).
  private func compactPill(
    _ candidate: CandidateViewModel,
    geometry: OwlCandidatePanelGeometry
  ) -> some View {
    let selected = candidate.id == state.highlightedIndex
    // 字↔数字：序号与词之间的间距（仿搜狗，序号更贴近词、成组；5pt，原 7 偏散）。
    return HStack(spacing: geometry.compactPill.contentSpacing) {
      // Feature 7: 仅候选 preset hides the序号/字母 label.
      if state.candidateFormat.showsLabel {
        Text(labelText(for: candidate))
          .font(.system(size: geometry.compactPill.secondaryFontSize, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(selected ? palette.onAccent.opacity(0.85) : palette.ink2)
          // 与前/后页行的空槽共用同一个宽度，列才不会因量算误差错开；数字右对齐成一条
          // 数字沟（page_size ≤ 9 时全是等宽数字，观感与原来逐点一致）。
          .frame(width: geometry.labelSlotWidth, alignment: .trailing)
      }
      pinBadge(candidate)
      Text(candidate.text)
        .font(state.candidateFont.font(size: geometry.compactPill.candidateFontSize))
        .foregroundStyle(selected ? palette.onAccent : palette.ink)
      if state.showsCompactComment(for: candidate), let note = candidate.comment, note != "置顶" {
        Text(note)
          .font(.system(size: geometry.compactPill.secondaryFontSize))
          .monospacedDigit()
          .foregroundStyle(selected ? palette.onAccent.opacity(0.82) : palette.ink3)
      }
      if let prov = candidate.provenance {
        provenanceTag(
          prov,
          selected: selected,
          geometry: geometry.compactPill.provenance
        )
      }
    }
    // Never compress/truncate a candidate to "…" — take the ideal width and let the
    // bar grow to fit (the top octagram candidates are wider than the later ones).
    .fixedSize()
    // Capsule padding 8 (was 11): trims the space to the LEFT of the index, so the highlighted
    // pill no longer carries a wide accent margin before the number ("序号左边比较宽").
    .padding(.horizontal, geometry.compactPill.horizontalPadding)
    .padding(.vertical, geometry.compactPill.verticalPadding)
    // 横排选中块与竖排 listRow 同一 helper，排布切换不跳戏；块的上下沿就是这里的 7pt 内边，
    // 离面板内壁恒为容器的 resolved inset（多行相邻行距也从同一 geometry 取得）。
    .background { if selected { selectionFill(cornerRadius: geometry.selectionRadius) } }
    .contentShape(Rectangle())
    .onTapGesture {
      if let onSelectToken {
        onSelectToken(candidate.token)
      } else {
        onSelect(candidate.id)
      }
    }
    .contextMenu { pinMenu(candidate) }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("current-candidate-\(candidate.id)")
  }

  /// Page indicator: a dim prev-dot, the accent current-dot, a dim next-dot — each
  /// present only when that page exists. The dim dots are tappable for mouse paging.
  ///
  /// 点本身（5pt）与 18pt 命中区是全档位固定的：18 已经远低于 HIG 的 44pt 下限，再按小档
  /// 收就真点不中了。只有它与候选之间的留白随档位走。
  private func pageDots(geometry: OwlCandidatePanelGeometry.PageDots) -> some View {
    HStack(spacing: geometry.spacing) {
      if state.hasPrevPage {
        pageDotButton(palette.ink3.opacity(0.5), label: "上一页", geometry: geometry) { onPage(true) }
          .accessibilityIdentifier("candidate-page-previous")
      }
      dot(palette.accent, diameter: geometry.dotDiameter)
        .frame(width: geometry.hitSize, height: geometry.hitSize)
        .accessibilityLabel("当前页")
      if state.hasNextPage {
        pageDotButton(palette.ink3.opacity(0.5), label: "下一页", geometry: geometry) { onPage(false) }
          .accessibilityIdentifier("candidate-page-next")
      }
    }
    .padding(.trailing, geometry.trailingPadding)
  }

  private func pageDotButton(
    _ color: Color,
    label: String,
    geometry: OwlCandidatePanelGeometry.PageDots,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      dot(color, diameter: geometry.dotDiameter)
        .frame(width: geometry.hitSize, height: geometry.hitSize)
        .contentShape(.interaction, Rectangle())
    }
    .buttonStyle(.owlPlain)
    .accessibilityLabel(Text(label))
  }

  private func dot(_ color: Color, diameter: CGFloat) -> some View {
    Circle().fill(color).frame(width: diameter, height: diameter)
  }

  /// G3 来源小标签：小药丸语法（圆角 5、横 4 纵 3、base*0.68）。
  /// 颜色取自 provenance token（`OwlProvenance.color`）；仅 `provenance != nil` 才渲染。
  private func provenanceTag(
    _ prov: OwlProvenance,
    selected: Bool,
    geometry: OwlCandidatePanelGeometry.Tag
  ) -> some View {
    Text(prov.displayName)
      .font(.system(size: geometry.fontSize, weight: .semibold))
      .padding(.horizontal, geometry.horizontalPadding)
      .padding(.vertical, geometry.verticalPadding)
      .background {
        RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
          .fill(selected ? palette.onAccent.opacity(0.2) : prov.color.opacity(0.16))
      }
      .foregroundStyle(selected ? palette.onAccent : prov.color)
      .accessibilityLabel("来源 \(prov.displayName)\(prov.needsConfirmation ? "，需确认" : "")")
  }

  // MARK: Vertical list (expanded / Rime vertical)

  private func verticalList(geometry: OwlCandidatePanelGeometry) -> some View {
    VStack(alignment: .leading, spacing: geometry.verticalList.spacing) {
      ForEach(state.candidates) { candidate in
        listRow(candidate, geometry: geometry)
      }
    }
    // 选中行四边按 resolved inset 等距内嵌；这 5pt 从 `listRow` 的横向 padding 里让出来
    // （14 → 9），所以行文字仍在离面板内壁 14pt 处，面板宽度也分毫未动——只有色块内收。
    // 上下原来是 3/4，同样统一到 5。
    .padding(.horizontal, geometry.verticalList.inset)
    .padding(.vertical, geometry.verticalList.inset)
    // 从横排展开时右上角的收起箭头压在第一行上，行内容按 collapseClearance 整块让开。
    // 箭头本身按外框 trailing 6 定位，不受这里影响。
    .padding(.trailing, showsExpandChevron ? geometry.collapseClearance : 0)
    .overlay(alignment: .top) {
      // Hairline between the header and the list (the design's list border-top).
      if showsHeader {
        Rectangle().fill(divider).frame(height: geometry.verticalList.hairlineHeight)
      }
    }
    .overlay(alignment: .topTrailing) {
      // Collapse affordance when expanded from the compact bar (not Rime-native vertical).
      if showsExpandChevron {
        expandChevron(geometry: geometry.expandChevron)
          .padding(.trailing, geometry.verticalList.collapseTrailingPadding)
          .padding(.top, geometry.verticalList.collapseTopPadding)
      }
    }
  }

  /// A list row: number + word + optional provenance tag + reading/释义 note.
  ///
  /// 铺满结构（07-26 grilling 定案）：大号带点序号（`1.`，base*0.9）让左侧不再是
  /// 低密度空气；行内左右各 10pt 相等；行铺满面板宽，高亮胶囊左右到边、边距目视对称。
  private func listRow(
    _ candidate: CandidateViewModel,
    geometry: OwlCandidatePanelGeometry
  ) -> some View {
    let selected = candidate.id == state.highlightedIndex
    let row = geometry.listRow
    return VStack(alignment: .leading, spacing: row.contentSpacing) {
      HStack(spacing: row.itemSpacing) {
        // Feature 7: 仅候选 preset hides the序号/字母 label.
        if state.candidateFormat.showsLabel {
          Text((candidate.label.isEmpty ? "\(candidate.id + 1)" : candidate.label) + ".")
            .font(.system(size: row.labelFontSize))
            .monospacedDigit()
            .foregroundStyle(selected ? palette.onAccent.opacity(0.85) : palette.ink2)
        }
        pinBadge(candidate)
        Text(candidate.text)
          .font(state.candidateFont.font(size: row.candidateFontSize))
          .foregroundStyle(selected ? palette.onAccent : palette.ink)
        // Feature 7: 隐藏注释 / 仅候选 presets drop the reading / 释义 comment.
        if state.candidateFormat.showsComment, let note = candidate.comment, !note.isEmpty, note != "置顶" {
          Text(note)
            .font(.system(size: row.commentFontSize))
            .monospacedDigit()
            .foregroundStyle(selected ? palette.onAccent.opacity(0.82) : palette.ink3)
        }
        if let prov = candidate.provenance {
          provenanceTag(
            prov,
            selected: selected,
            geometry: row.provenance
          )
        }
      }
    }
    // 左右边距相等：「1」到左边 = 末字到右边（参照图的对称感）。中档行内 9 +
    // 容器 inset 5 = 14；verticalHeader.leading 由这两个 resolved 值推出，不会错开。
    .padding(.horizontal, row.horizontalPadding)
    .padding(.vertical, row.verticalPadding)
    // 行铺满（可用宽度内）（关输入串时面板宽 = 最宽候选行，即参照图的撑满感；开输入串时
    // 与「输入条」同宽）；选中块 = 四边留白的纯色圆角块（与横排 compactPill 同 helper）。
    // 已知代价：开输入串且整句拼音比最宽候选还宽时，选中行会拖一条到输入串宽度的色尾。
    // 改窄会破坏「候选撑满」的参照系，故保留。
    .frame(maxWidth: .infinity, alignment: .leading)
    .background { if selected { selectionFill(cornerRadius: geometry.selectionRadius) } }
    .contentShape(Rectangle())
    .onTapGesture {
      if let onSelectToken {
        onSelectToken(candidate.token)
      } else {
        onSelect(candidate.id)
      }
    }
    .contextMenu { pinMenu(candidate) }
    .accessibilityElement(children: .combine)
  }
}

/// The composing caret in the preedit header: a thin accent bar that blinks unless
/// Reduce Motion is on (then it stays solid).
private struct OwlCaret: View {
  let color: Color
  let height: CGFloat
  let geometry: OwlCandidatePanelGeometry.Caret
  let animated: Bool
  @State private var visible = true

  var body: some View {
    RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
      .fill(color)
      .frame(width: geometry.width, height: max(geometry.minimumHeight, height))
      .opacity(visible ? 1 : 0)
      .onAppear {
        guard animated else { return }
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
          visible = false
        }
      }
  }
}
