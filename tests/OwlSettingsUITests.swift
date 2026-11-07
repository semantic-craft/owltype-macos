import AppKit
import Carbon
import XCTest

final class OwlSettingsUITests: XCTestCase {
  private var previousInputSource: TISInputSource?

  // The installed Owltype input method shares this app's bundle id. While it is the active input
  // source, its panels count as the target app's interrupting dialogs and it composes typed text,
  // so the run uses an ASCII keyboard layout and restores the user's source afterwards.
  override func setUpWithError() throws {
    previousInputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    if let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
      TISSelectInputSource(ascii)
    }
  }

  override func tearDown() {
    if let previousInputSource { TISSelectInputSource(previousInputSource) }
    super.tearDown()
  }

  func testAppModeMemoryUsesFullWidthSettingsToggle() throws {
    let app = try launchSettings()
    defer { app.terminate() }
    let row = app.buttons["settings.rememberAppMode"]
    XCTAssertTrue(row.waitForExistence(timeout: 3), "Memory must use the shared settings toggle row")
    guard row.exists else { return }
    let manage = app.buttons["settings.manageAppMemory"]
    XCTAssertEqual(row.frame.maxX, manage.frame.maxX, accuracy: 2,
                   "The toggle must align with the card's trailing controls")
    XCTAssertGreaterThan(row.frame.width, 400, "The whole settings row must be clickable")
    XCTAssertTrue(row.isSelected)
    app.activate()
    row.click()
    XCTAssertFalse(row.isSelected)
    app.activate()
    row.click()
    XCTAssertTrue(row.isSelected)
    let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    screenshot.name = "App mode memory — shared settings toggle"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  func testLegacyUserMigrationEntryIsClickableWithIsolatedUserDir() throws {
    let app = try launchSettings()
    defer { app.terminate() }
    openPage("about", in: app)

    let entry = app.buttons["迁移旧版输入记录…"]
    XCTAssertTrue(entry.waitForExistence(timeout: 3),
                  "Legacy migration must remain reachable from settings maintenance")
    guard entry.exists else { return }
    entry.click()
  }

  func testSettingsControlsCanBeClickedWithIsolatedUserDir() throws {
    let app = try launchSettings()

    tapMany([
      "双拼输入",
      "五笔输入"
    ], in: app)
    tap("拼音设置", in: app)
    tap("设置模糊拼音", in: app)
    tap("zh = z（翘舌）", in: app)
    tap("完成", in: app)
    tap("五笔设置", in: app)
    tapMany([
      "候选显示五笔编码提示",
      "空码自动清码",
      "纯单字",
      "z 临时拼音反查"
    ], in: app)
    tap("标点与习惯", in: app)
    tapMany([
      "中文下使用英文标点",
      "输入中文时 “/” 弹出符号选单",
      "输入中文时 “<” 弹出符号选单",
      "在候选中显示 emoji",
      "中文与英文间加入空格"
    ], in: app)

    // 中英文状态切换与「翻页与选词键」live on the 快捷键设置 sidebar page.
    openPage("shortcuts", in: app)
    tapMany([
      "使用 Shift 切换中英文",
      "减号等号翻页",
      "左右中括号翻页",
      "逗号句号翻页",
      "分号引号选 2/3 位",
    ], in: app)

    openPage("appearance", in: app)
    tapMany(["竖排", "圆体", "候选条动画", "多行"], in: app)

    openPage("quickSend", in: app)
    XCTAssertFalse(app.staticTexts["提示词助手"].exists)
    type("template-title", text: "uitest snippet", in: app)
    type("template-body", text: "first line\nsecond line", in: app)
    tap("template-save", in: app)
    XCTAssertTrue(app.buttons["uitest snippet"].waitForExistence(timeout: 3))
    tap("提示词", in: app)
    XCTAssertTrue(app.buttons["uitest snippet"].waitForNonExistence(timeout: 3))
    tap("新建", in: app)
    type("template-title", text: "uitest prompt", in: app)
    type("template-body", text: "prompt body", in: app)
    tap("template-save", in: app)
    XCTAssertTrue(app.buttons["uitest prompt"].waitForExistence(timeout: 3))
    tap("全部", in: app)
    XCTAssertTrue(app.buttons["uitest snippet"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["uitest prompt"].exists)

    openPage("clipboard", in: app)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("uitest clipboard", forType: .string)
    tapMany(["启用剪贴板面板", "捕获当前剪贴板", "清空记录"], in: app)

    openPage("project", in: app)
    // 云端 AI 先开：它是全部技能行的总闸，关着时下面几行是 disabled，点不动。
    tapMany(["启用划词工具箱", "启用云端 AI", "任意提问", "来源核验", "辅助检索", "划词翻译",
             "润色", "提示词优化", "任务书"], in: app)

    openPage("ai", in: app)
    for preset in ["OpenAI", "Google Gemini", "火山引擎 · 豆包 Seed", "自定义（OpenAI 兼容）", "DeepSeek"] {
      choose(preset, from: "选择供应商预设", in: app)
    }
    choose("deepseek-v4-pro", from: "选择模型", in: app)

    openPage("skin", in: app)
    tapMany(["珞珈青", "暗"], in: app)

    openPage("about", in: app)
    // 重置用户词典… 在 UI-test 模式下接的是空闭包（确认弹窗归 delegate），点它只验按钮可命中。
    tapMany(["应用配置改动", "迁移旧版输入记录…", "重置用户词典…", "打开猫头鹰配置目录…", "查看诊断日志…", "欢迎与引导…"], in: app)
  }

  func testSnippetCategoryFilterKeepsBothKindsAccessible() throws {
    let app = try launchSettings(seedFilterEntries: true)
    defer { app.terminate() }
    openPage("quickSend", in: app)
    XCTAssertTrue(app.buttons["e2e snippet"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["e2e prompt"].exists)
    tap("提示词", in: app)
    XCTAssertTrue(app.buttons["e2e snippet"].waitForNonExistence(timeout: 3))
    XCTAssertTrue(app.buttons["e2e prompt"].exists)
    tap("全部", in: app)
    XCTAssertTrue(app.buttons["e2e snippet"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["e2e prompt"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Snippet filter — all entries"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  private func launchSettings(seedFilterEntries: Bool = false) throws -> XCUIApplication {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("OwltypeUITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }

    if seedFilterEntries {
      let entries: [[String: Any]] = ["general", "prompt"].map { category in
        ["id": UUID().uuidString, "title": category == "general" ? "e2e snippet" : "e2e prompt",
         "body": "Synthetic filter fixture", "bodyType": "plainText", "syntax": "standard",
         "candidateAliases": [], "tags": [], "isPinned": false, "category": category,
         "parameters": [], "invocationMode": "searchOnly", "expansionMode": "delimiterDrop"]
      }
      try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "entries": entries])
        .write(to: root.appendingPathComponent("owl_templates.json"))
      try Data(#"{"formatVersion":1,"committed":true}"#.utf8)
        .write(to: root.appendingPathComponent("owl_templates_state.json"))
    }

    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-show-settings"]
    app.launchEnvironment["OWL_TEST_USER_DIR"] = root.path
    app.launchEnvironment["OWL_TEST_LOG_DIR"] = root.appendingPathComponent("logs", isDirectory: true).path
    app.launch()
    let ready = app.windows.firstMatch.waitForExistence(timeout: 5)
      || app.otherElements["OwlSettingsView"].waitForExistence(timeout: 5)
      || app.buttons["双拼输入"].waitForExistence(timeout: 5)
      || app.staticTexts["猫头鹰输入法"].waitForExistence(timeout: 5)
    XCTAssertTrue(ready, "Settings window did not become accessible")
    return app
  }

  private func openPage(_ page: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    guard let row = sidebarElement(page, in: app) else {
      XCTFail("Missing sidebar page \(page)", file: file, line: line)
      return
    }
    app.activate()
    row.click()
  }

  private func sidebarElement(_ page: String, in app: XCUIApplication) -> XCUIElement? {
    let title = [
      "shortcuts": "快捷键设置",
      "appearance": "候选窗设置",
      "quickSend": "快捷片段",
      "clipboard": "剪贴板",
      "project": "划词工具箱",
      "ai": "AI 配置",
      "skin": "皮肤外观",
      "about": "关于",
    ][page] ?? page
    let candidates = [
      app.otherElements["settings.sidebar.\(page)"],
      app.buttons[title],
      app.staticTexts[title],
    ]
    for element in candidates where element.waitForExistence(timeout: 0.5) {
      return element
    }
    return nil
  }

  private func tapMany(_ labels: [String], in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    for label in labels {
      tap(label, in: app, file: file, line: line)
    }
  }

  // Other apps on a shared desktop can raise windows over the settings window mid-run, so every
  // click and keystroke first brings the app under test forward.
  private func tap(_ label: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    for _ in 0..<5 {
      if let element = element(label, in: app) {
        app.activate()
        element.click()
        return
      }
      app.scrollViews.firstMatch.swipeUp()
    }
    for _ in 0..<5 {
      if let element = element(label, in: app) {
        app.activate()
        element.click()
        return
      }
      app.scrollViews.firstMatch.swipeDown()
    }
    attachHierarchy(of: app, named: "Missing \(label)")
    XCTFail("Missing tappable settings control: \(label)", file: file, line: line)
  }

  private func choose(_ item: String, from menu: String, in app: XCUIApplication,
                      file: StaticString = #filePath, line: UInt = #line) {
    tap(menu, in: app, file: file, line: line)
    let entry = app.menuItems[item]
    guard entry.waitForExistence(timeout: 2) else {
      attachHierarchy(of: app, named: "Missing menu item \(item)")
      XCTFail("Missing menu item \(item) in \(menu)", file: file, line: line)
      return
    }
    entry.click()
  }

  private func type(_ label: String, text: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    for _ in 0..<5 {
      if let field = firstExisting([app.textFields[label], app.secureTextFields[label], app.textViews[label]]) {
        app.activate()
        field.click()
        field.typeText(text)
        return
      }
      app.scrollViews.firstMatch.swipeUp()
    }
    for _ in 0..<5 {
      if let field = firstExisting([app.textFields[label], app.secureTextFields[label], app.textViews[label]]) {
        app.activate()
        field.click()
        field.typeText(text)
        return
      }
      app.scrollViews.firstMatch.swipeDown()
    }
    attachHierarchy(of: app, named: "Missing \(label)")
    XCTFail("Missing text input: \(label)", file: file, line: line)
  }

  /// A miss only says the queries came up empty; the tree shows what the control became.
  private func attachHierarchy(of app: XCUIApplication, named name: String) {
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "\(name) — accessibility tree"
    tree.lifetime = .keepAlways
    add(tree)
  }

  private func element(_ label: String, in app: XCUIApplication) -> XCUIElement? {
    firstExisting([
      app.buttons[label],
      app.menuButtons[label],
      app.popUpButtons[label],
      app.staticTexts[label],
      app.checkBoxes[label],
      app.radioButtons[label],
      app.switches[label],
      app.textFields[label],
      app.secureTextFields[label],
      app.textViews[label],
    ])
  }

  private func firstExisting(_ elements: [XCUIElement]) -> XCUIElement? {
    elements.first { $0.exists }
  }
}
