//
//  InputSource.swift
//  Famo

import Foundation
import InputMethodKit

// MARK: - Input source install: register → enable → select (upstream Squirrel behavior)
//
// Keep only Famo's own bundle identity (`im.famo.inputmethod.Famo[.Hans/.Hant]`) and use TIS as the
// activation surface. Do NOT write `AppleEnabledInputSources` directly: on modern macOS that plist
// omits third-party IMEs, and injecting a Famo row creates duplicate TIS records that can leave the
// menu bar title selected while the input menu itself has no Famo row.
//
// The selected-but-not-enabled half-state DIAGNOSTIC (`--detect-activation` /
// `detectAndGuideIfHalfState`) is kept: it only prints copyable recovery guidance and never blocks
// enable/select.

final class FamoInstaller {
  static let inputSourcePrefix = "im.famo.inputmethod.Famo"
  static let squirrelInputSourcePrefix = ["im", "rime", "inputmethod", "Squirrel"].joined(separator: ".")

  enum InputMode: String, CaseIterable {
    static let primary = Self.hans
    case hans = "im.famo.inputmethod.Famo.Hans"
    case hant = "im.famo.inputmethod.Famo.Hant"
  }

  private lazy var inputSources: [String: TISInputSource] = {
    var inputSources = [String: TISInputSource]()
    let sourceList = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
    for inputSource in sourceList {
      let sourceIDRef = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
      guard let sourceID = unsafeBitCast(sourceIDRef, to: CFString?.self) as String? else { continue }
      inputSources[sourceID] = inputSource
    }
    return inputSources
  }()

