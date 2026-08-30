//
//  OwlSwiftUICandidatePanel.swift
//  猫头鹰输入法 (Owltype) — SwiftUI candidate panel
//
//  A non-activating NSPanel hosting the SwiftUI candidate view. This is the SOLE
//  candidate renderer (the legacy AppKit OwlPanel was retired when SwiftUI became
//  the only renderer). Created lazily by OwlApplicationDelegate on first composition.
//
//  Boundary (ADR-0001 / 0002): this view layer renders candidates only. Key
//  events, marked text, and commit must stay on the native IMK hot path
//  (OwlInputController). A non-activating panel must never steal focus
//  from the host app.
//

import AppKit
import SwiftUI

/// Pure validator for the IMK caret anchor (B3 — anchor validation cascade).
///
/// The IMK client's `attributes(forCharacterIndex:0,lineHeightRectangle:)` can hand back a
/// junk caret rect: `.zero` / `.null` / infinite / a NaN-or-∞ coordinate / zero-height / an
/// origin on no screen (Electron/Chromium/WebKit/terminals, or right after a focus change).
/// Feeding that to `clampedFrame` lands the panel at the screen origin or the wrong display.
/// This namespace decides whether a rect is usable and resolves a fresh→previous→nil cascade,
/// so the caller falls back to the last known-good anchor instead of using (or storing) junk.
///
/// Pure CoreGraphics: no AppKit side effects beyond reading the `CGRect` / screen frames passed
/// in. Unit-testable with fabricated rects + fake screen frames (no IMK client, no live NSScreen).
enum OwlCandidateAnchor {
  /// Why a caret rect is unusable. `Equatable` so tests assert the exact rejection.
  enum Reason: Equatable {
    case nullRect            // CGRect.null sentinel
    case infiniteRect        // CGRect.infinite sentinel
    case nonFiniteCoordinate // any of origin/size is NaN or ±infinity
    case zeroHeight          // height <= minimumHeight (degenerate caret line)
    case offscreen           // origin contained by no supplied screen frame
  }

  /// Returns `nil` when `rect` is a usable anchor, else the typed reason it was rejected.
  /// Order matters: the cheap sentinel/finite checks run before the screen-containment check.
  static func rejectionReason(_ rect: CGRect, screens: [CGRect], minimumHeight: CGFloat = 1) -> Reason? {
    if rect.isNull { return .nullRect }
    if rect.isInfinite { return .infiniteRect }
    if !rect.origin.x.isFinite || !rect.origin.y.isFinite
      || !rect.size.width.isFinite || !rect.size.height.isFinite { return .nonFiniteCoordinate }
    if rect.size.height <= minimumHeight { return .zeroHeight }
    if !screens.contains(where: { $0.contains(rect.origin) }) { return .offscreen }
    return nil
  }

  /// Convenience: `true` when the rect can be used to position a surface.
  static func isUsable(_ rect: CGRect, screens: [CGRect], minimumHeight: CGFloat = 1) -> Bool {
    rejectionReason(rect, screens: screens, minimumHeight: minimumHeight) == nil
  }

  /// Resolve cascade: usable `fresh` → usable `previous` → `nil` (caller supplies a safe default).
  /// Deliberately small: no AX provider and no TTL cache; reusing the last usable anchor handles
  /// the common case with much less state. Delegates to the ordered multi-candidate form (B4).
  static func resolve(fresh: CGRect, previous: CGRect?, screens: [CGRect], minimumHeight: CGFloat = 1) -> CGRect? {
    resolve(candidates: [fresh], previous: previous, screens: screens, minimumHeight: minimumHeight)
  }

  /// Ordered multi-candidate resolve (B4 — caret-end anchoring). Tries each rect in `candidates`
  /// in order and returns the first usable one; else a usable `previous`; else `nil` (caller
  /// supplies a safe default). The caller passes "this composition" candidates first (e.g.
  /// `[caretRect, headRect]`) so the caret-end rect wins when usable and the char-0 head rect is
  /// the secondary, both preferred over the stale `previous`. Pure CoreGraphics — unit-testable.
  static func resolve(candidates: [CGRect], previous: CGRect?, screens: [CGRect], minimumHeight: CGFloat = 1) -> CGRect? {
    for rect in candidates where isUsable(rect, screens: screens, minimumHeight: minimumHeight) {
      return rect
    }
    if let previous, isUsable(previous, screens: screens, minimumHeight: minimumHeight) { return previous }
    return nil
  }

