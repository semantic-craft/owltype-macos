//
//  InputSource.swift
//  Owltype
//
//  Created by Leo Liu on 5/10/24.
//

import AppKit
import Foundation
import InputMethodKit
import Security

// MARK: - Input source install: register → enable → select (upstream Squirrel behavior)
//
// Keep only Owltype's own bundle identity (`im.owltype.inputmethod.Owltype[.Hans/.Hant]`) and use TIS as the
// activation surface. Do NOT write `AppleEnabledInputSources` directly: on modern macOS that plist
// omits third-party IMEs, and injecting a Owltype row creates duplicate TIS records that can leave the
// menu bar title selected while the input menu itself has no Owltype row.
//
// The selected-but-not-enabled half-state DIAGNOSTIC (`--detect-activation` /
// `detectAndGuideIfHalfState`) is kept: it only prints copyable recovery guidance and never blocks
// enable/select.

final class OwlInstaller {
  static let inputSourcePrefix = "im.owltype.inputmethod.Owltype"
  static let squirrelInputSourcePrefix = ["im", "rime", "inputmethod", "Squirrel"].joined(separator: ".")

  enum InputMode: String, CaseIterable {
    static let primary = Self.hans
    case hans = "im.owltype.inputmethod.Owltype.Hans"
    case hant = "im.owltype.inputmethod.Owltype.Hant"

    /// 面向用户的模式名，只给结果文案用。日志与诊断一律继续用 `rawValue` 的精确 source id。
    var displayName: String {
      switch self {
      case .hans: return "猫头鹰（简体）"
      case .hant: return "猫头鹰（繁体）"
      }
    }
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
    TISRegisterInputSource(OwlApp.appDir as CFURL)
    notifyInputSourcesChanged()
    Self.refreshInputMenuAgents()
  }

  func register() {
    let enabledInputModes = enabledModes()
    if !enabledInputModes.isEmpty {
      print("User already registered Owltype method(s): \(enabledInputModes.map { $0.rawValue })")
      return
    }
    TISRegisterInputSource(OwlApp.appDir as CFURL)
    print("Registered input source from \(OwlApp.appDir)")
  }