  func enabledModes() -> [InputMode] {
    var enabledModes = Set<InputMode>()
    for (mode, inputSource) in getInputSource(modes: InputMode.allCases) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), enabled {
        enabledModes.insert(mode)
      }
      if enabledModes.count == InputMode.allCases.count {
        break
      }
    }
    return Array(enabledModes)
  }

  /// Tell the system the enabled/selected input-source list changed so the live GUI session
  /// (input menu, System Settings) repaints without a logout. A `TISEnableInputSource` from a
  /// transient installer process otherwise may not refresh the menu until the next login.
  func notifyInputSourcesChanged() {
    let center = CFNotificationCenterGetDistributedCenter()
    let names: [CFString?] = [
      kTISNotifyEnabledKeyboardInputSourcesChanged,
      kTISNotifySelectedKeyboardInputSourceChanged,
    ]
    for case let name? in names {
      CFNotificationCenterPostNotification(center, CFNotificationName(rawValue: name), nil, nil, true)
    }
  }

  /// Force the input-menu agents to re-read the enabled list now. The distributed notification may
  /// be cached or raced; launchd restarts these agents and they read a fresh TIS list on relaunch.
  /// Best-effort; never throws into the caller.
  static func refreshInputMenuAgents() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    p.arguments = ["-9", "TextInputMenuAgent", "TextInputSwitcher"]
    p.standardError = FileHandle.nullDevice  // "No matching processes" is expected, not an error
    try? p.run()
    p.waitUntilExit()
  }

  /// Repair install-time registration without touching the user's input-source list directly.
  /// The installer GUI process owns `TISEnableInputSource` and any macOS consent prompt. This
  /// helper is intentionally limited to register + notify + menu-agent refresh, so updates cannot
  /// create duplicate TIS rows or steal the active input source.
  func repairRegistrationForInstalledBundle() {
    TISRegisterInputSource(FamoApp.appDir as CFURL)
    notifyInputSourcesChanged()
    Self.refreshInputMenuAgents()
  }

  func register() {
    let enabledInputModes = enabledModes()
    if !enabledInputModes.isEmpty {
      print("User already registered Famo method(s): \(enabledInputModes.map { $0.rawValue })")
      return
    }
    TISRegisterInputSource(FamoApp.appDir as CFURL)
    print("Registered input source from \(FamoApp.appDir)")
  }

  func enable(modes: [InputMode] = []) {
    let enabledInputModes = enabledModes()
    if !enabledInputModes.isEmpty && modes.isEmpty {
      print("User already enabled Famo method(s): \(enabledInputModes.map { $0.rawValue })")
      // Preserve manually enabled input modes.
      return
    }
    let modesToEnable = modes.isEmpty ? [.primary] : modes
    for (mode, inputSource) in getInputSource(modes: modesToEnable) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), !enabled {
        let error = TISEnableInputSource(inputSource)
        print("Enable \(error == noErr ? "succeeds" : "fails") for input source: \(mode.rawValue)")
      }
    }
    notifyInputSourcesChanged()
  }

  func select(mode: InputMode? = nil) {
    let enabledInputModes = enabledModes()
    let modeToSelect = mode ?? .primary
    if !enabledInputModes.contains(modeToSelect) {
      if mode != nil {
        enable(modes: [modeToSelect])
      } else {
        print("Default method not enabled yet: \(modeToSelect.rawValue)")
        return
      }
    }
    for (mode, inputSource) in getInputSource(modes: [modeToSelect]) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled),
         let selectable = getBool(for: inputSource, key: kTISPropertyInputSourceIsSelectCapable),
         let selected = getBool(for: inputSource, key: kTISPropertyInputSourceIsSelected),
         enabled && selectable && !selected {
        let error = TISSelectInputSource(inputSource)
        print("Selection \(error == noErr ? "succeeds" : "fails") for input source: \(mode.rawValue)")
      } else {
        print("Failed to select \(mode.rawValue)")
      }
    }
    notifyInputSourcesChanged()
  }

  /// `--select-input-source <arg>` 的纯 CLI 分发决策：参数是法墨自家输入模式，还是任意系统输入源 id
  /// （如 `com.apple.keylayout.ABC`，postinstall 更新序列在 kill 旧进程前切出用）。纯函数、无 TIS ——
  /// 单测保证系统 id 绝不会误落回「选中法墨」的无参默认路径。
  enum SelectTarget: Equatable {
    case famoMode(InputMode)
    case systemSource(String)
  }

  static func selectTarget(for argument: String) -> SelectTarget {
    if let mode = InputMode(rawValue: argument) {
      return .famoMode(mode)
    }
    return .systemSource(argument)
  }

  /// Select ANY system input source by exact id：`TISCreateInputSourceList` 按
  /// `kTISPropertyInputSourceID` 精确匹配（`inputSources` 字典即该映射）后 `TISSelectInputSource`。
  /// postinstall 更新序列用它切出到 ABC（TIS-ACTIVATION-NOTES 定律 12）。best-effort：找不到 / 失败
  /// 只打印，不抛错——select 失败是常态（定律 2/3），绝不据此让安装失败。
  func select(sourceID: String) {
    guard let inputSource = inputSources[sourceID] else {
      print("Input source not found: \(sourceID)")
      return
    }
    let error = TISSelectInputSource(inputSource)
    print("Selection \(error == noErr ? "succeeds" : "fails") for input source: \(sourceID)")
    notifyInputSourcesChanged()
  }

  func disable(modes: [InputMode] = []) {
    let modesToDisable = modes.isEmpty ? InputMode.allCases : modes
    for (mode, inputSource) in getInputSource(modes: modesToDisable) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), enabled {
        let error = TISDisableInputSource(inputSource)
        print("Disable \(error == noErr ? "succeeds" : "fails") for input source: \(mode.rawValue)")
      }
    }
  }

  static func currentInputSourceID() -> String? {
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    return unsafeBitCast(idRef, to: CFString?.self) as String?
  }

  static func currentInputSourceDisplayName(for id: String?) -> String {
    guard let id, !id.isEmpty else { return "未知" }
    if id.hasPrefix(inputSourcePrefix) {
      return "法墨输入法（\(id)）"
    }
    if id.hasPrefix(squirrelInputSourcePrefix) {
      return "Squirrel（\(id)，当前不是法墨）"
    }
    return id
  }

  static func currentInputSourceDisplayName() -> String {
    currentInputSourceDisplayName(for: currentInputSourceID())
  }

  // MARK: - Diagnostic only: selected-but-not-enabled half-state. NEVER blocks enable/select and is
  // NOT on the IMK key-event hot path (called from `--detect-activation` and the selected-source
  // CHANGE observer). Prints copyable System Settings recovery guidance; that is its whole job.

  struct ActivationDiagnosis: Equatable {
    /// A Famo mode is the current selected source but its TIS enabled bit is false (the
    /// key-swallowing dead half-state).
    let brokenHalfState: Bool
    /// The mode involved, if any.
    let mode: InputMode?
  }

  /// Pure half-state detector: current selected id + which Famo modes are enabled → is it the dead
  /// state? No TIS, no IO — unit-testable.
  static func diagnoseHalfState(currentSourceID: String?, trulyEnabledModes: Set<InputMode>) -> ActivationDiagnosis {
    guard let currentSourceID, currentSourceID.hasPrefix(inputSourcePrefix),
          let mode = InputMode(rawValue: currentSourceID) else {
      return ActivationDiagnosis(brokenHalfState: false, mode: nil)
    }
    let broken = !trulyEnabledModes.contains(mode)
    return ActivationDiagnosis(brokenHalfState: broken, mode: broken ? mode : nil)
  }

  @discardableResult
  func detectAndGuideIfHalfState() -> ActivationDiagnosis {
    let diagnosis = Self.diagnoseHalfState(
      currentSourceID: Self.currentInputSourceID(),
      trulyEnabledModes: Set(enabledModes())
    )
    if diagnosis.brokenHalfState {
      print(Self.activationGuidanceText(for: diagnosis.mode))
    }
    return diagnosis
  }

  /// Copyable, human-readable recovery guidance for the broken half-state.
  static func activationGuidanceText(for mode: InputMode?) -> String {
    let label = mode?.rawValue ?? FamoInstaller.InputMode.primary.rawValue
    return """
    [法墨激活诊断] 检测到“已选中但未真正启用”的死半态：当前输入法是 \(label)，但它没有被真正启用，\
    会吞掉所有按键（包括英文）。
    一键恢复步骤（请手动在系统设置中操作，不要让程序自动改你正在用的输入法）：
      1. 打开 系统设置 → 键盘 → 输入法 → 点“编辑…”（System Settings → Keyboard → Input Sources → Edit…）。
      2. 若列表里有“法墨/Famo”，先用减号(−)移除，再用加号(+) → 简体中文 → 重新加入“法墨”。
      3. 若列表里没有“法墨”，直接用加号(+)添加。
      4. 加回后从右上角输入法菜单切到“法墨”，测试能否打字。
    判断是否启用，请以上面“输入法 → 编辑…”里的列表为准；不要用 \
    `defaults read … AppleEnabledInputSources` 来核对——新版 macOS 不在该列表收录第三方输入法，会误判为“未启用”。
    """
  }

  static func activationStatusText() -> String {
    activationStatusText(
      currentInputSourceID: currentInputSourceID() ?? "未知",
      lastHostKeyEventDate: FamoActivationHealth.lastHostKeyEventDate()
    )
  }

  static func activationStatusText(currentInputSourceID current: String, lastHostKeyEventDate: String?) -> String {
    let handleStatus = lastHostKeyEventDate.map {
      "最近一次宿主按键进入 Famo handle(): \($0)"
    } ?? "本次登录尚未观察到宿主按键进入 Famo handle()。若菜单已选中法墨但打字无反应，请在系统设置 → 键盘 → 输入法里手动添加一次法墨。"
    return """
    [法墨激活诊断]
    当前系统输入源：\(current)
    \(handleStatus)
    """
  }

  private func getInputSource(modes: [InputMode]) -> [InputMode: TISInputSource] {
    var matchingSources = [InputMode: TISInputSource]()
    for mode in modes {
      if let inputSource = inputSources[mode.rawValue] {
        matchingSources[mode] = inputSource
      }
    }
    return matchingSources
  }

  private func getBool(for inputSource: TISInputSource, key: CFString!) -> Bool? {
    let enabledRef = TISGetInputSourceProperty(inputSource, key)
    guard let enabled = unsafeBitCast(enabledRef, to: CFBoolean?.self) else { return nil }
    return CFBooleanGetValue(enabled)
  }

  private func getString(for inputSource: TISInputSource, key: CFString!) -> String? {
    let ref = TISGetInputSourceProperty(inputSource, key)
    return unsafeBitCast(ref, to: CFString?.self) as String?
  }

  /// Read-only snapshot of every installed input source under Famo's prefix (id + the four TIS
  /// capability/state bits + labels). Fresh-process read via the lazy `inputSources` map — Law 4 is
  /// satisfied when this runs from the short-lived `--diagnose-tis` CLI. Never mutates TIS.
  func famoSourceStates() -> [TISSourceState] {
    inputSources.compactMap { id, source in
      guard id.hasPrefix(Self.inputSourcePrefix) else { return nil }
      return TISSourceState(
        id: id,
        bundleID: getString(for: source, key: kTISPropertyBundleID) ?? "",
        localizedName: getString(for: source, key: kTISPropertyLocalizedName) ?? "",
        enableCapable: getBool(for: source, key: kTISPropertyInputSourceIsEnableCapable) ?? false,
        selectCapable: getBool(for: source, key: kTISPropertyInputSourceIsSelectCapable) ?? false,
        enabled: getBool(for: source, key: kTISPropertyInputSourceIsEnabled) ?? false,
        selected: getBool(for: source, key: kTISPropertyInputSourceIsSelected) ?? false)
    }.sorted { $0.id < $1.id }
  }

}

