//
//  OwlFuzzySheet.swift
//  猫头鹰输入法 (Owltype) — 模糊拼音 (fuzzy-pinyin) settings sheet
//
//  v0.3.5: the 模糊拼音 「设置…」 sheet opened from the 键盘输入 page. A 深大红-themed
//  list of `SettingsCheckRow`s, one per fuzzy pair (zh=z / ch=c / sh=s / n=l / r=l /
//  f=h / an=ang / en=eng / in=ing). Each row write-throughs to `OwlFuzzyPreferences`
//  (the single key home) AND updates a local `@State` mirror so the checkmark flips
//  immediately. The page reads the post-close count via `OwlFuzzySnapshot.current()`.
//
//  Persistence boundary (see `.trellis/spec/frontend/owl-modern-ui-direction.md`):
//  these toggles map to `speller/algebra` derive rules previewed by
//  `OwlConfigPatchBuilder`; this sheet persists choices in UserDefaults, and the parent
//  keyboard page writes Owltype's user_data_dir + `deploy()` when the sheet closes.
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI is the settings UI layer only — never
//  touches the IMK key-event hot path (OwlInputController).
//
//  Concurrency: not `@MainActor`-isolated (matches the rest of the settings UI).
//

import SwiftUI

/// 深大红-themed sheet of the nine 模糊拼音 toggles. State + write-through live here:
/// the local `@State` fields seed from `OwlFuzzyPreferences` on init and each toggle
/// flips the mirror AND writes back through `OwlFuzzyPreferences`, keeping the
/// UserDefaults key strings solely in `OwlFuzzyPreferences`.
///
/// Not `@MainActor`-isolated. Presented from `OwlKeyboardPage`'s `.sheet`.
struct OwlFuzzySheet: View {
  let palette: OwlCandidatePalette
  let theme: OwlCandidateTheme
  let reduceTransparency: Bool

  @Environment(\.dismiss) private var dismiss

  // Local mirrors of the nine fuzzy toggles, seeded from the prefs home on init so the
  // sheet opens reflecting the persisted state. Each toggle updates the mirror (for an
  // instant checkmark flip) AND `OwlFuzzyPreferences` (the persisted source of truth).
  @State private var zhz: Bool
  @State private var chc: Bool
  @State private var shs: Bool
  @State private var nl: Bool
  @State private var rl: Bool
  @State private var fh: Bool
  @State private var anang: Bool
  @State private var eneng: Bool
  @State private var ining: Bool

  init(palette: OwlCandidatePalette, theme: OwlCandidateTheme, reduceTransparency: Bool) {
    self.palette = palette
    self.theme = theme
    self.reduceTransparency = reduceTransparency
    let snapshot = OwlFuzzySnapshot.current()
    _zhz = State(initialValue: snapshot.zhz)
    _chc = State(initialValue: snapshot.chc)
    _shs = State(initialValue: snapshot.shs)
    _nl = State(initialValue: snapshot.nl)
    _rl = State(initialValue: snapshot.rl)
    _fh = State(initialValue: snapshot.fh)
    _anang = State(initialValue: snapshot.anang)
    _eneng = State(initialValue: snapshot.eneng)
    _ining = State(initialValue: snapshot.ining)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      ScrollView {
        VStack(spacing: 16) {
          shengmuCard
          yunmuCard
        }
      }
      footer
    }
    .padding(20)
    .frame(width: 460, height: 520)
    .background(palette.card)
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("模糊拼音")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(palette.ink)
      Text("开启后这些音将互相模糊匹配（如 zh 与 z 视为相同）。修改即时保存；关闭面板后会应用到 Rime。")
        .font(.system(size: 12))
        .foregroundStyle(palette.ink3)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - 声母 group (翘舌 + n/l + r/l + f/h)

  private var shengmuCard: some View {
    SettingsCard(
      title: "声母",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(spacing: 0) {
        row("zh = z（翘舌）", isOn: zhz) {
          zhz = OwlSettingsActions.toggleLocalBool(zhz) { OwlFuzzyPreferences.zhz = $0 }
        }
        SettingsCardDivider(palette: palette)
        row("ch = c（翘舌）", isOn: chc) {
          chc = OwlSettingsActions.toggleLocalBool(chc) { OwlFuzzyPreferences.chc = $0 }
        }
        SettingsCardDivider(palette: palette)
        row("sh = s（翘舌）", isOn: shs) {
          shs = OwlSettingsActions.toggleLocalBool(shs) { OwlFuzzyPreferences.shs = $0 }
        }
        SettingsCardDivider(palette: palette)
        row("n = l", isOn: nl) {
          nl = OwlSettingsActions.toggleLocalBool(nl) { OwlFuzzyPreferences.nl = $0 }
        }
        SettingsCardDivider(palette: palette)
        row("r = l", isOn: rl) {
          rl = OwlSettingsActions.toggleLocalBool(rl) { OwlFuzzyPreferences.rl = $0 }
        }
        SettingsCardDivider(palette: palette)
        row("f = h", isOn: fh) {
          fh = OwlSettingsActions.toggleLocalBool(fh) { OwlFuzzyPreferences.fh = $0 }
        }
      }
    }
  }

  // MARK: - 韵母 group (an/ang, en/eng, in/ing)

  private var yunmuCard: some View {
    SettingsCard(
      title: "韵母",
      palette: palette,
      theme: theme,
      reduceTransparency: reduceTransparency
    ) {
      VStack(spacing: 0) {
        row("an = ang", isOn: anang) {
          anang = OwlSettingsActions.toggleLocalBool(anang) { OwlFuzzyPreferences.anang = $0 }
        }
        SettingsCardDivider(palette: palette)
        row("en = eng", isOn: eneng) {
          eneng = OwlSettingsActions.toggleLocalBool(eneng) { OwlFuzzyPreferences.eneng = $0 }
        }
        SettingsCardDivider(palette: palette)
        row("in = ing", isOn: ining) {
          ining = OwlSettingsActions.toggleLocalBool(ining) { OwlFuzzyPreferences.ining = $0 }
        }
      }
    }
  }

  /// One fuzzy-pair check row. `onToggle` flips the local mirror + persists; the row
  /// reflects `isOn` immediately. No key chips (the pair label carries the meaning).
  private func row(_ title: String, isOn: Bool, onToggle: @escaping () -> Void) -> some View {
    SettingsCheckRow(
      title: title,
      isOn: isOn,
      palette: palette,
      onToggle: onToggle
    )
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 10) {
      Spacer(minLength: 0)
      Button(action: { dismiss() }) {
        Text("完成")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(palette.onAccent)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(palette.accent)
          }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("完成")
    }
  }
}
