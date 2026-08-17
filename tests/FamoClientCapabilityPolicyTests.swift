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

  func testToDesktopBundlePrefixIsElectron() {
    // 08-17 真机实锤：Cursor（ToDesktop 打包，com.todesktop.230313mzl4w4u92）不在旧名单里，
    // delayedCandidatePositioning 落成 notNeeded → 候选窗钉在陈旧锚点、不跟随光标。
    // ToDesktop 家族 bundle ID 一律是 com.todesktop.<随机串>，前缀判定整族覆盖。
    let cursor = policy.evaluate(.init(host: .init(bundleID: "com.todesktop.230313mzl4w4u92")))
    XCTAssertFalse(cursor.selectedRange.allowed)
    XCTAssertFalse(cursor.replacementRange.allowed)
    XCTAssertFalse(cursor.surroundingText.allowed)
    XCTAssertTrue(cursor.delayedCandidatePositioning.allowed)
    XCTAssertEqual(cursor.delayedCandidatePositioning.reason, .delayedForElectronClient)
  }

  func testLinksElectronFrameworkFactMarksUnknownBundleAsElectron() {
    // 通用检测的策略侧：宿主包里真带 Electron Framework（运行时事实）就按 Electron 处理，
    // 无论 bundle ID 认不认识——这是「不再维护名单」的关键一环。
    let detected = policy.evaluate(.init(host: .init(
      bundleID: "com.example.some-future-electron-app", linksElectronFramework: true
    )))
    XCTAssertFalse(detected.replacementRange.allowed)
    XCTAssertTrue(detected.delayedCandidatePositioning.allowed)
    XCTAssertEqual(detected.delayedCandidatePositioning.reason, .delayedForElectronClient)

    // 同一个未知 bundle、没有该事实 → 仍走 default，证明判定确实来自这个输入。
    let plain = policy.evaluate(.init(host: .init(bundleID: "com.example.some-future-electron-app")))
    XCTAssertTrue(plain.replacementRange.allowed)
    XCTAssertFalse(plain.delayedCandidatePositioning.allowed)
  }

  func testElectronFrameworkNameSniffing() {
    // 探测器的纯核心：框架目录名单里认 `Electron Framework*`（Cursor/VS Code/Slack 实测
    // 都是这个标准名），普通框架不误伤。
    XCTAssertTrue(FamoElectronHostDetector.frameworkNamesLinkElectron(
      ["Squirrel.framework", "Electron Framework.framework"]
    ))
    XCTAssertTrue(FamoElectronHostDetector.frameworkNamesLinkElectron(["electron framework.framework"]))
    XCTAssertFalse(FamoElectronHostDetector.frameworkNamesLinkElectron(
      ["Sparkle.framework", "Mantle.framework"]
    ))
    XCTAssertFalse(FamoElectronHostDetector.frameworkNamesLinkElectron([]))
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