// MARK: - Read-only six-layer TIS activation diagnosis (W1.4)
//
// Separates the register → enumerate → enable → select → menu-visible → client-attach lifecycle so
// "installed but not usable" maps to a specific FAMO-* code instead of "reboot/logout". Read-only:
// no enable/select/disable, no `AppleEnabledInputSources` write. Law 4: `Famo --diagnose-tis` is a
// short-lived process, so its TIS read-back is fresh by construction. §5/§6 of the de-Squirrel plan.

/// One installed input source's read-only TIS state. Pure value — the classifier is unit-testable
/// with synthetic states, no TIS access.
struct TISSourceState: Equatable, Codable {
  let id: String
  let bundleID: String
  let localizedName: String
  let enableCapable: Bool
  let selectCapable: Bool
  let enabled: Bool
  let selected: Bool
}

enum ActivationLayer: String, Codable, CaseIterable {
  case register, enumerate, enable, select, menuVisible, clientAttach
}

/// One layer's verdict. `ok == nil` means a read-only probe genuinely cannot determine this layer
/// (menuVisible = the input-menu cache is opaque; clientAttach = needs a live app) — an honest
/// ceiling, never scored as a failure.
struct LayerResult: Equatable, Codable {
  let layer: ActivationLayer
  let ok: Bool?
  let code: String?
  let detail: String
}

