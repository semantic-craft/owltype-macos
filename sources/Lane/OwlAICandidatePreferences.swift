//
//  OwlAICandidatePreferences.swift
//  Owltype — Lane A: Cloud AI Candidate & Association Preferences (#392)
//
//  Manages user settings for cloud AI candidate associations and English mode
//  AI candidate completions. Backed by OwlDefaults.
//

import Foundation

public enum OwlAICandidatePreferences: Sendable {
  public static let aiAssociationEnabledKey = "OwlAIAssociationEnabled"
  public static let aiEnglishCandidateEnabledKey = "OwlAIEnglishCandidateEnabled"
  public static let jevDiscriminativeRerankEnabledKey = "OwlJevDiscriminativeRerankEnabled"

  /// Default false: user must explicitly enable cloud AI associations.
  public static var aiAssociationEnabled: Bool {
    get { OwlDefaults.standard.object(forKey: aiAssociationEnabledKey) as? Bool ?? false }
    set { OwlDefaults.standard.set(newValue, forKey: aiAssociationEnabledKey) }
  }

  /// Default false: user must explicitly enable AI candidates in English input mode.
  public static var aiEnglishCandidateEnabled: Bool {
    get { OwlDefaults.standard.object(forKey: aiEnglishCandidateEnabledKey) as? Bool ?? false }
    set { OwlDefaults.standard.set(newValue, forKey: aiEnglishCandidateEnabledKey) }
  }

  /// Default false: user must explicitly enable discriminative Jev candidate reranking.
  public static var jevDiscriminativeRerankEnabled: Bool {
    get { OwlDefaults.standard.object(forKey: jevDiscriminativeRerankEnabledKey) as? Bool ?? false }
    set { OwlDefaults.standard.set(newValue, forKey: jevDiscriminativeRerankEnabledKey) }
  }

  public static func resetForTesting() {
    OwlDefaults.standard.removeObject(forKey: aiAssociationEnabledKey)
    OwlDefaults.standard.removeObject(forKey: aiEnglishCandidateEnabledKey)
    OwlDefaults.standard.removeObject(forKey: jevDiscriminativeRerankEnabledKey)
  }
}
