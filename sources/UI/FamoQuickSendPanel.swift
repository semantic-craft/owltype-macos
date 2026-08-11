//
//  FamoQuickSendPanel.swift
//  法墨输入法 (Famo) — 快捷短语面板 (quick-phrase picker panel) [PR2]
//
//  A floating NSPanel that lists the configured 快捷短语 (`FamoQuickSendStore`) and inserts a
//  picked phrase at the cursor — mode-independent (works identically in 五笔/拼音/英文 because it
//  never touches the Rime engine).
//
//  PR2 adopts `FamoPromptFillSheet`'s FOCUS RECIPE so the panel can host a TYPED SEARCH field
//  WITHOUT losing the insert-into-host path. Instead of PR1's hard `canBecomeKey = false` (which
//  can never focus a text field — the reason the emoji panel dropped search), the panel is a
//  `.nonactivatingPanel` with `becomesKeyOnlyIfNeeded = true`: it becomes key ONLY when the search
//  field needs input, never at the app level. On show it captures the frontmost `NSRunningApplication`;
//  before a pick's insert runs it REACTIVATES that captured app so focus returns to the original
//  text field, and the controller inserts through the client reference it captured up-front. Iron
//  rule (unchanged): the pick path must NEVER call `NSApp.activate(...)` — that deactivates the IME
//  session at the app level and nils `client` (the reason `FamoAIWindow` is copy-only). The proven
//  capture→restore lifecycle mirrors `FamoPromptFillSheet` exactly.
//
//  Positioning (PR2, design B): the panel is placed NEAR the caret by reusing the candidate panel's
//  last caret anchor (`FamoApplicationDelegate.lastCaretAnchor`, mirroring
//  `FamoSwiftUICandidatePanel.clampedFrame`): below the caret by default, flipped above when it would
//  fall off the screen bottom, clamped to the screen holding the caret. When no caret is known
//  (summoned with no active composition), it falls back to centering under the mouse (PR1 / emoji
//  behavior).
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI UI layer only; the IMK key-event hot path
//  (FamoInputController) is untouched — we only ADD a caller of the existing insert seam
//  (`apply(.insertText:client:)` via the controller's captured client).
//
//  Concurrency: not `@MainActor`-isolated (matches the other Famo panels); the non-isolated
//  delegate creates/shows it on the main thread. AppKit window lifecycle + focus restore are NOT
//  headless-testable — only the pure filter/selection logic in `FamoPickerPanelModel` is unit
//  tested; the insert-after-restore + near-caret positioning are real-machine smoke items.
//

import AppKit
import SwiftUI

// MARK: - Model

/// One row in the picker list. Source-agnostic so the panel/model skeleton can be SHARED across
/// picker sources (快捷短语 / 提示词): each source maps its own entries into rows via a small adapter
/// (see `quickSend`). `id` is the underlying entry's stable identity (its trigger code) — the pick
/// handler resolves it back to the source entry to decide what to insert. Pure value type, no AppKit.
struct FamoPickerRow: Identifiable, Equatable {
  /// Stable identity of the underlying entry (the trigger code).
  let id: String
  /// The string shown in the list row (快捷短语: the phrase; 提示词: the title).
  let display: String
  /// The haystack the search query matches against (case-insensitive substring). Precomputed so
  /// filtering stays a single test; a source builds it from whatever fields it wants searchable.
  let searchText: String

  /// `searchText` defaults to `display` when a source has nothing else to match on.
  init(id: String, display: String, searchText: String? = nil) {
    self.id = id
    self.display = display
    self.searchText = searchText ?? display
  }
}

extension FamoPickerRow {
  /// Map a 快捷短语 entry to a picker row: show the phrase, search phrase OR trigger code. The "\n"
  /// separator reproduces the old `text.contains || code.contains` semantics — no realistic query
  /// contains a newline, so a match can never span the phrase/code boundary.
  static func quickSend(_ entry: FamoQuickSendEntry) -> FamoPickerRow {
    FamoPickerRow(id: entry.code, display: entry.text, searchText: entry.text + "\n" + entry.code)
  }

  /// Map a 提示词 entry to a picker row: show the (single-line) title, search title OR trigger code.
  /// The body/variables live on the source `FamoPromptEntry` (resolved back by `id` on pick), not on
  /// the row. Same "\n"-separated searchText convention as `quickSend`.
  static func prompt(_ entry: FamoPromptEntry) -> FamoPickerRow {
    FamoPickerRow(id: entry.code, display: entry.title, searchText: entry.title + "\n" + entry.code)
  }
}

