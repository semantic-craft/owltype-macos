//
//  OwlInputMenuTitles.swift
//  Owltype
//
//  Single responsibility: the status-menu title strings for OwlInputController.
//  Moved verbatim out of OwlInputController.swift (god-object shrink, 2026-06-20);
//  a standalone type, not part of the controller class.
//

enum OwlInputMenuTitles {
  static let clipboard = "剪贴板…"
  static let emoji = "表情符号…"
  static let quickSend = "快捷片段…"
  static let settings = "设置…"
  static let deploy = "应用配置改动"
  static let syncUserData = "同步用户数据"
  static let migrateLegacyUserData = "迁移旧版输入记录…"
  static let resetUserDict = "重置用户词典…"
  static let syncDirectory = "设置同步目录..."
  static let onboarding = "欢迎与引导…"
  static let rimeConfig = "打开猫头鹰配置目录…"
  static let logs = "查看诊断日志…"

  static func cjkInput(asciiMode: Bool) -> String {
    asciiMode ? "切换至中文输入" : "切换至英文输入"
  }

  static func traditionalInput(traditional: Bool) -> String {
    traditional ? "切换至简体输入" : "切换至繁体输入"
  }

  static func asciiPunctuation(asciiPunct: Bool) -> String {
    asciiPunct ? "使用中文标点符号" : "使用英文标点符号"
  }

  static func fullShape(fullShape: Bool) -> String {
    fullShape ? "使用半角输入" : "使用全角输入"
  }
}
