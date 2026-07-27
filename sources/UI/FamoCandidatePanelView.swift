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
  /// Click-to-select for a 卷轴后页行 candidate, by **absolute** index into the whole candidate
  /// list. Separate from `onSelect` (which is a current-page offset) because the two land on
  /// different librime calls. Optional so the settings skin-preview call site is unaffected.
  var onSelectAbsolute: ((Int) -> Void)? = nil
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
  ///
  /// 竖排两形态（07-26 grilling 定案）：开 = 搜狗式「输入条 + 通栏候选」（header 在
  /// 竖排下带 card2 底色成独立条带）；关 = 参照图式纯候选铺满。两形态行都通栏到面板边。
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
      } else if state.isScroll {
        scrollStack
      } else {
        compactRow
      }
    }
    // 竖排让内容/输入串撑宽度（仿鼠鬚管 stacked / 搜狗竖排：以最宽候选贴边 + 对称边距）。
    // 原 150 强制下限在单字候选页留出 ~80pt 右侧空白（「左右不平衡」），改为随字号的
    // 小下限（base*4 ≈ 64/76/92），仅防单候选无序号时面板过窄，正常内容都由内容撑宽。
    // 横排维持 210。
    .frame(minWidth: showsFullList ? base * 4 : 210, alignment: .leading)
    .background { glass }
    .overlay {
      RoundedRectangle(cornerRadius: state.theme.cornerRadius, style: .continuous)
        .strokeBorder(panelBorder, lineWidth: 1)
    }
    .overlay {
      // 薄雾玻璃的顶部内侧高光（R4 mist：inset 0 1px 0 白）——受光面在上。
      RoundedRectangle(cornerRadius: state.theme.cornerRadius, style: .continuous)
        .strokeBorder(
          LinearGradient(
            stops: [.init(color: .white.opacity(colorScheme == .dark ? 0.08 : 0.30), location: 0),
                    .init(color: .clear, location: 0.25)],
            startPoint: .top, endPoint: .bottom),
          lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: state.theme.cornerRadius, style: .continuous))
    // 面板投影不在这里画：SwiftUI 的 .shadow 不撑布局，而窗口尺寸 = contentView.fittingSize，
    // 模糊没有落点。改由 NSPanel 的 `hasShadow` 按内容 alpha 画（FamoSwiftUICandidatePanel）。
    .animation(animateOK ? .snappy(duration: 0.08) : nil, value: state.highlightedIndex)
    .animation(animateOK ? .snappy(duration: 0.12) : nil, value: state.isExpanded)
    // 卷轴的「上滚一行」。仅卷轴下挂动画：其余形态传 nil，翻页仍是既有的瞬时替换，
    // 已发布行为零变化。窗口 frame 本身不参与动画（`setFrameAndShadow` 是直接 setFrame），
    // 靠卷轴行数恒定来保证高度不跳；宽度仍会随候选变化瞬时吸附。
    .animation(animateOK && state.isScroll ? .snappy(duration: 0.18) : nil, value: state.page)
  }

  /// 薄雾玻璃（07-26 grilling R4 定案，HIG Materials）：material 上叠 card @ 0.72 ——
  /// 比原 0.85 更透，让 vibrancy 模糊透出来；Reduce Transparency 回退不透明 card。
  /// 横排/竖排共用（面板外壳是同一层材质，两种排布才协调）。
  @ViewBuilder private var glass: some View {
    let shape = RoundedRectangle(cornerRadius: state.theme.cornerRadius, style: .continuous)
    if reduceTransparency {
      shape.fill(palette.card)
    } else {
      ZStack {
        shape.fill(.regularMaterial)
        shape.fill(palette.card.opacity(0.72))
      }
    }
  }

  /// 选中块（横竖共用）——「通栏圆角」2A，07-26 grilling R6 定案。
  ///
  /// 纯 accent 平色 + 圆角 8，出血到面板内壁；R4 的三层立体（顶部白渐变顶光、内侧 1px
  /// 白描边、accent 外投影）全部撤掉。依据：面板本身已经是玻璃层，Liquid Glass 的
  /// 「avoid glass on glass」意味着选中态不该再是一个自带材质的物件，只该是面板内的
  /// 一块 tint——浮起来的是整块面板（NSPanel `hasShadow`），行只是面板内的分区。
  ///
  /// 圆角保留 8 而不是走 rime-ice `hilited_corner_radius: 0` 的直角出血：HIG 明确
  /// macOS 选中态用 rounded-corner appearance，Tahoe 全系统也在往圆角走。
  @ViewBuilder private func selectionFill(cornerRadius r: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: r, style: .continuous).fill(palette.accent)
  }

  /// 横排 2A 的纵向出血量：选中块顶到候选条的上下内边（上 4 / 下 9，与容器 padding 一一
  /// 对应）。`.background` 里的负 padding 只让背景越界、不改变层布局尺寸。
  ///
  /// 卷轴里主行紧邻别的行时该侧只出 2：行间距只有 5pt，出满会压到邻行上。上下分开判
  /// ——前页行只在上方（页号 < 主行）、后页行只在下方（页号 > 主行），末页可以只有前页行。
  private var compactBleed: (top: CGFloat, bottom: CGFloat) {
    let rowAbove = state.isScroll && state.scrollRows.contains { $0.id < state.page }
    let rowBelow = state.isScroll && state.scrollRows.contains { $0.id > state.page }
    return (rowAbove ? -2 : -4, rowBelow ? -2 : -9)
  }

  // MARK: Header — preedit (dotted underline) + blinking caret + expand chevron

  private var header: some View {
    let mono = state.preedit.hasPrefix("\\")
    // 竖排「输入条」形态：与候选行文字对齐的 14pt 左边距（横排维持原样）。
    let vertical = showsFullList
    return HStack(spacing: 8) {
      // preedit rendered as pieces: 音节 runs (the active one tinted accent) separated by faint
      // interpunct delimiters, with the blinking caret spliced in at cursor_pos. Arrow keys move
      // both cursor_pos and the highlight span, so the bar and the tint slide through the pinyin.
      HStack(alignment: .bottom, spacing: 0) {
        ForEach(Array(preeditPieces().enumerated()), id: \.offset) { _, piece in
          preeditPieceView(piece, mono: mono)
        }
      }
      Spacer(minLength: 2)   // 原 8：输入串是面板最宽行时，这里的富余直接变成右侧空白
    }
    .padding(.leading, 14)
    .padding(.trailing, 8)
    .padding(.top, vertical ? 7 : 9)
    .padding(.bottom, vertical ? 6 : 5)
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
    mainRow
      .padding(.horizontal, 8)
      .padding(.top, 4)
      .padding(.bottom, 9)
  }

  /// 当前页那一行：候选 + 翻页点 + 展开箭头。卷轴与单行横排共用，唯一的区别是外面套的容器。
  private var mainRow: some View {
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
  }

  // MARK: 卷轴（主行 + 后页行，按页对齐）

  /// 卷轴的行集合：主行（librime 当前页）与预取的前/后页行按**页号排序**合并——前页行
  /// （页号 = 主行 − 1）自然落在主行上方，后页行跟在下方。
  ///
  /// 所有行必须放进**同一个** `ForEach`、以页号为身份：翻一页后集合从 [p−1, p, p+1, …]
  /// 变成 [p, p+1, p+2, …]，页号不变的行身份不变，SwiftUI 于是把它们各自动画挪一格
  /// ——观感即「整块上滚一行」（旧主行退成前页行、原后页行升为主行）。拆成多个 ForEach
  /// 就没有这个跨格身份，只会得到逐行的交叉淡化。
  private var scrollPages: [FamoScrollRow] {
    ([FamoScrollRow(id: state.page, candidates: state.candidates)] + state.scrollRows)
      .sorted { $0.id < $1.id }
  }

  /// 没翻过页时 `scrollRows` 为空，卷轴就是单行——展开是翻页动作换来的（2026-07-28）。
  /// 末页没有后页可取，只剩前页行 + 主行——这是「到底了」的诚实表达，不拿空行凑高度。
  private var scrollStack: some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(scrollPages) { row in
        scrollRow(row)
      }
    }
    .padding(.horizontal, 8)
    .padding(.top, 4)
    .padding(.bottom, 9)
  }

  /// 一行 = 一整页。主行走 `mainRow`（带序号、可高亮、挂翻页点与展开箭头）；前/后页行
  /// 只有候选文字（+码提示注释）、稍淡（0.75），点击走绝对下标。非主行**不带序号**是
  /// 刻意的：数字键只选得中主行，给别的行编号会造出「看得到按不到」的假承诺。
  @ViewBuilder private func scrollRow(_ row: FamoScrollRow) -> some View {
    if row.id == state.page {
      mainRow
    } else {
      HStack(spacing: 6) {
        ForEach(row.candidates) { candidate in
          scrollPill(candidate)
        }
      }
      .opacity(0.75)
    }
  }

  /// 前/后页行的候选：候选文字 + 码提示注释（门控与主行同一条 `showsCompactComment`——
  /// 信息密度跟主行一致，截图定案 2026-07-28），尺寸/内边距与 `compactPill` 逐项对齐
  /// （同字号、同 5pt 字-注释间距、同 8/7 内边距），多行才读成一张网格；`.fixedSize()`
  /// 保证绝不压缩截断。
  private func scrollPill(_ candidate: CandidateViewModel) -> some View {
    HStack(spacing: 5) {
      Text(candidate.text)
        .font(state.fontDesign.candidateFont(size: base + 1))
        .foregroundStyle(palette.ink)
      if state.showsCompactComment(for: candidate), let note = candidate.comment {
        Text(note)
          .font(.system(size: base * 0.72))
          .monospacedDigit()
          .foregroundStyle(palette.ink3)
      }
    }
    .fixedSize()
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .contentShape(Rectangle())
    // `candidate.id` 在前/后页行里是整张候选列表的绝对下标（见 `FamoScrollRow`）。
    .onTapGesture { onSelectAbsolute?(candidate.id) }
    .accessibilityLabel(Text(candidate.text))
  }

  /// Expand/collapse affordance — lives in the candidate row (not the preedit header,
  /// which is hidden when the 显示输入串 toggle is off) so it's always reachable.
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
    // 2A：横排选中块与竖排 listRow 同一 helper（纯色圆角 8），排布切换不跳戏；
    // 纵向出血到候选条的上下内边，等同竖排的「出血到面板内壁」。
    .background {
      if selected {
        let bleed = compactBleed
        selectionFill(cornerRadius: 8)
          .padding(.top, bleed.top)
          .padding(.bottom, bleed.bottom)
      }
    }
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
    VStack(alignment: .leading, spacing: 0) {
      ForEach(state.candidates) { candidate in
        listRow(candidate)
      }
    }
    // 2A 通栏（07-26 grilling R6 定案）：原来容器留 4pt 横向内边距、选中块离面板边
    // 4pt；现在把这 4pt 移进 `listRow` 自己的横向 padding（10 → 14），行文字位置分毫
    // 未动，但选中块出血到面板内壁。
    .padding(.top, 3)
    .padding(.bottom, 4)
    // 内容贴边后，从横排展开时右上角的收起箭头不再有富余空白可借，给行内容留出走位。
    .padding(.trailing, showsExpandChevron ? 18 : 0)
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
  ///
  /// 铺满结构（07-26 grilling 定案）：大号带点序号（`1.`，base*0.9）让左侧不再是
  /// 低密度空气；行内左右各 10pt 相等；行铺满面板宽，高亮胶囊左右到边、边距目视对称。
  private func listRow(_ candidate: CandidateViewModel) -> some View {
    let selected = candidate.id == state.highlightedIndex
    return VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 7) {
        // Feature 7: 仅候选 preset hides the序号/字母 label.
        if state.candidateFormat.showsLabel {
          Text((candidate.label.isEmpty ? "\(candidate.id + 1)" : candidate.label) + ".")
            .font(.system(size: base * 0.9))
            .monospacedDigit()
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
          .padding(.leading, base * 0.9 + 7)   // 对齐词首 ≈ 序号宽(base*0.9) + HStack 间距(7)
      }
    }
    // 左右边距相等：「1」到左边 = 末字到右边（参照图的对称感）。14 = 原 10 + 容器让出的 4。
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    // 行铺满面板宽（关输入串时面板宽 = 最宽候选行，即参照图的撑满感；开输入串时
    // 与「输入条」同宽）；选中块 = 出血到面板内壁的纯色圆角块（与横排 compactPill 同 helper）。
    // 通栏的已知代价：开输入串且整句拼音比最宽候选还宽时，选中行会拖一条到输入串
    // 宽度的色尾。改窄会破坏「候选撑满」的参照系，故保留通栏。
    .frame(maxWidth: .infinity, alignment: .leading)
    .background { if selected { selectionFill(cornerRadius: 8) } }
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

