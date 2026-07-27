import AppKit
import XCTest

final class FamoSettingsUITests: XCTestCase {
  func testSettingsControlsCanBeClickedWithIsolatedUserDir() throws {
    let app = try launchSettings()

    tapMany([
      "双拼输入",
      "五笔输入",
      "候选编码提示",
      "空码自动清码",
      "纯单字",
      "z 临时拼音反查",
      // 简入繁出 toggle → 「默认状态·简繁体」下拉（menu Picker，与其它 picker 一样不在本 tap-smoke 内）。
      "设置模糊拼音",
    ], in: app)
    tap("zh = z（翘舌）", in: app)
    tap("完成", in: app)
    tapMany([
      "中文下使用英文标点",
      // slash→顿号 行已按机主 07-21 拍板下线；符号卡新增行为「输入中文时 “<” 弹出符号选单」。
      "输入中文时 “<” 弹出符号选单",
      "在候选中显示 emoji",
      "中文与英文间加入空格",
    ], in: app)

    // 中英文状态切换 / 候选翻页 / 候选快速选词 moved to the 快捷键设置 sidebar page.
    openPage("shortcuts", in: app)
    tapMany([
      "使用 Shift 切换中英文",
      "减号等号翻页",
      "左右中括号翻页",
      "逗号句号翻页",
      "分号引号选 2/3 位",
    ], in: app)

    openPage("appearance", in: app)
    tapMany(["竖排", "圆体", "候选条动画", "卷轴"], in: app)

    openPage("quickSend", in: app)
    type("短语", text: "uitest", in: app)
    type("编码，如 fm 或 fmcs", text: "ui", in: app)
    tap("添加短语", in: app)
    tap("清空", in: app)

    openPage("clipboard", in: app)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("uitest clipboard", forType: .string)
    tapMany(["启用剪贴板面板", "捕获当前剪贴板", "清空记录"], in: app)

    openPage("project", in: app)
    // 云端 AI 先开：它是全部技能行的总闸，关着时下面几行是 disabled，点不动。
    tapMany(["启用划词工具箱", "启用云端 AI", "任意提问", "来源核验", "辅助检索", "划词翻译",
             "润色", "提示词优化"], in: app)

    openPage("ai", in: app)
    tapMany([
      "+ OpenAI",
      "+ Google Gemini",
      "+ 小米 MiMo",
      "+ 火山引擎 · 豆包 Seed",
      "+ 自定义（OpenAI 兼容）",
      "+ DeepSeek",
      "Reasoner · V4 Pro",
    ], in: app)

    openPage("skin", in: app)
    tapMany(["珞珈青", "暗"], in: app)

    openPage("about", in: app)
    // 重置用户词典… 在 UI-test 模式下接的是空闭包（确认弹窗归 delegate），点它只验按钮可命中。
    tapMany(["应用配置改动", "同步用户数据", "重置用户词典…", "打开法墨配置目录…", "查看诊断日志…", "欢迎与引导…"], in: app)
  }

  private func launchSettings() throws -> XCUIApplication {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("FamoUITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }

    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-show-settings"]
    app.launchEnvironment["FAMO_TEST_USER_DIR"] = root.path
    app.launchEnvironment["FAMO_TEST_LOG_DIR"] = root.appendingPathComponent("logs", isDirectory: true).path
    app.launch()
    let ready = app.otherElements["FamoSettingsView"].waitForExistence(timeout: 5)
      || app.buttons["双拼输入"].waitForExistence(timeout: 5)
      || app.staticTexts["法墨输入法"].waitForExistence(timeout: 5)
    XCTAssertTrue(ready, "Settings window did not become accessible")
    return app
  }

  private func openPage(_ page: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    guard let row = sidebarElement(page, in: app) else {
      XCTFail("Missing sidebar page \(page)", file: file, line: line)
      return
    }
    row.click()
  }

  private func sidebarElement(_ page: String, in app: XCUIApplication) -> XCUIElement? {
    let title = [
      "shortcuts": "快捷键设置",
      "appearance": "候选窗设置",
      "quickSend": "快捷短语",
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

  private func tap(_ label: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    for _ in 0..<5 {
      if let element = element(label, in: app) {
        element.click()
        return
      }
      app.scrollViews.firstMatch.swipeUp()
    }
    for _ in 0..<5 {
      if let element = element(label, in: app) {
        element.click()
        return
      }
      app.scrollViews.firstMatch.swipeDown()
    }
    XCTFail("Missing tappable settings control: \(label)", file: file, line: line)
  }

  private func type(_ label: String, text: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    for _ in 0..<5 {
      if let field = firstExisting([app.textFields[label], app.secureTextFields[label], app.textViews[label]]) {
        field.click()
        field.typeText(text)
        return
      }
      app.scrollViews.firstMatch.swipeUp()
    }
    for _ in 0..<5 {
      if let field = firstExisting([app.textFields[label], app.secureTextFields[label], app.textViews[label]]) {
        field.click()
        field.typeText(text)
        return
      }
      app.scrollViews.firstMatch.swipeDown()
    }
    XCTFail("Missing text input: \(label)", file: file, line: line)
  }

  private func element(_ label: String, in app: XCUIApplication) -> XCUIElement? {
    firstExisting([
      app.buttons[label],
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
