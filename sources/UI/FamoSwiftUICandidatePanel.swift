//
//  FamoSwiftUICandidatePanel.swift
//  法墨输入法 (Famo) — SwiftUI candidate panel
//
//  A non-activating NSPanel hosting the SwiftUI candidate view. This is the SOLE
//  candidate renderer (the legacy AppKit FamoPanel was retired when SwiftUI became
//  the only renderer). Created lazily by FamoApplicationDelegate on first composition.
//
//  Boundary (ADR-0001 / 0002): this view layer renders candidates only. Key
//  events, marked text, and commit must stay on the native IMK hot path
//  (FamoInputController). A non-activating panel must never steal focus
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
enum FamoCandidateAnchor {
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
}

/// The immutable content the candidate panel renders for one composition — the value that crosses
/// the panel seam (C3). Built by the controller (`showPanel`) and passed to `update(_:prefs:)`;
/// the visual prefs (font/theme/appearance) ride alongside as a separate `FamoPanelSnapshot`.
///
/// Its `Equatable` conformance doubles as the B5 render-dedup key: an identical re-push (a
/// `showPanel` right after commit, or an identical per-key re-paint) early-outs instead of running
/// two SwiftUI layout passes. Any single visible change — preedit, any candidate field, highlight,
/// page, paging flags, orientation, schema, or the caret anchor — makes it unequal so the full
/// render still runs. The candidate part is the `[CandidateViewModel]` array itself (already
/// `Equatable` over its rendering fields), so array equality covers every per-candidate change.
/// Pure value type — the only AppKit type is `NSRect` (a `CGRect`, which is `Equatable`).
struct FamoPanelContent: Equatable {
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
  /// 预览后页（三行候选·方向④Ⓑ）：后 1–2 页的只读预览行，控制器在 `showPanel` 里按偏好
  /// 预取；空数组 = 无预览（开关关 / 末页 / 竖排 / 折行）。`var` + 默认值让既有构造点
  /// （含 B5 等式测试的逐字段构造）保持源兼容；数组相等自动并入 B5 去重签名。
  var previewRows: [[CandidateViewModel]] = []

  func replacing(anchor: NSRect) -> FamoPanelContent {
    FamoPanelContent(
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
      previewRows: previewRows
    )
  }
}

/// Pure gate + shaping for the 预览后页 rows（三行候选·方向④Ⓑ）。Lives beside
/// `FamoPanelContent`（同一面板值层）so the controller's `showPanel` stays a thin
/// call site and the decision/chunking is unit-testable without IMK or librime.
enum FamoPreviewPagesPlan {
  /// Whether `showPanel` should peek at the next page(s) for this composition.
  /// True only when: 开关开、还有后页、本页非空，且本次组字会以横排紧凑条渲染
  /// （竖排/折行不叠加预览——与视图侧的渲染分支一致）。
  static func wantsPreview(prefs: FamoPanelSnapshot, lastPage: Bool, candidateCount: Int,
                           rimeVertical: Bool, schemaID: String) -> Bool {
    prefs.previewPages
      && !lastPage
      && candidateCount > 0
      && !prefs.orientation.isVertical(rimeVertical: rimeVertical, schemaID: schemaID)
      && !prefs.orientation.wraps
  }

  /// Chunk the peeked candidates into preview rows of `pageSize`（尾行可不满）。预览行
  /// 只渲染候选文字：无序号/注释/徽章（做法Ⓑ 的裁决）；id 仅为 ForEach 稳定性。
  static func rows(from peeked: [RimeCandidate], pageSize: Int) -> [[CandidateViewModel]] {
    guard pageSize > 0 else { return [] }
    return stride(from: 0, to: peeked.count, by: pageSize).map { base in
      peeked[base..<min(base + pageSize, peeked.count)].enumerated().map { offset, cand in
        CandidateViewModel(id: base + offset, label: "", text: cand.text)
      }
    }
  }
}

final class FamoSwiftUICandidatePanel: NSPanel {
  private let panelState = CandidatePanelState()
  private var lastRimeVertical = false
  private var lastSchemaID = ""

  /// The content + prefs of the last fully-rendered `update(_:prefs:)` (B5). Used to skip the
  /// two SwiftUI layout passes when an identical update arrives while the panel is visible.
  /// Both invalidated (set `nil`) on `hidePanel()` and `refreshPreferences()` so the next show /
  /// settings-driven look change always re-renders fully.
  private var lastContent: FamoPanelContent?
  private var lastPrefs: FamoPanelSnapshot?

  /// Called when a candidate row is clicked. The input controller wires this to
  /// `selectCandidate(_:)`. NEEDS REAL-MACHINE VERIFICATION: click hit-testing in a
  /// non-activating panel.
  var onSelect: ((Int) -> Void)?

  /// Called when a paging chevron is clicked (up == true → previous page). The
  /// input controller wires this to `page(up:)`. NEEDS REAL-MACHINE VERIFICATION:
  /// chevron hit-testing in a non-activating panel.
  var onPage: ((Bool) -> Void)?

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
    hasShadow = false
    isOpaque = false
    backgroundColor = .clear
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

