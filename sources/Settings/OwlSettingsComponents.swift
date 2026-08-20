//
//  OwlSettingsComponents.swift
//  法墨输入法 (Owltype) — SwiftUI settings window
//
//  Reusable card kit for the sidebar-nav settings window, refreshed to the Claude Design
//  settings handoff visual: lighter cards floating on a darker window with a 1px hairline
//  border + soft shadow; square check, ring-dot radio, keycap KeyChip, and a pill toggle.
//  Palette-driven — no hardcoded colors; honors Reduce Transparency like the candidate panel.
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI is the settings UI layer only.
//
//  Concurrency: not `@MainActor`-isolated (matches the rest of the settings /
//  candidate UI); rendered on the main thread via the non-isolated delegate.
//

import SwiftUI

/// Grouped, rounded 深大红 card with a section header — the shared chrome for the
/// settings detail pages. Mirrors the macOS System Settings / 豆包 card look: a lighter
/// `card` fill on the darker window, a hairline border, and a soft shadow.
///
/// Palette + theme are passed in (not read from a hardcoded constant) so a single
/// instance reflects the window's active color scheme + chosen skin. `reduceTransparency`
/// drops the card's translucency for the accessibility setting.
struct SettingsCard<Content: View>: View {
  let title: String
  let palette: OwlCandidatePalette
  let theme: OwlCandidateTheme
  let reduceTransparency: Bool
  @ViewBuilder let content: () -> Content

  init(
    title: String,
    palette: OwlCandidatePalette,
    theme: OwlCandidateTheme,
    reduceTransparency: Bool,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.palette = palette
    self.theme = theme
    self.reduceTransparency = reduceTransparency
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !title.isEmpty {
        Text(title)
          .font(.owlSerif(size: 12))
          .kerning(0.4)
          .foregroundStyle(palette.ink2)
      }
      content()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        .fill(reduceTransparency ? palette.card : palette.card.opacity(0.92))
    }
    .overlay {
      RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        .strokeBorder(palette.ink.opacity(0.07), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
  }
}

/// Hairline row separator for stacking rows inside a `SettingsCard`. Palette-driven.
struct SettingsCardDivider: View {
  let palette: OwlCandidatePalette

  var body: some View {
    Rectangle()
      .fill(palette.ink.opacity(0.08))
      .frame(height: 1)
  }
}

// MARK: - Leading controls (square check / ring-dot radio)

/// 18×18 square checkbox: filled accent + white ✓ when on, hairline ring when off.
/// State change is conveyed by fill + shape, not color alone.
struct SettingsCheckBox: View {
  let isOn: Bool
  let palette: OwlCandidatePalette

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(isOn ? palette.accent : Color.clear)
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .strokeBorder(isOn ? palette.accent : palette.ink3.opacity(0.55), lineWidth: 1.5)
      if isOn {
        Image(systemName: "checkmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(palette.onAccent)
      }
    }
    .frame(width: 18, height: 18)
    .accessibilityHidden(true)
  }
}

/// 18×18 radio: a 2px ring + a 9px inner accent dot when selected.
struct SettingsRadioDot: View {
  let isOn: Bool
  let palette: OwlCandidatePalette

  var body: some View {
    ZStack {
      Circle()
        .strokeBorder(isOn ? palette.accent : palette.ink3.opacity(0.55), lineWidth: 2)
      if isOn {
        Circle().fill(palette.accent).frame(width: 9, height: 9)
      }
    }
    .frame(width: 18, height: 18)
    .accessibilityHidden(true)
  }
}

/// 38×22 pill toggle: accent track + right knob when on, muted track + left knob when off.
/// Position (not just color) carries the state. Honors Reduce Motion.
struct OwlPillToggle: View {
  let isOn: Bool
  let palette: OwlCandidatePalette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: isOn ? .trailing : .leading) {
      Capsule()
        .fill(isOn ? palette.accent : palette.ink3.opacity(0.35))
        .frame(width: 38, height: 22)
      Circle()
        .fill(.white)
        .frame(width: 18, height: 18)
        .padding(2)
        .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 0.5)
    }
    .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: isOn)
    .accessibilityHidden(true)
  }
}

