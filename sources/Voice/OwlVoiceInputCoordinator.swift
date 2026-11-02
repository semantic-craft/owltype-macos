//
//  OwlVoiceInputCoordinator.swift
//  Owltype — Voice Input Subsystem
//

import AppKit
import AVFoundation
import Foundation
import InputMethodKit

struct OwlVoiceTargetSnapshot: @unchecked Sendable {
  weak var controller: OwlInputController?
  weak var client: IMKTextInput?
  let frontmostApp: NSRunningApplication?
  let bundleIdentifier: String?
  let capturedAt: Date
  let caretAnchor: NSRect
  public let preContext: String

  init(
    controller: OwlInputController? = nil,
    client: IMKTextInput? = nil,
    frontmostApp: NSRunningApplication? = nil,
    bundleIdentifier: String? = nil,
    capturedAt: Date = Date(),
    caretAnchor: NSRect = .zero,
    preContext: String = ""
  ) {
    self.controller = controller
    self.client = client
    self.frontmostApp = frontmostApp
    self.bundleIdentifier = bundleIdentifier
    self.capturedAt = capturedAt
    self.caretAnchor = caretAnchor
    self.preContext = preContext
  }
}

@MainActor
final class OwlVoiceInputCoordinator {
  static let shared = OwlVoiceInputCoordinator()

  enum Mode: Equatable, Sendable {
    case idle
    case holding(startTime: Date)
    case toggled(startTime: Date)
    case handsFreeLocked(startTime: Date)
    case recognizing
    case polishing(rawTranscript: String)
    case completed(finalText: String)
    case failed(String)
  }

  private(set) var mode: Mode = .idle
  private(set) var targetSnapshot: OwlVoiceTargetSnapshot?

  private var durationTimer: Timer?
  private var dismissTimer: Timer?
  private var recognitionTask: Task<Void, Never>?

  // Dependencies (Injected or defaulted for production & offline testing)
  var audioRecorder: OwlAudioRecordingProtocol = OwlVoiceAudioRecorder.shared
  var asrClient: OwlVoiceASRServiceProtocol = OwlVoiceGrokASRClient.shared
  var hotwordsExtractor: OwlVoiceHotwordsExtracting = OwlVoiceHotwordsExtractor.shared
  var postProcessor: OwlVoicePolishServiceProtocol? = OwlVoiceDeepSeekPolisher.shared
  var hudPanel: OwlVoiceCapsulePanel = OwlVoiceCapsulePanel.shared

  var shortcutMatcher: ((NSEvent) -> Bool)?
  var targetSnapshotProvider: (() -> OwlVoiceTargetSnapshot)?
  var secureInputChecker: (() -> Bool)?
  var microphonePermissionStatusProvider: (() -> AVAuthorizationStatus)?
  var microphonePermissionRequester: (() async -> Bool)?
  var isEnabledOverride: Bool?

  var isVoiceEnabled: Bool {
    isEnabledOverride ?? OwlVoiceSettings.isEnabled
  }

  var isPolishEnabledOverride: Bool?
  var isPolishEnabled: Bool {
    isPolishEnabledOverride ?? OwlVoiceSettings.isPolishEnabled
  }

  init() {}

  // MARK: - Key Event Handling

  /// Fallback trigger when a hotkey tap fires without an `NSEvent`.
  func handleVoiceHotKeyTrigger() {
    guard isVoiceEnabled else { return }
    switch mode {
    case .idle:
      startVoiceInput()
    case .toggled, .handsFreeLocked:
      finishRecordingAndTranscribe()
    default:
      break
    }
  }

  /// Intercepts key events. Returns true if consumed by the voice input subsystem.
  func handleKeyEvent(_ event: NSEvent) -> Bool {
    guard isVoiceEnabled else { return false }

    if event.type == .keyDown {
      if event.keyCode == 53 { // Escape
        if mode != .idle {
          cancelVoiceInput()
          return true
        }
      }

      if event.keyCode == 49 { // Space
        switch mode {
        case let .holding(t0), let .toggled(t0):
          mode = .handsFreeLocked(startTime: t0)
          updateRecordingHUD(level: 0)
          return true
        case .handsFreeLocked:
          return true
        default:
          break
        }
      }

      if isVoiceShortcut(event) {
        switch mode {
        case .idle:
          startVoiceInput()
          return true
        case .toggled, .handsFreeLocked:
          finishRecordingAndTranscribe()
          return true
        case .holding:
          return true // Ignore auto-repeat keyDown
        default:
          break
        }
      }
    } else if event.type == .keyUp {
      if isVoiceShortcutKeyUp(event) {
        switch mode {
        case let .holding(t0):
          let elapsed = Date().timeIntervalSince(t0)
          if elapsed < 0.300 {
            // Clicked quickly -> transition to toggle mode
            mode = .toggled(startTime: t0)
            updateRecordingHUD(level: 0)
          } else {
            // Held to speak -> finish recording
            finishRecordingAndTranscribe()
          }
          return true
        case .handsFreeLocked:
          // Ignore keyUp while locked in hands-free mode
          return true
        default:
          break
        }
      }
    }

    return false
  }

