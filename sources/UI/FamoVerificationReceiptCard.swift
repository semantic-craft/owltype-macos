//
//  FamoVerificationReceiptCard.swift
//  法墨输入法 (Famo) — 核验回执卡渲染 (issue #135, 方案三「朱印」HIG 定稿)
//
//  纯渲染层：NSPanel + SwiftUI 按原型 HIG 标注绘制（卡宽 460 / 圆角 12 / 内距 16 /
//  印章 56×56 · 2.5pt 描边 / 行高 24 / 图标钮 24×24 / 按钮高 22 / SF Mono 11 徽标）。
//  一切状态与动作在 FamoVerificationReceiptModel；跳库/剪贴板纪律也在模型层。
//  键盘走查：↑↓ 选锚点 / ⏎ 联网核验 / ⌘C 复制回执 / esc 关闭；焦点环；respect reduce motion。
//

import AppKit
import SwiftUI

// MARK: - 面板与控制器

/// 回执卡浮窗：nonactivating（不激活 Famo 也可成 key 接键盘）。esc/↑↓/⏎ 走 keyDown，
/// ⌘C 走 performKeyEquivalent（命令键事件不会落进 keyDown）。
final class FamoVerificationReceiptPanel: NSPanel {
  weak var receiptModel: FamoVerificationReceiptModel?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func keyDown(with event: NSEvent) {
    guard let model = receiptModel else { return super.keyDown(with: event) }
    switch event.keyCode {
    case 53: model.requestClose()          // esc
    case 125: model.moveFocus(1)           // ↓
    case 126: model.moveFocus(-1)          // ↑
    case 36, 76: model.verifyFocused()     // ⏎
    default: super.keyDown(with: event)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.modifierFlags.contains(.command),
       event.charactersIgnoringModifiers?.lowercased() == "c",
       let model = receiptModel {
      model.copyReceipt()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

/// 内容随状态流长高（子卡展开/收起）；顶左角钉住、向下生长，越界时贴屏收敛。
private final class FamoReceiptHostingView<Content: View>: NSHostingView<Content> {
  var onSizeChange: ((NSSize) -> Void)?
  private var lastSize: NSSize = .zero

  override func layout() {
    super.layout()
    let size = fittingSize
    if size != lastSize, size.width > 0, size.height > 0 {
      lastSize = size
      onSizeChange?(size)
    }
  }
}

@MainActor
final class FamoVerificationReceiptController {
  static let shared = FamoVerificationReceiptController()

  private var panel: FamoVerificationReceiptPanel?
  private var model: FamoVerificationReceiptModel?
  private var topLeft: NSPoint = .zero

  /// 划词菜单「来源核验」入口：抽锚点（案号闸）→ 建模型 → 弹卡。
  func show(selectedText: String, anchorBounds: NSRect?) {
    close()
    let anchors = FamoVerificationReceiptModel.admittedAnchors(
      from: selectedText,
      currentYear: Calendar.current.component(.year, from: Date()))
    let support = FamoLLMProviderCatalog.sourceSupport(for: FamoProviderProfileStore.shared.defaultProfile)
    let model = FamoVerificationReceiptModel(
      selectedText: selectedText,
      anchors: anchors,
      onlineVerifyAvailable: FamoCloudPreferences.isEnabled && support.supportsSourceVerification,
      verifier: { try await FamoSourceVerificationService.shared.verifyStructured($0) })
    model.onClose = { [weak self] in self?.close() }
    self.model = model

    let panel = FamoVerificationReceiptPanel(
      contentRect: NSRect(x: 0, y: 0, width: 492, height: 200),
      styleMask: [.nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.level = .popUpMenu
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.hasShadow = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.receiptModel = model

    let hosting = FamoReceiptHostingView(rootView: FamoVerificationReceiptView(model: model))
    hosting.onSizeChange = { [weak self] size in self?.resize(to: size) }
    panel.contentView = hosting
    self.panel = panel

    let size = hosting.fittingSize
    topLeft = Self.preferredTopLeft(for: anchorBounds, size: size)
    panel.setContentSize(size)
    panel.setFrameTopLeftPoint(topLeft)
    panel.makeKeyAndOrderFront(nil)
  }

  func close() {
    model?.cancelAll()
    model = nil
    panel?.receiptModel = nil
    panel?.orderOut(nil)
    panel = nil
  }

  private func resize(to size: NSSize) {
    guard let panel else { return }
    let visible = panel.screen?.visibleFrame
      ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    var origin = topLeft
    // 向下长出屏 → 抬高顶边；仍不够就贴顶。
    if origin.y - size.height < visible.minY {
      origin.y = min(visible.minY + size.height + 8, visible.maxY - 8)
    }
    panel.setContentSize(size)
    panel.setFrameTopLeftPoint(origin)
  }

  /// 原型锚定：卡顶左角贴在选区尾部右下（sel.right+10, sel.bottom-6），出屏则贴边收敛。
  static func preferredTopLeft(for bounds: NSRect?, size: NSSize) -> NSPoint {
    let mouse = NSEvent.mouseLocation
    let anchor = bounds ?? NSRect(x: mouse.x, y: mouse.y, width: 0, height: 0)
    let screen = NSScreen.screens.first { $0.frame.intersects(anchor) || $0.frame.contains(mouse) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

    var x = anchor.maxX + 10
    var top = anchor.minY + 6
    if x + size.width > visible.maxX - 8 { x = visible.maxX - size.width - 8 }
    x = max(x, visible.minX + 8)
    if top - size.height < visible.minY + 8 { top = min(visible.minY + size.height + 8, visible.maxY - 8) }
    top = min(top, visible.maxY - 8)
    return NSPoint(x: x, y: top)
  }
}

// MARK: - 语义色（原型色板：已核绿 / 搜不到橙 / 疑似杜撰红）

private struct FamoReceiptSemantics {
  let ok: Color
  let warn: Color
  let bad: Color

  init(scheme: ColorScheme) {
    if scheme == .dark {
      ok = famoColor(hex: "5CB985")
      warn = famoColor(hex: "D98B4A")
      bad = famoColor(hex: "E06A72")
    } else {
      ok = famoColor(hex: "2E7D4F")
      warn = famoColor(hex: "B45B12")
      bad = famoColor(hex: "B4232C")
    }
  }
}

// MARK: - 主视图

struct FamoVerificationReceiptView: View {
  @ObservedObject var model: FamoVerificationReceiptModel
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var palette: FamoCandidatePalette {
    FamoSkinPreferences.skin.theme.palette(for: colorScheme)
  }
  private var semantics: FamoReceiptSemantics { FamoReceiptSemantics(scheme: colorScheme) }
  private var edge: Color { palette.ink3.opacity(0.35) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      sealRow
      quoteView
      anchorList
      footer
      keyboardHints
    }
    .padding(EdgeInsets(top: 16, leading: 16, bottom: 12, trailing: 16))
    .frame(width: 460, alignment: .topLeading)
    .background {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(palette.card)
        .overlay(alignment: .top) {
          // 顶部 3pt 朱线（原型 ::before accent bar）。
          UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12)
            .fill(palette.accent)
            .frame(height: 3)
        }
        .overlay {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(edge, lineWidth: 1)
        }
    }
    .overlay(alignment: .bottom) { toastView }
    .padding(16)  // 面板留白承接阴影
  }

  // MARK: 印鉴方章 + 标题区

  private var sealRow: some View {
    HStack(alignment: .top, spacing: 12) {
      sealView
      VStack(alignment: .leading, spacing: 2) {
        Text("核验回执")
          .font(.famoSerif(size: 15, weight: .bold))
          .tracking(3)
          .foregroundStyle(palette.ink)
        Text(model.subtitle)
          .font(.system(size: 11.5))
          .monospacedDigit()
          .foregroundStyle(palette.ink2)
        Text(model.sealHint)
          .font(.system(size: 11))
          .foregroundStyle(palette.ink3)
      }
      Spacer(minLength: 0)
      Button(action: { model.requestClose() }) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(palette.ink2)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("关闭核验回执")
    }
  }

  /// 印鉴方章 56×56：2×2「法墨核讫」，未核灰、已核朱红；已核后点击复制回执。
  private var sealView: some View {
    let active = model.hasOutcome && !model.isBusy
    let color = active ? palette.accent : palette.ink3
    let grid = VStack(spacing: 2) {
      HStack(spacing: 6) { sealGlyph("法"); sealGlyph("墨") }
      HStack(spacing: 6) { sealGlyph("核"); sealGlyph("讫") }
    }
    .foregroundStyle(color)
    return Button(action: { if active { model.copyReceipt() } }) {
      grid
        .frame(width: 56, height: 56)
        .overlay {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(color, lineWidth: 2.5)
        }
        .rotationEffect(.degrees(-8))
        .opacity(active ? 0.9 : 0.45)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(active ? "复制核验回执" : "核验未完成")
  }

  private func sealGlyph(_ char: String) -> some View {
    Text(char).font(.famoSerif(size: 17, weight: .bold))
  }

  // MARK: 引文摘录

  private var quoteView: some View {
    Text("“\(FamoVerificationQueryRouter.normalizeSelection(model.selectedText))”")
      .font(.famoSerif(size: 12.5, weight: .regular))
      .foregroundStyle(palette.ink2)
      .lineLimit(2)
      .lineSpacing(3)
      .padding(.leading, 10)
      .overlay(alignment: .leading) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(palette.accent.opacity(0.25))
          .frame(width: 3)
      }
  }

  // MARK: 待核清单

  private var anchorList: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 2) {
        if model.isBusy { busyHead }
        if model.anchors.isEmpty {
          Text("未抽取到可核锚点；可用下方按钮对整段选区跳库核对。")
            .font(.system(size: 12))
            .foregroundStyle(palette.ink2)
            .padding(.vertical, 6)
        }
        ForEach(Array(model.anchors.enumerated()), id: \.element.id) { index, anchor in
          FamoAnchorRowView(
            model: model, anchor: anchor, focused: index == model.focusedIndex,
            palette: palette, semantics: semantics, edge: edge)
        }
      }
    }
    .frame(maxHeight: 430)  // 多锚点封顶内部滚动，不炸高
  }

  private var busyHead: some View {
    HStack(spacing: 7) {
      Image(systemName: "checkmark.shield")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(palette.accent)
      Text("待核清单")
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(palette.ink)
      Spacer(minLength: 0)
      ProgressView().controlSize(.small)
      Text("正在联网核验…")
        .font(.system(size: 12))
        .foregroundStyle(palette.ink2)
      Button("取消") { model.cancelAll() }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(palette.accent)
    }
    .padding(.bottom, 6)
  }

  // MARK: 底部批量动作

  @ViewBuilder
  private var footer: some View {
    VStack(alignment: .leading, spacing: 0) {
      Divider().overlay(edge)
      HStack(spacing: 7) {
        if model.hasOutcome && !model.isBusy {
          Text("已核 \(model.verifiedCount) · 待核 \(model.pendingCount) · 疑似杜撰 \(model.suspectedCount)")
            .font(.system(size: 12))
            .foregroundStyle(palette.ink2)
        } else if model.onlineVerifyAvailable {
          batchButton("一键联网核验全部", symbol: "globe", primary: true) { model.verifyAll() }
            .disabled(model.isBusy)
            .opacity(model.isBusy ? 0.45 : 1)
        }
        batchButton("一键打开核验（百度学术 + 北大法宝）", symbol: "safari", primary: false) {
          model.openAllForManualVerify()
        }
        Spacer(minLength: 0)
        if model.hasOutcome && !model.isBusy {
          Button("复制核验摘要") { model.copyReceipt() }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.accent)
        }
      }
      .padding(.top, 9)
    }
  }

  private func batchButton(_ title: String, symbol: String, primary: Bool,
                           action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
        Text(title).font(.system(size: 12, weight: .semibold))
      }
      .padding(.horizontal, 11)
      .frame(height: 24)
      .foregroundStyle(primary ? palette.onAccent : palette.ink)
      .background {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(primary ? palette.accent : Color.clear)
          .overlay {
            if !primary {
              RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(edge, lineWidth: 1)
            }
          }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: 键盘提示 + toast

  private var keyboardHints: some View {
    HStack(spacing: 12) {
      hint(keys: ["↑", "↓"], label: "选锚点")
      hint(keys: ["⏎"], label: "联网核验")
      hint(keys: ["⌘C"], label: "复制回执")
      hint(keys: ["esc"], label: "关闭")
    }
    .padding(.top, 8)
    .overlay(alignment: .top) { Divider().overlay(edge.opacity(0.6)) }
  }

  private func hint(keys: [String], label: String) -> some View {
    HStack(spacing: 3) {
      ForEach(keys, id: \.self) { key in
        Text(key)
          .font(.system(size: 10.5, design: .monospaced))
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background {
            RoundedRectangle(cornerRadius: 4).fill(palette.card2)
              .overlay { RoundedRectangle(cornerRadius: 4).stroke(edge, lineWidth: 1) }
          }
      }
      Text(label).font(.system(size: 11))
    }
    .foregroundStyle(palette.ink2)
  }

  @ViewBuilder
  private var toastView: some View {
    if let toast = model.toastText {
      Text(toast)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(palette.onAccent)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(palette.accent.opacity(0.95)))
        .padding(.bottom, 24)
        .transition(reduceMotion ? .identity : .opacity)
        .allowsHitTesting(false)
    }
  }
}

// MARK: - 锚点行

private struct FamoAnchorRowView: View {
  @ObservedObject var model: FamoVerificationReceiptModel
  let anchor: FamoVerificationAnchor
  let focused: Bool
  let palette: FamoCandidatePalette
  let semantics: FamoReceiptSemantics
  let edge: Color

