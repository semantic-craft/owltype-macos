//
//  FamoPromptFillSheet.swift
//  法墨输入法 (Famo) — 提示词填空 sheet（R4）
//
//  当一条命中的提示词正文含 `{{变量}}` 时，控制器在提交拦截处调 `present(entry:onComplete:)` 弹出
//  本 sheet：每个变量一栏，用户填值后 [插入]/Enter → 回调带回 `FamoPromptVariables.substitute`
//  替换好的正文（控制器随即 `insertText` 进原宿主）；[取消]/Esc/关窗 → 回调 nil，什么都不插。
//
//  非激活面板（`.nonactivatingPanel` + `becomesKeyOnlyIfNeeded`）：只有编辑文本框时才短暂成为
//  key window，不在应用层抢占宿主；showing 前捕获 frontmost app，每条收尾路径都把焦点交还宿主，
//  这样回调里的 `insertText` 仍落在原输入框。使用 capture→restore
//  生命周期（单实例复用、`isReleasedWhenClosed = false`、回调 `[weak self]` 防环）。
//
//  边界：SwiftUI 是唯一渲染层（view 经 `NSHostingView` 托管）；IMK 按键热路径不被触碰。AppKit
//  窗口生命周期不可 headless 单测——纯逻辑（变量抽取 / 替换）在 `FamoPromptStore` 侧已全测，本文件
//  刻意做薄。真机冒烟（焦点交还后 insertText 是否落到 TextEdit / 微信 / 浏览器）是用户的确认步。
//
//  并发：类级别不 `@MainActor`-isolated（与 `FamoSettingsWindow` 一致）；非隔离的
//  控制器在主线程调 `present`。
//

import AppKit
import SwiftUI

/// 填空 sheet 的视图模型：保序变量名 + 各自当前值。`@Published values` 驱动文本框双向绑定。
final class FamoPromptFillModel: ObservableObject {
  let entry: FamoPromptEntry
  /// 去重、保序的变量名（来自 `FamoPromptVariables.extract`）。
  let variables: [String]
  @Published var values: [String: String]

  init(entry: FamoPromptEntry) {
    self.entry = entry
    let names = FamoPromptVariables.extract(from: entry.body)
    self.variables = names
    self.values = Dictionary(uniqueKeysWithValues: names.map { ($0, "") })
  }

  /// 当前替换好的正文。未填的变量按 `substitute` 规则保留 `{{名}}` 占位。
  var filledBody: String {
    FamoPromptVariables.substitute(entry.body, values: values)
  }
}

final class FamoPromptFillSheet: NSWindowController {
  /// 单实例复用（azooKey 生命周期）。主线程 only（控制器从主线程经 `MainActor.assumeIsolated` 调），
  /// 故非原子 static 安全。
  @MainActor static let shared = FamoPromptFillSheet()

  /// 强引用 view model，让它与窗口同寿；每次 `present` 重建。
  private var model: FamoPromptFillModel?
  /// 焦点编排（present 捕获宿主 → 收尾交还 / 丢弃）走共享 broker；见 `FamoPanelInsertionBroker`。
  private let broker = FamoPanelInsertionBroker()
  /// 本次呈现的完成回调：[插入] 回带替换好的正文，[取消]/Esc/关窗回带 nil。
  private var onComplete: ((String?) -> Void)?
  /// 防重复收尾（confirm/cancel 与 windowWillClose 可能都触发）。
  private var completed = true

  init() {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
      styleMask: [.titled, .closable, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.title = NSLocalizedString("填写提示词变量", comment: "Famo prompt fill-in sheet title")
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

  /// 弹出填空 sheet 收集 `entry` 的变量值。`onComplete(filledBody)` 在用户 [插入] 时调用（已替换
  /// 好的正文）；`onComplete(nil)` 在取消 / Esc / 关窗时调用（控制器据此不插任何字）。
  func present(entry: FamoPromptEntry, onComplete: @escaping (String?) -> Void) {
    // 若上一次呈现还挂着（极少见：两次提示词提交叠在一起），先当取消收尾（不交还焦点，马上要重弹）。
    finish(nil, restoreFocus: false)

    self.onComplete = onComplete
    self.completed = false
    broker.capture()

    let model = FamoPromptFillModel(entry: entry)
    self.model = model
    let root = FamoPromptFillView(
      model: model,
      onInsert: { [weak self] in self?.confirm() },
      onCancel: { [weak self] in self?.cancel() }
    )
    window?.contentView = NSHostingView(rootView: root)
    sizeWindow(forVariableCount: model.variables.count)
    window?.center()
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }

  private func confirm() {
    guard let model else { cancel(); return }
    let filled = model.filledBody
    finish(filled, restoreFocus: true)
    window?.close()
  }

  private func cancel() {
    finish(nil, restoreFocus: true)
    window?.close()
  }

  /// 单点收尾：幂等（`completed` 守卫）、清回调与 model、可选交还焦点，最后调一次回调。
  private func finish(_ result: String?, restoreFocus: Bool) {
    guard !completed else { return }
    completed = true
    let callback = onComplete
    onComplete = nil
    model = nil
    if restoreFocus { broker.restoreFocus() } else { broker.drop() }
    callback?(result)
  }

  private func sizeWindow(forVariableCount count: Int) {
    let rows = max(count, 1)
    let height = min(CGFloat(rows) * 56 + 132, 520)
    window?.setContentSize(NSSize(width: 440, height: height))
  }
}

extension FamoPromptFillSheet: NSWindowDelegate {
  /// 红灯关窗 = 取消（若不是已经 confirm/cancel 收尾过）。
  func windowWillClose(_ notification: Notification) {
    finish(nil, restoreFocus: true)
  }
}

// MARK: - View

private struct FamoPromptFillView: View {
  @ObservedObject var model: FamoPromptFillModel
  let onInsert: () -> Void
  let onCancel: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @FocusState private var focused: String?

  private var palette: FamoCandidatePalette {
    FamoSkinPreferences.skin.theme.palette(for: colorScheme)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(model.variables, id: \.self) { name in
            field(name)
          }
        }
        .padding(.vertical, 2)
      }
      buttons
    }
    .padding(18)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(palette.card)
    .onAppear { focused = model.variables.first }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(model.entry.title)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(palette.ink)
        .lineLimit(1)
      Text("填写变量后插入到当前输入框。")
        .font(.system(size: 12))
        .foregroundStyle(palette.ink3)
    }
  }

  private func field(_ name: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(name)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(palette.ink2)
      TextField(
        name,
        text: Binding(
          get: { model.values[name] ?? "" },
          set: { model.values[name] = $0 }
        )
      )
      .textFieldStyle(.roundedBorder)
      .focused($focused, equals: name)
      .onSubmit(onInsert)
    }
  }

  private var buttons: some View {
    HStack(spacing: 10) {
      Spacer()
      Button("取消", action: onCancel)
        .keyboardShortcut(.cancelAction)
      Button("插入", action: onInsert)
        .keyboardShortcut(.defaultAction)
    }
  }
}
