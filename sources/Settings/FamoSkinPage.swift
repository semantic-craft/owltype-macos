//
//  FamoSkinPage.swift
//  法墨输入法 (Famo) — 皮肤外观 (Skin) settings page
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI settings UI only; not @MainActor-isolated.
//

import Foundation
import AppKit
import SwiftUI

// MARK: - 皮肤外观 (Skin)

/// Skin selection: a 2-column grid of the 皮肤 cards + a 明暗 segment (the candidate
/// panel's appearance mode, the same preference surfaced on 候选窗外观).
struct FamoSkinPage: View {
  @Bindable var state: FamoSettingsState
  let palette: FamoCandidatePalette
  let theme: FamoCandidateTheme
  let reduceTransparency: Bool
  /// Refresh a currently-visible candidate panel immediately, exactly like the 候选窗外观 page —
  /// without it a skin / 明暗 change only takes effect on the next composition.
  var onPanelPreferencesChanged: () -> Void = {}

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        skinCard
        appearanceCard
      }
      .padding(20)
    }
  }

  private var skinCard: some View {
    SettingsCard(title: "配色皮肤", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      LazyVGrid(
        columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
        spacing: 12
      ) {
        ForEach(FamoSkin.allCases) { skin in
          skinCardCell(skin)
        }
      }
    }
  }

  private func skinCardCell(_ skin: FamoSkin) -> some View {
    let selected = skin == state.skin
    return HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(skin.swatch)
        .frame(width: 38, height: 38)
        .overlay {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
        }
      VStack(alignment: .leading, spacing: 2) {
        Text(skin.displayName)
          .font(.system(size: 13.5, weight: .medium))
          .foregroundStyle(palette.ink)
      }
      Spacer(minLength: 4)
      if selected {
        Image(systemName: "checkmark")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(palette.accent)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: 11, style: .continuous).fill(palette.card2)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .strokeBorder(selected ? palette.accent : Color.clear, lineWidth: 2)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      FamoSettingsActions.set(skin, state: state, keyPath: \.skin) {
        FamoSkinPreferences.skin = $0
      }
      onPanelPreferencesChanged()
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .accessibilityLabel(skin.displayName)
  }

  /// 明暗: the candidate panel's appearance mode (shared with 候选窗外观). Written through
  /// the mirror + `FamoPanelPreferences` so the key string stays in one place.
  private var appearanceCard: some View {
    let binding = Binding(
      get: { state.panelAppearance },
      set: { newValue in
        FamoSettingsActions.set(newValue, state: state, keyPath: \.panelAppearance) {
          FamoPanelPreferences.appearance = $0
        }
        onPanelPreferencesChanged()
      }
    )
    return SettingsCard(title: "明暗", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 8) {
        FamoSegmentedControl(
          selection: binding,
          options: [("跟随系统", .system), ("亮", .light), ("暗", .dark)],
          palette: palette
        )
        Text("影响候选窗的明暗显示。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}
