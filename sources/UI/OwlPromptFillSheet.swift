//
//  OwlPromptFillSheet.swift
//  猫头鹰输入法 (Owltype) — 提示词填空 sheet（R4）
//
//  Non-activating parameter UI. The shared invocation owns the selected entry, original host,
//  substitution and single terminal outcome; this sheet owns only field editing and window life.
//  Enter confirms text insertion; cancel / Esc / close never synthesize host key events.
//  Main-thread only, matching the IMK controller. Real-host focus behavior needs device acceptance.
//

import AppKit
import SwiftUI
import Combine

/// 填空 sheet 的视图模型：保序变量名 + 各自当前值。`@Published values` 驱动文本框双向绑定。
final class OwlPromptFillModel: ObservableObject {
  let title: String
  /// 去重、保序的变量名（来自 `OwlPromptVariables.extract`）。
  let variables: [String]
  @Published var values: [String: String]

  let invocation: OwlTemplateInvocation

  @Published private(set) var copyStatus: String?
  private var observation: AnyCancellable?

  init(invocation: OwlTemplateInvocation) {
    switch invocation.content {
    case .plainText: title = "快捷短语"
    case .prompt(let entry): title = entry.title
    case .template(let entry): title = entry.title
    }
    self.invocation = invocation
    variables = invocation.variables
    values = invocation.initialValues
    observation = invocation.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
  }

  convenience init(entry: OwlPromptEntry, invocation: OwlTemplateInvocation) { self.init(invocation: invocation) }
  convenience init(template: OwlTemplateEntry, invocation: OwlTemplateInvocation) { self.init(invocation: invocation) }

  var isEditing: Bool { invocation.state == .awaitingConfirmation }
  func copyResult() {
    copyStatus = invocation.copyResult() ? "已复制结果。" : "复制失败，结果仍保留。请重试复制。"
  }

  var evaluation: OwlTemplateEngine.Evaluation { invocation.evaluate(values: values) }
  var filledBody: String { invocation.retainedResult?.text ?? evaluation.previewText }
  var canConfirm: Bool { isEditing && evaluation.readyText != nil }
  var parameters: [OwlTemplateEngine.Parameter] { invocation.parsed.parameters }

  func continueWithEmptyClipboard() {
    guard evaluation.needsEmptyClipboardDecision else { return }
    objectWillChange.send()
    invocation.continueWithEmptyClipboard()
  }
}

final class OwlPromptFillSheet: NSWindowController {
  /// 单实例复用（azooKey 生命周期）。主线程 only（控制器从主线程经 `MainActor.assumeIsolated` 调），
  /// 故非原子 static 安全。
  @MainActor static let shared = OwlPromptFillSheet()

  /// 强引用 view model，让它与窗口同寿；每次 `present` 重建。
  private var model: OwlPromptFillModel?
  private var completionObservation: AnyCancellable?
  private let showsWindows: Bool

