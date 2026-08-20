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

/// Single UserDefaults home for the 候选 emoji preference. Default: off（出厂关）.
enum OwlEmojiPreferences {
  private static let candidateEmojiKey = "OwlEmojiInCandidates"

  /// 在打字候选里显示 emoji（rime-ice 原生 `emoji` switch）. Default `false` — Owltype 出厂把
  /// schema switch reset 1→0（famo-seed.sh），这是面向用户的开关。
  static var candidateEmojiEnabled: Bool {
    get { OwlDefaults.standard.bool(forKey: candidateEmojiKey) }
    set { OwlDefaults.standard.set(newValue, forKey: candidateEmojiKey) }
  }
}
