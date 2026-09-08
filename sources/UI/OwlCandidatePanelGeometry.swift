//
//  OwlCandidatePanelGeometry.swift
//  猫头鹰输入法 (Owltype) — resolved candidate-panel geometry
//

import CoreGraphics

/// 候选窗一次解析后的完整 geometry。
///
/// 视图只消费这里已经判定好的点数，不再分别决定某个值是否缩放。横排、竖排、临时展开
/// 与多行都从同一个不可变值对象取得字号、留白、最小宽度和固定尺寸规则。
struct OwlCandidatePanelGeometry: Equatable, Sendable {
  struct Panel: Equatable, Sendable {
    let spacing: CGFloat
    let cornerRadius: CGFloat
    let strokeWidth: CGFloat
  }

  struct Caret: Equatable, Sendable {
    let cornerRadius: CGFloat
    let width: CGFloat
    let minimumHeight: CGFloat
  }

  struct Tag: Equatable, Sendable {
    let fontSize: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let cornerRadius: CGFloat
  }

  struct Header: Equatable, Sendable {
    let preeditFontSize: CGFloat
    let spacing: CGFloat
    let pieceSpacing: CGFloat
    let kerning: CGFloat
    let spacerMinimumLength: CGFloat
    /// 音节分隔点 `·` 左右**额外**的内边。0 是刻意的：`·` 的字身本来就带左右边空，
    /// 中档 16pt 下整个字身宽 4.4pt ≈ 一个半角空格，已经是设计好的分隔量；再各加 2pt
    /// 会让每个音节边界占到 8.4pt——正好是一个字母 `a` 的宽度，长拼音串于是整串发散。
    let delimiterHorizontalPadding: CGFloat
    let caretHorizontalPadding: CGFloat
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let caret: Caret
  }

  struct CompactRow: Equatable, Sendable {
    let inset: CGFloat
  }

  struct MainRow: Equatable, Sendable {
    /// 候选**之间**的额外间隔。0 是刻意的：相邻候选之间已经隔着两份 `compactPill`
    /// 的左右内边（中档 8 + 8 = 16pt，比候选字号的 0.8 倍还宽），再加 6pt 就凑成
    /// 22pt——比一个汉字（中档 20pt）还宽，两个词之间塞得下第三个词。归零后相邻
    /// 候选的点击区还连成一片，两块之间不再有点不中的死区。
    let spacing: CGFloat
    /// 候选与**翻页控件组**（分隔线 + 翻页点 + 展开箭头）之间的间隔，以及该组内部的
    /// 间隔。与 `spacing` 分开是因为两者量的是不同的东西：候选之间收紧不该顺带把翻页
    /// 点和箭头也拽过来——那组控件各自还有自己的内边（`dividerHorizontalPadding` /
    /// `pageDots.trailingPadding` / `expandChevronLeadingPadding`），本值只管组间距。
    let pagerSpacing: CGFloat
    let dividerWidth: CGFloat
    let dividerHeight: CGFloat
    let dividerHorizontalPadding: CGFloat
    let expandChevronLeadingPadding: CGFloat
  }

  struct CompactPill: Equatable, Sendable {
    let contentSpacing: CGFloat
    let candidateFontSize: CGFloat
    let secondaryFontSize: CGFloat
    let provenance: Tag
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
  }

  struct VerticalList: Equatable, Sendable {
    let minimumWidth: CGFloat
    let spacing: CGFloat
    let inset: CGFloat
    let hairlineHeight: CGFloat
    let collapseTrailingPadding: CGFloat
    let collapseTopPadding: CGFloat
  }

  struct SourceLine: Equatable, Sendable {
    let fontSize: CGFloat
    let leadingPadding: CGFloat
  }

  struct ListRow: Equatable, Sendable {
    let contentSpacing: CGFloat
    let itemSpacing: CGFloat
    let labelFontSize: CGFloat
    let candidateFontSize: CGFloat
    let badge: Tag
    let commentFontSize: CGFloat
    let provenance: Tag
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let sourceLine: SourceLine
  }

  struct ScrollStack: Equatable, Sendable {
    let spacing: CGFloat
    let inset: CGFloat
  }

  struct ScrollRow: Equatable, Sendable {
    let spacing: CGFloat
  }

  struct ScrollPill: Equatable, Sendable {
    let contentSpacing: CGFloat
    let candidateFontSize: CGFloat
    let secondaryFontSize: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
  }

  struct PageDots: Equatable, Sendable {
    let spacing: CGFloat
    let hitSize: CGFloat
    let dotDiameter: CGFloat
    let trailingPadding: CGFloat
  }

  struct ExpandChevron: Equatable, Sendable {
    let fontSize: CGFloat
    let hitPadding: CGFloat

    var hitWidth: CGFloat { fontSize + hitPadding * 2 }
  }

  let panel: Panel
  let minimumWidth: CGFloat
  /// 序号槽宽度：主行所有序号里最宽的一个（0 = 本次不显示序号）。主行的序号和多行
  /// 前/后页行的空槽都按这**同一个**宽度摆放，各行候选文字于是落在同一条左边界上；
  /// 两侧共用一个数，任何度量误差同时发生、不会让列错开。视图量出后交给这里解析。
  let labelSlotWidth: CGFloat
  let selectionInset: CGFloat
  let selectionRadius: CGFloat
  let header: Header
  let verticalHeader: Header
  let compactRow: CompactRow
  let mainRow: MainRow
  let compactPill: CompactPill
  let verticalList: VerticalList
  let listRow: ListRow
  let scrollStack: ScrollStack
  let scrollRow: ScrollRow
  let scrollPill: ScrollPill
  let pageDots: PageDots
  let expandChevron: ExpandChevron