  func enable(modes: [InputMode] = []) {
    let enabledInputModes = enabledModes()
    if !enabledInputModes.isEmpty && modes.isEmpty {
      print("User already enabled Owltype method(s): \(enabledInputModes.map { $0.rawValue })")
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

  /// 「未启用则 enable → select → notify」这条既有链路刚才到底做成了什么。加这个返回值没有改动任何
  /// TIS 行为（同样的调用、同样的打印、同样的 notify），只是把结果 return 出来，供 `makeDefault()`
  /// 那层薄包装分三态文案。要点：`alreadySelected` 走的正是那句 "Failed to select" 的打印分支 ——
  /// 「已经就是当前输入源」不是失败，调用方绝不能据此报错。
  enum SelectOutcome: Equatable {
    case selected
    case alreadySelected
    case notEnabled
    case notSelectable
    case sourceMissing
    case selectFailed(OSStatus)
  }

  @discardableResult
  func select(mode: InputMode? = nil) -> SelectOutcome {
    let enabledInputModes = enabledModes()
    let modeToSelect = mode ?? .primary
    if !enabledInputModes.contains(modeToSelect) {
      if mode != nil {
        enable(modes: [modeToSelect])
      } else {
        print("Default method not enabled yet: \(modeToSelect.rawValue)")
        return .notEnabled
      }
    }
    var outcome = SelectOutcome.sourceMissing
    for (mode, inputSource) in getInputSource(modes: [modeToSelect]) {
      let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled)
      let selectable = getBool(for: inputSource, key: kTISPropertyInputSourceIsSelectCapable)
      let selected = getBool(for: inputSource, key: kTISPropertyInputSourceIsSelected)
      if enabled == true, selectable == true, selected == false {
        let error = TISSelectInputSource(inputSource)
        print("Selection \(error == noErr ? "succeeds" : "fails") for input source: \(mode.rawValue)")
        outcome = error == noErr ? .selected : .selectFailed(error)
      } else {
        print("Failed to select \(mode.rawValue)")
        outcome = selected == true ? .alreadySelected : (selectable != true ? .notSelectable : .notEnabled)
      }
    }
    notifyInputSourcesChanged()
    return outcome
  }

  // MARK: - 「设为系统默认输入法」：只有设置页的用户点击可以走这里
  //
  // macOS 没有 set-default API，也没有排序 API。系统在切换输入源时把它写进
  // `AppleSelectedInputSources`，那才是登录时恢复的目标 —— 所以 enable + select 就是「默认」在这台
  // 机器上能达到的全部含义（「第三方列表顺序决定默认」已被对照实验证伪）。因此下面不新增任何 TIS 逻辑，只是把上面那条既有链路包成三态结果给 UI。
  //
  // no-steal 边界：`makeDefault()` 只能由用户在设置页显式点击触发。安装 / 更新 / 启动路径一律不得
  // 复用 —— 程序自作主张抢用户当前的输入源正是 no-steal 禁止的事。

  enum MakeDefaultResult: Equatable {
    case alreadyDefault(mode: InputMode)
    case madeDefault(mode: InputMode)
    case failed(reason: String)
  }

  /// 判定先于动作：已启用且已选中就直接判「已是默认」，一个 TIS 调用都不发。
  enum MakeDefaultPlan: Equatable {
    case alreadyDefault(InputMode)
    case select(InputMode)
  }

  /// 纯决策，无 TIS、无 IO。模式选择：优先**已启用**的猫头鹰模式 —— 只启用了繁体的用户点「设为默认」
  /// 必须落在繁体，盲选 primary 会把人切到简体；两个都没启用才回落 primary，由 select 顺手 enable。
  static func makeDefaultPlan(enabledModes: Set<InputMode>, currentSourceID: String?) -> MakeDefaultPlan {
    if let currentSourceID, let mode = InputMode(rawValue: currentSourceID), enabledModes.contains(mode) {
      return .alreadyDefault(mode)
    }
    return .select(InputMode.allCases.first { enabledModes.contains($0) } ?? .primary)
  }

  /// 把链路结果翻成用户看得懂的三态。纯函数。
  static func makeDefaultResult(mode: InputMode, outcome: SelectOutcome) -> MakeDefaultResult {
    switch outcome {
    case .selected:
      return .madeDefault(mode: mode)
    case .alreadySelected:
      return .alreadyDefault(mode: mode)
    case .selectFailed(let status):
      if status == paramErr {
        return .failed(
          reason: "系统拒绝切换到\(mode.displayName)（TIS 错误 \(status)）。请到 系统设置 → 键盘 → 输入法 → 编辑… 里重新加入猫头鹰后再试。")
      }
      return .failed(reason: "系统拒绝切换到\(mode.displayName)（TIS 错误 \(status)）。")
    case .notEnabled:
      return .failed(reason: "\(mode.displayName)尚未真正启用。请到 系统设置 → 键盘 → 输入法 → 编辑… 里加一次猫头鹰，再回来重试。")
    case .notSelectable:
      return .failed(reason: "\(mode.displayName)当前不可选中。请到 系统设置 → 键盘 → 输入法 → 编辑… 里移除猫头鹰后重新加入。")
    case .sourceMissing:
      return .failed(reason: "系统里查不到\(mode.displayName)（\(mode.rawValue)）。请重新安装猫头鹰。")
    }
  }

  /// 用户点击「设为系统默认输入法」的唯一入口。
  func makeDefault() -> MakeDefaultResult {
    let plan = Self.makeDefaultPlan(
      enabledModes: Set(enabledModes()), currentSourceID: Self.currentInputSourceID())
    switch plan {
    case .alreadyDefault(let mode):
      return .alreadyDefault(mode: mode)
    case .select(let mode):
      return Self.makeDefaultResult(mode: mode, outcome: select(mode: mode))
    }
  }

  /// `--select-input-source <arg>` 的纯 CLI 分发决策：参数是猫头鹰自家输入模式，还是任意系统输入源 id
  /// （如 `com.apple.keylayout.ABC`，postinstall 更新序列在 kill 旧进程前切出用）。纯函数、无 TIS ——
  /// 单测保证系统 id 绝不会误落回「选中猫头鹰」的无参默认路径。
  enum SelectTarget: Equatable {
    case owlMode(InputMode)
    case systemSource(String)
  }

  static func selectTarget(for argument: String) -> SelectTarget {
    if let mode = InputMode(rawValue: argument) {
      return .owlMode(mode)
    }
    return .systemSource(argument)
  }

  /// Select ANY system input source by exact id：`TISCreateInputSourceList` 按
  /// `kTISPropertyInputSourceID` 精确匹配（`inputSources` 字典即该映射）后 `TISSelectInputSource`。
  /// postinstall 更新序列用它切出到 ABC（见 `docs/operations/installation.md`）。best-effort：找不到 / 失败
  /// 只打印，不抛错——select 失败是常态（历史观察），绝不据此让安装失败。
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
      return "猫头鹰输入法（\(id)）"
    }
    if id.hasPrefix(squirrelInputSourcePrefix) {
      return "Squirrel（\(id)，当前不是猫头鹰）"
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
    /// A Owltype mode is the current selected source but its TIS enabled bit is false (the
    /// key-swallowing dead half-state).
    let brokenHalfState: Bool
    /// The mode involved, if any.
    let mode: InputMode?
  }