/// Which source the panel is showing. The list/search/nav skeleton is shared; only the row source
/// and the pick action differ (短语 inserts the phrase string; 提示词 inserts the body, routing
/// through a fill sheet when it has `{{变量}}`).
enum FamoPickerSegment: String, CaseIterable {
  case phrase
  case prompt

  var label: String { self == .phrase ? "短语" : "提示词" }
}

/// Pure, unit-testable state for the picker panel: the loaded rows, the current search query, and
/// the current selection. Filtering is a case-insensitive substring match on each row's precomputed
/// `searchText`; an empty query shows the full list. Selection, navigation, and 1–9 number mapping
/// all operate on the FILTERED (`visible`) rows and are clamped into range. No AppKit — the view
/// holds it as `@State` and tests drive it directly. Shared by every picker source (短语/提示词).
struct FamoPickerPanelModel: Equatable {
  /// The full loaded row list (source of truth for filtering); also feeds the "nothing configured
  /// at all" vs. "no match for this query" distinction in the view.
  private(set) var rows: [FamoPickerRow]
  /// The live search query (from the panel's search field). Empty = show everything.
  private(set) var query: String
  /// Highlighted row index into `visible`, clamped to it (0 when non-empty, -1 when empty).
  private(set) var selection: Int

  init(rows: [FamoPickerRow], query: String = "") {
    self.rows = rows
    self.query = query
    self.selection = rows.isEmpty ? -1 : 0
  }

  /// Rows visible under the current query: case-insensitive substring on each row's `searchText`.
  /// An empty (or whitespace-only) query shows the full list.
  var visible: [FamoPickerRow] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return rows }
    return rows.filter { $0.searchText.localizedCaseInsensitiveContains(trimmed) }
  }

  /// No rows to show for the current query (either nothing configured, or nothing matched).
  var isEmpty: Bool { visible.isEmpty }

  /// The row the highlight currently points at (⏎ target), or nil when nothing is visible.
  var selectedRow: FamoPickerRow? {
    let visibleRows = visible
    return visibleRows.indices.contains(selection) ? visibleRows[selection] : nil
  }

  func isSelected(_ index: Int) -> Bool { index == selection }

  /// Move the highlight by `delta` rows within the filtered list, clamped (no wraparound).
  mutating func moveSelection(by delta: Int) {
    let count = visible.count
    guard count > 0 else { selection = -1; return }
    selection = max(0, min(count - 1, selection + delta))
  }

  /// Point the highlight at `index` in the filtered list (hover/click); ignored when out of range.
  mutating func select(_ index: Int) {
    guard visible.indices.contains(index) else { return }
    selection = index
  }

  /// Map a 1–9 number key (1-based) to the Nth VISIBLE row, or nil when out of range.
  func row(forNumber number: Int) -> FamoPickerRow? {
    let index = number - 1
    let visibleRows = visible
    guard (1...9).contains(number), visibleRows.indices.contains(index) else { return nil }
    return visibleRows[index]
  }

  /// Update the search query and clamp the selection back into the new filtered result set
  /// (so ⏎/number keys never point past the end after typing narrows the list).
  mutating func setQuery(_ newQuery: String) {
    query = newQuery
    let count = visible.count
    selection = count > 0 ? max(0, min(count - 1, selection)) : -1
  }
}

// MARK: - Panel

final class FamoQuickSendPanel: NSPanel {
  /// Where a picked 短语 goes. Set by the input controller to insert at the cursor via the client it
  /// captured up-front; left nil when shown without a client → falls back to the pasteboard.
  /// Re-assigned on every show so the panel can be a reused singleton across triggers.
  var phrasePickHandler: ((String) -> Void)?

  /// Where a picked 提示词 goes: the controller inserts its body (routing through a fill sheet when it
  /// has `{{变量}}`) via the same captured client. No pasteboard fallback — the panel is summoned with
  /// a live client from the menu/hotkey, and a body may need variable substitution before it lands.
  var promptPickHandler: ((FamoPromptEntry) -> Void)?

