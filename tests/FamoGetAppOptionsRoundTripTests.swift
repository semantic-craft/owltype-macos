//
//  FamoGetAppOptionsRoundTripTests.swift
//  FamoTests — task 07-11-app-english-domain-crack-followup (AC3)
//
//  The correct regression seam for the "应用默认英文 config 域裂缝" fix (archived task
//  07-08, 修法 ③: per-app `app_options` collapsed into the famo config domain via
//  `famo.custom.yaml`). Every existing test only asserts the WRITTEN patch TEXT
//  (`FamoSettingsE2ETests` / `FamoKeyboardPatchBuilderTests`); NONE exercises the READ
//  side `FamoConfig.getAppOptions`. That "假覆盖" is exactly what let the cross-domain
//  crack ship. `RimeSeamTests` uses `FakeRimeSession` (no librime), so it cannot reach the
//  real `config_open` this bug lived in.
//
//  This test drives the real bug mode: deploy a `famo.custom.yaml` carrying
//  `app_options/<bundle>/ascii_mode: true` into a temp `user_data_dir`, compile it with a
//  REAL librime deploy, then `config_open("famo")` → `getAppOptions(bundle)` and assert the
//  option reads back. It also asserts the factory Terminal preset (which lives in the famo
//  base `famo.yaml`) still reads back — proving the fix did not regress the factory block.
//
//  Feasibility: `main()` skips IMK/Rime startup under XCTest (`runningUnitTests`,
//  Main.swift), so the process-global librime singleton is idle. This test owns a
//  one-time `setup`/`initialize`/deploy against a temp dir. No other test inits real
//  librime, so there is no double-init conflict. Only forward is locked: the fix is
//  already shipped, so "red before" is not reproducible — this is a防复发 invariant.
//

import XCTest
@testable import Famo

final class FamoGetAppOptionsRoundTripTests: XCTestCase {
  /// bundle id only this test writes into `famo.custom.yaml` — never a factory preset.
  private static let testBundleID = "com.famo.test.roundtrip"

  private static var tmpUserDir: URL?
  private static var engine: LiveRimeEngine?
  private static var deployOK = false
  private static var sharedSupportPresent = false

  override class func setUp() {
    super.setUp()
    let fm = FileManager.default
    let base = fm.temporaryDirectory
      .appending(component: "famo-getappoptions-roundtrip-\(UUID().uuidString)", directoryHint: .isDirectory)
    let logDir = base.appending(component: "log", directoryHint: .isDirectory)
    tmpUserDir = base
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)

    // A `famo.custom.yaml` structurally identical to the write side's
    // `famoAppOptionsCustomYAML` output: a `patch:` root carrying per-app app_options in
    // the FAMO domain (base = famo.yaml, patch = famo.custom.yaml).
    let customYAML = """
    # 法墨 test fixture — getAppOptions 真 librime 往返回归测试 (task 07-11)
    patch:
      "app_options/\(testBundleID)/ascii_mode": true
    """
    let customURL = base.appending(component: FamoRimeIdentity.customConfigFile, directoryHint: .notDirectory)
    try? Data(customYAML.utf8).write(to: customURL)

    guard let sharedSupport = Bundle.main.sharedSupportPath else { return }
    sharedSupportPresent = true

    // Drive the real librime lifecycle through the production `LiveRimeEngine` seam rather
    // than the raw `rime_get_api_stdbool()` C symbol: that symbol is linked into the Famo
    // binary but not re-exported to the FamoTests bundle, so referencing it directly fails to
    // link. `LiveRimeEngine`'s calls are compiled into the Famo module (reachable via
    // `@testable import`), and so is `FamoConfig` below.
    let engine = LiveRimeEngine()
    self.engine = engine
    // Traits mirror production `setupRime`, but point user_data_dir at the temp dir so the
    // compiled `build/famo.yaml` (base + custom patch) lands there for `config_open("famo")`.
    var traits = RimeTraits.rimeStructInit()
    traits.setCString(sharedSupport, to: \.shared_data_dir)
    traits.setCString(base.path, to: \.user_data_dir)
    traits.setCString(logDir.path, to: \.log_dir)
    traits.setCString(FamoRimeIdentity.appName, to: \.app_name)
    engine.setup(&traits)
    engine.initialize(nil)
    // Full workspace deploy first (creates `build/`, compiles default + schemas). The
    // config-only `deploy_config_file` alone fails on a COLD temp user_data_dir (no `build/`
    // yet), so we replay the production boot order: `start_maintenance` builds the workspace,
    // `join_maintenance_thread` waits for the async prism/dict work to land, then
    // `deploy_config_file("famo.yaml")` compiles `build/famo.yaml` (base + custom patch) —
    // exactly what `startRime` does after `initialize`.
    if engine.startMaintenance(fullCheck: true) {
      engine.joinMaintenance()
    }
    deployOK = engine.deployConfigFile(FamoRimeIdentity.configFile, versionKey: "config_version")
  }

  override class func tearDown() {
    // This class is the suite's only real-librime integration exception. Release the
    // process-global engine before deleting its user_data_dir so no initialized singleton keeps
    // paths into a directory that no longer exists. No other FamoTests case initializes librime.
    engine?.cleanupAllSessions()
    engine?.finalize()
    engine = nil
    if let dir = tmpUserDir {
      try? FileManager.default.removeItem(at: dir)
    }
    super.tearDown()
  }

  private func openFamoConfig() -> FamoConfig {
    XCTAssertTrue(Self.sharedSupportPresent, "Bundle.main.sharedSupportPath is nil in the test host")
    XCTAssertTrue(Self.deployOK, "deploy_config_file(\"famo.yaml\") failed — build/famo.yaml not compiled")
    let config = FamoConfig()
    XCTAssertTrue(config.openBaseConfig(), "config_open(\"famo\") failed — build/famo.yaml missing?")
    return config
  }

  /// AC3 mechanism lock: a user-added bundle written into the famo domain (`famo.custom.yaml`)
  /// reads back through the real `config_open("famo")` → `getAppOptions` path. Pre-fix this
  /// value lived in the `default` domain that `getAppOptions` never opened → silent failure.
  func testUserAddedAppOptionReadsBackFromFamoDomain() {
    let config = openFamoConfig()
    let options = config.getAppOptions(Self.testBundleID)
    XCTAssertEqual(options, ["ascii_mode": true])
  }

  /// AC2 factory-preset non-regression: the factory `com.apple.Terminal` block (from the
  /// famo.yaml base, data/famo.yaml) still reads back with both flags after the fix.
  func testFactoryTerminalPresetNotRegressed() {
    let config = openFamoConfig()
    let options = config.getAppOptions("com.apple.Terminal")
    XCTAssertEqual(options["ascii_mode"], true)
    XCTAssertEqual(options["no_inline"], true)
  }
}
