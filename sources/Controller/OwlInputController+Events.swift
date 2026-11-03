//
//  OwlInputController+Events.swift
//  Owltype — AI Writing Auxiliary Subsystem (Milestone M6 / Issue #394)
//
//  Handles keyboard events and hotkeys for the AI writing auxiliary panel:
//  1. Intercepting the pure Swift "/ai" sequence via OwlAICommandDetector
//  2. Handling the Shift+K global shortcut (capturing typing, selection, or standalone context)
//  3. Status menu invocation ("AI 写作助手 (⇧K)")
//

import AppKit
import Carbon
import Foundation
import InputMethodKit

extension OwlInputController {

  /// Intercepts the "/ai" typed sequence and summons the AI conversation panel.
  func handleAICommandDetector(_ event: NSEvent) -> Bool {
    guard OwlAIWritingSettings.isEnabled else {
      if aiCommandDetector.isArmed {
        aiCommandDetector.reset()
      }
      return false
    }

    // Command/Option/Control chords never match the bare "/ai" sequence.
    let flags = event.modifierFlags.intersection([.control, .option, .command])
    guard flags.isEmpty else {
      let pending = aiCommandDetector.flushPendingText()
      if !pending.isEmpty {
        client?.insertText(pending, replacementRange: .empty)
      }
      return false
    }

    if event.keyCode == UInt16(kVK_Delete) {
      if aiCommandDetector.isArmed {
        aiCommandDetector.reset()
        return true
      }
      return false
    }

    guard let chars = event.characters, !chars.isEmpty else {
      return false
    }

    let result = aiCommandDetector.process(character: chars)
    if result.isTriggered {
      invokeAIWritingFromTyping()
      return true
    }

    if result.shouldFlush.slash {
      if result.shouldFlush.a {
        client?.insertText("/a", replacementRange: .empty)
      } else {
        client?.insertText("/", replacementRange: .empty)
      }
      // A second slash flushes the old prefix but remains buffered as a new command.
      return aiCommandDetector.isArmed
    }

    if aiCommandDetector.isArmed {
      return true
    }

    return false
  }

  /// Handles the Shift+K hotkey: checks composing (typing), selection, or standalone.
  func handleAIWritingHotKey(_ event: NSEvent) -> Bool {
    guard OwlAIWritingSettings.isEnabled else { return false }

    let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
    guard flags == [.shift], event.keyCode == UInt16(kVK_ANSI_K) else {
      return false
    }

    let isComposing = !preedit.isEmpty || (engineSession?.composition()?.commitTextPreview?.isEmpty == false)
    if isComposing {
      invokeAIWritingFromTyping()
      return true
    }

    let selection = MainActor.assumeIsolated {
      NSApp.owlAppDelegate.selectionMenuCoordinator?.readCurrentSelection()
    }
    if let snapshot = selection, !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      _ = MainActor.assumeIsolated {
        OwlAIWindow.shared.show(context: .selection(snapshot: snapshot))
      }
      return true
    }

    _ = MainActor.assumeIsolated {
      OwlAIWindow.shared.show(context: .standalone)
    }
    return true
  }

  /// Clears host composition and invokes the AI writing window with `.typing` context.
  func invokeAIWritingFromTyping() {
    let originalPreedit = self.preedit
    clearHostComposition()
    engineSession?.clearComposition()
    hidePalettes()
    preedit = ""
    let clientBundleID = client?.bundleIdentifier() ?? currentApp
    _ = MainActor.assumeIsolated {
      OwlAIWindow.shared.show(
        context: .typing(
          client: self.client,
          preedit: originalPreedit,
          frontmostApp: NSWorkspace.shared.frontmostApplication,
          bundleID: clientBundleID
        )
      )
    }
  }

  /// Status menu item handler: "AI 写作助手 (⇧K)".
  @objc func showOwltypeAIWritingAssistant() {
    OwlLatencyTrace.event("button.open.aiWritingAssistant")
    let isComposing = !preedit.isEmpty || (engineSession?.composition()?.commitTextPreview?.isEmpty == false)
    if isComposing {
      invokeAIWritingFromTyping()
    } else {
      let selection = MainActor.assumeIsolated {
        NSApp.owlAppDelegate.selectionMenuCoordinator?.readCurrentSelection()
      }
      if let snapshot = selection, !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        _ = MainActor.assumeIsolated {
          OwlAIWindow.shared.show(context: .selection(snapshot: snapshot))
        }
      } else {
        _ = MainActor.assumeIsolated {
          OwlAIWindow.shared.show(context: .standalone)
        }
      }
    }
  }
}