  /// Focus choreography (capture the host on show → restore before a pick inserts → pasteboard
  /// fallback) lives in the shared broker; see `FamoPanelInsertionBroker`.
  private let broker = FamoPanelInsertionBroker()

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 360),
      styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )

    isReleasedWhenClosed = false
    isFloatingPanel = true
    level = .floating
    hidesOnDeactivate = false
    // FamoPromptFillSheet recipe: become key ONLY when the search field needs input, never at the
    // app level. This replaces PR1's hard `canBecomeKey = false` (which could never focus a text
    // field — the reason the emoji panel dropped search) while still not activating Famo's app.
    becomesKeyOnlyIfNeeded = true
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    // NOT movable-by-background: with it on, AppKit's window-drag machinery swallows mouseDown on
    // non-control SwiftUI views (our rows are Text + .onTapGesture), so picking would silently do
    // nothing (same trap the emoji panel documents). Off → every tap lands.
    isMovableByWindowBackground = false
    hasShadow = true
    isOpaque = false
    backgroundColor = .clear
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true
    standardWindowButton(.closeButton)?.isHidden = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    installContentView()
  }

  /// Show near the caret and make key (so the search field is typeable) WITHOUT activating Famo's
  /// app, capturing the frontmost app first so a pick can restore focus to it. Rebuilds the content
  /// so the phrase list reflects the latest `famo_quick_send.json` and the query/selection reset on
  /// each show (freshness). Positioning: near the caret (design B) with a mouse-centered fallback.
  func showPanel(initialSegment: FamoPickerSegment = .phrase) {
    broker.capture()
    installContentView(initialSegment: initialSegment)
    positionPanel()
    makeKeyAndOrderFront(nil)
  }

  func hidePanel() {
    // esc / close-without-pick: hand focus back to the host so the user isn't stranded in Famo.
    restoreFocus()
    orderOut(nil)
  }

  /// Restore host focus before/without a pick — delegates to the shared broker (idempotent; the
  /// choreography and the "never `NSApp.activate`" rule live there).
  private func restoreFocus() { broker.restoreFocus() }

  /// (Re)install the SwiftUI content with a freshly loaded phrase list. Cheap and user-triggered
  /// (never on the key-event hot path).
  private func installContentView(initialSegment: FamoPickerSegment = .phrase) {
    contentView = NSHostingView(
      rootView: FamoQuickSendPanelView(
        initialSegment: initialSegment,
        onPickPhrase: { [weak self] phrase in self?.handlePhrasePick(phrase) },
        onPickPrompt: { [weak self] entry in self?.handlePromptPick(entry) },
        onClose: { [weak self] in self?.hidePanel() }
      )
    )
  }

  /// Route a 短语 pick to the controller's inserter when set, else copy to the pasteboard. Restores
  /// focus to the captured host FIRST so the controller's `client.insertText` lands in the original
  /// field, then inserts (mirrors `FamoPromptFillSheet`: restore → callback). The view calls this
  /// then `onClose` (→ `hidePanel`), so the panel orders out after the insert.
  private func handlePhrasePick(_ phrase: String) {
    broker.restoreAndDeliver(phrase, host: phrasePickHandler)
  }

  /// Route a 提示词 pick to the controller (restore host focus first, same as `handlePhrasePick`).
  /// The controller decides body-insert vs. fill sheet. Dropped silently when no handler is wired
  /// (settings-page summon, which shows no 提示词).
  private func handlePromptPick(_ entry: FamoPromptEntry) {
    restoreFocus()
    promptPickHandler?(entry)
  }

  // MARK: Positioning

  /// Place the panel near the caret using the candidate panel's last anchor; fall back to
  /// centering under the mouse when there is no known caret (summoned with no composition).
  private func positionPanel() {
    let size = frame.size
    let anchor = NSApp.famoAppDelegate.lastCaretAnchor
    if anchor != .zero {
      setFrame(clampedFrame(anchor: anchor, size: size), display: false)
    } else {
      positionCenteredUnderMouse(size: size)
    }
  }

  /// Place the panel below the caret anchor. Delegates to `FamoFloatingPanelPositioner.belowCaret`
  /// (`useVisibleFrame: false`, same full-`frame` pick + clamp as the candidate panel).
  private func clampedFrame(anchor: NSRect, size: NSSize) -> NSRect {
    FamoFloatingPanelPositioner.belowCaret(
      anchor: anchor, size: size,
      screens: NSScreen.screens.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) },
      useVisibleFrame: false)
  }

  private func positionCenteredUnderMouse(size: NSSize) {
    guard let placed = FamoFloatingPanelPositioner.centeredUnder(
      point: NSEvent.mouseLocation, size: size,
      screens: NSScreen.screens.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) }) else { return }
    setFrameOrigin(placed.origin)
  }
}

// MARK: - View

