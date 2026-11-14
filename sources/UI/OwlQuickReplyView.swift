//
//  OwlQuickReplyView.swift
//  Owltype — AI Writing Auxiliary Subsystem (Milestone M7 / Issue #397)
//
//  Quick reply view with 5 template switcher chips, 3 candidate reply cards,
//  subtitles ("精炼直接", "专业周全", "积极推进"), keycap badges [1]/[2]/[3],
//  shimmer skeleton view, in-place re-generation, and one-key writeback shortcuts.
//

import AppKit
import SwiftUI

// MARK: - View Model

@MainActor
final class OwlQuickReplyViewModel: ObservableObject {
  @Published var selectedTemplate: OwlReplyTemplate = .agree
  @Published var candidates: [String] = []
  @Published var isLoading: Bool = false
  @Published var errorMessage: String? = nil

  let contextText: String
  let invocationContext: OwlAIInvocationContext
  private let generator: OwlReplyGeneratorProtocol
  private var activeTask: Task<Void, Never>?
  private var generationEpoch: UInt64 = 0

  init(
    contextText: String,
    invocationContext: OwlAIInvocationContext,
    generator: OwlReplyGeneratorProtocol = OwlAIPolishService.shared
  ) {
    self.contextText = contextText
    self.invocationContext = invocationContext
    self.generator = generator
  }

  func load() {
    triggerGenerate(template: selectedTemplate)
  }

  func selectTemplate(_ template: OwlReplyTemplate) {
    guard template != selectedTemplate || candidates.isEmpty else { return }
    selectedTemplate = template
    triggerGenerate(template: template)
  }

  func triggerGenerate(template: OwlReplyTemplate) {
    activeTask?.cancel()
    generationEpoch &+= 1
    let currentEpoch = generationEpoch

    isLoading = true
    errorMessage = nil

    activeTask = Task { [weak self] in
      guard let self else { return }
      do {
        try Task.checkCancellation()
        let results = try await self.generator.generateReplies(contextText: self.contextText, template: template)
        try Task.checkCancellation()

        guard currentEpoch == self.generationEpoch else { return }
        self.candidates = results
        self.isLoading = false
      } catch is CancellationError {
        // Discard cleanly
      } catch {
        guard currentEpoch == self.generationEpoch else { return }
        self.errorMessage = error.localizedDescription
        self.isLoading = false
      }
    }
  }
}

// MARK: - Reply Skeleton View

struct OwlReplySkeletonView: View {
  let template: OwlReplyTemplate
  let palette: OwlCandidatePalette
  @State private var shimmerPhase: Bool = false

  init(template: OwlReplyTemplate, palette: OwlCandidatePalette) {
    self.template = template
    self.palette = palette
  }

  var body: some View {
    VStack(spacing: 8) {
      ForEach(1...3, id: \.self) { idx in
        skeletonCard(index: idx)
      }
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
        Text("正在生成「\(template.rawValue)」回复候选…")
          .font(.system(size: 11.5))
          .foregroundColor(palette.ink2)
      }
      .padding(.top, 2)
    }
    .onAppear {
      withAnimation(Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
        shimmerPhase.toggle()
      }
    }
  }

  private func skeletonCard(index: Int) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Text("[\(index)]")
        .font(.system(size: 11, weight: .bold, design: .monospaced))
        .foregroundColor(palette.accent.opacity(0.6))
      VStack(alignment: .leading, spacing: 6) {
        RoundedRectangle(cornerRadius: 3)
          .fill(palette.ink3.opacity(shimmerPhase ? 0.3 : 0.15))
          .frame(maxWidth: .infinity, maxHeight: 11)
        RoundedRectangle(cornerRadius: 3)
          .fill(palette.ink3.opacity(shimmerPhase ? 0.25 : 0.12))
          .frame(maxWidth: .infinity * 0.7, maxHeight: 11)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(RoundedRectangle(cornerRadius: 7).fill(palette.card2.opacity(0.4)))
    .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.ink3.opacity(0.15), lineWidth: 0.8))
  }
}

// MARK: - Quick Reply View

struct OwlQuickReplyView: View {
  @ObservedObject var viewModel: OwlQuickReplyViewModel
  let palette: OwlCandidatePalette
  var inputFocused: Bool = false
  let onChoose: (String) -> Void