  init(showsWindows: Bool = true) {
    self.showsWindows = showsWindows
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
      styleMask: [.titled, .closable, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.title = NSLocalizedString("填写模板参数", comment: "Owltype prompt fill-in sheet title")
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    // 只在文本框需要时短暂成为 key window，不在应用层抢占宿主。
    panel.becomesKeyOnlyIfNeeded = true
    panel.minSize = NSSize(width: 420, height: 200)
    panel.center()
    super.init(window: panel)
    panel.delegate = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Retain every invocation during bounded restoration, including direct no-parameter calls.
  /// A new invocation cancels pending work before its callback can present an obsolete result.
  func begin(invocation: OwlTemplateInvocation) {
    dismissForNewInvocation()
    model = OwlPromptFillModel(invocation: invocation)
    completionObservation = invocation.stateChanges.sink { [weak self, weak invocation] state in
      guard let self, let invocation, self.model?.invocation === invocation,
            case .completed(_, let outcome) = state, outcome.finishesPresentation else { return }
      self.finish(restoreFocus: false)
      self.window?.orderOut(nil)
    }
    invocation.start { [weak self] invocation in self?.present(invocation: invocation) }
  }

  func dismissForNewInvocation() {
    finish(reason: .replaced, restoreFocus: false)
    window?.orderOut(nil)
  }

  private func present(invocation: OwlTemplateInvocation) {
    guard let model, model.invocation === invocation else { return }
    let root = OwlPromptFillView(
      model: model,
      onInsert: { [weak self] in self?.confirm() },
      onCancel: { [weak self] in self?.cancel() }
    )
    window?.title = model.isEditing ? "结果预览" : "结果已保留"
    window?.contentView = NSHostingView(rootView: root)
    sizeWindow(forVariableCount: model.variables.count)
    window?.center()
    guard showsWindows else { return }
    if invocation.outcome?.keepsHostFocus == true {
      // Show a retained result without stealing the restored host's key status. The user can
      // explicitly click this panel to inspect/copy. Never call showWindow/makeKey here.
      window?.orderFrontRegardless()
    } else {
      if let window { invocation.notePresentationTransition(window: window, active: true) }
      showWindow(nil)
      window?.makeKeyAndOrderFront(nil)
      if let window { invocation.notePresentationTransition(window: window, active: false) }
    }
  }

  private func confirm() {
    guard let model, model.canConfirm else { return }
    window?.orderOut(nil) // release the parameter field BEFORE restoring the host
    guard model.invocation.confirm(values: model.values) else {
      present(invocation: model.invocation)
      return
    }
  }

  private func cancel() {
    finish(restoreFocus: true)
    window?.close()
  }

  private func finish(reason: OwlTemplateInvocation.Cancellation = .user, restoreFocus: Bool) {
    let previous = model
    model = nil
    completionObservation = nil
    // NSWindow is reused and otherwise keeps its hosting view (and the entire result) alive.
    window?.contentView = nil
    previous?.invocation.cancel(reason, restoreFocus: restoreFocus)
  }

  private func sizeWindow(forVariableCount count: Int) {
    let rows = max(count, 1)
    let height = min(CGFloat(rows) * 86 + 330, 760)
    window?.setContentSize(NSSize(width: 580, height: height))
  }
}

extension OwlPromptFillSheet: NSWindowDelegate {
  /// 红灯关窗 = 取消（若不是已经 confirm/cancel 收尾过）。
  func windowWillClose(_ notification: Notification) {
    finish(reason: .windowClosed, restoreFocus: true)
  }
}

// MARK: - View

private struct OwlPromptFillView: View {
  @ObservedObject var model: OwlPromptFillModel
  let onInsert: () -> Void
  let onCancel: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @FocusState private var focused: String?
  @State private var multiline = Set<String>()

  private var palette: OwlCandidatePalette {
    OwlCandidatePanelSettings.live.currentSkin().theme.palette(for: colorScheme)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      if model.isEditing && !model.parameters.isEmpty {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(model.parameters) { parameter in
            field(parameter)
          }
        }
        .padding(.vertical, 2)
      }
      }
      if model.isEditing && model.evaluation.needsEmptyClipboardDecision {
        VStack(alignment: .leading, spacing: 6) {
          Text("本次没有可用剪贴板文本").font(.callout).foregroundStyle(.orange)
          Text("可取消，复制材料后重新调用；或本次按空文本继续。")
            .font(.caption).foregroundStyle(.secondary)
          Button("本次按空文本继续") { model.continueWithEmptyClipboard() }
            .accessibilityIdentifier("template-continue-empty-clipboard")
        }.accessibilityIdentifier("template-missing-clipboard")
      }
      if let failure = model.invocation.preparationFailure, model.isEditing {
        Text(failure.message).font(.callout).accessibilityIdentifier("template-preservation-outcome")
      }
      if let offset = model.invocation.retainedResult?.cursorOffset ?? model.evaluation.cursorOffset {
        Text(OwlTemplateCursorPlacement.positionDescription(text: model.filledBody, offset: offset))
          .font(.caption).accessibilityIdentifier("template-cursor-preview")
      }
      if let outcome = model.invocation.outcome {
        Text(outcome.message).font(.callout).accessibilityIdentifier("template-delivery-outcome")
      }
      Text("展开结果预览").font(.caption)
      ScrollView([.horizontal, .vertical]) {
        Text(verbatim: model.filledBody).font(.system(.body, design: .monospaced))
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      }.frame(minHeight: 100, maxHeight: 220).accessibilityIdentifier("template-result-preview")
      if model.isEditing && !model.evaluation.diagnostics.isEmpty {
        ScrollView {
          VStack(alignment: .leading) {
            ForEach(Array(model.evaluation.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
              Text(diagnostic.location(in: model.invocation.content.body) + "：" + diagnostic.message).font(.caption).foregroundStyle(diagnostic.severity == .error ? .red : .orange)
            }
          }
        }.frame(maxHeight: 90)
      }
      if model.isEditing && !model.evaluation.missingKeys.isEmpty {
        Text("请完成必填参数；可选参数也可明确选择本次留空。").font(.caption).foregroundStyle(.secondary)
      }
      buttons
    }
    .padding(18)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(palette.card)
    .onAppear {
      guard model.isEditing else { return }
      focused = model.parameters.first(where: { model.evaluation.missingKeys.contains($0.key) })
        .map { model.invocation.valueKey(for: $0) } ?? model.variables.first
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(model.title)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(palette.ink)
        .lineLimit(1)
      Text(model.isEditing ? "单行 ↩ 插入；多行 ↩ 换行、⌘↩ 插入。请先核对预览。" : "本次不会再次尝试插入；可明确复制完整结果。")
        .font(.system(size: 12))
        .foregroundStyle(palette.ink3)
    }
  }

