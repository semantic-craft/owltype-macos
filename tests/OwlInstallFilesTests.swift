import Darwin
import Foundation
import XCTest

/// The privileged file phase must not leave bundle-shaped copies where LaunchServices and the
/// input menu look (#217 follow-up): intermediates live in the private work directory, and a
/// validated commit removes them.
final class OwlInstallFilesTests: XCTestCase {
  private var root: URL!
  private var layout: OwlInstallFiles.Layout!
  private var inputMethods: URL { layout.inputMethods }
  private var live: URL { inputMethods.appendingPathComponent("Owltype.app") }

  override func setUpWithError() throws {
    // realpath keeps /private, the form of the shipped work directory; Foundation's
    // resolvingSymlinksInPath would hand back the /var symlink path instead.
    root = URL(fileURLWithPath: String(cString: realpath(FileManager.default.temporaryDirectory.path, nil)))
      .appendingPathComponent("OwlInstallFilesTests-\(UUID().uuidString)")
    let state = root.appendingPathComponent("db/installer-state")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    layout = OwlInstallFiles.Layout(inputMethods: root.appendingPathComponent("Input Methods"),
                                    work: state.appendingPathComponent("work"))
  }

  override func tearDownWithError() throws {
    if let root { try FileManager.default.removeItem(at: root) }
  }

  func testFirstInstallLeavesOnlyTheLiveAppAndAnEmptyWorkDirectory() throws {
    try commit(try bundle("new"))
    XCTAssertEqual(try marker(live), "new")
    XCTAssertEqual(try entries(inputMethods), ["Owltype.app"])
    XCTAssertEqual(try entries(layout.work), [])
  }

  func testUpdateRemovesRetiredContentsAndCandidateWrapper() throws {
    try commit(try bundle("old"))
    let shell = try inode(live)
    try commit(try bundle("new"))
    XCTAssertEqual(try marker(live), "new")
    XCTAssertEqual(try inode(live), shell)
    XCTAssertEqual(try entries(inputMethods), ["Owltype.app"])
    XCTAssertEqual(try entries(layout.work), [])
  }

  func testFailedValidationKeepsCandidateInWorkNotInputMethods() throws {
    try commit(try bundle("old"))
    XCTAssertThrowsError(try commit(try bundle("new")) { location in
      if location == self.live { throw CocoaError(.fileReadCorruptFile) }
    })
    XCTAssertEqual(try marker(live), "old")
    XCTAssertEqual(try entries(inputMethods), ["Owltype.app"])
    let retained = try entries(layout.work)
    XCTAssertEqual(retained.count, 1)
    XCTAssertTrue(retained[0].hasPrefix("prepared-"))
    let candidate = layout.work.appendingPathComponent(retained[0]).appendingPathComponent("Owltype.app")
    XCTAssertEqual(try marker(candidate), "new")
  }

