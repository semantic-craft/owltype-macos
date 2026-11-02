//
//  OwlVoiceCapsuleView.swift
//  Owltype — Voice Input Subsystem
//

import SwiftUI

@Observable
final class OwlVoiceCapsuleViewModel: @unchecked Sendable {
  var state: OwlVoiceCapsuleState = .idle
  var theme: OwlCandidateTheme = .shenda

  init() {}
}

struct OwlVoiceCapsuleView: View {
  var viewModel: OwlVoiceCapsuleViewModel
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private var palette: OwlCandidatePalette {
    viewModel.theme.palette(for: colorScheme)
  }

  init(viewModel: OwlVoiceCapsuleViewModel) {
    self.viewModel = viewModel
  }

  var body: some View {
    HStack(spacing: 10) {
      switch viewModel.state {
      case .idle:
        EmptyView()

      case let .recording(level, duration, isHandsFreeLocked):
        recordingContent(level: level, duration: duration, isLocked: isHandsFreeLocked)

      case .recognizing:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("转写中...").font(.system(size: 13, weight: .medium))
        }

      case let .polishing(rawTranscript):
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          VStack(alignment: .leading, spacing: 3) {
            Text("润色中...")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(palette.accent)
            Text(rawTranscript)
              .font(.system(size: 13, weight: .regular))
              .foregroundStyle(palette.ink)
              .lineLimit(2)
              .truncationMode(.tail)
              .frame(minWidth: 140, maxWidth: 360, alignment: .leading)
          }
        }

      case let .completed(finalText):
        HStack(spacing: 6) {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
          Text("已上屏").font(.system(size: 13, weight: .medium))
          Text(finalText).font(.system(size: 12)).foregroundStyle(palette.ink3).lineLimit(1)
        }

      case let .failed(error):
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          Text(error).font(.system(size: 12, weight: .medium))
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background {
      if reduceTransparency {
        Capsule().fill(palette.card)
      } else {
        Capsule()
          .fill(palette.card.opacity(0.88))
          .background(.ultraThinMaterial, in: Capsule())
      }
    }
    .overlay(
      Capsule()
        .strokeBorder(palette.accentDeep.opacity(0.20), lineWidth: 1)
    )
    .animation(.easeInOut(duration: 0.15), value: viewModel.state)
  }

  private func recordingContent(level: Float, duration: TimeInterval, isLocked: Bool) -> some View {
    HStack(spacing: 10) {
      // Pulsing red mic dot
      Circle()
        .fill(Color.red)
        .frame(width: 8, height: 8)

      // Dynamic audio waveform (5 bars)
      HStack(spacing: 3) {
        ForEach(0..<5) { index in
          let multiplier = [0.4, 0.7, 1.0, 0.8, 0.5][index]
          let height = max(4.0, CGFloat(level * Float(multiplier)) * 20.0 + 4.0)
          RoundedRectangle(cornerRadius: 1.5)
            .fill(palette.accent)
            .frame(width: 3, height: height)
        }
      }
      .frame(height: 24)

      // Elapsed duration timer
      Text(formattedDuration(duration))
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(palette.ink)

      // Hands-free badge
      if isLocked {
        HStack(spacing: 3) {
          Image(systemName: "lock.fill").font(.system(size: 9))
          Text("已锁定").font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(palette.accent.opacity(0.18)))
        .foregroundStyle(palette.accent)
      } else {
        Text("空格锁定")
          .font(.system(size: 10))
          .foregroundStyle(palette.ink3)
      }
    }
  }

  private func formattedDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let m = total / 60
    let s = total % 60
    return String(format: "%02d:%02d", m, s)
  }
}