/// The 短语/提示词 picker in SwiftUI: a compact near-caret list (design B skin — warm off-white card,
/// 绛红 accent for the selected row, serif labels) with a segmented control (短语 | 提示词) and a
/// search field at the top. Typing filters the active segment's list; ↑↓ navigate, ⏎ commits the
/// highlight, 1–9 direct-pick (empty query only), esc closes. A 短语 pick inserts the phrase; a 提示词
/// pick hands its entry back so the controller inserts the body (fill sheet when it has `{{变量}}`).
/// Inserts go through the active IMK client (via the panel's callbacks) or copy as fallback.
struct FamoQuickSendPanelView: View {
  /// A 短语 was picked → host inserts it (or falls back to the pasteboard).
  let onPickPhrase: (String) -> Void
  /// A 提示词 was picked → host inserts its body, routing through a fill sheet when it has variables.
  let onPickPrompt: (FamoPromptEntry) -> Void
  /// The ✕ / esc closed the panel.
  let onClose: () -> Void

  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme

  /// Which source is showing. Defaults to 短语 so the menu/hotkey summon lands on the familiar
  /// list; 提示词助手热键（FamoHotKeySlot.promptAssistant）传 .prompt 直达提示词页。
  @State private var segment: FamoPickerSegment

  init(
    initialSegment: FamoPickerSegment = .phrase,
    onPickPhrase: @escaping (String) -> Void,
    onPickPrompt: @escaping (FamoPromptEntry) -> Void,
    onClose: @escaping () -> Void
  ) {
    _segment = State(initialValue: initialSegment)
    self.onPickPhrase = onPickPhrase
    self.onPickPrompt = onPickPrompt
    self.onClose = onClose
  }
  @State private var phraseModel = FamoPickerPanelModel(
    rows: FamoQuickSendStore.load().map(FamoPickerRow.quickSend)
  )
  /// The 提示词 entries backing `promptModel`; a pick resolves its row `id` back to one of these to
  /// recover the body/variables (the row itself carries only the title + searchable text).
  @State private var promptEntries = FamoPromptStore.load()
  @State private var promptModel = FamoPickerPanelModel(
    rows: FamoPromptStore.load().map(FamoPickerRow.prompt)
  )
  @FocusState private var searchFocused: Bool

  /// Theme follows the chosen 皮肤 (read live, like the candidate/emoji panels).
  private var theme: FamoCandidateTheme { FamoCandidatePanelSettings.live.currentSkin().theme }
  private var palette: FamoCandidatePalette { theme.palette(for: colorScheme) }

  /// Binding to the active segment's model — mutations write back into the right @State. Reads go
  /// through the read-only `model` accessor so the existing `model.…` call sites stay unchanged; each
  /// segment keeps its own query/selection, so switching tabs preserves per-tab state.
  private var modelBinding: Binding<FamoPickerPanelModel> {
    switch segment {
    case .phrase: return $phraseModel
    case .prompt: return $promptModel
    }
  }
  private var model: FamoPickerPanelModel { modelBinding.wrappedValue }

