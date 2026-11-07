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
        title: "候选显示五笔编码提示",
        isOn: codeHint,
        palette: palette,
        isEnabled: isEnabled,
        onToggle: onToggleCodeHint
      )
      explanation("开启后在五笔候选旁显示剩余编码或全码提示；关闭后原生五笔打字不显示编码，仅在 z 临时拼音反查、五笔拼音混输及 z 通配查字时显示五笔编码。")
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
