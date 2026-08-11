//
//  FamoCandidatePanelGeometry.swift
//  法墨输入法 (Famo) — resolved candidate-panel geometry
//

import CoreGraphics

/// 横排候选窗一次解析后的完整 geometry。
///
/// 视图只消费这里已经判定好的点数，不再分别决定某个值是否缩放。竖排与卷轴的剩余
/// geometry 会在各自迁移票中接入；当前先把横排的字号、留白、最小宽度和固定尺寸规则
/// 收到同一个不可变值对象里。
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

  struct PageDots: Equatable, Sendable {
    let hitSize: CGFloat
    let dotDiameter: CGFloat
    let trailingPadding: CGFloat
  }

  struct ExpandChevron: Equatable, Sendable {
    let fontSize: CGFloat
    let hitPadding: CGFloat
    let trailingClearance: CGFloat

    var hitWidth: CGFloat { fontSize + hitPadding * 2 }
  }

  let base: CGFloat
  let minimumWidth: CGFloat
  let selectionInset: CGFloat
  let selectionRadius: CGFloat
  let header: Header
  let compactRow: CompactRow
  let mainRow: MainRow
  let compactPill: CompactPill
  let pageDots: PageDots
  let expandChevron: ExpandChevron

  var chevronClearance: CGFloat {
    expandChevron.hitWidth + expandChevron.trailingClearance
  }

  var expandChevronReservedWidth: CGFloat {
    mainRow.expandChevronLeadingPadding + expandChevron.hitWidth
  }

  init(base: CGFloat, panelCornerRadius: CGFloat) {
    func metric(_ atMedium: CGFloat) -> CGFloat {
      FamoPanelFontSize.metric(atMedium, base: base)
    }

    let selectionInset = metric(5)
    let pillHorizontalPadding = metric(8)
    let chevron = ExpandChevron(
      fontSize: base - 5,
      hitPadding: metric(4),
      trailingClearance: metric(6)
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
    compactRow = CompactRow(inset: selectionInset)
    mainRow = MainRow(
      spacing: metric(6),
      dividerWidth: 1,
      dividerHeight: base * 0.9,
      dividerHorizontalPadding: metric(5),
      expandChevronLeadingPadding: chevronLeadingPadding
    )
    compactPill = CompactPill(
      contentSpacing: metric(5),
      candidateFontSize: base + 1,
      secondaryFontSize: base * 0.72,
      provenanceFontSize: base * 0.68,
      provenanceHorizontalPadding: metric(4),
      provenanceVerticalPadding: metric(3),
      horizontalPadding: pillHorizontalPadding,
      verticalPadding: metric(7)
    )
    pageDots = PageDots(
      hitSize: 18,
      dotDiameter: 5,
      trailingPadding: metric(4)
    )
    expandChevron = chevron
  }
}
