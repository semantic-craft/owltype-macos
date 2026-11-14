//
//  OwlSnapshotEmitter.swift
//

import Foundation

@MainActor
final class OwlSnapshotEmitter {
  static let shared = OwlSnapshotEmitter()

  private var wasComposing: Bool = false

  init() {}

  func emitComposing(rawInput: String) {
    let snapshot = OwlCompositionSnapshot(
      id: OwlSnapshotIDGenerator.shared.next(),
      rawInput: rawInput
    )

    OwlSnapshotRegistry.shared.update(snapshot)

    wasComposing = true
  }

  func emitCleared() {
    guard wasComposing else { return }
    OwlSnapshotRegistry.shared.update(nil)
    wasComposing = false
  }
}
