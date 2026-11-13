//
//  OwlEmojiPreferences.swift
//  法墨输入法 (Owltype) — 候选 emoji preference
//
//  UserDefaults home for the 「在候选中显示 emoji」 toggle (rime-ice `emoji` switch). The
//  emoji / symbol PANEL is summoned from the input-method menu bar and needs no stored
//  enable flag (the old enable + trigger prefs were removed). No key-event / hot-path
//  involvement.
//

import Foundation

/// Single UserDefaults home for the 候选 emoji preference. Default: on, matching the pinned macOS upstream host.
enum OwlEmojiPreferences {
  private static let candidateEmojiKey = "OwlEmojiInCandidates"

  /// 在打字候选里显示 emoji。未保存偏好时遵循 macOS 上游默认开启。
  static var candidateEmojiEnabled: Bool {
    get { (OwlDefaults.standard.object(forKey: candidateEmojiKey) as? Bool) ?? OwlAppCore.keyboardCatalog.auxiliaryDefaults[candidateEmojiKey]! }
    set { OwlDefaults.standard.set(newValue, forKey: candidateEmojiKey) }
  }
}