  /// Pure half-state detector: current selected id + which Owltype modes are enabled → is it the dead
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
    let label = mode?.rawValue ?? OwlInstaller.InputMode.primary.rawValue
    return """
    [猫头鹰激活诊断] 检测到“已选中但未真正启用”的死半态：当前输入法是 \(label)，但它没有被真正启用，\
    会吞掉所有按键（包括英文）。
    一键恢复步骤（请手动在系统设置中操作，不要让程序自动改你正在用的输入法）：
      1. 打开 系统设置 → 键盘 → 输入法 → 点“编辑…”（System Settings → Keyboard → Input Sources → Edit…）。
      2. 若列表里有“猫头鹰/Owltype”，先用减号(−)移除，再用加号(+) → 简体中文 → 重新加入“猫头鹰”。
      3. 若列表里没有“猫头鹰”，直接用加号(+)添加。
      4. 加回后从右上角输入法菜单切到“猫头鹰”，测试能否打字。
    判断是否启用，请以上面“输入法 → 编辑…”里的列表为准；不要用 \
    `defaults read … AppleEnabledInputSources` 来核对——新版 macOS 不在该列表收录第三方输入法，会误判为“未启用”。
    """
  }

  static func activationStatusText() -> String {
    activationStatusText(
      currentInputSourceID: currentInputSourceID() ?? "未知",
      lastHostKeyEventDate: OwlActivationHealth.lastHostKeyEventDate()
    )
  }

  static func activationStatusText(currentInputSourceID current: String, lastHostKeyEventDate: String?) -> String {
    let handleStatus = lastHostKeyEventDate.map {
      "最近一次宿主按键进入 Owltype handle(): \($0)"
    } ?? "本次登录尚未观察到宿主按键进入 Owltype handle()。若菜单已选中猫头鹰但打字无反应，请在系统设置 → 键盘 → 输入法里手动添加一次猫头鹰。"
    return """
    [猫头鹰激活诊断]
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

  /// Read-only snapshot of every installed input source under Owltype's prefix (id + the four TIS
  /// capability/state bits + labels). Fresh-process read via the lazy `inputSources` map — Law 4 is
  /// satisfied when this runs from the short-lived `--diagnose-tis` CLI. Never mutates TIS.
  func owlSourceStates() -> [TISSourceState] {
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
// "installed but not usable" maps to a specific OWL-* code instead of "reboot/logout". Read-only:
// no enable/select/disable, no `AppleEnabledInputSources` write. Law 4: `Owltype --diagnose-tis` is a
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

/// One LaunchServices claim on Owltype's bundle identifier: the bundle that claims it, and the Team ID
/// its signature carries. `teamID == nil` means unsigned or ad-hoc — the shape every local build
/// has. Pure value, so the classifier below is unit-testable without touching LaunchServices.
struct LSBundleClaim: Equatable, Codable {
  let path: String
  let teamID: String?
}

/// Read-only verdict on who claims Owltype's bundle identifier. macOS resolves an input method by
/// bundle id, so a second claimant can be resolved *instead of* the installed copy at login: the
/// IMK service fails to come up and the system falls through to the next input source. That is the
/// measured cause of 「重启后默认输入法变成别家」 on this developer machine, and it regenerates every
/// time a build runs.
///
/// Advisory by design: `code` never becomes `OwlTISReport.Summary.code`. A shadowing development
/// build is a developer-machine condition, not a broken install, and check-installed.sh treats any
/// summary code as a failure.
struct LSClaimReport: Equatable, Codable {
  let bundleID: String
  let claimCount: Int
  let unsignedCount: Int
  let claims: [LSBundleClaim]
  let code: String?
  let detail: String
}

enum OwlTISDiagnostics {
  /// §5 user-facing message per OWL-* code (developer meaning stays in each layer's `detail`).
  static let userMessage: [String: String] = [
    "OWL-TIS-001": "系统尚未识别 Owltype 输入源。",
    "OWL-TIS-002": "Owltype 输入源无法启用。",
    "OWL-TIS-003": "Owltype 输入源启用结果不一致。",
    "OWL-TIS-004": "Owltype 输入源无法选中。",
    "OWL-TIS-005": "当前 App 未连接到 Owltype。",
    "OWL-TIS-006": "输入菜单尚未显示 Owltype。",
    "OWL-INSTALL-001": "Owltype 未安装在系统输入法目录。",
    "OWL-SIGN-001": "Owltype 签名校验未通过。",
    "OWL-SIGN-002": "Owltype 发布物未通过系统安全评估。",
    "OWL-DATA-001": "Owltype 数据目录不可用。",
    "OWL-DATA-002": "检测到非 Owltype 数据路径写入。",
    "OWL-UPDATE-001": "更新时仍有旧输入连接。",
    "OWL-LS-001": "多个构建认领同一 bundle id，装机版可能被遮蔽。",
    "OWL-LS-002": "存在未签名构建认领同一 bundle id。",
  ]

  /// PURE six-layer classifier. `sources` is the installed set already filtered to Owltype's prefix.
  /// No TIS, no IO — the §6 root-cause matrix 活跃 rows are its unit tests.
  static func classify(
    sources: [TISSourceState], currentSourceID: String?, expectedIDs: [String], primaryID: String
  ) -> TISDiagnosis {
    var layers: [LayerResult] = []
    let registered = !sources.isEmpty
    let presentIDs = Set(sources.map { $0.id })
    let primaryPresent = presentIDs.contains(primaryID)
    let primary = sources.first { $0.id == primaryID }
    // Half-state precedence: the current source is a Owltype source whose enabled bit is false — the
    // key-swallowing dead state. This is a select-layer pathology (004), not an enable failure.
    let halfState = currentSourceID.flatMap { cur in sources.first { $0.id == cur && !$0.enabled } }

    // 1. register
    layers.append(LayerResult(
      layer: .register, ok: registered, code: registered ? nil : "OWL-TIS-001",
      detail: registered
        ? "\(sources.count) 个 Owltype 输入源可枚举（TISCreateInputSourceList includeAllInstalled=true）"
        : "0 个 Owltype 输入源可枚举 → 未注册（核对安装路径/签名/Info.plist）"))

    // 2. enumerate
    let missing = expectedIDs.filter { !presentIDs.contains($0) }
    if !registered {
      layers.append(LayerResult(layer: .enumerate, ok: nil, code: nil, detail: "未评估（register 失败）"))
    } else if !primaryPresent {
      layers.append(LayerResult(
        layer: .enumerate, ok: false, code: "OWL-TIS-001",
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
        layer: .enable, ok: nil, code: nil, detail: "enabled=false，属选中半态，见 select 层（OWL-TIS-004）"))
    } else if let primary, !primary.enableCapable {
      layers.append(LayerResult(
        layer: .enable, ok: false, code: "OWL-TIS-002",
        detail: "主输入源 \(primaryID) 不可启用（IsEnableCapable=false / 父条目未启用）"))
    } else if let wrong = sources.first(where: { $0.enabled && !expectedIDs.contains($0.id) }) {
      layers.append(LayerResult(
        layer: .enable, ok: false, code: "OWL-TIS-002",
        detail: "启用了非期望输入源 \(wrong.id) 而非 \(primaryID)（enable 打在错误条目/按名称选择）—— 只按精确 source id 操作"))
    } else {
      layers.append(LayerResult(
        layer: .enable, ok: false, code: "OWL-TIS-003",
        detail: "主输入源 \(primaryID) 可启用但读回 enabled=false —— 运行 --enable-input-source；读回仍 false = 启用不一致"))
    }

    // 4. select
    if !registered || !primaryPresent {
      layers.append(LayerResult(layer: .select, ok: nil, code: nil, detail: "未评估（主输入源不可枚举）"))
    } else if let half = halfState {
      layers.append(LayerResult(
        layer: .select, ok: false, code: "OWL-TIS-004",
        detail: "当前源 \(half.id) 已选中但 enabled=false（吞键死半态）—— 先切 ABC 再重选「猫头鹰」，或系统设置→键盘→输入法重加一次"))
    } else if let primary, primary.enabled {
      if !primary.selectCapable {
        layers.append(LayerResult(
          layer: .select, ok: false, code: "OWL-TIS-004",
          detail: "主输入源 \(primaryID) 已启用但不可选中（IsSelectCapable=false）"))
      } else if primary.selected {
        layers.append(LayerResult(layer: .select, ok: true, code: nil, detail: "主输入源 \(primaryID) 已选中（当前）"))
      } else {
        layers.append(LayerResult(
          layer: .select, ok: true, code: nil,
          detail: "主输入源 \(primaryID) 已启用且可选中；当前未选中 —— 在输入菜单选「猫头鹰」即可"))
      }
    } else {
      layers.append(LayerResult(layer: .select, ok: nil, code: nil, detail: "未评估（主输入源未启用）"))
    }

    // 5. menuVisible — read-only ceiling; surfaces the OWL-TIS-006 candidate note
    let primaryEnabled = primary?.enabled ?? false
    layers.append(LayerResult(
      layer: .menuVisible, ok: nil, code: nil,
      detail: primaryEnabled
        ? "只读探针看不到输入菜单缓存。若已 enabled 但菜单仍不列「猫头鹰」= OWL-TIS-006（菜单缓存未刷新）：等软/硬窗自然翻绿或用手动菜单代理刷新按钮；刷新后仍不列 = 会话层拒收（TIS 全绿也无用户态解法，2026-08-12 本机实证），注销重登即愈"
        : "未评估（主输入源未启用）"))

    // 6. clientAttach — read-only ceiling; per-app IMK attach needs a live app
    layers.append(LayerResult(
      layer: .clientAttach, ok: nil, code: nil,
      detail: "系统当前输入源 = \(currentSourceID ?? "无")。某 App 的 IMK client 是否 attach 需活跃 App：TIS 全绿但某「已打开」App 无输入 = OWL-TIS-005，重开该 App（系统天花板，微信同款）"))

    let firstFailing = layers.first { $0.ok == false }
    return TISDiagnosis(layers: layers, firstFailingLayer: firstFailing?.layer, code: firstFailing?.code)
  }

  /// PURE claim classifier over whatever LaunchServices resolves for `bundleID`, in any order.
  /// Two conditions are worth a code, and an unsigned claimant wins the headline because it names
  /// the mechanism: a bundle with no Team ID is a local build, and resolving to it is what breaks
  /// the login restore. Exactly one signed claimant — the installed copy — is the healthy shape.
  static func classifyClaims(bundleID: String, claims: [LSBundleClaim]) -> LSClaimReport {
    let sorted = claims.sorted { $0.path < $1.path }
    let unsigned = sorted.filter { ($0.teamID ?? "").isEmpty }
    let paths = sorted.map { $0.path }.joined(separator: "、")
    let code: String?
    let detail: String
    if !unsigned.isEmpty {
      code = "OWL-LS-002"
      detail = "\(sorted.count) 个 bundle 认领 \(bundleID)，其中 \(unsigned.count) 个无 teamID（未签名 / ad-hoc 开发构建）："
        + "\(unsigned.map { $0.path }.joined(separator: "、"))"
    } else if sorted.count > 1 {
      code = "OWL-LS-001"
      detail = "\(sorted.count) 个已签名 bundle 认领 \(bundleID)：\(paths)；只应有装机版一条，其余会遮蔽它"
    } else if let only = sorted.first {
      code = nil
      detail = "唯一认领 \(only.path)（teamID \(only.teamID ?? "")）"
    } else {
      code = nil
      detail = "LaunchServices 解析不到 \(bundleID) 的任何认领 —— 未安装或未注册，见 register 层与 OWL-INSTALL-001"
    }
    return LSClaimReport(
      bundleID: bundleID, claimCount: sorted.count, unsignedCount: unsigned.count,
      claims: sorted, code: code, detail: detail)
  }

  /// LaunchServices claims on `bundleID`. Read-only: resolves the registration database, mutates
  /// nothing.
  ///
  /// Honest ceiling, same spirit as the `ok == nil` layers: this sees only claimants whose bundle
  /// still exists. Registrations left behind by deleted build directories are invisible here —
  /// `scripts/ime-check.sh` lists those and `scripts/clean-dev.sh` sweeps them. A *live* competing
  /// build is the case that changes which bundle macOS resolves, so it is the set worth reporting,
  /// and it is the only one affordable: an `lsregister -dump` scan takes ~15s on this machine and
  /// would blow the 20s budget check-installed.sh puts on `--diagnose-tis`.
  static func launchServicesClaims(for bundleID: String) -> [LSBundleClaim] {
    NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).map {
      LSBundleClaim(path: $0.path, teamID: teamID(ofBundleAt: $0))
    }
  }

  /// Team ID from a bundle's code signature, `nil` when it carries none (unsigned or ad-hoc).
  /// Reads the signature as recorded on disk; never validates, never mutates.
  private static func teamID(ofBundleAt url: URL) -> String? {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
          let staticCode else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(
      staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let signing = information as? [String: Any] else { return nil }
    return signing[kSecCodeInfoTeamIdentifier as String] as? String
  }

  /// Short remediation line per headline code (§6 修复/预防 column, condensed).
  static func actionText(for code: String) -> String {
    switch code {
    case "OWL-INSTALL-001": return "Owltype 未装在 /Library/Input Methods/Owltype.app —— 用 DMG 安装器安装，勿手动 cp。"
    case "OWL-TIS-001": return "系统查不到 Owltype 输入源 —— 核对 codesign/spctl/xattr/权限后重跑 --install。"
    case "OWL-TIS-002": return "Owltype 输入源不可启用 —— 只按精确 source id 操作、检查父条目；绝不按 localized name 选源。"
    case "OWL-TIS-003": return "启用读回不一致 —— 运行 --enable-input-source；fresh-process 复核仍 false 说明未落地。"
    case "OWL-TIS-004": return "选中半态/不可选 —— 先切 ABC 再在输入菜单重选「猫头鹰」；必要时系统设置→键盘→输入法重加一次。"
    case "OWL-LS-001": return "同一 bundle id 被多个 bundle 认领 —— 跑 scripts/clean-dev.sh --apply，只留装机版一条认领。"
    case "OWL-LS-002": return "未签名（ad-hoc）开发构建认领了同一 bundle id，登录可能解析到它 —— 跑 scripts/clean-dev.sh --apply。"
    case "OWL-DATA-001": return "数据目录缺失（可选中但无候选）—— 启动一次 Owltype 部署 schema 到 ~/Library/Application Support/Owltype；永不 fallback 到 ~/Library/Rime。"
    default: return userMessage[code] ?? code
    }
  }

  /// Assemble the full read-only report (TIS six layers + install identity + data-root existence).
  /// The only IO: TIS read, filesystem stat, installed Info.plist read. No mutation.
  static func buildReport() -> OwlTISReport {
    let expected = [OwlInstaller.InputMode.hans.rawValue, OwlInstaller.InputMode.hant.rawValue]
    let primary = OwlInstaller.InputMode.primary.rawValue
    let sources = OwlInstaller().owlSourceStates()
    let currentID = OwlInstaller.currentInputSourceID()
    let diag = classify(sources: sources, currentSourceID: currentID, expectedIDs: expected, primaryID: primary)

    let canonicalPath = "/Library/Input Methods/Owltype.app"
    let installed = FileManager.default.fileExists(atPath: canonicalPath)
    let installedBundleID = installed
      ? NSDictionary(contentsOf: URL(fileURLWithPath: canonicalPath).appending(components: "Contents", "Info.plist"))?["CFBundleIdentifier"] as? String
      : nil
    let identity = OwlTISReport.Identity(
      expectedBundleID: OwlInstaller.inputSourcePrefix, expectedSourceIDs: expected, primarySourceID: primary,
      installPath: canonicalPath, installed: installed, installedBundleID: installedBundleID,
      bundleIDMatches: installedBundleID == OwlInstaller.inputSourcePrefix,
      runningBundlePath: OwlApp.appDir.path, installCode: installed ? nil : "OWL-INSTALL-001")

    let userDir = OwlApp.userDir
    let dataExists = FileManager.default.fileExists(atPath: userDir.path)
    let dataRoot = OwlTISReport.DataRoot(path: userDir.path, exists: dataExists, code: dataExists ? nil : "OWL-DATA-001")

    // Who else claims this bundle id. Deliberately outside the headline: a shadowing development
    // build is a developer-machine condition (§1.3 结论 D), and folding it into `summaryCode` would
    // turn a healthy install red in check-installed.sh. It reports; clean-dev.sh acts, by hand.
    let launchServices = classifyClaims(
      bundleID: OwlInstaller.inputSourcePrefix,
      claims: launchServicesClaims(for: OwlInstaller.inputSourcePrefix))

    // Headline priority: not installed → TIS layer failure → data root missing.
    let summaryCode = identity.installCode ?? diag.code ?? dataRoot.code
    let summary = OwlTISReport.Summary(
      code: summaryCode, userMessage: summaryCode.flatMap { userMessage[$0] },
      firstFailingLayer: diag.firstFailingLayer,
      actionable: summaryCode.map { actionText(for: $0) }
        ?? "所有可只读判定的 TIS 层健康；menuVisible/clientAttach 属只读天花板，见对应层 detail。")

    return OwlTISReport(
      identity: identity, dataRoot: dataRoot, launchServices: launchServices, currentSourceID: currentID,
      sources: sources, layers: diag.layers, summary: summary)
  }
}

struct OwlTISReport: Codable {
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
  let launchServices: LSClaimReport
  let currentSourceID: String?
  let sources: [TISSourceState]
  let layers: [LayerResult]
  let summary: Summary
}

enum OwlActivationHealth {
  private static let markerURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("owl-last-host-key-event.txt")

  static func recordHostKeyEventOnce() {
    let text = ISO8601DateFormatter().string(from: Date())
    try? text.write(to: markerURL, atomically: true, encoding: .utf8)
  }

  static func lastHostKeyEventDate() -> String? {
    try? String(contentsOf: markerURL, encoding: .utf8)
  }
}