  var body: some View {
    VStack(spacing: 0) {
      segmentRow
      Rectangle().fill(palette.ink.opacity(0.08)).frame(height: 1)
      searchRow
      Rectangle().fill(palette.ink.opacity(0.08)).frame(height: 1)
      listBody
      footerRow
    }
    .frame(width: 300, height: 360)
    .background { glass }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(palette.accentDeep.opacity(0.16), lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.18), radius: 22, y: 8)
    // Arrow-nav + number direct-pick. ⏎ is handled by the search field's onSubmit and esc by
    // onExitCommand (both fire while the field is key). Digit keys reach here only when the field
    // doesn't consume them; see `handleKeyPress` for the empty-query digit-pick decision.
    .onKeyPress(phases: .down) { handleKeyPress($0) }
    .onExitCommand(perform: onClose)
    .onAppear { searchFocused = true }
  }

  @ViewBuilder private var glass: some View {
    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    if reduceTransparency {
      shape.fill(palette.card)
    } else {
      ZStack { shape.fill(.regularMaterial); shape.fill(palette.card.opacity(0.86)) }
    }
  }

  // MARK: Segment

  /// The 短语 | 提示词 segmented control (design B2): two pills, 绛红 fill on the active one. Tapping
  /// swaps the active model; each segment keeps its own query/selection.
  private var segmentRow: some View {
    HStack(spacing: 3) {
      ForEach(FamoPickerSegment.allCases, id: \.self) { seg in
        let active = segment == seg
        Text(seg.label)
          .font(.system(size: 11.5, weight: active ? .semibold : .regular))
          .foregroundStyle(active ? palette.onAccent : palette.ink2)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 4)
          .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .fill(active ? palette.accent : Color.clear)
          }
          .contentShape(Rectangle())
          .onTapGesture { segment = seg }
          .accessibilityLabel(seg.label)
          .accessibilityAddTraits(active ? .isSelected : [])
      }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
  }

  // MARK: Search

  private var searchRow: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12))
        .foregroundStyle(palette.ink3)
      TextField(
        segment == .phrase ? "搜索短语…" : "搜索提示词…",
        text: Binding(get: { model.query }, set: { modelBinding.wrappedValue.setQuery($0) })
      )
      .textFieldStyle(.plain)
      .font(.system(size: 13))
      .foregroundStyle(palette.ink)
      .focused($searchFocused)
      .onSubmit { commitSelected() }
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(palette.ink3)
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("关闭")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
  }

  // MARK: List

  @ViewBuilder private var listBody: some View {
    if model.isEmpty {
      emptyState
    } else {
      ScrollView {
        VStack(spacing: 2) {
          ForEach(Array(model.visible.enumerated()), id: \.element.id) { index, row in
            rowView(index: index, row: row)
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
      }
    }
  }

  private func rowView(index: Int, row: FamoPickerRow) -> some View {
    let selected = model.isSelected(index)
    return HStack(spacing: 8) {
      Text(index < 9 ? "\(index + 1)" : "")
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(selected ? palette.onAccent.opacity(0.85) : palette.ink3)
        .frame(width: 15, alignment: .center)
      Text(row.display)
        .font(.system(size: 13))
        .foregroundStyle(selected ? palette.onAccent : palette.ink)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 10)
    .frame(height: 30)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(selected ? palette.accent : Color.clear)
    }
    .contentShape(Rectangle())
    .onTapGesture { pick(row) }
    .accessibilityLabel(row.display)
  }

  private var emptyState: some View {
    let nothingConfigured = model.rows.isEmpty
    let kind = segment.label
    let settingsPage = segment == .phrase ? "快捷短语" : "提示词"
    return VStack(spacing: 6) {
      Text(nothingConfigured ? "还没有配置\(kind)" : "无匹配\(kind)")
        .font(.system(size: 13))
        .foregroundStyle(palette.ink2)
      Text(nothingConfigured ? "在「\(settingsPage)」设置里添加" : "换个关键词试试")
        .font(.system(size: 11.5))
        .foregroundStyle(palette.ink3)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: Footer

  private var footerRow: some View {
    HStack {
      Spacer(minLength: 0)
      Text("↑↓ · 1–9 · ⏎ 上屏")
        .font(.system(size: 10))
        .foregroundStyle(palette.ink3)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .overlay(alignment: .top) { Rectangle().fill(palette.ink.opacity(0.08)).frame(height: 1) }
  }

  // MARK: Pick + keyboard

  /// Commit the picked row for the active segment and close. Iron rule (see the panel doc): the
  /// insert path never activates Famo — the panel restores focus to the captured host, then the
  /// controller inserts through its captured IMK `client`. 短语 → insert the phrase; 提示词 → resolve
  /// the row `id` back to its `FamoPromptEntry` and hand it to the controller (body / fill sheet).
  private func pick(_ row: FamoPickerRow) {
    switch segment {
    case .phrase:
      onPickPhrase(row.display)
    case .prompt:
      if let entry = promptEntries.first(where: { $0.code == row.id }) { onPickPrompt(entry) }
    }
    onClose()
  }

  /// ⏎: commit the currently highlighted (filtered) row.
  private func commitSelected() {
    if let row = model.selectedRow { pick(row) }
  }

  /// Keyboard navigation, routed through the pure model (unit-tested via `FamoQuickSendPanelModel`).
  /// The search field is the key responder, so ⏎ is its `onSubmit` and esc its `onExitCommand`;
  /// this handler covers ↑↓ nav and the 1–9 direct-pick.
  ///
  /// Digit decision (documented): 1–9 direct-pick the Nth VISIBLE row ONLY when the search box is
  /// EMPTY. Once the user has typed a query, digits are treated as literal search characters (so a
  /// numeric phrase or a code containing digits can be filtered) rather than jumping to a row —
  /// otherwise the digit would be ambiguous between "type into search" and "pick row N".
  private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
    switch press.key {
    case .upArrow:
      modelBinding.wrappedValue.moveSelection(by: -1)
      return .handled
    case .downArrow:
      modelBinding.wrappedValue.moveSelection(by: 1)
      return .handled
    default:
      if model.query.isEmpty,
         let digit = Int(press.characters),
         let row = model.row(forNumber: digit) {
        pick(row)
        return .handled
      }
      return .ignored
    }
  }
}
