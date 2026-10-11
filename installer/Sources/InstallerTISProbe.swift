// Read-only fresh-process TIS diagnostics; installation uses the shared IME session driver.

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
