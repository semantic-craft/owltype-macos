import SwiftUI

/// Wubi hint and z-mode presentation; keyboard preferences own persistence.
struct OwlWubiLookupSettings: View {
  let codeHint: Bool
  let zWildcard: Bool
  let zReverseLookup: Bool
  let palette: OwlCandidatePalette
  let isEnabled: Bool
  let onToggleCodeHint: () -> Void
  let onToggleZWildcard: () -> Void
  let onToggleZReverseLookup: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      SettingsToggleRow(
        title: "候选剩余编码提示",
        isOn: codeHint,
        palette: palette,
        isEnabled: isEnabled,
        onToggle: onToggleCodeHint
      )
      explanation("开启时优先显示尚未输入的编码；没有可补部分时，保留词条的完整编码注释。")
      SettingsCardDivider(palette: palette)
      SettingsToggleRow(
        title: "z 通配",
        isOn: zWildcard,
        palette: palette,
        isEnabled: isEnabled,
        onToggle: onToggleZWildcard
      )
      explanation("用 z 代替不确定的码位；开启时暂停临时拼音反查。")
      SettingsCardDivider(palette: palette)
      SettingsToggleRow(
        title: "z 临时拼音反查",
        isOn: zReverseLookup,
        palette: palette,
        isEnabled: isEnabled && !zWildcard,
        onToggle: onToggleZReverseLookup
      )
      explanation("关闭通配且未开启拼音混输时，按 z 加拼音查字；反查词条保留五笔编码注释。")
      SettingsCardDivider(palette: palette)
    }
  }

  private func explanation(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 12))
      .foregroundStyle(palette.ink3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
  }
}