    contentView = NSHostingView(
      rootView: FamoCandidatePanelView(
        state: panelState,
        onSelect: { [weak self] index in self?.onSelect?(index) },
        onPage: { [weak self] up in self?.onPage?(up) },
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
  func update(_ content: FamoPanelContent, prefs: FamoPanelSnapshot) -> Bool {
    // Nothing to show (between compositions / right after commit, where the controller
    // still calls showPanel with an empty menu): hide instead of rendering an empty pill.
    if content.candidates.isEmpty && content.preedit.isEmpty {
      hidePanel()
      return false
    }
    // B5: skip both layout passes when this update is byte-identical to the one already on
    // screen. Guarded by `isVisible` (so the first show after a hide always renders) and by
    // `lastContent`/`lastPrefs` being reset to nil on hide/refreshPreferences. The early-out
    // body is a harmless ensure-visible — no panelState mutation, no layout, no reframeToFit.
    if content == lastContent && prefs == lastPrefs && isVisible {
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
    panelState.previewRows = content.previewRows
    applyPreferences(prefs, rimeVertical: content.isVertical, schemaID: content.schemaID)

    lastAnchor = content.anchor
    // Force the hosting view to lay out the NEW candidates before measuring; otherwise
    // fittingSize returns the previous page's size and the panel shows clipped ("half")
    // while fast-paging. reframeToFit() is an async backstop if the sync pass is stale.
    contentView?.layoutSubtreeIfNeeded()
    let fittingSize = contentView?.fittingSize ?? NSSize(width: 320, height: 120)
    setFrame(clampedFrame(anchor: content.anchor, size: fittingSize), display: true)

    if !isVisible {
      orderFrontRegardless()
      FamoLatencyTrace.event("candidatePanel.firstVisible")
    }
    reframeToFit()
    // B5: remember what we just rendered so an identical re-push can early-out next time.
    lastContent = content
    lastPrefs = prefs
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
    setFrame(clampedFrame(anchor: anchor, size: fittingSize), display: true)
  }

  /// Re-fit the panel to the current content size against the last caret anchor. Called
  /// when the expand chevron toggles `isExpanded` in-view (no new `update(...)` arrives),
  /// so the revealed list isn't clipped. Dispatched async so SwiftUI re-lays-out the
  /// hosting view before we read `fittingSize`.
  func reframeToFit() {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isVisible else { return }
      let fittingSize = self.contentView?.fittingSize ?? self.frame.size
      let frame = self.clampedFrame(anchor: self.lastAnchor, size: fittingSize)
      self.setFrame(frame, display: true)
    }
  }

  func hidePanel() {
    orderOut(nil)
    // B5: a re-show must always fully re-render (the early-out is guarded by `isVisible`, but
    // resetting here also makes the intent explicit and survives any future visibility tweak).
    lastContent = nil
    lastPrefs = nil
  }

  /// Refresh visual preferences while the settings window is open. This is deliberately
  /// panel-only (UserDefaults -> state -> SwiftUI redraw) and does not touch Rime or IMK
  /// key handling.
  func refreshPreferences() {
    // B5: a settings-driven look change (font/skin/orientation default/appearance) invalidates
    // the dedup key — the next `update(_:prefs:)` must fully re-render with the fresh prefs
    // rather than early-out on unchanged content.
    lastContent = nil
    lastPrefs = nil
    applyPreferences(.current(), rimeVertical: lastRimeVertical, schemaID: lastSchemaID)
    contentView?.layoutSubtreeIfNeeded()
    reframeToFit()
  }

  private func applyPreferences(_ prefs: FamoPanelSnapshot, rimeVertical: Bool, schemaID: String) {
    panelState.schemaID = schemaID
    // 每次组字都从「未展开」起（「默认形态 单行/卷轴」已并入排列方向，2026-07-22）：竖排走
    // `isVertical`、折行走 `isFlow`，横排/自动为紧凑单行；候选条右侧展开箭头仍可临时切成纵向列表。
    panelState.isExpanded = false
    // G8 横排/竖排: `.auto` resolves Rime plus schema defaults; explicit choices override.
    panelState.isVertical = prefs.orientation.isVertical(rimeVertical: rimeVertical, schemaID: schemaID)
    // 横排折行（多行矩形）：仅显式 `.flow` 为真，与竖排互斥。
    panelState.isFlow = prefs.orientation.wraps
    // Honor the v0.2.2/G8 appearance prefs.
    panelState.fontSize = prefs.fontSize.base
    panelState.fontDesign = prefs.fontDesign
    panelState.animationsEnabled = prefs.animationsEnabled
    panelState.showPreedit = prefs.showPreedit
    // Feature 4 / 7: paging-arrow visibility + candidate-format preset (self-drawn panel).
    panelState.showPaging = prefs.showPaging
    panelState.candidateFormat = prefs.candidateFormat
    // Honor the chosen 皮肤 so the live candidate panel follows the settings page.
    panelState.theme = prefs.theme
    switch prefs.appearance {
    case .system: self.appearance = nil
    case .light:  self.appearance = NSAppearance(named: .aqua)
    case .dark:   self.appearance = NSAppearance(named: .darkAqua)
    }
  }

  /// Place the panel below the caret anchor, clamped multi-display-safe. Delegates the screen
  /// math to `FamoFloatingPanelPositioner.belowCaret` (`useVisibleFrame: false` — Squirrel-faithful
  /// full-`frame` pick + clamp, so a caret reported in the menu-bar/Dock band still resolves).
  private func clampedFrame(anchor: NSRect, size: NSSize) -> NSRect {
    FamoFloatingPanelPositioner.belowCaret(
      anchor: anchor, size: size,
      screens: NSScreen.screens.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) },
      useVisibleFrame: false)
  }
}
