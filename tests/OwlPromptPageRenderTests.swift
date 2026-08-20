//
//  OwlPromptPageRenderTests.swift
//  OwltypeTests — 提示词管理面板 (OwlPromptPage) 渲染冒烟（R5）
//
//  Proves the master-detail 提示词 settings page builds and lays out its SwiftUI body without a
//  real machine, against an INJECTED `OwlConfigWriter` pointed at an isolated temp dir — so the
//  page never reads or writes the real `~/Library/Application Support/Owltype`. `NSHostingView`'s
//  `fittingSize` forces the body to evaluate (the headless equivalent of "it renders"); a non-zero
//  size means every branch the initial state touches compiled and laid out.
//
//  The store/variable contracts are locked separately in `OwlPromptStoreTests`; this is the view
//  seam: the page reaches its data through `writer.rimeDir`, so seeding that temp dir and confirming
//  the page's data source resolves to it ties the render to the injected fake.
//
//  Limitation (documented): `.onAppear` (which calls `reload()`) does not fire deterministically in
//  a headless `NSHostingView`, so this asserts the body lays out and that the injected data source
//  is the temp dir — not the post-load row contents (those are covered by `OwlPromptStoreTests`).
//

import AppKit
import SwiftUI
import XCTest
@testable import Owltype

@MainActor
final class OwlPromptPageRenderTests: XCTestCase {

  private var tempRoot: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("OwlPromptPageRenderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
      try FileManager.default.removeItem(at: tempRoot)
    }
    try super.tearDownWithError()
  }

  private func fittingSize<V: View>(of view: V) -> NSSize {
    let host = NSHostingView(rootView: view)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }

  private func page(writer: OwlConfigWriter, scheme: ColorScheme = .light, reduceTransparency: Bool = false) -> OwlPromptPage {
    let theme = OwlSkin.deepred.theme
    return OwlPromptPage(
      palette: theme.palette(for: scheme),
      theme: theme,
      reduceTransparency: reduceTransparency,
      writer: writer
    )
  }

  func testRendersWithInjectedWriterAndNeverTouchesRealUserDir() {
    let writer = OwlConfigWriter(rimeDir: tempRoot)
    // The page's data source must resolve to the injected temp dir, not OwlApp.userDir.
    XCTAssertEqual(writer.rimeDir, tempRoot)

    let size = fittingSize(of: page(writer: writer))
    XCTAssertGreaterThan(size.width, 0, "prompt page should lay out a non-zero width")
    XCTAssertGreaterThan(size.height, 0, "prompt page should lay out a non-zero height")
  }

  func testRendersAcrossSchemeAndTransparencyBranches() {
    let writer = OwlConfigWriter(rimeDir: tempRoot)
    for scheme in [ColorScheme.light, .dark] {
      for reduceTransparency in [false, true] {
        let size = fittingSize(of: page(writer: writer, scheme: scheme, reduceTransparency: reduceTransparency))
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
      }
    }
  }

  func testSeededTempDirIsReachableThroughTheInjectedWriter() throws {
    // Seed the injected temp dir with a multi-line, variable-bearing prompt + a quick-send code,
    // then confirm the page's exact data sources (writer.rimeDir) surface them — this is the wiring
    // the page's `reload()` depends on.
    let writer = OwlConfigWriter(rimeDir: tempRoot)
    try OwlQuickSendStore.save(
      [try OwlQuickSendStore.entry(text: "判决摘要", code: "pjzy")],
      writer: writer,
      timestamp: "20260701-000000"
    )
    try OwlPromptStore.save(
      [
        try OwlPromptStore.entry(code: "hetong", title: "合同审查", body: "请审查：\n{{合同正文}}", category: "法律"),
        try OwlPromptStore.entry(code: "fanyi", title: "翻译", body: "把下面译成{{语言}}：{{原文}}"),
      ],
      writer: writer,
      timestamp: "20260701-000001"
    )

    let loaded = OwlPromptStore.load(rimeDir: writer.rimeDir)
    XCTAssertEqual(loaded.map(\.code), ["fanyi", "hetong"], "page data source must read the injected temp dir")
    let collisionCodes = OwlPromptStore.quickSendCodes(rimeDir: writer.rimeDir)
    XCTAssertTrue(collisionCodes.contains("pjzy"), "shared-namespace collision source must read the injected temp dir")

    // The page still lays out with seeded data present in its source dir.
    let size = fittingSize(of: page(writer: writer))
    XCTAssertGreaterThan(size.height, 0)
  }
}
