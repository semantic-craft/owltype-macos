//
//  OwlSnapshotRegistry.swift
//

import Foundation

/// MainActor-isolated holder of the live composition snapshot.
@MainActor
final class OwlSnapshotRegistry {
  static let shared = OwlSnapshotRegistry()

  private(set) var current: OwlCompositionSnapshot?

  init() {}

  func update(_ snapshot: OwlCompositionSnapshot?) {
    current = snapshot
  }
}