  // MARK: - Workflow Actions

  func startVoiceInput() {
    if isSecureInputActive() {
      hudPanel.present(state: .failed("密码输入模式下已禁用语音输入"), anchor: .zero)
      scheduleDismiss(after: 2.0)
      return
    }

    // 1. Lock Target Snapshot
    if let customProvider = targetSnapshotProvider {
      targetSnapshot = customProvider()
    } else {
      let controller = NSApp.owlAppDelegate.runtime.activatedInputController
      let client = controller?.client
      let frontApp = NSWorkspace.shared.frontmostApplication
      let anchor = NSApp.owlAppDelegate.currentHostCaretAnchor

      var preContext = ""
      if let client {
        let sel = client.selectedRange()
        if sel.location != NSNotFound && sel.location > 0 {
          let cursor = sel.location
          let length = min(cursor, 200)
          let start = max(0, cursor - length)
          let range = NSRange(location: start, length: length)
          if let sub = client.attributedSubstring(from: range)?.string {
            preContext = sub
          }
        }
      }

      targetSnapshot = OwlVoiceTargetSnapshot(
        controller: controller,
        client: client,
        frontmostApp: frontApp,
        bundleIdentifier: frontApp?.bundleIdentifier,
        capturedAt: Date(),
        caretAnchor: anchor,
        preContext: preContext
      )
    }

    let anchor = targetSnapshot?.caretAnchor ?? .zero

    let shouldCheckPermission = (microphonePermissionStatusProvider != nil) || (audioRecorder is OwlVoiceAudioRecorder)
    if shouldCheckPermission {
      let currentStatus = microphonePermissionStatusProvider?() ?? OwlMicrophonePermission.status
      if currentStatus == .notDetermined {
        let requester = microphonePermissionRequester ?? { await OwlMicrophonePermission.request() }
        Task { @MainActor [weak self] in
          guard let self else { return }
          let granted = await requester()
          if granted {
            self.beginAudioRecording(anchor: anchor, initialMode: .toggled(startTime: Date()))
          } else {
            self.mode = .idle
            self.hudPanel.present(
              state: .failed(OwlVoiceAudioError.microphonePermissionDenied.localizedDescription),
              anchor: anchor
            )
            self.scheduleDismiss(after: 2.0)
          }
        }
        return
      }
    }

    beginAudioRecording(anchor: anchor, initialMode: .holding(startTime: Date()))
  }

  private func beginAudioRecording(anchor: NSRect, initialMode: Mode) {
    // 2. Start Audio Recording
    do {
      mode = initialMode
      hudPanel.present(state: .recording(level: 0.0, duration: 0.0, isHandsFreeLocked: false), anchor: anchor)

      audioRecorder.audioLevelHandler = { [weak self] level in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.updateRecordingHUD(level: level)
        }
      }

      audioRecorder.autoStopHandler = { [weak self] in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.finishRecordingAndTranscribe()
        }
      }

