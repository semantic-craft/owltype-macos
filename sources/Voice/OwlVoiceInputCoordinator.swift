//
//  OwlVoiceInputCoordinator.swift
//  Owltype — Voice Input Subsystem
//

import AppKit
import AVFoundation
import Foundation
import InputMethodKit

protocol OwlVoicePolishServiceProtocol: Sendable {
  func polish(rawTranscript: String, hotwords: [String], preContext: String?) async throws -> String
}

struct OwlVoiceTargetSnapshot: @unchecked Sendable {
  weak var client: IMKTextInput?
  let frontmostApp: NSRunningApplication?
  let caretAnchor: NSRect
  let preContext: String

  init(
    client: IMKTextInput? = nil,
    frontmostApp: NSRunningApplication? = nil,
    caretAnchor: NSRect = .zero,
    preContext: String = ""
  ) {
    self.client = client
    self.frontmostApp = frontmostApp
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

  static let rightOptionKeyCode: UInt16 = 61 // kVK_RightOption
  private static let deviceLeftOptionMask: UInt = 0x00000020 // NX_DEVICELALTKEYMASK
  private static let deviceRightOptionMask: UInt = 0x00000040 // NX_DEVICERALTKEYMASK

  private(set) var mode: Mode = .idle
  private(set) var targetSnapshot: OwlVoiceTargetSnapshot?
  private(set) var isHoldingRightOption = false

  private var durationTimer: Timer?
  private var dismissTimer: Timer?
  private var recognitionTask: Task<Void, Never>?
  private var globalEventMonitor: Any?
  private var lastHandledEventTimestamp: TimeInterval = -1
  private var lastHandledEventType: NSEvent.EventType?
  private var lastHandledKeyCode: UInt16 = .max
  // Cancellation is cooperative. Every callback must still belong to this recording.
  private var voiceGeneration: UInt64 = 0

  // Dependencies (Injected or defaulted for production & offline testing)
  var audioRecorder: OwlAudioRecordingProtocol = OwlVoiceAudioRecorder.shared
  var asrClient: OwlVoiceASRServiceProtocol = OwlVoiceASRClient.shared
  var hotwordsExtractor: OwlVoiceHotwordsExtracting = OwlVoiceHotwordsExtractor.shared
  var postProcessor: OwlVoicePolishServiceProtocol? = OwlVoicePolisher.shared
  var hudPanel: OwlVoiceCapsulePanel = OwlVoiceCapsulePanel.shared

  var targetSnapshotProvider: (() -> OwlVoiceTargetSnapshot)?
  var secureInputChecker: (() -> Bool)?
  var microphonePermissionStatusProvider: (() -> AVAuthorizationStatus)?
  var microphonePermissionRequester: (() async -> Bool)?
  var isEnabledOverride: Bool?
  var holdRightOptionEnabledOverride: Bool?
  var physicalRightOptionHeldProvider: (() -> Bool)? = OwlDefaults.isRunningUnitTests
    ? nil
    : { CGEventSource.keyState(.hidSystemState, key: 61) }

  var isVoiceEnabled: Bool {
    isEnabledOverride ?? OwlVoiceSettings.isEnabled
  }

  var isHoldRightOptionEnabled: Bool {
    holdRightOptionEnabledOverride ?? OwlVoiceSettings.holdRightOptionEnabled
  }

  var isPolishEnabledOverride: Bool?
  var isPolishEnabled: Bool {
    isPolishEnabledOverride ?? OwlVoiceSettings.isPolishEnabled
  }

  init() {}

  // MARK: - Global Event Monitor (MSIME Right Option Hold Fallback)

  /// Installs a lightweight global monitor for `.flagsChanged` and `.keyDown` so holding Right Option
  /// works even in hosts that do not forward bare modifier key transitions to `IMKInputController.handle`.
  func startGlobalMonitor() {
    guard !OwlDefaults.isRunningUnitTests, globalEventMonitor == nil else { return }
    globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
      Task { @MainActor [weak self] in
        guard let self, self.isVoiceEnabled else { return }
        guard event.timestamp != self.lastHandledEventTimestamp
           || event.type != self.lastHandledEventType
           || event.keyCode != self.lastHandledKeyCode else {
          return
        }
        guard OwlInstaller.currentInputSourceID()?.hasPrefix(OwlInstaller.inputSourcePrefix) == true else {
          return
        }
        _ = self.handleKeyEvent(event)
      }
    }
  }

