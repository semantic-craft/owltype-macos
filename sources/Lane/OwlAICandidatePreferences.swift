//
//  OwlAICandidatePreferences.swift
//  Owltype — Lane A: Cloud AI Candidate & Association Preferences (#392)
//
//  Manages user settings for cloud AI candidate associations and English mode
//  AI candidate completions. Backed by OwlDefaults.
//

import Foundation

enum OwlAICandidatePreferences: Sendable {
  static let aiAssociationEnabledKey = "OwlAIAssociationEnabled"
  static let aiEnglishCandidateEnabledKey = "OwlAIEnglishCandidateEnabled"
  static let jevDiscriminativeRerankEnabledKey = "OwlJevDiscriminativeRerankEnabled"

  /// Default false: user must explicitly enable cloud AI associations.
  static var aiAssociationEnabled: Bool {
    get { OwlDefaults.standard.object(forKey: aiAssociationEnabledKey) as? Bool ?? false }
    set { OwlDefaults.standard.set(newValue, forKey: aiAssociationEnabledKey) }
  }

  /// Default false: user must explicitly enable AI candidates in English input mode.
  static var aiEnglishCandidateEnabled: Bool {
    get { OwlDefaults.standard.object(forKey: aiEnglishCandidateEnabledKey) as? Bool ?? false }
    set { OwlDefaults.standard.set(newValue, forKey: aiEnglishCandidateEnabledKey) }
  }

  /// Default false: user must explicitly enable discriminative Jev candidate reranking.
  static var jevDiscriminativeRerankEnabled: Bool {
    get { OwlDefaults.standard.object(forKey: jevDiscriminativeRerankEnabledKey) as? Bool ?? false }
    set { OwlDefaults.standard.set(newValue, forKey: jevDiscriminativeRerankEnabledKey) }
  }

  // periphery:ignore
  static func resetForTesting() {
    OwlDefaults.standard.removeObject(forKey: aiAssociationEnabledKey)
    OwlDefaults.standard.removeObject(forKey: aiEnglishCandidateEnabledKey)
    OwlDefaults.standard.removeObject(forKey: jevDiscriminativeRerankEnabledKey)
  }
}