  func testIncompleteLiveAppIsRetainedOutsideInputMethodsAndInstalledFresh() throws {
    let shell = live.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: shell, withIntermediateDirectories: true)
    try commit(try bundle("new"))
    XCTAssertEqual(try marker(live), "new")
    XCTAssertEqual(try entries(inputMethods), ["Owltype.app"])
    XCTAssertEqual(try entries(layout.work), [])
    let retained = layout.work.deletingLastPathComponent().appendingPathComponent("retained")
    let kept = try entries(retained)
    XCTAssertEqual(kept.count, 1)
    XCTAssertTrue(kept[0].hasPrefix("incomplete-Owltype-"))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: retained.appendingPathComponent(kept[0]).appendingPathComponent("Contents/Resources").path))
  }

  func testHeldLockStopsBeforeCopying() throws {
    try commit(try bundle("old"))
    try FileManager.default.createDirectory(at: layout.work.appendingPathComponent("install-lock"),
                                            withIntermediateDirectories: false)
    XCTAssertThrowsError(try commit(try bundle("new")))
    XCTAssertEqual(try marker(live), "old")
    XCTAssertEqual(try entries(layout.work), ["install-lock"])
  }

  func testSymlinkedWorkDirectoryIsRefused() throws {
    let elsewhere = root.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: layout.work, withDestinationURL: elsewhere)
    XCTAssertThrowsError(try commit(try bundle("new")))
    XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
    XCTAssertEqual(try entries(elsewhere), [])
  }

  func testDifferentVolumesAreRefused() throws {
    XCTAssertThrowsError(try OwlInstallFiles.requireSameVolume(root, URL(fileURLWithPath: "/dev"))) { error in
      XCTAssertEqual((error as? POSIXError)?.code, .EXDEV)
    }
    XCTAssertNoThrow(try OwlInstallFiles.requireSameVolume(root, layout.work.deletingLastPathComponent()))
  }

  func testCanonicalCheckKeepsPrivatePrefixAndRejectsSymlinkedVar() throws {
    XCTAssertTrue(root.path.hasPrefix("/private/"))
    XCTAssertTrue(OwlBundleSwap.isCanonical(root))
    XCTAssertFalse(OwlBundleSwap.isCanonical(URL(fileURLWithPath: String(root.path.dropFirst("/private".count)))))
  }

  func testSystemLayoutKeepsWorkOutsideInputMethods() {
    let system = OwlInstallFiles.Layout.system
    XCTAssertEqual(system.inputMethods.path, "/Library/Input Methods")
    XCTAssertFalse(system.work.path.hasPrefix(system.inputMethods.path + "/"))
    XCTAssertEqual(system.work.deletingLastPathComponent().path,
                   "/private/var/db/im.owltype.inputmethod.Owltype-installer")
  }

  func testUpdateAllowsInputModeDictEvolutionAndRejectsForeignBundle() throws {
    let oldApp = try bundle("old", inputModes: ["Hans"])
    try commit(oldApp)
    let evolvedApp = try bundle("new", inputModes: ["Hans", "Hant"])
    try commit(evolvedApp)
    XCTAssertEqual(try marker(live), "new")

    let foreignInfo = live.appendingPathComponent("Contents/Info.plist")
    let foreign: [String: Any] = ["CFBundleIdentifier": "com.example.other",
                                  "InputMethodConnectionName": "Owltype_Connection",
                                  "CFBundleVersion": "1.0"]
    try PropertyListSerialization.data(fromPropertyList: foreign, format: .xml, options: 0).write(to: foreignInfo)
    XCTAssertThrowsError(try commit(try bundle("after-foreign")))
  }

  func testCorruptLiveInfoPlistIsRetainedAndReplacedCleanly() throws {
    try commit(try bundle("old"))
    try Data("not-a-plist".utf8).write(to: live.appendingPathComponent("Contents/Info.plist"))
    try commit(try bundle("repaired"))
    XCTAssertEqual(try marker(live), "repaired")
    let retained = layout.work.deletingLastPathComponent().appendingPathComponent("retained")
    XCTAssertEqual(try entries(retained).count, 1)
  }

  private func commit(_ source: URL, verify: @escaping (URL) throws -> Void = { _ in }) throws {
    try OwlInstallFiles.commit(source: source, layout: layout, verify: verify) { _ in }
  }

  private func bundle(_ text: String, inputModes: [String] = ["Hans"]) throws -> URL {
    let app = root.appendingPathComponent("source-\(UUID().uuidString)/Owltype.app")
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": "im.owltype.inputmethod.Owltype",
                               "InputMethodConnectionName": "Owltype_Connection",
                               "ComponentInputModeDict": ["tsVisibleInputModeOrderedArrayKey": inputModes],
                               "CFBundleVersion": text]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
    try Data(text.utf8).write(to: contents.appendingPathComponent("marker"))
    return app
  }

  private func marker(_ app: URL) throws -> String {
    String(decoding: try Data(contentsOf: app.appendingPathComponent("Contents/marker")), as: UTF8.self)
  }

  private func entries(_ directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }

  private func inode(_ url: URL) throws -> ino_t {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
    return info.st_ino
  }
}
