//
//  OwlInputController+RimeOptions.swift
//  Owltype
//
//  Single responsibility: thin librime RimeOption read/write/toggle helpers and the
//  derived status-flags tuple used by the menu builder and toggle actions.
//  Moved verbatim out of OwlInputController.swift (god-object shrink, 2026-06-20);
//  no logic edits.
//

extension OwlInputController {
  typealias RimeStatusFlags = (asciiMode: Bool, traditional: Bool, asciiPunct: Bool, fullShape: Bool)

  func currentRimeStatusFlags() -> RimeStatusFlags {
    guard let rime, rime.isValid, let status = rime.status() else { return (false, false, false, false) }
    return (status.isASCIIMode, currentTraditionalOutputEnabled(), status.isASCIIPunct, status.isFullShape)
  }

  func setRimeOption(_ option: RimeOption, _ enabled: Bool) {
    guard let rime, rime.isValid else { return }
    rime.setOption(option, enabled)
  }

  func toggleRimeOption(_ option: RimeOption) {
    guard let rime, rime.isValid else { return }
    rime.setOption(option, !rime.option(option))
    rimeUpdate()
  }

  func rimeOption(_ option: RimeOption) -> Bool {
    guard let rime, rime.isValid else { return false }
    return rime.option(option)
  }

  func currentTraditionalOutputEnabled() -> Bool {
    // rime-ice 全拼/双拼走 `.traditionalization`，五笔走 `.zhTrad`；`.transcription` 是 rime_mint 类
    // 方案的简繁 option，本底座用不到但保留以兼容其他可能携带这些 option 的方案。
    rimeOption(.traditional) || rimeOption(.traditionalization) || rimeOption(.zhTrad) || rimeOption(.transcription)
  }

  /// 简↔繁 全局开关：把 Owltype 暴露的各方案用到的所有简繁 option 一次性设到当前会话，使「简入繁出」
  /// 对全拼/双拼（`transcription`）与五笔（`zh_trad`）等所有方案统一生效。不调 `rimeUpdate()`，
  /// 由调用方决定是否立即重渲染（session seed 不需要、菜单/设置即时切换需要）。
  func setTraditionalOutputOptions(_ traditional: Bool) {
    setRimeOption(.traditional, traditional)
    setRimeOption(.traditionalization, traditional)
    setRimeOption(.zhTrad, traditional)
    setRimeOption(.transcription, traditional)
    setRimeOption(.simplification, !traditional)
  }
}