  private func field(_ parameter: OwlTemplateEngine.Parameter) -> some View {
    let key = model.invocation.valueKey(for: parameter)
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(parameter.name).font(.system(size: 12, weight: .medium))
        Text(parameter.isRequired ? "必填" : "可选").font(.caption).foregroundStyle(.secondary)
        Spacer()
        if !parameter.isRequired { Button("本次留空") { model.values[key] = "" }.font(.caption) }
        if let value = parameter.defaultValue { Button("恢复默认") { model.values[key] = value }.font(.caption) }
      }
      if parameter.options.isEmpty {
        if multiline.contains(key) || model.values[key]?.contains("\n") == true {
          TextEditor(text: Binding(get: { model.values[key] ?? "" }, set: { model.values[key] = $0 }))
            .frame(height: 80).focused($focused, equals: key)
        } else {
          TextField(parameter.name, text: Binding(get: { model.values[key] ?? "" }, set: { model.values[key] = $0 }))
            .textFieldStyle(.roundedBorder).focused($focused, equals: key).onSubmit { if model.canConfirm { onInsert() } }
          Button("多行输入") { multiline.insert(key) }.font(.caption)
        }
      } else {
        Picker(parameter.name, selection: Binding<String?>(get: { model.values[key] }, set: { model.values[key] = $0 })) {
          Text("请选择").tag(nil as String?)
          if !parameter.isRequired { Text("本次留空").tag(Optional("")) }
          ForEach(parameter.options, id: \.self) { option in Text(option).tag(Optional(option)) }
        }.labelsHidden().focused($focused, equals: key)
      }
      if model.evaluation.missingKeys.contains(parameter.key) {
        Text(parameter.isRequired ? "此参数尚未完成。" : "尚未填写；可选择本次留空。").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var buttons: some View {
    HStack(spacing: 10) {
      if let status = model.copyStatus { Text(status).font(.caption).accessibilityIdentifier("template-copy-status") }
      Spacer()
      Button(model.isEditing ? "取消" : "关闭", action: onCancel)
        .keyboardShortcut(.cancelAction)
      if model.invocation.outcome != nil {
        Button("复制结果") { model.copyResult() }
          .accessibilityIdentifier("template-copy-result")
      } else {
        Button(model.invocation.preparationFailure == nil ? "插入" : "保留结果供复制", action: onInsert)
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(!model.canConfirm)
      }
    }
  }
}
