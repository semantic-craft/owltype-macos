//
//  FamoCandidatePanelGeometry.swift
//  法墨输入法 (Famo) — resolved candidate-panel geometry
//

import CoreGraphics

/// 候选窗一次解析后的完整 geometry。
///
/// 视图只消费这里已经判定好的点数，不再分别决定某个值是否缩放。横排、竖排、临时展开
/// 与卷轴都从同一个不可变值对象取得字号、留白、最小宽度和固定尺寸规则。
struct FamoCandidatePanelGeometry: Equatable, Sendable {
  struct Header: Equatable, Sendable {
    let preeditFontSize: CGFloat
    let spacing: CGFloat
    let spacerMinimumLength: CGFloat
    let delimiterHorizontalPadding: CGFloat
    let caretHorizontalPadding: CGFloat
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
  }

  struct CompactRow: Equatable, Sendable {
    let inset: CGFloat
  }

  struct MainRow: Equatable, Sendable {
    let spacing: CGFloat
    let dividerWidth: CGFloat
    let dividerHeight: CGFloat
    let dividerHorizontalPadding: CGFloat
    let expandChevronLeadingPadding: CGFloat
  }

  struct CompactPill: Equatable, Sendable {
    let contentSpacing: CGFloat
    let candidateFontSize: CGFloat
    let secondaryFontSize: CGFloat
    let provenanceFontSize: CGFloat
    let provenanceHorizontalPadding: CGFloat
    let provenanceVerticalPadding: CGFloat
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
    let badgeFontSize: CGFloat
    let badgeHorizontalPadding: CGFloat
    let badgeVerticalPadding: CGFloat
    let commentFontSize: CGFloat
    let provenanceFontSize: CGFloat
    let provenanceHorizontalPadding: CGFloat
    let provenanceVerticalPadding: CGFloat
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
    let hitSize: CGFloat
    let dotDiameter: CGFloat
    let trailingPadding: CGFloat
  }

  struct ExpandChevron: Equatable, Sendable {
    let fontSize: CGFloat
    let hitPadding: CGFloat

    var hitWidth: CGFloat { fontSize + hitPadding * 2 }
  }

  let base: CGFloat
  let minimumWidth: CGFloat
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

  init(base: CGFloat, panelCornerRadius: CGFloat) {
    func metric(_ atMedium: CGFloat) -> CGFloat {
      FamoPanelFontSize.metric(atMedium, base: base)
    }

    let selectionInset = metric(5)
    let pillContentSpacing = metric(5)
    let pillHorizontalPadding = metric(8)
    let pillVerticalPadding = metric(7)
    let secondaryFontSize = base * 0.72
    let listItemSpacing = metric(7)
    let listHorizontalPadding = metric(9)
    let labelFontSize = base * 0.9
    let collapseTrailingPadding = metric(6)
    let chevron = ExpandChevron(
      fontSize: base - 5,
      hitPadding: metric(4)
    )
    let chevronLeadingPadding = metric(4)

    self.base = base
    minimumWidth = metric(210)
    self.selectionInset = selectionInset
    selectionRadius = max(4, panelCornerRadius - selectionInset)
    header = Header(
      preeditFontSize: base - 3,
      spacing: metric(8),
      spacerMinimumLength: 2,
      delimiterHorizontalPadding: 2,
      caretHorizontalPadding: 0.5,
      leadingPadding: selectionInset + pillHorizontalPadding,
      trailingPadding: metric(8),
      topPadding: metric(9),
      bottomPadding: metric(5)
    )
    verticalHeader = Header(
      preeditFontSize: base - 3,
      spacing: metric(8),
      spacerMinimumLength: 2,
      delimiterHorizontalPadding: 2,
      caretHorizontalPadding: 0.5,
      leadingPadding: selectionInset + listHorizontalPadding,
      trailingPadding: metric(8),
      topPadding: metric(7),
      bottomPadding: metric(6)
    )
    compactRow = CompactRow(inset: selectionInset)
    mainRow = MainRow(
      spacing: metric(6),
      dividerWidth: 1,
      dividerHeight: base * 0.9,
      dividerHorizontalPadding: metric(5),
      expandChevronLeadingPadding: chevronLeadingPadding
    )
    compactPill = CompactPill(
      contentSpacing: pillContentSpacing,
      candidateFontSize: base + 1,
      secondaryFontSize: secondaryFontSize,
      provenanceFontSize: base * 0.68,
      provenanceHorizontalPadding: metric(4),
      provenanceVerticalPadding: metric(3),
      horizontalPadding: pillHorizontalPadding,
      verticalPadding: pillVerticalPadding
    )
    verticalList = VerticalList(
      minimumWidth: base * 4,
      spacing: 0,
      inset: selectionInset,
      hairlineHeight: 1,
      collapseTrailingPadding: collapseTrailingPadding,
      collapseTopPadding: metric(2)
    )
    listRow = ListRow(
      contentSpacing: metric(3),
      itemSpacing: listItemSpacing,
      labelFontSize: labelFontSize,
      candidateFontSize: base,
      badgeFontSize: base * 0.68,
      badgeHorizontalPadding: metric(4),
      badgeVerticalPadding: metric(3),
      commentFontSize: base * 0.8,
      provenanceFontSize: base * 0.68,
      provenanceHorizontalPadding: metric(4),
      provenanceVerticalPadding: metric(3),
      horizontalPadding: listHorizontalPadding,
      verticalPadding: metric(7),
      sourceLine: SourceLine(
        fontSize: base * 0.78,
        leadingPadding: labelFontSize + listItemSpacing
      )
    )
    scrollStack = ScrollStack(
      spacing: metric(5),
      inset: selectionInset
    )
    scrollRow = ScrollRow(spacing: metric(6))
    scrollPill = ScrollPill(
      contentSpacing: pillContentSpacing,
      candidateFontSize: base + 1,
      secondaryFontSize: secondaryFontSize,
      horizontalPadding: pillHorizontalPadding,
      verticalPadding: pillVerticalPadding
    )
    pageDots = PageDots(
      hitSize: 18,
      dotDiameter: 5,
      trailingPadding: metric(4)
    )
    expandChevron = chevron
  }
}
