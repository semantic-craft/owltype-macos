//
//  OwlAIPolishCardsView.swift
//  Owltype — AI Writing Auxiliary Subsystem (Milestone M7 / Issue #397)
//
//  Dual candidate polish view with 4-style switcher bar, word diff badge,
//  macOS keycap badges [1]/[2], skeleton shimmer view, in-place re-generation,
//  and one-key writeback shortcuts ([1]/[2] when not focused, ⌘1/⌘2 globally).
//

import AppKit
import SwiftUI

// MARK: - Text Diff Summary

public struct OwlTextDiffSummary: Equatable {
  public let deltaCount: Int
  public let percentageChange: Double

  public init(original: String, candidate: String) {
    self.deltaCount = candidate.count - original.count
    self.percentageChange = original.isEmpty ? 0.0 : Double(deltaCount) / Double(original.count)
  }

  public var badgeText: String {
    if deltaCount == 0 {
      return "±0 字"
    } else if deltaCount > 0 {
      return "+\(deltaCount) 字"
    } else {
      let percent = Int(abs(percentageChange) * 100)
      return "\(deltaCount) 字 (-\(percent)%)"
    }
  }

  public var badgeColor: Color {
    if deltaCount < 0 {
      return Color.green
    } else if deltaCount > 0 {
      return Color.blue
    } else {
      return Color.secondary
    }
  }
}

// MARK: - Polish Skeleton Shimmer View

struct OwlPolishSkeletonView: View {
  let style: OwlPolishStyle
  let palette: OwlCandidatePalette
  @State private var shimmerPhase: Bool = false

  init(style: OwlPolishStyle, palette: OwlCandidatePalette) {
    self.style = style
    self.palette = palette
  }

  var body: some View {
    VStack(spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        skeletonCard(label: "候选 1")
        skeletonCard(label: "候选 2")
      }
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
        Text("正在生成「\(style.rawValue)」双候选…")
          .font(.system(size: 11.5))
          .foregroundColor(palette.ink2)
      }
      .padding(.top, 4)
    }
    .onAppear {
      withAnimation(Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
        shimmerPhase.toggle()
      }
    }
  }

  private func skeletonCard(label: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(label)
          .font(.system(size: 11, weight: .bold))
          .foregroundColor(palette.accent.opacity(0.6))
        Spacer()
        RoundedRectangle(cornerRadius: 3)
          .fill(palette.ink3.opacity(shimmerPhase ? 0.25 : 0.12))
          .frame(width: 40, height: 14)
      }
      RoundedRectangle(cornerRadius: 3)
        .fill(palette.ink3.opacity(shimmerPhase ? 0.3 : 0.15))
        .frame(maxWidth: .infinity, maxHeight: 12)
      RoundedRectangle(cornerRadius: 3)
        .fill(palette.ink3.opacity(shimmerPhase ? 0.25 : 0.12))
        .frame(maxWidth: .infinity * 0.85, maxHeight: 12)
      RoundedRectangle(cornerRadius: 3)
        .fill(palette.ink3.opacity(shimmerPhase ? 0.2 : 0.1))
        .frame(maxWidth: .infinity * 0.65, maxHeight: 12)
      Spacer()
      RoundedRectangle(cornerRadius: 5)
        .fill(palette.ink3.opacity(shimmerPhase ? 0.2 : 0.1))
        .frame(maxWidth: .infinity, maxHeight: 22)
    }
    .padding(10)
    .frame(maxWidth: .infinity, minHeight: 130)
    .background(RoundedRectangle(cornerRadius: 8).fill(palette.card2.opacity(0.5)))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.ink3.opacity(0.15), lineWidth: 1))
  }
}

// MARK: - View Model

@MainActor
final class OwlAIPolishViewModel: ObservableObject {
  @Published var selectedStyle: OwlPolishStyle = .faithful
  @Published var candidates: [String] = []
  @Published var isLoading: Bool = false
  @Published var errorMessage: String? = nil

  let originalText: String
  let context: OwlAIInvocationContext
  private let client: OwlSelectionPolishClientProtocol
  private var activeTask: Task<Void, Never>?
  private var candidateGeneration: UInt64 = 0

  init(
    originalText: String,
    context: OwlAIInvocationContext,
    client: OwlSelectionPolishClientProtocol = OwlAIPolishService.shared
  ) {
    self.originalText = originalText
    self.context = context
    self.client = client
  }

  func load() {
    triggerPolish(style: selectedStyle)
  }

  func selectStyle(_ style: OwlPolishStyle) {
    guard style != selectedStyle || candidates.isEmpty else { return }
    selectedStyle = style
    triggerPolish(style: style)
  }

  func triggerPolish(style: OwlPolishStyle) {
    activeTask?.cancel()
    candidateGeneration &+= 1
    let currentGen = candidateGeneration

    isLoading = true
    errorMessage = nil

    activeTask = Task { [weak self] in
      guard let self else { return }
      do {
        try Task.checkCancellation()
        let results = try await self.client.polishSelection(text: self.originalText, style: style)
        try Task.checkCancellation()

        guard currentGen == self.candidateGeneration else { return }
        self.candidates = results
        self.isLoading = false
      } catch is CancellationError {
        // Discard cleanly
      } catch {
        guard currentGen == self.candidateGeneration else { return }
        self.errorMessage = (error as? OwlSelectionPolishError)?.userMessage ?? "润色请求失败"
        self.isLoading = false
      }
    }
  }

  func cancel() {
    activeTask?.cancel()
    activeTask = nil
  }
}

// MARK: - Polish Cards View

