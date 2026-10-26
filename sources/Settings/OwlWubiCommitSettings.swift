import SwiftUI

/// The two native Wubi commit policies; persistence remains owned by the keyboard page.
struct OwlWubiCommitSettings: View {
  let autoCommitUnique: Bool
  let fifthCodeTopCommit: Bool
  let palette: OwlCandidatePalette
  let isEnabled: Bool
  let onToggleAutoCommitUnique: () -> Void
  let onToggleFifthCodeTopCommit: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      SettingsToggleRow(
        title: "四码唯一候选自动上屏",
        isOn: autoCommitUnique,
        palette: palette,
        isEnabled: isEnabled,
        onToggle: onToggleAutoCommitUnique
      )
      SettingsCardDivider(palette: palette)
      SettingsToggleRow(
        title: "第五码将首选上屏",
        isOn: fifthCodeTopCommit,
        palette: palette,
        isEnabled: isEnabled,
        onToggle: onToggleFifthCodeTopCommit
      )
      Text("关闭仅影响五笔拼音混输，续输遵循拼音组字规则；纯五笔仍将首选上屏，并把第五码留作下一组开头。")
        .font(.system(size: 12))
        .foregroundStyle(palette.ink3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .padding(.bottom, 4)
      SettingsCardDivider(palette: palette)
    }
  }
}
