//
//  OwlUserDictResetPrompt.swift
//  Owltype
//
//  「重置用户词典…」的确认弹窗 (#37)。同 `OwlUpdateLogoutPrompt` 的形态：alert 的**构造**
//  是纯函数（可断言按钮次序/默认键），`runModal` 只在 `confirm()` 里发生。
//
//  默认按钮刻意是「取消」：这是毁灭性动作，回车/误触必须落在安全的一侧。NSAlert 把
//  keyEquivalent "\r" 给第一个 addButton，所以「取消」先加。
//

import AppKit

enum OwlUserDictResetPrompt {
  static let cancelTitle = "取消"
  static let confirmTitle = "重置"

  static func makeAlert() -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "重置用户词典？"
    alert.informativeText = """
      将清空输入习惯与自造词学习记录——猫头鹰会忘掉你上屏过哪些词、以及它们的排序。

      方案选择、皮肤、快捷短语等设置不受影响，词库也不受影响。
      原词典会先整目录备份到配置目录的 .owl-backup/ 下，可手工还原。
      """
    alert.addButton(withTitle: cancelTitle)   // 第一个 = 默认（毁灭性动作，默认落安全侧）
    alert.addButton(withTitle: confirmTitle).hasDestructiveAction = true
    return alert
  }

  /// true = 用户确认重置。
  static func confirm() -> Bool {
    makeAlert().runModal() == .alertSecondButtonReturn
  }
}
