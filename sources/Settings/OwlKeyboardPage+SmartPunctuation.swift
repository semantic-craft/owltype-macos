import SwiftUI

extension OwlKeyboardPage {
  @ViewBuilder
  var smartPunctuationRows: some View {
        SettingsToggleRow(
          title: "智能标点",
          isOn: state.keyboardSmartPunctuation,
          palette: palette,
          onToggle: {
            OwlSettingsActions.toggle(state: state, keyPath: \.keyboardSmartPunctuation) {
              OwlKeyboardPreferences.smartPunctuation = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "重复标点改为中文",
          isOn: state.keyboardSmartPunctuationRepeat,
          palette: palette,
          onToggle: {
            OwlSettingsActions.toggle(state: state, keyPath: \.keyboardSmartPunctuationRepeat) {
              OwlKeyboardPreferences.smartPunctuationRepeat = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "标点后空格改为英文",
          isOn: state.keyboardSmartPunctuationSpace,
          palette: palette,
          onToggle: {
            OwlSettingsActions.toggle(state: state, keyPath: \.keyboardSmartPunctuationSpace) {
              OwlKeyboardPreferences.smartPunctuationSpace = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
  }
}
