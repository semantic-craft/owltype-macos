// InstallerTISProbe — `OwltypeInstaller --tis-probe` 自探针（fresh 进程 TIS 真值，1.3.32-fix2）。
//
// 为什么必须 fresh 进程：安装器老进程的 TIS 快照陈旧，读不到 consent 之后的变更（1.3.32-fix1
// QA 真机：装前已开的 App 打不出、新开的 App 能打——同机理），进程内 TISCreateInputSourceList
// 读回因此假阴性、误弹注销引导。verifier 每 tick spawn 自身可执行文件带 `--tis-probe`，由
// main.swift 在 SwiftUI App 生命周期启动前拦截到这里：直查 TIS、单行输出真值、exit(0)——
// 不进 NSApplication/SwiftUI，无窗口无 Dock 图标。读法与 QA DIAG 探针对齐（swiftc fresh 进程
// 实证读值为真）：
//   - parent = 父条目 IsEnabled 位（父条目无 tsInputModeDefaultStateKey，该位可信；
//     定律 4 只废 default-on 模式的位）；
//   - hans = enabled-only 列表（TISCreateInputSourceList(nil, false)）成员资格；
//   - hansSelectCapable = Hans 的 IsSelectCapable 位（诊断参考，不进 verified 判定）。
// 输出格式/解析是 InstallerActivationPolicy 的纯函数（probeOutput/parseProbeOutput），两端单测。

import Foundation
import Carbon

enum InstallerTISProbe {
    /// 单行机器可读输出，如 `parent=1 hans=1 hansSelectCapable=1`。
    static func output() -> String {
        InstallerActivationPolicy.probeOutput(currentSignals())
    }

    private static func currentSignals() -> InstallerActivationPolicy.ProbeSignals {
        InstallerActivationPolicy.ProbeSignals(
            parentEnabled: boolProperty(
                of: findSource(id: Installer.inputMethodID, includeAllInstalled: true),
                key: kTISPropertyInputSourceIsEnabled),
            primaryModeEnabled: findSource(
                id: Installer.primaryModeID, includeAllInstalled: false) != nil,
            primaryModeSelectCapable: boolProperty(
                of: findSource(id: Installer.primaryModeID, includeAllInstalled: true),
                key: kTISPropertyInputSourceIsSelectCapable))
    }

    private static func boolProperty(of source: TISInputSource?, key: CFString) -> Bool {
        guard let source,
              let ref = TISGetInputSourceProperty(source, key),
              let value = unsafeBitCast(ref, to: CFBoolean?.self) else {
            return false
        }
        return CFBooleanGetValue(value)
    }

    /// 每次都新取列表（本进程刚启动，本来就是 fresh 快照——这正是探针存在的意义）。
    private static func findSource(id: String, includeAllInstalled: Bool) -> TISInputSource? {
        guard let cfList = TISCreateInputSourceList(nil, includeAllInstalled)?.takeRetainedValue(),
              let list = cfList as? [TISInputSource] else {
            return nil
        }
        return list.first { source in
            guard let ref = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
                return false
            }
            return (unsafeBitCast(ref, to: CFString.self) as String) == id
        }
    }
}
