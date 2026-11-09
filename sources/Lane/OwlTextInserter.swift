//
//  OwlTextInserter.swift
//  猫头鹰输入法 (Owltype) — Unified host delivery selection replacement adapter
//

import Foundation

@MainActor
final class OwlTextInserter {
  static let shared = OwlTextInserter()

  private let core = try! OwlAppSession("textInserter")

  func insert(
    _ text: String,
    bundleID: String?,
    axSet: () -> Bool,
    paste: (String) -> Bool,
    copyOnly: (String) -> Void
  ) -> OwlInsertOutcome {
    OwlTemplateHostDelivery.replaceSelection(
      text,
      bundleID: bundleID,
      session: core,
      axSet: axSet,
      paste: paste,
      copyOnly: copyOnly
    )
  }
}
