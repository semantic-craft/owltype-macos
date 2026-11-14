//
//  OwlAIWritingSettings.swift
//  Owltype — AI Writing Auxiliary Subsystem (Milestone M6 / Issue #394)
//

import Foundation

enum OwlAIWritingSettings: Sendable {
  static let enabledKey = "OwlAIWritingPanelEnabled"

  static var isEnabled: Bool {
    get {
      OwlDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }
    set {
      OwlDefaults.standard.set(newValue, forKey: enabledKey)
    }
  }

}