// MARK: - Primary button

/// Flat filled primary button in the brand accent — matches the app's existing maroon action
/// buttons (`actionButton` / `smallButton` / 打开表情面板). Use in place of
/// `.buttonStyle(.borderedProminent).tint(...)`, whose macOS prominent chrome reads as a
/// different shape than the rest of the settings buttons. Dims when pressed or disabled.
struct OwlFilledButtonStyle: ButtonStyle {
  let palette: OwlCandidatePalette

  func makeBody(configuration: Configuration) -> some View {
    FilledLabel(configuration: configuration, palette: palette)
  }

  private struct FilledLabel: View {
    let configuration: ButtonStyleConfiguration
    let palette: OwlCandidatePalette
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
      configuration.label
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(palette.onAccent)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(palette.accent)
        }
        .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
        .contentShape(Rectangle())
    }
  }
}

// MARK: - Segmented control

/// Palette-driven segmented control — the maroon sibling of `OwlPillToggle`. Replaces
/// `Picker(...).pickerStyle(.segmented)`, whose selected segment on macOS always paints with
/// the system accent (blue) and ignores `.tint`. A light track holds equal-width segments;
/// the selected one fills with `palette.accent` + `palette.onAccent` text. Honors Reduce
/// Motion and dims when `.disabled`.
struct OwlSegmentedControl<Value: Hashable>: View {
  @Binding var selection: Value
  let options: [(String, Value)]
  let palette: OwlCandidatePalette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    HStack(spacing: 3) {
      ForEach(options.indices, id: \.self) { index in
        let title = options[index].0
        let value = options[index].1
        let isOn = value == selection
        Button { selection = value } label: {
          Text(title)
            .font(.system(size: 13, weight: isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? palette.onAccent : palette.ink2)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
          if isOn {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(palette.accent)
              .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 0.5)
          }
        }
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(title)
      }
    }
    .padding(3)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(palette.ink3.opacity(0.16))
    }
    .opacity(isEnabled ? 1 : 0.5)
    .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: selection)
  }
}

// MARK: - Key chips

/// A small rounded keycap chip for a row's trailing edge — the 豆包-style shortcut hint
/// (⇧ / "- =" / "⌥⇧H"). Keycap look: `card2` fill, hairline inset border, a 1px bottom
/// edge. Monospaced so multi-glyph hints stay legible. Decorative — the row carries the
/// accessibility label.
struct KeyChip: View {
  let label: String
  let palette: OwlCandidatePalette

  init(_ label: String, palette: OwlCandidatePalette) {
    self.label = label
    self.palette = palette
  }

  var body: some View {
    Text(label)
      .font(.system(size: 11, weight: .medium, design: .monospaced))
      .foregroundStyle(palette.ink2)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .frame(minWidth: 22)
      .background {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(palette.card2)
      }
      .overlay {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .strokeBorder(palette.ink.opacity(0.14), lineWidth: 1)
      }
      .shadow(color: palette.ink.opacity(0.12), radius: 0, x: 0, y: 1)
      .accessibilityHidden(true)
  }
}

/// Trailing strip of `KeyChip`s for an option row. Extracted so check / radio rows share
/// the same spacing and so an empty list renders nothing.
private struct KeyChipStrip: View {
  let keys: [String]
  let palette: OwlCandidatePalette

  var body: some View {
    if !keys.isEmpty {
      HStack(spacing: 6) {
        ForEach(keys, id: \.self) { key in
          KeyChip(key, palette: palette)
        }
      }
    }
  }
}

// MARK: - Option rows

