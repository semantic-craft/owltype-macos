//
//  FamoHostCaretAnchorMemory.swift
//  法墨输入法 (Famo) — host-scoped last-good caret anchor
//
//  The `previous` half of the B3 anchor cascade (`FamoCandidateAnchor.resolve`), given an owner.
//  When a host hands back a junk caret rect the cascade falls back to the last known-good anchor;
//  before this type that anchor was ONE process-wide `NSRect` shared by every host, reset by
//  nothing — not `activateServer`, not `deactivateServer`. So a host whose rect is always rejected
//  (WeChat) silently inherited the anchor left behind by the PREVIOUS app, and on a multi-display
//  setup that put the candidate bar on the other app's screen.
//
//  Scoping the memory to the host that produced it makes stale cross-host reuse unrepresentable:
//  ask for a different host's anchor and you get `nil`, so the caller runs its own fallback
//  instead of silently borrowing another app's caret.
//
//  Single slot on purpose: only the most recent host is remembered, so switching hosts forgets the
//  old anchor outright. A per-host table would keep anchors for windows that have since moved or
//  closed, and buys nothing the cascade needs — `previous` only exists to bridge junk rects within
//  one app's typing session.
//
//  Boundary (ADR-0001 / 0002): pure value type — no AppKit, no NSScreen, no side effects, host
//  identity is a plain `String?`. Mirrors `FamoFloatingPanelPositioner` (the placement math) and
//  `FamoCandidateAnchor` (the validation cascade): the surfaces delegate their state and geometry
//  to value types that unit-test with fabricated inputs.
//

import CoreGraphics

/// The last known-good caret anchor, remembered together with the host app it came from.
struct FamoHostCaretAnchorMemory {
  /// Bundle ID of the host that produced `anchor`, normalized (`nil` = a host reporting none).
  private var host: String?
  /// The stored anchor, `nil` until the first `record`.
  private var anchor: CGRect?

  init() {}

  /// Remember `anchor` as the last known-good caret rect for `host`. Recording for a different
  /// host REPLACES the record — the previous host's anchor is forgotten, never merged.
  /// Callers record only anchors that already passed `FamoCandidateAnchor`, so this stores no junk.
  mutating func record(_ anchor: CGRect, host: String?) {
    self.host = Self.normalized(host)
    self.anchor = anchor
  }

  /// The last known-good caret anchor for `host`, or `nil` when the record belongs to another host
  /// (or nothing has been recorded yet). `nil` is the whole point of this type: it forces the
  /// caller onto its own fallback rather than another app's caret.
  ///
  /// A host reporting no bundle ID matches only another host reporting none — there is no
  /// information to tell two such clients apart, and refusing them outright would drop the
  /// last-good fallback for the (rare) clients IMK hands us without an identity.
  func anchor(for host: String?) -> CGRect? {
    guard let anchor, self.host == Self.normalized(host) else { return nil }
    return anchor
  }

  /// `""` — a session whose `currentApp` was never set — and `nil` are the same unnamed host.
  private static func normalized(_ host: String?) -> String? {
    guard let host, !host.isEmpty else { return nil }
    return host
  }
}
