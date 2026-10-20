import Darwin
import Foundation
import XCTest

final class OwlBundleSwapTests: XCTestCase {
  private var root: URL!
  private var app: URL { root.appendingPathComponent("Owltype.app") }
  private var live: URL { app.appendingPathComponent("Contents") }
  private var staged: URL { app.appendingPathComponent(".Contents.update") }

  override func setUpWithError() throws {
    // realpath keeps /private, the form of the shipped work directory; Foundation's
    // resolvingSymlinksInPath would hand back the /var symlink path instead.
    root = URL(fileURLWithPath: String(cString: realpath(FileManager.default.temporaryDirectory.path, nil)))
      .appendingPathComponent("OwlBundleSwapTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try contents(live, text: "old")
  }

  override func tearDownWithError() throws {
    if let root { try FileManager.default.removeItem(at: root) }
  }

  func testExchangeKeepsAppAndOpenOldInodeWhilePublishingNewContents() throws {
    try contents(staged, text: "new")
    let wrapperInode = try inode(app)
    let oldInode = try inode(live)
    let newInode = try inode(staged)
    let oldHandle = try FileHandle(forReadingFrom: live.appendingPathComponent("marker"))
    defer { try? oldHandle.close() }
    let exchange = try OwlBundleSwap.exchangeContents(in: app)
    XCTAssertEqual(try inode(app), wrapperInode)
    XCTAssertEqual(try inode(live), newInode)
    XCTAssertEqual(try inode(staged), oldInode)
    XCTAssertEqual(try marker(exchange.installedContents), "new")
    XCTAssertEqual(try marker(exchange.retiredContents), "old")
    XCTAssertEqual(try oldHandle.readToEnd(), Data("old".utf8))
  }

  func testSecondExchangeRestoresOriginalContentsWithoutDeletingEitherVersion() throws {
    try contents(staged, text: "new")
    let oldInode = try inode(live)
    try OwlBundleSwap.exchangeContents(in: app)
    try OwlBundleSwap.exchangeContents(in: app)
    XCTAssertEqual(try inode(live), oldInode)
    XCTAssertEqual(try marker(live), "old")
    XCTAssertEqual(try marker(staged), "new")
  }

  func testMissingStageLeavesLiveUntouched() throws {
    expectError(ENOENT) { try OwlBundleSwap.exchangeContents(in: app) }
    XCTAssertEqual(try marker(live), "old")
  }

  func testMissingLiveDoesNotPublishStageAsUpdate() throws {
    try FileManager.default.removeItem(at: live)
    try contents(staged, text: "new")
    expectError(ENOENT) { try OwlBundleSwap.exchangeContents(in: app) }
    XCTAssertEqual(try marker(staged), "new")
    XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
  }

  func testRejectsNonDirectoryStage() throws {
    try Data("not contents".utf8).write(to: staged)
    expectError(ENOTDIR) { try OwlBundleSwap.exchangeContents(in: app) }
    XCTAssertEqual(try marker(live), "old")
  }

  func testRejectsSymlinkStageWithoutFollowingIt() throws {
    let outside = root.appendingPathComponent("outside")
    try contents(outside, text: "outside")
    try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: outside)
    expectError(ELOOP) { try OwlBundleSwap.exchangeContents(in: app) }
    XCTAssertEqual(try marker(live), "old")
    XCTAssertEqual(try marker(outside), "outside")
  }

  func testRejectsSymlinkLiveWithoutFollowingIt() throws {
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.moveItem(at: live, to: outside)
    try FileManager.default.createSymbolicLink(at: live, withDestinationURL: outside)
    try contents(staged, text: "new")
    expectError(ELOOP) { try OwlBundleSwap.exchangeContents(in: app) }
    XCTAssertEqual(try marker(outside), "old")
    XCTAssertEqual(try marker(staged), "new")
  }

  func testRejectsSymlinkAncestor() throws {
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    try contents(staged, text: "new")
    expectError(ELOOP) { try OwlBundleSwap.exchangeContents(in: alias.appendingPathComponent("Owltype.app")) }
    XCTAssertEqual(try marker(live), "old")
  }

  func testPermissionFailurePreservesBothDirectoriesWithoutFallback() throws {
    try XCTSkipIf(getuid() == 0, "Permission failure requires a non-root test runner")
    try contents(staged, text: "new")
    let oldInode = try inode(live)
    let newInode = try inode(staged)
    XCTAssertEqual(chmod(app.path, 0o555), 0)
    defer { _ = chmod(app.path, 0o755) }
    expectError(EACCES) { try OwlBundleSwap.exchangeContents(in: app) }
    XCTAssertEqual(try inode(live), oldInode)
    XCTAssertEqual(try inode(staged), newInode)
  }