  func stopGlobalMonitor() {
    if let monitor = globalEventMonitor {
      NSEvent.removeMonitor(monitor)
      globalEventMonitor = nil
    }
  }

  // MARK: - Key Event Handling

  /// Intercepts key events. Returns true if consumed by the voice input subsystem.
  func handleKeyEvent(_ event: NSEvent) -> Bool {
    guard isVoiceEnabled else { return false }

    if event.timestamp > 0 {
      lastHandledEventTimestamp = event.timestamp
      lastHandledEventType = event.type
      lastHandledKeyCode = event.keyCode
    }

    if event.type == .flagsChanged {
      return handleFlagsChangedEvent(event)
    }

    if event.type == .keyDown {
      if isHoldingRightOption, case .holding = mode {
        if event.keyCode == 53 { // Escape
          cancelVoiceInput()
          return true
        }
        if event.keyCode == 49 { // Space -> lock hands-free
          if case let .holding(t0) = mode {
            mode = .handsFreeLocked(startTime: t0)
            updateRecordingHUD(level: 0)
          }
          return true
        }
        if !event.isARepeat {
          // ChordCancel (msime VoiceHoldShortcut.h): Option + another key is a keyboard shortcut
          // or Option character, not speech. Cancel recording and pass the key chord to the host.
          cancelVoiceInput()
          return false
        }
      }

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
    } else if event.type == .keyUp {
      if event.keyCode == 49, case .handsFreeLocked = mode {
        return true
      }
    }

    return false
  }

  private func handleFlagsChangedEvent(_ event: NSEvent) -> Bool {
    guard isHoldRightOptionEnabled else { return false }

    if event.keyCode == Self.rightOptionKeyCode {
      if Self.isRightOptionPressFlags(event.modifierFlags) {
        switch mode {
        case .idle:
          isHoldingRightOption = true
          startVoiceInput()
          if mode == .idle {
            isHoldingRightOption = false
          }
          return true
        case .toggled, .handsFreeLocked:
          isHoldingRightOption = false
          finishRecordingAndTranscribe()
          return true
        case .holding:
          return true
        default:
          return false
        }
      } else if isHoldingRightOption {
        isHoldingRightOption = false
        switch mode {
        case .holding:
          finishRecordingAndTranscribe()
          return true
        case .handsFreeLocked:
          return true
        default:
          return true
        }
      }
    } else if isHoldingRightOption, !Self.isRightOptionStillHeld(event.modifierFlags) {
      isHoldingRightOption = false
      if case .holding = mode {
        finishRecordingAndTranscribe()
        return true
      }
    }

    return false
  }

  static func isRightOptionPressFlags(_ flags: NSEvent.ModifierFlags) -> Bool {
    let relevant = flags.intersection([.command, .option, .control, .shift])
    guard relevant == [.option] else { return false }
    let raw = flags.rawValue
    let deviceOptionBits = raw & (deviceLeftOptionMask | deviceRightOptionMask)
    if deviceOptionBits != 0 {
      return (raw & deviceRightOptionMask) != 0 && (raw & deviceLeftOptionMask) == 0
    }
    return true
  }