struct OwlAIPolishCardsView: View {
  @ObservedObject var viewModel: OwlAIPolishViewModel
  let palette: OwlCandidatePalette
  var inputFocused: Bool = false
  let onChoose: (String) -> Void
  let onDismiss: () -> Void

  init(
    viewModel: OwlAIPolishViewModel,
    palette: OwlCandidatePalette,
    inputFocused: Bool = false,
    onChoose: @escaping (String) -> Void,
    onDismiss: @escaping () -> Void
  ) {
    self.viewModel = viewModel
    self.palette = palette
    self.inputFocused = inputFocused
    self.onChoose = onChoose
    self.onDismiss = onDismiss
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // 1. 4-Style Switching Bar
      OwlPolishStyleBar(
        selectedStyle: $viewModel.selectedStyle,
        isDisabled: viewModel.isLoading,
        palette: palette,
        onSelectStyle: { style in
          viewModel.selectStyle(style)
        }
      )

      // 2. Candidate Display Area
      if viewModel.isLoading {
        OwlPolishSkeletonView(style: viewModel.selectedStyle, palette: palette)
          .frame(minHeight: 140)
      } else if let error = viewModel.errorMessage {
        errorPlaceholder(error)
      } else if viewModel.candidates.count >= 2 {
        dualCards
      } else {
        emptyPlaceholder
      }
    }
    .onAppear {
      if viewModel.candidates.isEmpty && !viewModel.isLoading {
        viewModel.load()
      }
    }
    .onKeyPress(phases: .down) { press in
      guard !inputFocused else { return .ignored }
      guard !viewModel.isLoading, viewModel.candidates.count >= 2 else { return .ignored }
      if press.characters == "1" {
        onChoose(viewModel.candidates[0])
        return .handled
      } else if press.characters == "2" {
        onChoose(viewModel.candidates[1])
        return .handled
      }
      return .ignored
    }
    // Universal ⌘1 / ⌘2 shortcuts
    .background(
      Group {
        if viewModel.candidates.count >= 2 {
          Button("") { onChoose(viewModel.candidates[0]) }
            .keyboardShortcut("1", modifiers: [.command])
            .opacity(0)
          Button("") { onChoose(viewModel.candidates[1]) }
            .keyboardShortcut("2", modifiers: [.command])
            .opacity(0)
        }
      }
    )
  }

  private var dualCards: some View {
    HStack(alignment: .top, spacing: 12) {
      candidateCard(index: 1, text: viewModel.candidates[0], shortcut: "1")
      candidateCard(index: 2, text: viewModel.candidates[1], shortcut: "2")
    }
  }

  private func candidateCard(index: Int, text: String, shortcut: String) -> some View {
    let diff = OwlTextDiffSummary(original: viewModel.originalText, candidate: text)
    let actionTitle = viewModel.context.primaryActionTitle

    return VStack(alignment: .leading, spacing: 8) {
      // Header: Badge + Diff tag + Quick Copy + Keycap Badge
      HStack(alignment: .center, spacing: 6) {
        Text("[\(index)]")
          .font(.system(size: 11, weight: .bold, design: .monospaced))
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(Capsule().fill(palette.accent.opacity(0.16)))
          .foregroundColor(palette.accent)

        Text(diff.badgeText)
          .font(.system(size: 10, weight: .medium))
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(diff.badgeColor.opacity(0.12))
          .foregroundColor(diff.badgeColor)
          .cornerRadius(4)

        Spacer()

        Button {
          let pb = NSPasteboard.general
          pb.clearContents()
          pb.setString(text, forType: .string)
        } label: {
          Image(systemName: "doc.on.doc")
            .font(.system(size: 10.5))
            .foregroundColor(palette.ink3)
        }
        .buttonStyle(.owlPlain)
        .help("复制候选文本")

        // macOS Keycap Badge
        Text("[ \(shortcut) ]")
          .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
          .padding(.horizontal, 4)
          .padding(.vertical, 1.5)
          .background(palette.card)
          .foregroundColor(palette.ink2)
          .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.ink3.opacity(0.35), lineWidth: 0.8))
          .help("快捷键: \(shortcut) 或 ⌘\(shortcut)")
      }

      // Candidate Text ScrollView
      ScrollView {
        Text(text)
          .font(Font.owlSerif(size: 13.5))
          .lineSpacing(4)
          .foregroundColor(palette.ink)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .frame(minHeight: 70, maxHeight: 150)

      // Commit Button
      Button(action: { onChoose(text) }) {
        HStack(spacing: 4) {
          Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 10, weight: .semibold))
          Text("\(actionTitle) [\(shortcut)]")
            .font(.system(size: 11.5, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(palette.accent.opacity(0.9))
        .foregroundColor(palette.onAccent)
        .cornerRadius(5)
      }
      .buttonStyle(.owlPlain)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(palette.card2.opacity(0.85)))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.ink3.opacity(0.2), lineWidth: 1))
  }

  private func errorPlaceholder(_ error: String) -> some View {
    VStack(spacing: 8) {
      Text(error)
        .font(.system(size: 12))
        .foregroundColor(.red)
      Button("重试") {
        viewModel.load()
      }
      .buttonStyle(.owlPlain)
    }
    .frame(maxWidth: .infinity, minHeight: 100)
  }

  private var emptyPlaceholder: some View {
    VStack(spacing: 8) {
      Text("暂无润色结果")
        .font(.system(size: 12))
        .foregroundColor(palette.ink3)
      Button("重新生成") {
        viewModel.load()
      }
      .buttonStyle(.owlPlain)
    }
    .frame(maxWidth: .infinity, minHeight: 100)
  }
}
