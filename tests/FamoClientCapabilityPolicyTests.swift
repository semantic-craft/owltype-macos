//
//  FamoClientCapabilityPolicyTests.swift
//  FamoTests
//

import XCTest
@testable import Famo

final class FamoClientCapabilityPolicyTests: XCTestCase {
  private let policy = FamoClientCapabilityPolicy()

  func testDefaultAppKitClientAllowsRangeAndCaretButNeverNonzeroAttributes() {
    let decisions = policy.evaluate(.init(host: .init(bundleID: "com.apple.TextEdit")))
    XCTAssertTrue(decisions.selectedRange.allowed)
    XCTAssertTrue(decisions.replacementRange.allowed)
    XCTAssertTrue(decisions.caretAttributes.allowed)
    XCTAssertFalse(decisions.nonzeroCharacterIndexAttributes.allowed)
    XCTAssertEqual(decisions.nonzeroCharacterIndexAttributes.reason, .deniedNonzeroCharacterIndexHotPath)
  }

  func testOfficeDeniesSelectedAndReplacementRanges() {
    for bundle in ["com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint"] {
      let decisions = policy.evaluate(.init(host: .init(bundleID: bundle)))
      XCTAssertFalse(decisions.selectedRange.allowed, bundle)
      XCTAssertFalse(decisions.replacementRange.allowed, bundle)
      XCTAssertEqual(decisions.selectedRange.reason, .deniedOfficeRange)
    }
  }

  func testWordDeniesInputModeSwitch() {
    let decisions = policy.evaluate(.init(host: .init(bundleID: "com.microsoft.Word")))
    XCTAssertFalse(decisions.inputModeSwitch.allowed)
    XCTAssertEqual(decisions.inputModeSwitch.reason, .deniedOfficeInputMode)
  }

  func testChromiumAndGoogleDocsDenyContextReadsAndRequestDelayedPositioning() {
    let chrome = policy.evaluate(.init(host: .init(bundleID: "com.google.Chrome")))
    XCTAssertFalse(chrome.surroundingText.allowed)
    XCTAssertTrue(chrome.delayedCandidatePositioning.allowed)
    XCTAssertEqual(chrome.delayedCandidatePositioning.reason, .delayedForChromiumClient)

    let docs = policy.evaluate(.init(host: .init(
      bundleID: "com.google.Chrome",
      windowTitle: "Contract Draft - Google Docs",
      urlHost: "docs.google.com"
    )))
    XCTAssertFalse(docs.surroundingText.allowed)
    XCTAssertEqual(docs.surroundingText.reason, .deniedGoogleDocsClient)
    XCTAssertTrue(docs.delayedCandidatePositioning.allowed)
    XCTAssertEqual(docs.delayedCandidatePositioning.reason, .delayedForGoogleDocsClient)
  }

  func testElectronDeniesRangesAndRequestsDelayedPositioning() {
    // claudefordesktop/codex：07-21 真机实锤（`<` 菜单 → `<<>`）后补入清单——Electron 宿主
    // 的 insertText(replacementRange:) 只认位置不删除，写路径必须拿不到 replacementRange。
    for bundle in ["com.microsoft.VSCode", "com.anthropic.claudefordesktop", "com.openai.codex"] {
      let decisions = policy.evaluate(.init(host: .init(bundleID: bundle)))
      XCTAssertFalse(decisions.selectedRange.allowed, bundle)
      XCTAssertFalse(decisions.replacementRange.allowed, bundle)
      XCTAssertFalse(decisions.surroundingText.allowed, bundle)
      XCTAssertTrue(decisions.delayedCandidatePositioning.allowed, bundle)
    }
  }

  func testAutoPairWriteTrustSignalOnlyComesFromAppKitAllowlist() {
    // 自动配对写路径（自替换/跳过覆写）只信 allowedAppKitClient——allowedDefault 的宿主
    // （未知 App，可能是没进清单的 Electron）读可以、写语义不可信。锁 reason 语义本身。
    let textEdit = policy.evaluate(.init(host: .init(bundleID: "com.apple.TextEdit")))
    XCTAssertEqual(textEdit.replacementRange.reason, .allowedAppKitClient)
    let unknown = policy.evaluate(.init(host: .init(bundleID: "com.example.unknownapp")))
    XCTAssertTrue(unknown.replacementRange.allowed)
    XCTAssertEqual(unknown.replacementRange.reason, .allowedDefault, "未知宿主必须是 default，不得冒充 AppKit 白名单")
  }

  func testSafariAddressBarIsConservative() {
    let decisions = policy.evaluate(.init(host: .init(
      bundleID: "com.apple.Safari",
      fieldRole: "AXSearchField",
      fieldIdentifierSignal: "UnifiedSearchField"
    )))
    XCTAssertFalse(decisions.selectedRange.allowed)
    XCTAssertFalse(decisions.surroundingText.allowed)
    XCTAssertFalse(decisions.contextMenu.allowed)
    XCTAssertTrue(decisions.delayedCandidatePositioning.allowed)
  }

  func testSecureAndPasswordLikeContextsDenyTextReadsAndEnablePrivacyComposition() {
    let secure = policy.evaluate(.init(
      host: .init(bundleID: "com.apple.Terminal"),
      privacy: .init(isSecureInputEnabled: true)
    ))
    XCTAssertFalse(secure.surroundingText.allowed)
    XCTAssertEqual(secure.surroundingText.reason, .deniedTerminalSecureInput)
    XCTAssertFalse(secure.selectedRange.allowed)
    XCTAssertTrue(secure.privacyComposition.allowed)

    let password = policy.evaluate(.init(
      host: .init(bundleID: "com.apple.TextEdit", fieldIdentifierSignal: "password field"),
      privacy: .init(isPasswordLike: true)
    ))
    XCTAssertFalse(password.surroundingText.allowed)
    XCTAssertEqual(password.surroundingText.reason, .deniedPasswordLikeContext)
    XCTAssertTrue(password.privacyComposition.allowed)
  }

  func testLauncherSearchClientsDenyContextMenuAndHostReads() {
    for bundle in ["com.apple.Spotlight", "com.raycast.macos"] {
      let decisions = policy.evaluate(.init(host: .init(bundleID: bundle)))
      XCTAssertFalse(decisions.contextMenu.allowed, bundle)
      XCTAssertFalse(decisions.surroundingText.allowed, bundle)
      XCTAssertFalse(decisions.caretAttributes.allowed, bundle)
    }
  }

  func testUserWorkaroundOverrideReturnsSafeDiagnosticReason() {
    let decisions = policy.evaluate(.init(
      host: .init(bundleID: "com.example.SafeEditor"),
      workarounds: .init(forceDeniedCapabilitiesByBundleID: [
        "com.example.SafeEditor": [.surroundingText]
      ])
    ))
    XCTAssertFalse(decisions.surroundingText.allowed)
    XCTAssertEqual(decisions.surroundingText.diagnosticReason, "userForcedDeny")
  }
}