      try audioRecorder.startRecording()
      startDurationTimer()
    } catch {
      mode = .idle
      hudPanel.present(state: .failed(error.localizedDescription), anchor: anchor)
      scheduleDismiss(after: 2.0)
    }
  }

  func finishRecordingAndTranscribe() {
    stopDurationTimer()

    let wavData: Data
    do {
      wavData = try audioRecorder.stopRecording()
    } catch {
      // Mis-touch guard: duration too short or pure silence
      cancelVoiceInput()
      return
    }

    guard wavData.count >= 44 else {
      cancelVoiceInput()
      return
    }

    let snapshot = targetSnapshot
    let anchor = snapshot?.caretAnchor ?? .zero
    mode = .recognizing
    hudPanel.present(state: .recognizing, anchor: anchor)

    recognitionTask?.cancel()
    recognitionTask = Task { [weak self] in
      guard let self else { return }
      do {
        // Step 1: Grok ASR Transcription with Hotwords Prompt
        let hotwords = self.hotwordsExtractor.extractHotwords(limit: 50)
        let prompt = self.hotwordsExtractor.buildPrompt(preContext: snapshot?.preContext, hotwords: hotwords, maxBytes: 800)
        let promptToSend = prompt.isEmpty ? nil : prompt
        let rawTranscript = try await self.asrClient.transcribe(audioWavData: wavData, prompt: promptToSend)
        try Task.checkCancellation()

        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          await MainActor.run {
            self.cancelVoiceInput()
          }
          return
        }

        // Step 2: Post-Processing Polish (if enabled)
        if self.isPolishEnabled, let polisher = self.postProcessor {
          // Subtitle preview in .polishing
          await MainActor.run {
            self.mode = .polishing(rawTranscript: trimmed)
            self.hudPanel.updateState(.polishing(rawTranscript: trimmed), anchor: anchor)
          }
          do {
            let polishedText = try await polisher.polish(rawTranscript: trimmed, hotwords: hotwords, preContext: snapshot?.preContext)
            try Task.checkCancellation()
            await MainActor.run {
              self.deliverFinalText(polishedText)
            }
          } catch is CancellationError {
            await MainActor.run {
              self.cancelVoiceInput()
            }
          } catch {
            // Degrade gracefully to raw transcript on polish error/timeout
            await MainActor.run {
              self.deliverFinalText(trimmed)
            }
          }
        } else {
          await MainActor.run {
            self.deliverFinalText(trimmed)
          }
        }
      } catch is CancellationError {
        await MainActor.run {
          self.cancelVoiceInput()
        }
      } catch {
        await MainActor.run {
          self.mode = .failed(error.localizedDescription)
          self.hudPanel.present(state: .failed(error.localizedDescription), anchor: anchor)
          self.scheduleDismiss(after: 2.0)
        }
      }
    }
  }

  func cancelVoiceInput() {
    stopDurationTimer()
    recognitionTask?.cancel()
    recognitionTask = nil
    audioRecorder.cancelRecording()
    mode = .idle
    targetSnapshot = nil
    hudPanel.dismiss()
  }

  func deliverFinalText(_ text: String) {
    let anchor = targetSnapshot?.caretAnchor ?? .zero
    mode = .completed(finalText: text)
    hudPanel.updateState(.completed(finalText: text), anchor: anchor)
    scheduleDismiss(after: 1.2)

    // Insertion Ladder:
    // Tier 1: Direct IMK client insert
    if let client = targetSnapshot?.client {
      client.insertText(text, replacementRange: .empty)
      return
    }

    // Tier 2: Simulated ⌘V paste ladder
    if let app = targetSnapshot?.frontmostApp, !app.isActive {
      app.activate()
    }
    let pasted = OwlPasteInserter.paste(text)
    if !pasted {
      // Tier 3: Copy only
      OwlPasteInserter.copyOnly(text)
    }
  }

  // MARK: - Private Helpers

  private func updateRecordingHUD(level: Float) {
    guard case let .holding(t0) = mode else {
      if case let .toggled(t0) = mode {
        let dur = Date().timeIntervalSince(t0)
        hudPanel.present(state: .recording(level: level, duration: dur, isHandsFreeLocked: false), anchor: targetSnapshot?.caretAnchor ?? .zero)
      } else if case let .handsFreeLocked(t0) = mode {
        let dur = Date().timeIntervalSince(t0)
        hudPanel.present(state: .recording(level: level, duration: dur, isHandsFreeLocked: true), anchor: targetSnapshot?.caretAnchor ?? .zero)
      }
      return
    }
    let dur = Date().timeIntervalSince(t0)
    hudPanel.present(state: .recording(level: level, duration: dur, isHandsFreeLocked: false), anchor: targetSnapshot?.caretAnchor ?? .zero)
  }

  private func startDurationTimer() {
    durationTimer?.invalidate()
    durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        switch self.mode {
        case let .holding(t0), let .toggled(t0), let .handsFreeLocked(t0):
          let dur = Date().timeIntervalSince(t0)
          if dur >= OwlVoiceAudioRecorder.maxDuration {
            self.finishRecordingAndTranscribe()
          }
        default:
          break
        }
      }
    }
  }

  private func stopDurationTimer() {
    durationTimer?.invalidate()
    durationTimer = nil
  }

  private func scheduleDismiss(after interval: TimeInterval) {
    dismissTimer?.invalidate()
    dismissTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.hudPanel.dismiss()
        self.mode = .idle
      }
    }
  }

  private func isVoiceShortcut(_ event: NSEvent) -> Bool {
    if let customMatcher = shortcutMatcher {
      return customMatcher(event)
    }
    guard let combo = OwlVoiceSettings.hotkey?.carbonCombo else { return false }
    return OwlHotKeyMatcher.matches(combo, keyCode: event.keyCode, flags: event.modifierFlags)
  }

  private func isVoiceShortcutKeyUp(_ event: NSEvent) -> Bool {
    if isVoiceShortcut(event) { return true }
    if case .holding = mode, let combo = OwlVoiceSettings.hotkey?.carbonCombo {
      return UInt32(event.keyCode) == combo.keyCode
    }
    return false
  }

  private func isSecureInputActive() -> Bool {
    if let custom = secureInputChecker {
      return custom()
    }
    return IsSecureEventInputEnabled()
  }
}