  /// Pure fallback anchor for cases where both the host caret rect and last-good rect are junk.
  static func safeFallbackAnchor(screens: [CGRect]) -> CGRect {
    let frame = screens.first ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
    let x = frame.midX
    let y = frame.maxY - frame.height * 0.25
    return CGRect(x: x, y: y, width: 1, height: 18)
  }

  /// Chromium/Electron deadlock guard (azooKey parity). `showPanel` runs for every composition,
  /// but the caret query that feeds this cascade — `client.attributes(forCharacterIndex:)` — is a
  /// SYNCHRONOUS round-trip into the host. With zero candidates there is nothing to anchor, and
  /// issuing that query while a host holds a lock (Chrome's JS compiler) can deadlock the IME.
  /// azooKey guards the same way: 0 visible rows → bail before the cursor query. So: only query
  /// the caret when there is at least one candidate to show. Pure — testable without an IMK client.
  static func shouldQueryCaret(candidateCount: Int) -> Bool {
    candidateCount > 0
  }

  /// Whether this update needs the asynchronous second caret read used by Electron/Chromium.
  /// These hosts publish caret geometry over IPC, so the first asynchronous read can still be
  /// stale. Keep correcting after every visible content update, not only the first frame.
  static func shouldScheduleDelayedReposition(
    policyAllows: Bool,
    panelIsVisible: Bool,
    candidateCount: Int
  ) -> Bool {
    policyAllows && panelIsVisible && shouldQueryCaret(candidateCount: candidateCount)
  }
}

/// The immutable content the candidate panel renders for one composition — the value that crosses
/// the panel seam (C3). Built by the controller (`showPanel`) and passed to `update(_:settings:)`;
/// candidate settings ride alongside as the deep module's immutable runtime snapshot.
///
/// Its `Equatable` conformance doubles as the B5 render-dedup key: an identical re-push (a
/// `showPanel` right after commit, or an identical per-key re-paint) early-outs instead of running
/// two SwiftUI layout passes. Any single visible change — preedit, any candidate field, highlight,
/// page, paging flags, orientation, schema, or the caret anchor — makes it unequal so the full
/// render still runs. The candidate part is the `[CandidateViewModel]` array itself (already
/// `Equatable` over its rendering fields), so array equality covers every per-candidate change.
/// Pure value type — the only AppKit type is `NSRect` (a `CGRect`, which is `Equatable`).
struct OwlPanelContent: Equatable {
  let preedit: String
  /// Caret position within `preedit` (UTF-16 offset). Part of the equality signature so an
  /// arrow-key caret move re-renders even when the preedit text and candidates are unchanged.
  let cursor: Int
  /// Highlight span within `preedit` (the active syllable), UTF-16. Part of the equality
  /// signature so tinting the current syllable re-renders.
  let selStart: Int
  let selEnd: Int
  let candidates: [CandidateViewModel]
  let highlightedIndex: Int
  let page: Int
  let hasPrevPage: Bool
  let hasNextPage: Bool
  let isVertical: Bool
  let schemaID: String
  let anchor: NSRect
  /// 卷轴后页行：后 1–2 整页，控制器在 `showPanel` 里按偏好预取；空数组 = 不卷轴
  /// （非卷轴方向 / 末页 / 竖排）。`var` + 默认值让既有构造点（含 B5 等式测试的逐字段
  /// 构造）保持源兼容；数组相等自动并入 B5 去重签名。
  var scrollRows: [OwlScrollRow] = []

  func replacing(anchor: NSRect) -> OwlPanelContent {
    OwlPanelContent(
      preedit: preedit,
      cursor: cursor,
      selStart: selStart,
      selEnd: selEnd,
      candidates: candidates,
      highlightedIndex: highlightedIndex,
      page: page,
      hasPrevPage: hasPrevPage,
      hasNextPage: hasNextPage,
      isVertical: isVertical,
      schemaID: schemaID,
      anchor: anchor,
      scrollRows: scrollRows
    )
  }
}