/// A whole-row checkbox option with an optional trailing key-chip hint (☑ 使用 Shift
/// 切换中英文 [⇧]). State + side-effect are owned by the caller (`isOn` + an `onToggle`
/// write-through). Tappable across the full row; exposed to accessibility as a selectable
/// button.
struct SettingsCheckRow: View {
  let title: String
  let isOn: Bool
  let keys: [String]
  let palette: OwlCandidatePalette
  let isEnabled: Bool
  let onToggle: () -> Void

  init(
    title: String,
    isOn: Bool,
    keys: [String] = [],
    palette: OwlCandidatePalette,
    isEnabled: Bool = true,
    onToggle: @escaping () -> Void
  ) {
    self.title = title
    self.isOn = isOn
    self.keys = keys
    self.palette = palette
    self.isEnabled = isEnabled
    self.onToggle = onToggle
  }

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 11) {
        SettingsCheckBox(isOn: isOn, palette: palette)
        Text(title)
          .font(.system(size: 14))
          .foregroundStyle(palette.ink)
        Spacer(minLength: 8)
        KeyChipStrip(keys: keys, palette: palette)
      }
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.55)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    .accessibilityLabel(title)
  }
}

/// A whole-row radio option with an optional trailing view (e.g. a 双拼方案 `Picker`)
/// and/or key-chip hints (◉ 拼音输入 / ○ 双拼输入 ▼). State + side-effect are owned by the
/// caller: `isSelected` + an `onSelect` write-through. Tapping the leading control + title
/// selects it; the trailing view handles its own interaction.
struct SettingsRadioRow<Trailing: View>: View {
  let title: String
  let isSelected: Bool
  let keys: [String]
  let palette: OwlCandidatePalette
  let onSelect: () -> Void
  @ViewBuilder let trailing: () -> Trailing

  init(
    title: String,
    isSelected: Bool,
    keys: [String] = [],
    palette: OwlCandidatePalette,
    onSelect: @escaping () -> Void,
    @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
  ) {
    self.title = title
    self.isSelected = isSelected
    self.keys = keys
    self.palette = palette
    self.onSelect = onSelect
    self.trailing = trailing
  }

  var body: some View {
    HStack(spacing: 11) {
      Button(action: onSelect) {
        HStack(spacing: 11) {
          SettingsRadioDot(isOn: isSelected, palette: palette)
          Text(title)
            .font(.system(size: 14))
            .foregroundStyle(palette.ink)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      Spacer(minLength: 8)
      KeyChipStrip(keys: keys, palette: palette)
      trailing()
    }
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityLabel(title)
  }
}

/// A whole-row toggle option (符号 / 表情 enable). State + side-effect owned by the caller.
/// Optional `systemImage` + `subtitle` upgrade it to the icon＋标题＋一行说明 rich row used by
/// 内置技能 / 辅助功能权限 / 供应商行; omitted, it renders the original title-only row.
struct SettingsToggleRow: View {
  let title: String
  let subtitle: String?
  let systemImage: String?
  let isOn: Bool
  let palette: OwlCandidatePalette
  let isEnabled: Bool
  let onToggle: () -> Void

  init(
    title: String,
    subtitle: String? = nil,
    systemImage: String? = nil,
    isOn: Bool,
    palette: OwlCandidatePalette,
    isEnabled: Bool = true,
    onToggle: @escaping () -> Void
  ) {
    self.title = title
    self.subtitle = subtitle
    self.systemImage = systemImage
    self.isOn = isOn
    self.palette = palette
    self.isEnabled = isEnabled
    self.onToggle = onToggle
  }

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 11) {
        if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 13))
            .foregroundStyle(palette.accent)
            .frame(width: 26, height: 26)
            .background {
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.accent.opacity(0.10))
            }
            .accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 14))
            .foregroundStyle(palette.ink)
          if let subtitle {
            Text(subtitle)
              .font(.system(size: 11.5))
              .foregroundStyle(palette.ink3)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 8)
        OwlPillToggle(isOn: isOn, palette: palette)
      }
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.55)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    .accessibilityLabel(title)
  }
}