  private static func isRightOptionStillHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
    guard flags.contains(.option) else { return false }
    let raw = flags.rawValue
    let deviceOptionBits = raw & (deviceLeftOptionMask | deviceRightOptionMask)
    if deviceOptionBits != 0 {
      return (raw & deviceRightOptionMask) != 0
    }
    return true
  }

  /// Polls physical HID Right Option state as a fallback when macOS drops `.flagsChanged` on focus shifts.
  func pollPhysicalRightOptionReleaseIfNeeded() {
    guard isHoldingRightOption,
          case .holding = mode,
          let provider = physicalRightOptionHeldProvider else {
      return
    }
    if !provider() {
      isHoldingRightOption = false
      finishRecordingAndTranscribe()
    }
  }

  // MARK: - Workflow Actions

  func startVoiceInput() {
    guard mode == .idle else { return }
    voiceGeneration &+= 1
    let generation = voiceGeneration
    dismissTimer?.invalidate()
    dismissTimer = nil
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
        client: client,
        frontmostApp: frontApp,
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
          guard self.voiceGeneration == generation else { return }
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
    let generation = voiceGeneration
    do {
      mode = initialMode
      hudPanel.present(state: .recording(level: 0.0, duration: 0.0, isHandsFreeLocked: false), anchor: anchor)

      audioRecorder.audioLevelHandler = { [weak self] level in
        Task { @MainActor [weak self] in
          guard let self, self.voiceGeneration == generation else { return }
          self.updateRecordingHUD(level: level)
        }
      }

      audioRecorder.autoStopHandler = { [weak self] in
        Task { @MainActor [weak self] in
          guard let self, self.voiceGeneration == generation else { return }
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
    switch mode {
    case .holding, .toggled, .handsFreeLocked: break
    default: return
    }
    isHoldingRightOption = false
    let generation = voiceGeneration
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
    recognitionTask = Task { @MainActor [weak self] in
      guard let self, self.voiceGeneration == generation else { return }
      defer {
        if self.voiceGeneration == generation { self.recognitionTask = nil }
      }
      do {
        let hotwords = self.hotwordsExtractor.extractHotwords(limit: 50)
        let prompt = self.hotwordsExtractor.buildPrompt(preContext: snapshot?.preContext, hotwords: hotwords, maxBytes: 800)
        let rawTranscript = try await self.asrClient.transcribe(
          audioWavData: wavData, prompt: prompt.isEmpty ? nil : prompt)
        guard self.voiceGeneration == generation else { return }
        try Task.checkCancellation()

        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          self.cancelVoiceInput()
          return
        }

        if self.isPolishEnabled, let polisher = self.postProcessor {
          self.mode = .polishing(rawTranscript: trimmed)
          self.hudPanel.updateState(.polishing(rawTranscript: trimmed), anchor: anchor)
          do {
            let polishedText = try await polisher.polish(
              rawTranscript: trimmed, hotwords: hotwords, preContext: snapshot?.preContext)
            guard self.voiceGeneration == generation else { return }
            try Task.checkCancellation()
            self.deliverFinalText(polishedText)
          } catch {
            guard self.voiceGeneration == generation else { return }
            if Task.isCancelled || error is CancellationError {
              self.cancelVoiceInput()
            } else {
              // Only the current recording may degrade to its raw transcript.
              self.deliverFinalText(trimmed)
            }
          }
        } else {
          self.deliverFinalText(trimmed)
        }
      } catch {
        guard self.voiceGeneration == generation else { return }
        if Task.isCancelled || error is CancellationError {
          self.cancelVoiceInput()
        } else {
          self.mode = .failed(error.localizedDescription)
          self.hudPanel.present(state: .failed(error.localizedDescription), anchor: anchor)
          self.scheduleDismiss(after: 2.0)
        }
      }
    }
  }

  func cancelVoiceInput() {
    voiceGeneration &+= 1
    isHoldingRightOption = false
    dismissTimer?.invalidate()
    dismissTimer = nil
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

    _ = OwlTemplateHostDelivery.insertCaretOrFallback(
      text,
      client: targetSnapshot?.client,
      frontmostApp: targetSnapshot?.frontmostApp
    )
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
    let generation = voiceGeneration
    durationTimer?.invalidate()
    durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.voiceGeneration == generation else { return }
        self.pollPhysicalRightOptionReleaseIfNeeded()
        guard self.voiceGeneration == generation else { return }
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
    let generation = voiceGeneration
    dismissTimer?.invalidate()
    dismissTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.voiceGeneration == generation else { return }
        self.hudPanel.dismiss()
        self.mode = .idle
      }
    }
  }

  private func isSecureInputActive() -> Bool {
    if let custom = secureInputChecker {
      return custom()
    }
    return IsSecureEventInputEnabled()
  }
}