/// Pure gate + shaping for the 卷轴后页行。Lives beside `OwlPanelContent`（同一面板值层）
/// so the controller's `showPanel` stays a thin call site and the decision/chunking is
/// unit-testable without IMK or librime.
enum OwlScrollRowsPlan {
  /// Whether `showPanel` should peek at the next page(s) for this composition.
  /// True only when: 选了卷轴、**本次组字翻过页**（翻页才展开，2026-07-28）、还有后页、
  /// 本页非空，且本次组字确实以横排渲染（竖排不叠加后页行——与视图侧的渲染分支一致）。
  ///
  /// `.scroll` 的 `isVertical` 恒为 false，那条判断留着是为了将来若允许「自动+卷轴」组合时
  /// 门控依旧正确，且与视图分支一一对应；现在它只对非卷轴方向起作用（那些已被首条挡掉）。
  static func wantsRows(settings: OwlCandidatePanelSettings.Snapshot,
                        didPage: Bool, lastPage: Bool,
                        candidateCount: Int, rimeVertical: Bool, schemaID: String) -> Bool {
    return settings.orientation.scrolls
      && didPage
      && !lastPage
      && candidateCount > 0
      && !settings.orientation.isVertical(rimeVertical: rimeVertical, schemaID: schemaID)
  }

  /// Whether `showPanel` should peek at the page BEFORE the current one（前页行）。
  /// 展开后主行上方保留紧邻的上一页（固定 1 行滑动窗口，不累积）——翻页时旧主行不再
  /// 滚出消失，卷轴的「来路」还看得见。门控与 `wantsRows` 同构，差别只在方向：
  /// 前页看 `page > 0`（翻回第一页就没有前页），后页看 `!lastPage`。
  static func wantsPrevRow(settings: OwlCandidatePanelSettings.Snapshot,
                           didPage: Bool, page: Int,
                           candidateCount: Int, rimeVertical: Bool, schemaID: String) -> Bool {
    return settings.orientation.scrolls
      && didPage
      && page > 0
      && candidateCount > 0
      && !settings.orientation.isVertical(rimeVertical: rimeVertical, schemaID: schemaID)
  }

  /// Chunk the peeked candidates into whole pages（尾行可不满）。前/后页行渲染注释但不渲染
  /// 序号/徽章——序号只属于主行，因为数字键只选得中主行（这正是「按页对齐」保住的语义）。
  ///
  /// `startPage` = 该段首页的页号（后页 = 主行页号 + 1，前页 = 主行页号 − 1）；行 id 取
  /// 页号（卷轴动画的身份），候选 id 取**绝对下标**（`startPage * pageSize + …`），点击时
  /// 直接喂给 `select_candidate`。
  static func rows(from peeked: [RimeCandidate], pageSize: Int, startPage: Int) -> [OwlScrollRow] {
    guard pageSize > 0 else { return [] }
    return stride(from: 0, to: peeked.count, by: pageSize).map { base in
      let page = startPage + base / pageSize
      return OwlScrollRow(
        id: page,
        candidates: peeked[base..<min(base + pageSize, peeked.count)].enumerated().map { offset, cand in
          CandidateViewModel(id: page * pageSize + offset, label: "", text: cand.text, comment: cand.comment)
        })
    }
  }
}

final class OwlSwiftUICandidatePanel: NSPanel {
  private let panelState = CandidatePanelState()
  private var lastRimeVertical = false
  private var lastSchemaID = ""

  /// The content + settings of the last fully-rendered `update(_:settings:)` (B5). Used to skip the
  /// two SwiftUI layout passes when an identical update arrives while the panel is visible.
  /// Both invalidated (set `nil`) on `hidePanel()` and `refreshPreferences()` so the next show /
  /// settings-driven look change always re-renders fully.
  private var lastContent: OwlPanelContent?
  private var lastSettings: OwlCandidatePanelSettings.Snapshot?

  /// Called when a candidate row is clicked. The input controller wires this to
  /// `selectCandidate(_:)`. NEEDS REAL-MACHINE VERIFICATION: click hit-testing in a
  /// non-activating panel.
  var onSelect: ((Int) -> Void)?

