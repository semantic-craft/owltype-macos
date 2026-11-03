# Voice input

## Overview

Recording, speech transcription, optional text polishing and host insertion coordinated from a captured input target. AVFoundation and AppKit provide native effects; injectable recording, ASR, polishing and transport protocols support isolated checks.

## Interface

- `OwlAudioRecordingProtocol` defines recording, stop/cancel and level/autostop callbacks; `OwlVoiceAudioRecorder` implements it and `OwlWAVPacker.pack16kMono` builds WAV bytes. [OwlAudioRecordingProtocol.swift:OwlAudioRecordingProtocol] [OwlVoiceAudioRecorder.swift:OwlVoiceAudioRecorder] [OwlWAVPacker.swift:pack16kMono]
- `OwlMicrophonePermission` exposes authorization/request/settings actions; `OwlVoiceError` and `OwlVoiceAudioError` describe failures. [OwlMicrophonePermission.swift:OwlMicrophonePermission] [OwlVoiceError.swift:OwlVoiceError] [OwlAudioRecordingProtocol.swift:OwlVoiceAudioError]
- `OwlVoiceASRServiceProtocol` / `OwlVoiceGrokASRClient.transcribe` accept WAV data and an optional prompt. The default endpoint is xAI audio/transcriptions with grok-asr. [OwlVoiceGrokASRClient.swift:OwlVoiceGrokASRClient]
- `OwlVoicePolishServiceProtocol` / `OwlVoiceDeepSeekPolisher` accept transcript, hotwords and preceding context, with timeout/sanitization/fallback helpers. The default endpoint is DeepSeek chat/completions. [OwlVoicePolishServiceProtocol.swift:OwlVoicePolishServiceProtocol] [OwlVoiceDeepSeekPolisher.swift:OwlVoiceDeepSeekPolisher]
- `OwlVoiceHotwordsExtracting` / `OwlVoiceHotwordsExtractor` collect prioritized words and construct byte-bounded prompts. [OwlVoiceHotwordsExtractor.swift:OwlVoiceHotwordsExtractor]
- MainActor `OwlVoiceInputCoordinator` exposes key handling, start, transcribe, cancel and delivery; `OwlVoiceTargetSnapshot` retains target/context values and weak IMK references. Capsule state, view/model and nonactivating panel display recording/result states. [OwlVoiceInputCoordinator.swift:OwlVoiceInputCoordinator] [OwlVoiceInputCoordinator.swift:OwlVoiceTargetSnapshot] [OwlVoiceCapsuleState.swift:OwlVoiceCapsuleState] [OwlVoiceCapsuleView.swift:OwlVoiceCapsuleView] [OwlVoiceCapsulePanel.swift:OwlVoiceCapsulePanel]
- `OwlVoiceNetworkTransport` has URLSession and stub implementations; `OwlVoiceSettings` stores preferences and `OwlVoiceKeychain` manages provider credentials. [OwlVoiceNetworkTransport.swift:OwlVoiceNetworkTransport] [OwlVoiceSettings.swift:OwlVoiceSettings] [OwlVoiceKeychain.swift:OwlVoiceKeychain]

## Invariants

- Recording requires microphone authorization and rejects duplicate starts. PCM is converted to 16 kHz, 16-bit mono and capped at 1,920,000 bytes; stopping rejects duration below 0.30 s and peak RMS below 0.008. The packer discards an odd trailing byte. [OwlVoiceAudioRecorder.swift:startRecording] [OwlVoiceAudioRecorder.swift:appendPCMData] [OwlVoiceAudioRecorder.swift:stopRecording] [OwlWAVPacker.swift:pack16kMono]
- Secure input blocks recording start. Shortcut release before 0.300 s enters toggle mode; Space locks recording; Escape cancels an active mode. [OwlVoiceInputCoordinator.swift:startVoiceInput] [OwlVoiceInputCoordinator.swift:handleKeyEvent]
- ASR rejects fewer than 44 audio bytes, missing credentials, non-200 responses and empty transcripts. `polish` propagates CancellationError but falls back to trimmed original text on other failures; its validation checks nonempty output and a length ceiling, not semantic fidelity. [OwlVoiceGrokASRClient.swift:transcribe] [OwlVoiceDeepSeekPolisher.swift:polish] [OwlVoiceDeepSeekPolisher.swift:validate]
- Hotwords prioritize pins, custom words and repeated bigrams, sanitize/deduplicate tokens, and assemble whole words within the UTF-8 budget. [OwlVoiceHotwordsExtractor.swift:extractHotwords] [OwlVoiceHotwordsExtractor.swift:mergeAndDeduplicate] [OwlVoiceHotwordsExtractor.swift:buildPrompt]
- Voice and polishing default to disabled. Test storage prevents Keychain reads/writes; default network clients also consult their provider environment variables before Keychain. [OwlVoiceSettings.swift:isEnabled] [OwlVoiceSettings.swift:isPolishEnabled] [OwlVoiceKeychain.swift:OwlVoiceKeychain] [OwlVoiceGrokASRClient.swift:init] [OwlVoiceDeepSeekPolisher.swift:init]

## Side Effects

- Captures microphone buffers, starts/stops audio taps, requests microphone permission, displays floating UI and schedules timers/tasks. [OwlVoiceAudioRecorder.swift:OwlVoiceAudioRecorder] [OwlMicrophonePermission.swift:request] [OwlVoiceInputCoordinator.swift:OwlVoiceInputCoordinator]
- Reads SQLite tables pinned_candidates, user_dictionary_operations and personal_bigram through a read-only connection, and reads in-memory pinned words. [OwlVoiceHotwordsExtractor.swift:extractHotwords]
- Sends audio/context/hotwords to ASR and transcript/context/hotwords to the optional polishing provider through the injected transport. [OwlVoiceGrokASRClient.swift:transcribe] [OwlVoiceDeepSeekPolisher.swift:performNetworkRequest]
- Writes host text through IMK when the captured client survives; otherwise activates the captured application and attempts paste, then copy-only fallback. The completed HUD is set before delivery and does not establish host acceptance. [OwlVoiceInputCoordinator.swift:deliverFinalText]
- Persists defaults and provider Keychain items; stub transport records requests in memory under NSLock. [OwlVoiceSettings.swift:OwlVoiceSettings] [OwlVoiceKeychain.swift:OwlVoiceKeychain] [OwlVoiceNetworkTransport.swift:OwlStubVoiceTransport]

## Verification

From the repository root, run `make test` (the Makefile builds dependencies and prepares the dictionary seed before Xcode tests). This documentation pass did not execute the test target.