struct TISDiagnosis: Equatable, Codable {
  let layers: [LayerResult]
  let firstFailingLayer: ActivationLayer?
  let code: String?
}

enum FamoTISDiagnostics {
  /// §5 user-facing message per FAMO-* code (developer meaning stays in each layer's `detail`).
  static let userMessage: [String: String] = [
    "FAMO-TIS-001": "系统尚未识别 Famo 输入源。",
    "FAMO-TIS-002": "Famo 输入源无法启用。",
    "FAMO-TIS-003": "Famo 输入源启用结果不一致。",
    "FAMO-TIS-004": "Famo 输入源无法选中。",
    "FAMO-TIS-005": "当前 App 未连接到 Famo。",
    "FAMO-TIS-006": "输入菜单尚未显示 Famo。",
    "FAMO-INSTALL-001": "Famo 未安装在系统输入法目录。",
    "FAMO-SIGN-001": "Famo 签名校验未通过。",
    "FAMO-SIGN-002": "Famo 发布物未通过系统安全评估。",
    "FAMO-DATA-001": "Famo 数据目录不可用。",
    "FAMO-DATA-002": "检测到非 Famo 数据路径写入。",
    "FAMO-UPDATE-001": "更新时仍有旧输入连接。",
  ]

  /// PURE six-layer classifier. `sources` is the installed set already filtered to Famo's prefix.
  /// No TIS, no IO — the §6 root-cause matrix 活跃 rows are its unit tests.
  static func classify(
    sources: [TISSourceState], currentSourceID: String?, expectedIDs: [String], primaryID: String
  ) -> TISDiagnosis {
    var layers: [LayerResult] = []
    let registered = !sources.isEmpty
    let presentIDs = Set(sources.map { $0.id })
    let primaryPresent = presentIDs.contains(primaryID)
    let primary = sources.first { $0.id == primaryID }
    // Half-state precedence: the current source is a Famo source whose enabled bit is false — the
    // key-swallowing dead state. This is a select-layer pathology (004), not an enable failure.
    let halfState = currentSourceID.flatMap { cur in sources.first { $0.id == cur && !$0.enabled } }

    // 1. register
    layers.append(LayerResult(
      layer: .register, ok: registered, code: registered ? nil : "FAMO-TIS-001",
      detail: registered
        ? "\(sources.count) 个 Famo 输入源可枚举（TISCreateInputSourceList includeAllInstalled=true）"
        : "0 个 Famo 输入源可枚举 → 未注册（核对安装路径/签名/Info.plist）"))

    // 2. enumerate
    let missing = expectedIDs.filter { !presentIDs.contains($0) }
    if !registered {
      layers.append(LayerResult(layer: .enumerate, ok: nil, code: nil, detail: "未评估（register 失败）"))
    } else if !primaryPresent {
      layers.append(LayerResult(
        layer: .enumerate, ok: false, code: "FAMO-TIS-001",
        detail: "主输入源 \(primaryID) 不可枚举；已见 \(sources.map { $0.id })"))
    } else {
      layers.append(LayerResult(
        layer: .enumerate, ok: true, code: nil,
        detail: missing.isEmpty ? "全部期望输入源就位 \(expectedIDs)" : "主输入源就位；次要缺失 \(missing)"))
    }

    // 3. enable (defers to select when the not-enabled source is the current one → half-state)
    if !registered || !primaryPresent {
      layers.append(LayerResult(layer: .enable, ok: nil, code: nil, detail: "未评估（主输入源不可枚举）"))
    } else if let primary, primary.enabled {
      layers.append(LayerResult(layer: .enable, ok: true, code: nil, detail: "主输入源 \(primaryID) 已启用"))
    } else if halfState != nil {
      layers.append(LayerResult(
        layer: .enable, ok: nil, code: nil, detail: "enabled=false，属选中半态，见 select 层（FAMO-TIS-004）"))
    } else if let primary, !primary.enableCapable {
      layers.append(LayerResult(
        layer: .enable, ok: false, code: "FAMO-TIS-002",
        detail: "主输入源 \(primaryID) 不可启用（IsEnableCapable=false / 父条目未启用）"))
    } else if let wrong = sources.first(where: { $0.enabled && !expectedIDs.contains($0.id) }) {
      layers.append(LayerResult(
        layer: .enable, ok: false, code: "FAMO-TIS-002",
        detail: "启用了非期望输入源 \(wrong.id) 而非 \(primaryID)（enable 打在错误条目/按名称选择）—— 只按精确 source id 操作"))
    } else {
      layers.append(LayerResult(
        layer: .enable, ok: false, code: "FAMO-TIS-003",
        detail: "主输入源 \(primaryID) 可启用但读回 enabled=false —— 运行 --enable-input-source；读回仍 false = 启用不一致"))
    }

    // 4. select
    if !registered || !primaryPresent {
      layers.append(LayerResult(layer: .select, ok: nil, code: nil, detail: "未评估（主输入源不可枚举）"))
    } else if let half = halfState {
      layers.append(LayerResult(
        layer: .select, ok: false, code: "FAMO-TIS-004",
        detail: "当前源 \(half.id) 已选中但 enabled=false（吞键死半态）—— 先切 ABC 再重选「法墨」，或系统设置→键盘→输入法重加一次"))
    } else if let primary, primary.enabled {
      if !primary.selectCapable {
        layers.append(LayerResult(
          layer: .select, ok: false, code: "FAMO-TIS-004",
          detail: "主输入源 \(primaryID) 已启用但不可选中（IsSelectCapable=false）"))
      } else if primary.selected {
        layers.append(LayerResult(layer: .select, ok: true, code: nil, detail: "主输入源 \(primaryID) 已选中（当前）"))
      } else {
        layers.append(LayerResult(
          layer: .select, ok: true, code: nil,
          detail: "主输入源 \(primaryID) 已启用且可选中；当前未选中 —— 在输入菜单选「法墨」即可"))
      }
    } else {
      layers.append(LayerResult(layer: .select, ok: nil, code: nil, detail: "未评估（主输入源未启用）"))
    }

    // 5. menuVisible — read-only ceiling; surfaces the FAMO-TIS-006 candidate note
    let primaryEnabled = primary?.enabled ?? false
    layers.append(LayerResult(
      layer: .menuVisible, ok: nil, code: nil,
      detail: primaryEnabled
        ? "只读探针看不到输入菜单缓存。若已 enabled 但菜单仍不列「法墨」= FAMO-TIS-006（菜单缓存未刷新）：等软/硬窗自然翻绿或用手动菜单代理刷新按钮"
        : "未评估（主输入源未启用）"))

    // 6. clientAttach — read-only ceiling; per-app IMK attach needs a live app
    layers.append(LayerResult(
      layer: .clientAttach, ok: nil, code: nil,
      detail: "系统当前输入源 = \(currentSourceID ?? "无")。某 App 的 IMK client 是否 attach 需活跃 App：TIS 全绿但某「已打开」App 无输入 = FAMO-TIS-005，重开该 App（系统天花板，微信同款）"))

    let firstFailing = layers.first { $0.ok == false }
    return TISDiagnosis(layers: layers, firstFailingLayer: firstFailing?.layer, code: firstFailing?.code)
  }