  /// Called when a paging chevron is clicked (up == true → previous page). The
  /// input controller wires this to `page(up:)`. NEEDS REAL-MACHINE VERIFICATION:
  /// chevron hit-testing in a non-activating panel.
  var onPage: ((Bool) -> Void)?

  /// Called when a 卷轴后页行 candidate is clicked. Carries the candidate's **absolute** index
  /// into the whole candidate list (not a page offset), so the controller routes it through
  /// `select_candidate` instead of `select_candidate_on_current_page`. Mouse-only path —
  /// the keyboard hot path is untouched.
  var onSelectAbsolute: ((Int) -> Void)?

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false
    )

    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    isFloatingPanel = true
    level = .popUpMenu
    // 窗口投影交给 AppKit（与 emoji / 快捷短语 / 划词菜单四个面板一致）。此前是
    // `false` + 视图层 `.shadow(radius:16, y:8)`，但 SwiftUI 的 shadow 不撑布局，而窗口
    // 尺寸严格等于 `contentView.fittingSize`——16pt 的模糊没有落点，整个面板其实一直没有
    // 投影，屏幕上唯一“浮起来”的东西反而是选中胶囊自己的投影。改由系统按内容 alpha 画，
    // 改由系统按内容 alpha 画，尺寸变化时经 `setFrameAndShadow` 重算形状。
    hasShadow = true
    isOpaque = false
    backgroundColor = .clear
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

    contentView = NSHostingView(
      rootView: OwlCandidatePanelView(
        state: panelState,
        onSelect: { [weak self] index in self?.onSelect?(index) },
        onPage: { [weak self] up in self?.onPage?(up) },
        onSelectAbsolute: { [weak self] index in self?.onSelectAbsolute?(index) },
        onToggleExpand: { [weak self] in self?.reframeToFit() }
      )
    )
  }

  /// The caret anchor from the most recent `update(...)`, so an in-view expand toggle
  /// can re-fit the panel relative to the same anchor.
  private var lastAnchor: NSRect = .zero

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  @discardableResult
  func update(
    _ content: OwlPanelContent,
    settings: OwlCandidatePanelSettings.Snapshot
  ) -> Bool {
    // Nothing to show (between compositions / right after commit, where the controller
    // still calls showPanel with an empty menu): hide instead of rendering an empty pill.
    if content.candidates.isEmpty && content.preedit.isEmpty {
      hidePanel()
      return false
    }
    // B5: skip both layout passes when this update is byte-identical to the one already on
    // screen. Guarded by `isVisible` (so the first show after a hide always renders) and by
    // `lastContent`/`lastSettings` being reset to nil on hide/refreshPreferences. The early-out
    // body is a harmless ensure-visible — no panelState mutation, no layout, no reframeToFit.
    if content == lastContent && settings == lastSettings && isVisible {
      orderFrontRegardless()
      return false
    }
    let wasVisible = isVisible
    lastRimeVertical = content.isVertical
    lastSchemaID = content.schemaID
    panelState.preedit = content.preedit
    panelState.cursor = content.cursor
    panelState.selStart = content.selStart
    panelState.selEnd = content.selEnd
    panelState.candidates = content.candidates
    panelState.highlightedIndex = content.highlightedIndex
    panelState.page = content.page
    panelState.hasPrevPage = content.hasPrevPage
    panelState.hasNextPage = content.hasNextPage
    panelState.scrollRows = content.scrollRows
    applySettings(settings, rimeVertical: content.isVertical, schemaID: content.schemaID)

    lastAnchor = content.anchor
    // Force the hosting view to lay out the NEW candidates before measuring; otherwise
    // fittingSize returns the previous page's size and the panel shows clipped ("half")
    // while fast-paging. reframeToFit() is an async backstop if the sync pass is stale.
    contentView?.layoutSubtreeIfNeeded()
    let fittingSize = contentView?.fittingSize ?? NSSize(width: 320, height: 120)
    setFrameAndShadow(clampedFrame(anchor: content.anchor, size: fittingSize))

    if !isVisible {
      orderFrontRegardless()
      OwlLatencyTrace.event("candidatePanel.firstVisible")
    }
    reframeToFit()
    // B5: remember what we just rendered so an identical re-push can early-out next time.
    lastContent = content
    lastSettings = settings
    return !wasVisible
  }

  /// Reposition after a policy-requested delayed caret read. The first visible frame has already
  /// been shown; this only corrects a stale anchor from flaky clients.
  func reposition(anchor: NSRect) {
    lastAnchor = anchor
    if let lastContent {
      self.lastContent = lastContent.replacing(anchor: anchor)
    }
    contentView?.layoutSubtreeIfNeeded()
    let fittingSize = contentView?.fittingSize ?? frame.size
    setFrameAndShadow(clampedFrame(anchor: anchor, size: fittingSize))
  }

  /// `setFrame` + 仅在**尺寸真的变了**时重算窗口投影。
  ///
  /// AppKit 的窗口投影按内容 alpha 算，是这条热路径上唯一新增的成本；而候选窗每次按键都会
  /// `setFrame`，其中相当一部分（移高亮、翻到等宽的一页、只挪位置不改内容）尺寸并没变——
  /// 那些情况下旧投影形状依然正确，不必重算。面板形状恒为 radius 13 的圆角矩形，尺寸不变
  /// 即形状不变，所以这个判据是充分的。
  private func setFrameAndShadow(_ newFrame: NSRect) {
    let sizeChanged = newFrame.size != frame.size
    setFrame(newFrame, display: true)
    if sizeChanged { invalidateShadow() }
  }

  /// Re-fit the panel to the current content size against the last caret anchor. Called
  /// when the expand chevron toggles `isExpanded` in-view (no new `update(...)` arrives),
  /// so the revealed list isn't clipped. Dispatched async so SwiftUI re-lays-out the
  /// hosting view before we read `fittingSize`.
  func reframeToFit() {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isVisible else { return }
      let fittingSize = self.contentView?.fittingSize ?? self.frame.size
      self.setFrameAndShadow(self.clampedFrame(anchor: self.lastAnchor, size: fittingSize))
    }
  }

  func hidePanel() {
    orderOut(nil)
    // B5: a re-show must always fully re-render (the early-out is guarded by `isVisible`, but
    // resetting here also makes the intent explicit and survives any future visibility tweak).
    lastContent = nil
    lastSettings = nil
  }

  /// Refresh visual preferences while the settings window is open. This is deliberately
  /// panel-only (UserDefaults -> state -> SwiftUI redraw) and does not touch Rime or IMK
  /// key handling.
  func refreshPreferences() {
    // B5: a settings-driven look change (font/skin/orientation default/appearance) invalidates
    // the dedup key — the next `update(_:settings:)` must fully re-render with the fresh settings
    // rather than early-out on unchanged content.
    lastContent = nil
    lastSettings = nil
    applySettings(
      OwlCandidatePanelSettings.live.snapshot(),
      rimeVertical: lastRimeVertical,
      schemaID: lastSchemaID
    )
    contentView?.layoutSubtreeIfNeeded()
    reframeToFit()
  }

  private func applySettings(
    _ settings: OwlCandidatePanelSettings.Snapshot,
    rimeVertical: Bool,
    schemaID: String
  ) {
    // 每次组字都从「未展开」起（老的「默认形态 单行/卷轴」已并入排列方向，2026-07-22；注意
    // 那个「卷轴」指的是默认展开成纵列，与本处的卷轴形态不是一回事）：竖排走 `isVertical`、
    // 卷轴走 `isScroll`，横排/自动为紧凑单行；候选条右侧展开箭头仍可临时切成纵向列表。
    panelState.isExpanded = false
    OwlCandidatePanelSettings.live.apply(
      settings,
      to: panelState,
      rimeVertical: rimeVertical,
      schemaID: schemaID
    ) {
      self.appearance = $0
    }
  }

  /// Place the panel below the caret anchor, clamped multi-display-safe. Delegates the screen
  /// math to `OwlFloatingPanelPositioner.belowCaret` (`useVisibleFrame: false` — Squirrel-faithful
  /// full-`frame` pick + clamp, so a caret reported in the menu-bar/Dock band still resolves).
  private func clampedFrame(anchor: NSRect, size: NSSize) -> NSRect {
    OwlFloatingPanelPositioner.belowCaret(
      anchor: anchor, size: size,
      screens: NSScreen.screens.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) },
      useVisibleFrame: false)
  }
}
