//
//  FamoFuzzyPreferences.swift
//  法墨输入法 (Famo) — 模糊拼音 (fuzzy-pinyin) settings preferences
//
//  v0.3.5: the 模糊拼音 sub-settings shown via the 「设置…」 sheet on the 键盘输入 page
//  (the 豆包 reference's 模糊拼音 row). Nine common fuzzy-sound toggles (zh=z / ch=c /
//  sh=s / n=l / r=l / f=h / an=ang / en=eng / in=ing), persisted in UserDefaults
//  (Famo-namespaced), mirroring the single-key-home convention of `FamoKeyboardPreferences`:
//  every key string literal lives ONLY in this file, and the settings layer + the
//  patch builder read/write through these accessors so there are no duplicate literals.
//
//  Persistence boundary (see `.trellis/spec/frontend/famo-modern-ui-direction.md`):
//  these toggles ultimately map to `speller/algebra` derive rules. Preferences stay in
//  UserDefaults; `FamoKeyboardPage` writes the managed patch and deploys after the sheet
//  closes, while the preview sheet remains available for dry-run/rollback diagnostics.
//
//  Boundary (ADR-0001 / 0002 / 0003): prefs layer only — never touches the IMK
//  key-event hot path (FamoInputController).
//
//  Concurrency: plain `Sendable` value snapshot; the accessors run on the main thread
//  like the rest of the candidate / settings UI.
//

import Foundation

/// Single home for the 模糊拼音 sub-settings. The UserDefaults key string literals
/// (`"FamoFuzzy…"`) appear ONLY here; the 设置… sheet and `FamoFuzzySnapshot.current()`
/// read/write through these accessors so there are no duplicate literals anywhere else.
///
/// All toggles default to `false` (fuzzy off by default, like rime-ice's shipped
/// state): each accessor uses `object(forKey:) == nil ? false : bool(forKey:)` for an
/// explicit-false default rather than relying on UserDefaults' implicit `false`.
enum FamoFuzzyPreferences {
  // MARK: - 翘舌 (zh/ch/sh ↔ z/c/s)

  /// zh = z. Key `"FamoFuzzyZhZ"`, default `false`.
  /// Eventual Rime mapping: `speller/algebra` `derive/^zh/z/`.
  static var zhz: Bool {
    get { boolValue("FamoFuzzyZhZ") }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoFuzzyZhZ") }
  }

  /// ch = c. Key `"FamoFuzzyChC"`, default `false`.
  /// Eventual Rime mapping: `speller/algebra` `derive/^ch/c/`.
  static var chc: Bool {
    get { boolValue("FamoFuzzyChC") }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoFuzzyChC") }
  }

  /// sh = s. Key `"FamoFuzzyShS"`, default `false`.
  /// Eventual Rime mapping: `speller/algebra` `derive/^sh/s/`.
  static var shs: Bool {
    get { boolValue("FamoFuzzyShS") }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoFuzzyShS") }
  }

  // MARK: - 声母 (n/l, r/l, f/h)

  /// n = l. Key `"FamoFuzzyNL"`, default `false`.
  /// Eventual Rime mapping: `speller/algebra` `derive/^n/l/` + `derive/^l/n/`.
  static var nl: Bool {
    get { boolValue("FamoFuzzyNL") }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoFuzzyNL") }
  }

  /// r = l. Key `"FamoFuzzyRL"`, default `false`.
  /// Eventual Rime mapping: `speller/algebra` `derive/^r/l/`.
  static var rl: Bool {
    get { boolValue("FamoFuzzyRL") }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoFuzzyRL") }
  }

  /// f = h. Key `"FamoFuzzyFH"`, default `false`.
  /// Eventual Rime mapping: `speller/algebra` `derive/^f/h/` + `derive/^h/f/`.
  static var fh: Bool {
    get { boolValue("FamoFuzzyFH") }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoFuzzyFH") }
  }

  // MARK: - 韵母 (an/ang, en/eng, in/ing)

  /// an = ang. Key `"FamoFuzzyAnAng"`, default `false`.
  /// Eventual Rime mapping: `speller/algebra` `derive/an$/ang/` + `derive/ang$/an/`.
  static var anang: Bool {
    get { boolValue("FamoFuzzyAnAng") }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoFuzzyAnAng") }
  }

  /// en = eng. Key `"FamoFuzzyEnEng"`, default `false`.
  /// Eventual Rime mapping: `speller/algebra` `derive/en$/eng/` + `derive/eng$/en/`.
  static var eneng: Bool {
    get { boolValue("FamoFuzzyEnEng") }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoFuzzyEnEng") }
  }

  /// in = ing. Key `"FamoFuzzyInIng"`, default `false`.
  /// Eventual Rime mapping: `speller/algebra` `derive/in$/ing/` + `derive/ing$/in/`.
  static var ining: Bool {
    get { boolValue("FamoFuzzyInIng") }
    set { FamoDefaults.standard.set(newValue, forKey: "FamoFuzzyInIng") }
  }

  // MARK: - Helpers

  /// Read a Bool that defaults to `false` when the key was never written. Equivalent
  /// to UserDefaults' implicit `false`, but written explicitly so the default is part
  /// of the contract (and stays parallel to `FamoKeyboardPreferences.boolValue`).
  private static func boolValue(_ key: String) -> Bool {
    FamoDefaults.standard.object(forKey: key) == nil
      ? false
      : FamoDefaults.standard.bool(forKey: key)
  }
}

/// A plain, `Sendable` snapshot of the nine 模糊拼音 toggles, decoupled from
/// UserDefaults so the patch builder (`famoDefaultCustomYAML(from:)`) stays a pure
/// value→string function. Mirrors `FamoFuzzyPreferences` field-for-field.
struct FamoFuzzySnapshot: Sendable, Equatable {
  let zhz: Bool
  let chc: Bool
  let shs: Bool
  let nl: Bool
  let rl: Bool
  let fh: Bool
  let anang: Bool
  let eneng: Bool
  let ining: Bool

  /// Read the live preferences into a value snapshot. The single UserDefaults touch
  /// for the fuzzy toggles outside the prefs accessors themselves.
  static func current() -> FamoFuzzySnapshot {
    FamoFuzzySnapshot(
      zhz: FamoFuzzyPreferences.zhz,
      chc: FamoFuzzyPreferences.chc,
      shs: FamoFuzzyPreferences.shs,
      nl: FamoFuzzyPreferences.nl,
      rl: FamoFuzzyPreferences.rl,
      fh: FamoFuzzyPreferences.fh,
      anang: FamoFuzzyPreferences.anang,
      eneng: FamoFuzzyPreferences.eneng,
      ining: FamoFuzzyPreferences.ining
    )
  }

  /// How many fuzzy pairs are enabled — drives the row summary ("已开启 N 项").
  var enabledCount: Int {
    [zhz, chc, shs, nl, rl, fh, anang, eneng, ining].lazy.filter { $0 }.count
  }
}