  /// Short remediation line per headline code (§6 修复/预防 column, condensed).
  static func actionText(for code: String) -> String {
    switch code {
    case "FAMO-INSTALL-001": return "Famo 未装在 /Library/Input Methods/Famo.app —— 用 DMG 安装器安装，勿手动 cp。"
    case "FAMO-TIS-001": return "系统查不到 Famo 输入源 —— 核对 codesign/spctl/xattr/权限后重跑 --install。"
    case "FAMO-TIS-002": return "Famo 输入源不可启用 —— 只按精确 source id 操作、检查父条目；绝不按 localized name 选源。"
    case "FAMO-TIS-003": return "启用读回不一致 —— 运行 --enable-input-source；fresh-process 复核仍 false 说明未落地。"
    case "FAMO-TIS-004": return "选中半态/不可选 —— 先切 ABC 再在输入菜单重选「法墨」；必要时系统设置→键盘→输入法重加一次。"
    case "FAMO-DATA-001": return "数据目录缺失（可选中但无候选）—— 启动一次 Famo 部署 schema 到 ~/Library/Application Support/Famo；永不 fallback 到 ~/Library/Rime。"
    default: return userMessage[code] ?? code
    }
  }

  /// Assemble the full read-only report (TIS six layers + install identity + data-root existence).
  /// The only IO: TIS read, filesystem stat, installed Info.plist read. No mutation.
  static func buildReport() -> FamoTISReport {
    let expected = [FamoInstaller.InputMode.hans.rawValue, FamoInstaller.InputMode.hant.rawValue]
    let primary = FamoInstaller.InputMode.primary.rawValue
    let sources = FamoInstaller().famoSourceStates()
    let currentID = FamoInstaller.currentInputSourceID()
    let diag = classify(sources: sources, currentSourceID: currentID, expectedIDs: expected, primaryID: primary)

    let canonicalPath = "/Library/Input Methods/Famo.app"
    let installed = FileManager.default.fileExists(atPath: canonicalPath)
    let installedBundleID = installed
      ? NSDictionary(contentsOf: URL(fileURLWithPath: canonicalPath).appending(components: "Contents", "Info.plist"))?["CFBundleIdentifier"] as? String
      : nil
    let identity = FamoTISReport.Identity(
      expectedBundleID: FamoInstaller.inputSourcePrefix, expectedSourceIDs: expected, primarySourceID: primary,
      installPath: canonicalPath, installed: installed, installedBundleID: installedBundleID,
      bundleIDMatches: installedBundleID == FamoInstaller.inputSourcePrefix,
      runningBundlePath: FamoApp.appDir.path, installCode: installed ? nil : "FAMO-INSTALL-001")

    let userDir = FamoApp.userDir
    let dataExists = FileManager.default.fileExists(atPath: userDir.path)
    let dataRoot = FamoTISReport.DataRoot(path: userDir.path, exists: dataExists, code: dataExists ? nil : "FAMO-DATA-001")

    // Headline priority: not installed → TIS layer failure → data root missing.
    let summaryCode = identity.installCode ?? diag.code ?? dataRoot.code
    let summary = FamoTISReport.Summary(
      code: summaryCode, userMessage: summaryCode.flatMap { userMessage[$0] },
      firstFailingLayer: diag.firstFailingLayer,
      actionable: summaryCode.map { actionText(for: $0) }
        ?? "所有可只读判定的 TIS 层健康；menuVisible/clientAttach 属只读天花板，见对应层 detail。")

    return FamoTISReport(
      identity: identity, dataRoot: dataRoot, currentSourceID: currentID,
      sources: sources, layers: diag.layers, summary: summary)
  }
}

struct FamoTISReport: Codable {
  struct Identity: Codable {
    let expectedBundleID: String
    let expectedSourceIDs: [String]
    let primarySourceID: String
    let installPath: String
    let installed: Bool
    let installedBundleID: String?
    let bundleIDMatches: Bool
    let runningBundlePath: String
    let installCode: String?
  }
  struct DataRoot: Codable {
    let path: String
    let exists: Bool
    let code: String?
  }
  struct Summary: Codable {
    let code: String?
    let userMessage: String?
    let firstFailingLayer: ActivationLayer?
    let actionable: String
  }
  let identity: Identity
  let dataRoot: DataRoot
  let currentSourceID: String?
  let sources: [TISSourceState]
  let layers: [LayerResult]
  let summary: Summary
}

enum FamoActivationHealth {
  private static let markerURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("famo-last-host-key-event.txt")

  static func recordHostKeyEventOnce() {
    let text = ISO8601DateFormatter().string(from: Date())
    try? text.write(to: markerURL, atomically: true, encoding: .utf8)
  }

  static func lastHostKeyEventDate() -> String? {
    try? String(contentsOf: markerURL, encoding: .utf8)
  }
}