  init(
    viewModel: OwlQuickReplyViewModel,
    palette: OwlCandidatePalette,
    inputFocused: Bool = false,
    onChoose: @escaping (String) -> Void
  ) {
    self.viewModel = viewModel
    self.palette = palette
    self.inputFocused = inputFocused
    self.onChoose = onChoose
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // 1. 5-Template Switcher Bar
      templateChipsBar

      // 2. Candidates Display Area
      if viewModel.isLoading {
        OwlReplySkeletonView(template: viewModel.selectedTemplate, palette: palette)
          .frame(minHeight: 140)
      } else if let error = viewModel.errorMessage {
        errorPlaceholder(error)
      } else if viewModel.candidates.count >= 3 {
        cardsStack
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
      guard !viewModel.isLoading, viewModel.candidates.count >= 3 else { return .ignored }
      if press.characters == "1" {
        onChoose(viewModel.candidates[0])
        return .handled
      } else if press.characters == "2" {
        onChoose(viewModel.candidates[1])
        return .handled
      } else if press.characters == "3" {
        onChoose(viewModel.candidates[2])
        return .handled
      }
      return .ignored
    }
    // Universal ⌘1 / ⌘2 / ⌘3 shortcuts
    .background(
      Group {
        if viewModel.candidates.count >= 3 {
          Button("") { onChoose(viewModel.candidates[0]) }
            .keyboardShortcut("1", modifiers: [.command])
            .opacity(0)
          Button("") { onChoose(viewModel.candidates[1]) }
            .keyboardShortcut("2", modifiers: [.command])
            .opacity(0)
          Button("") { onChoose(viewModel.candidates[2]) }
            .keyboardShortcut("3", modifiers: [.command])
            .opacity(0)
        }
      }
    )
  }

  private var templateChipsBar: some View {
    HStack(spacing: 5) {
      ForEach(OwlReplyTemplate.allCases) { template in
        let isSelected = (template == viewModel.selectedTemplate)
        Button {
          guard !viewModel.isLoading, viewModel.selectedTemplate != template else { return }
          viewModel.selectTemplate(template)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: template.iconName)
              .font(.system(size: 10.5, weight: isSelected ? .bold : .medium))
            Text(template.title)
              .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4.5)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .fill(isSelected ? palette.accent.opacity(0.18) : palette.card2.opacity(0.6))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(isSelected ? palette.accent : palette.ink3.opacity(0.2), lineWidth: isSelected ? 1.2 : 0.8)
          )
          .foregroundColor(isSelected ? palette.accent : palette.ink)
        }
        .buttonStyle(.owlPlain)
        .disabled(viewModel.isLoading)
        .help(template.subtitle)
      }
      Spacer()
    }
  }

  private var cardsStack: some View {
    let perspectives = viewModel.selectedTemplate.candidatePerspectives
    let labels = [perspectives.first, perspectives.second, perspectives.third]

    return VStack(spacing: 8) {
      ForEach(0..<min(3, viewModel.candidates.count), id: \.self) { idx in
        replyCard(
          index: idx + 1,
          perspective: labels[idx],
          text: viewModel.candidates[idx],
          shortcut: "\(idx + 1)"
        )
      }
    }
  }

  private func replyCard(index: Int, perspective: String, text: String, shortcut: String) -> some View {
    let actionTitle = viewModel.invocationContext.primaryActionTitle

    return HStack(alignment: .top, spacing: 8) {
      // Index badge + Perspective
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 4) {
          Text("[\(index)]")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(palette.accent)
          Text(perspective)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(palette.ink2)
        }

        // macOS Keycap Badge
        Text("[ \(shortcut) ]")
          .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
          .padding(.horizontal, 3.5)
          .padding(.vertical, 1)
          .background(palette.card)
          .foregroundColor(palette.ink2)
          .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.ink3.opacity(0.35), lineWidth: 0.8))
      }
      .frame(width: 65, alignment: .leading)

      // Text
      Text(text)
        .font(Font.owlSerif(size: 13))
        .lineSpacing(3)
        .foregroundColor(palette.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .topLeading)

      // Action Button
      Button(action: { onChoose(text) }) {
        Text("\(actionTitle) [\(shortcut)]")
          .font(.system(size: 11, weight: .semibold))
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(palette.accent.opacity(0.9))
          .foregroundColor(palette.onAccent)
          .cornerRadius(5)
      }
      .buttonStyle(.owlPlain)
    }
    .padding(8)
    .background(RoundedRectangle(cornerRadius: 7).fill(palette.card2.opacity(0.85)))
    .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.ink3.opacity(0.2), lineWidth: 0.8))
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
    .frame(maxWidth: .infinity, minHeight: 90)
  }

  private var emptyPlaceholder: some View {
    VStack(spacing: 8) {
      Text("暂无回复候选")
        .font(.system(size: 12))
        .foregroundColor(palette.ink3)
      Button("重新生成") {
        viewModel.load()
      }
      .buttonStyle(.owlPlain)
    }
    .frame(maxWidth: .infinity, minHeight: 90)
  }
}
