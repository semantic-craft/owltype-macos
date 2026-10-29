//
//  OwlMarkedTextResendPolicy.swift
//  Owltype
//
//  #89（spec 主线仓#88 §3，spike #87 真机绿灯）：marked text 重发决策的纯函数 seam。
//
//  历史：`show()` 曾带「内容相同即跳过」的去重守卫（Squirrel show() L558-562 同款）。占位/
//  恒定内容场景（no_inline 的常量全角空格、inline candidate 退格后首候选不变）首键后每键
//  对客户端整轮静默 → Chromium omnibox 只认「本次 keyDown 栈内是否发生过 NSTextInputClient
//  调用」（`_hasUnhandledKeyDownEvent`），静默回合按键被重派为原始键 → 原始退格遇合成文本
//  `TextfieldModel::Backspace → CancelCompositionText` 整段清除（squirrel#906，猫头鹰 trace 实证）。
//
//  修法 = fcitx5-macos 契约（docs/chromium-omnibox-ime-prior-art.md §2.2）：每个被引擎消费
//  的按键都无条件重发 setMarkedText——**内容去重不复存在**。唯一保留的短路是「空→空」：
//  闲置轮（未组码）屏上无 marked text、也无可清内容，重发纯属浪费 IPC（engineUpdate 在
//  keyDown 后无条件运行，含 handled=false 的穿透轮）；这不是内容去重，语义 = 维持 #89 前
//  闲置路径的零 IPC 现状。
//
//  Pure: String only。测试面 = OwlMarkedTextResendPolicyTests（按键序列模拟锁
//  「重发次数 = 合成期消费键数」）。
//

enum OwlMarkedTextResendPolicy {

  /// `previous` = 上一次发给客户端的 marked text（`self.preedit`），`next` = 本轮渲染产物。
  /// true = 必须调 setMarkedText。合成期（任一端非空）永远 true——包括 next == previous
  /// （每键重发正是本策略的存在理由）与 非空→空（ESC/删空的清理回合）。
  static func shouldSend(previous: String, next: String) -> Bool {
    !(previous.isEmpty && next.isEmpty)
  }
}
