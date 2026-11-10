//
//  OwlPolishStyleBar.swift
//  Owltype — AI Writing Auxiliary Subsystem (Milestone M7 / Issue #397)
//
//  A segmented 4-style switcher bar for polish styles:
//  原意保真, 精炼书面, 得体商务, 口语转书面.
//

import SwiftUI

struct OwlPolishStyleBar: View {
  @Binding var selectedStyle: OwlPolishStyle
  let isDisabled: Bool
  let palette: OwlCandidatePalette
  let onSelectStyle: (OwlPolishStyle) -> Void

  init(
    selectedStyle: Binding<OwlPolishStyle>,
    isDisabled: Bool = false,
    palette: OwlCandidatePalette,
    onSelectStyle: @escaping (OwlPolishStyle) -> Void
  ) {
    self._selectedStyle = selectedStyle
    self.isDisabled = isDisabled
    self.palette = palette
    self.onSelectStyle = onSelectStyle
  }

  var body: some View {
    HStack(spacing: 6) {
      ForEach(OwlPolishStyle.allCases) { style in
        let isSelected = (selectedStyle == style)
        Button {
          guard !isDisabled, selectedStyle != style else { return }
          onSelectStyle(style)
          if selectedStyle != style {
            selectedStyle = style
          }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: style.iconName)
              .font(.system(size: 10.5, weight: isSelected ? .bold : .medium))
            Text(style.title)
              .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
          }
          .padding(.horizontal, 9)
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
        .disabled(isDisabled)
        .help(style.subtitle)
      }
      Spacer()
    }
  }
}