  func testFirstInstallPublishesCompleteApp() throws {
    let destination = root.appendingPathComponent("Installed.app")
    let wrapperInode = try inode(app)
    try OwlBundleSwap.publishFirstInstall(from: app, to: destination)
    XCTAssertEqual(try inode(destination), wrapperInode)
    XCTAssertEqual(try marker(destination.appendingPathComponent("Contents")), "old")
    XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
  }

  func testFirstInstallCannotReplaceExistingApp() throws {
    let destination = root.appendingPathComponent("Installed.app")
    try contents(destination.appendingPathComponent("Contents"), text: "existing")
    expectError(EEXIST) { try OwlBundleSwap.publishFirstInstall(from: app, to: destination) }
    XCTAssertEqual(try marker(destination.appendingPathComponent("Contents")), "existing")
    XCTAssertEqual(try marker(live), "old")
  }

  func testCommitRetiresOldContentsBeforeValidatingInstalledBundle() throws {
    let candidate = root.appendingPathComponent("Candidate.app")
    let retired = root.appendingPathComponent("Retired")
    try contents(candidate.appendingPathComponent("Contents"), text: "new")
    let oldInode = try inode(live)
    var checked: [URL] = []
    try OwlBundleSwap.commitPreparedApp(candidate, to: app, retired: retired) { location in
      checked.append(location)
      XCTAssertFalse(FileManager.default.fileExists(atPath: location.appendingPathComponent(".Contents.update").path))
      XCTAssertEqual(try self.marker(location.appendingPathComponent("Contents")), "new")
    }
    XCTAssertEqual(checked, [candidate, app])
    XCTAssertEqual(try inode(retired), oldInode)
    XCTAssertEqual(try marker(retired), "old")
    XCTAssertEqual(try marker(live), "new")
  }

  func testPostExchangeValidationFailureRestoresOldInodeAndPreservesFailedCandidate() throws {
    let candidate = root.appendingPathComponent("Candidate.app")
    let retired = root.appendingPathComponent("Retired")
    try contents(candidate.appendingPathComponent("Contents"), text: "new")
    let oldInode = try inode(live)
    XCTAssertThrowsError(try OwlBundleSwap.commitPreparedApp(candidate, to: app, retired: retired) { location in
      if location == self.app { throw CocoaError(.fileReadCorruptFile) }
    })
    XCTAssertEqual(try inode(live), oldInode)
    XCTAssertEqual(try marker(live), "old")
    XCTAssertEqual(try marker(candidate.appendingPathComponent("Contents")), "new")
    XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
  }

  func testPreCommitValidationFailureDoesNotMutateLiveOrCandidate() throws {
    let candidate = root.appendingPathComponent("Candidate.app")
    try contents(candidate.appendingPathComponent("Contents"), text: "new")
    XCTAssertThrowsError(try OwlBundleSwap.commitPreparedApp(candidate, to: app, retired: root.appendingPathComponent("Retired")) { _ in
      throw CocoaError(.fileReadCorruptFile)
    })
    XCTAssertEqual(try marker(live), "old")
    XCTAssertEqual(try marker(candidate.appendingPathComponent("Contents")), "new")
  }

  func testFirstInstallValidationFailureReturnsCandidateAndLeavesDestinationAbsent() throws {
    let destination = root.appendingPathComponent("Installed.app")
    XCTAssertThrowsError(try OwlBundleSwap.commitPreparedApp(app, to: destination, retired: root.appendingPathComponent("Retired")) { location in
      if location == destination { throw CocoaError(.fileReadCorruptFile) }
    })
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertEqual(try marker(live), "old")
  }

  private func contents(_ directory: URL, text: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: directory.appendingPathComponent("marker"))
  }

  private func marker(_ directory: URL) throws -> String {
    try String(contentsOf: directory.appendingPathComponent("marker"), encoding: .utf8)
  }

  private func inode(_ directory: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    return (attributes[.systemFileNumber] as! NSNumber).uint64Value
  }

  private func expectError<T>(_ code: Int32, file: StaticString = #filePath, line: UInt = #line, _ operation: () throws -> T) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
      XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain, file: file, line: line)
      XCTAssertEqual((error as NSError).code, Int(code), file: file, line: line)
    }
  }
}