  @State private var hovering = false
  private let jumpMenu = FamoVerifyJumpMenuController()

  private var state: FamoAnchorVerifyState { model.state(for: anchor) }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      headRow
      if state == .loading { loadingRow }
      if case .success(let source) = state { resultCard(source, confirmed: false) }
      if case .confirmed(let source) = state { resultCard(source, confirmed: true) }
      if state == .notFound { notFoundCard }
      if case .error(let message) = state { errorCard(message) }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .frame(minHeight: 24)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(hovering ? palette.card2 : Color.clear)
    }
    .overlay {
      if focused {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(palette.accent.opacity(0.45), lineWidth: 3)
      }
    }
    .onHover { hovering = $0 }
    .contextMenu { contextMenuContent }
  }

  private var headRow: some View {
    HStack(spacing: 7) {
      statusBadge
      Text(anchor.label)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(palette.ink)
        .lineLimit(1)
      Text(anchor.kind.badgeLabel)
        .font(.system(size: 11))
        .foregroundStyle(palette.ink2)
        .padding(.horizontal, 6)
        .background {
          RoundedRectangle(cornerRadius: 4).stroke(edge, lineWidth: 1)
        }
      Spacer(minLength: 0)
      if model.copiedAnchorID == anchor.id {
        Text("已复制")
          .font(.system(size: 11))
          .foregroundStyle(palette.accent)
      }
      if state == .loading {
        ProgressView().controlSize(.small)
      } else if state.isPending {
        if model.onlineVerifyAvailable {
          iconButton("globe", help: "联网核验…") { model.verify(anchor) }
        }
        iconButton("doc.on.doc", help: "复制检索词") { model.copyQuery(anchor) }
      }
      iconButton("arrow.up.forward.square", help: "跳库核对（法宝 / 知网 / 裁判文书网…）") {
        jumpMenu.present(groups: model.jumpGroups(for: anchor), at: NSEvent.mouseLocation) { item in
          model.open(item.route)
        }
      }
    }
  }

  private var statusBadge: some View {
    let verified = state.isVerified
    return Button(action: { if !verified { model.verify(anchor) } }) {
      Text(verified ? "[已核]" : "[待核]")
        .font(.system(size: 11, weight: .bold, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(verified ? semantics.ok : palette.accent)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(verified ? "已核" : "待核，点击联网核验")
  }

  private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(hovering ? palette.ink : palette.ink2)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }

  private var loadingRow: some View {
    HStack(spacing: 6) {
      ProgressView().controlSize(.small)
      Text("正在联网核验…")
        .font(.system(size: 12))
        .foregroundStyle(palette.ink2)
      Button("取消") { model.cancel(anchor) }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(palette.accent)
    }
    .padding(.leading, 12)
  }

  // MARK: 折叠详情 — 绿卡（已核）

  private func resultCard(_ source: FamoVerifiedAnchorSource, confirmed: Bool) -> some View {
    collapse(title: "已核详情 · 来源信息", anchorID: anchor.id) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Image(systemName: "checkmark.circle")
            .font(.system(size: 12, weight: .semibold))
          Text("已找到可核来源")
            .font(.system(size: 12.5, weight: .bold))
        }
        .foregroundStyle(semantics.ok)
        if let snippet = source.snippet, !snippet.isEmpty {
          Text(snippet)
            .font(.system(size: 12.5))
            .foregroundStyle(palette.ink)
            .lineLimit(4)
        }
        // LLM 返回的 URL 过 safeWebURL 闸：非 http(s)/带 userinfo → 降级不可点纯文本。
        if let url = FamoExternalLinkPolicy.safeWebURL(source.url) {
          Button(action: { model.open(FamoVerificationRoute(kind: .deepLink, source: .manual, query: "", url: url)) }) {
            Text(source.url)
              .font(.system(size: 12))
              .foregroundStyle(palette.accent)
              .lineLimit(1)
              .underline()
          }
          .buttonStyle(.plain)
        } else {
          Text(source.url)
            .font(.system(size: 12))
            .foregroundStyle(palette.ink2)
            .lineLimit(1)
            .help("该链接不是标准网址，已禁用点击")
        }
        Text("来源：\(source.provider) · 联网核验")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink2)
        if !confirmed {
          HStack(spacing: 7) {
            smallButton("确认[已核]", fill: semantics.ok) { model.confirm(anchor) }
            smallButton("不对，手动查", fill: nil) { model.manualFallback(anchor) }
          }
          .padding(.top, 4)
        }
        chipsRow(caption: "跳库复核：")
      }
      .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(semantics.ok.opacity(0.10))
      }
    }
  }

  // MARK: 折叠详情 — 橙/红卡（未核实 / 疑似杜撰）

  private var notFoundCard: some View {
    // 法条权威齐全：搜不到该条号高度可疑（常见于 AI 杜撰）→ 红「疑似杜撰 · 待核」。
    // 案例/文献搜不到可能只是库未收录 → 橙色中性提示。
    let isLaw = anchor.kind == .law
    let tone = isLaw ? semantics.bad : semantics.warn
    return collapse(title: "未能核实 · 手动查验建议", anchorID: anchor.id) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Image(systemName: isLaw ? "exclamationmark.triangle.fill" : "questionmark.circle")
            .font(.system(size: 12, weight: .semibold))
          Text(isLaw ? "疑似杜撰 · 待核" : "未能通过联网核实")
            .font(.system(size: 12.5, weight: .bold))
        }
        .foregroundStyle(tone)
        Text(isLaw
          ? "法条权威齐全，联网搜不到该条号——高度可疑（常见于 AI 杜撰）。请用下列来源手动核对。"
          : "搜不到 ≠ 不存在。建议使用下列来源手动查验（深链跳转，在你自己的浏览器中核对）：")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink)
        chipsRow(caption: nil)
      }
      .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(tone.opacity(0.10))
      }
    }
  }

  private func errorCard(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 12, weight: .semibold))
        Text("联网核验暂不可用")
          .font(.system(size: 12.5, weight: .bold))
      }
      .foregroundStyle(semantics.bad)
      Text(message)
        .font(.system(size: 12))
        .foregroundStyle(palette.ink2)
      chipsRow(caption: "手动查验：")
    }
    .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(semantics.bad.opacity(0.10))
    }
  }

  // MARK: 共用小件

  private func collapse<Content: View>(
    title: String, anchorID: String, @ViewBuilder content: () -> Content
  ) -> some View {
    let isOpen = model.expanded[anchorID] ?? true
    return VStack(alignment: .leading, spacing: 4) {
      Button(action: { model.expanded[anchorID] = !isOpen }) {
        Text("\(isOpen ? "▾" : "▸") \(title)")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(palette.accent)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if isOpen { content() }
    }
  }

  private func smallButton(_ title: String, fill: Color?, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 11)
        .frame(height: 22)
        .foregroundStyle(fill == nil ? palette.ink : .white)
        .background {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(fill ?? Color.clear)
            .overlay {
              if fill == nil {
                RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(edge, lineWidth: 1)
              }
            }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(minHeight: 24)  // 命中区 ≥24
  }

  private func chipsRow(caption: String?) -> some View {
    let items = model.manualChipItems(for: anchor)
    return HStack(spacing: 5) {
      if let caption {
        Text(caption)
          .font(.system(size: 12))
          .foregroundStyle(palette.ink2)
      }
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        Button(action: { model.open(item.route) }) {
          Text("\(item.title) ↗")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background {
              Capsule().stroke(edge, lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.top, 4)
  }

  @ViewBuilder
  private var contextMenuContent: some View {
    // 右键更多源：分组源菜单（与 ↗ 跳库同一模型）。
    ForEach(Array(model.jumpGroups(for: anchor).enumerated()), id: \.offset) { _, group in
      Section(group.title) {
        ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
          Button(item.title) { model.open(item.route) }
        }
      }
    }
    Divider()
    Button("复制检索词") { model.copyQuery(anchor) }
  }
}