  var collapseClearance: CGFloat {
    expandChevron.hitWidth + verticalList.collapseTrailingPadding
  }

  var expandChevronReservedWidth: CGFloat {
    mainRow.expandChevronLeadingPadding + expandChevron.hitWidth
  }

  init(candidateFontSize: CGFloat, panelCornerRadius: CGFloat, labelSlotWidth: CGFloat = 0) {
    let resolve: (CGFloat) -> CGFloat = {
      ($0 * candidateFontSize / OwlPanelFontSize.medium.base).rounded()
    }

    let selectionInset = resolve(5)
    /// 候选**之间**的额外间隔，主行与多行前/后页行共用（见 `MainRow.spacing`）。
    let candidateSpacing: CGFloat = 0
    let pillContentSpacing = resolve(5)
    let pillHorizontalPadding = resolve(8)
    let pillVerticalPadding = resolve(7)
    let secondaryFontSize = candidateFontSize * 0.72
    let listItemSpacing = resolve(7)
    let listHorizontalPadding = resolve(9)
    let labelFontSize = candidateFontSize * 0.9
    let collapseTrailingPadding = resolve(6)
    let tag = Tag(
      fontSize: candidateFontSize * 0.68,
      horizontalPadding: resolve(4),
      verticalPadding: resolve(3),
      cornerRadius: 5
    )
    let caret = Caret(cornerRadius: 1, width: 1.5, minimumHeight: 8)
    let chevron = ExpandChevron(
      fontSize: candidateFontSize - 5,
      hitPadding: resolve(4)
    )
    let chevronLeadingPadding = resolve(4)

    panel = Panel(spacing: 0, cornerRadius: panelCornerRadius, strokeWidth: 1)
    minimumWidth = resolve(210)
    self.labelSlotWidth = labelSlotWidth
    self.selectionInset = selectionInset
    selectionRadius = max(4, panelCornerRadius - selectionInset)
    header = Header(
      preeditFontSize: candidateFontSize - 3,
      spacing: resolve(8),
      pieceSpacing: 0,
      kerning: 0.4,
      spacerMinimumLength: 2,
      delimiterHorizontalPadding: 0,
      caretHorizontalPadding: 0.5,
      leadingPadding: selectionInset + pillHorizontalPadding,
      trailingPadding: resolve(8),
      topPadding: resolve(9),
      bottomPadding: resolve(5),
      caret: caret
    )
    verticalHeader = Header(
      preeditFontSize: candidateFontSize - 3,
      spacing: resolve(8),
      pieceSpacing: 0,
      kerning: 0.4,
      spacerMinimumLength: 2,
      delimiterHorizontalPadding: 0,
      caretHorizontalPadding: 0.5,
      leadingPadding: selectionInset + listHorizontalPadding,
      trailingPadding: resolve(8),
      topPadding: resolve(7),
      bottomPadding: resolve(6),
      caret: caret
    )
    compactRow = CompactRow(inset: selectionInset)
    mainRow = MainRow(
      spacing: candidateSpacing,
      pagerSpacing: resolve(6),
      dividerWidth: 1,
      dividerHeight: candidateFontSize * 0.9,
      dividerHorizontalPadding: resolve(5),
      expandChevronLeadingPadding: chevronLeadingPadding
    )
    compactPill = CompactPill(
      contentSpacing: pillContentSpacing,
      candidateFontSize: candidateFontSize + 1,
      secondaryFontSize: secondaryFontSize,
      provenance: tag,
      horizontalPadding: pillHorizontalPadding,
      verticalPadding: pillVerticalPadding
    )
    verticalList = VerticalList(
      minimumWidth: candidateFontSize * 4,
      spacing: 0,
      inset: selectionInset,
      hairlineHeight: 1,
      collapseTrailingPadding: collapseTrailingPadding,
      collapseTopPadding: resolve(2)
    )
    listRow = ListRow(
      contentSpacing: resolve(3),
      itemSpacing: listItemSpacing,
      labelFontSize: labelFontSize,
      candidateFontSize: candidateFontSize,
      badge: tag,
      commentFontSize: candidateFontSize * 0.8,
      provenance: tag,
      horizontalPadding: listHorizontalPadding,
      verticalPadding: resolve(7),
      sourceLine: SourceLine(
        fontSize: candidateFontSize * 0.78,
        leadingPadding: labelFontSize + listItemSpacing
      )
    )
    scrollStack = ScrollStack(
      spacing: resolve(5),
      inset: selectionInset
    )
    // 多行前/后页行的候选间隔必须与主行**同值**：两者是同一张网格的相邻行，差一点点
    // 都会逐列累加成肉眼可见的错位（差 6pt 时第 5 列已偏 24pt）。所以这里读同一个
    // `candidateSpacing`，而不是各自 `resolve` 一遍。
    scrollRow = ScrollRow(spacing: candidateSpacing)
    scrollPill = ScrollPill(
      contentSpacing: pillContentSpacing,
      candidateFontSize: candidateFontSize + 1,
      secondaryFontSize: secondaryFontSize,
      horizontalPadding: pillHorizontalPadding,
      verticalPadding: pillVerticalPadding
    )
    pageDots = PageDots(
      spacing: 0,
      hitSize: 18,
      dotDiameter: 5,
      trailingPadding: resolve(4)
    )
    expandChevron = chevron
  }
}
