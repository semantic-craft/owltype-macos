// Local acceptance harness. Never installs, types, changes input sources, or closes windows.
import AppKit
import ApplicationServices
import Carbon

struct Binding: Codable, Equatable {
    let pid: Int32
    let launched: Double
    let executable: String
    let window: Int
    let title: String
    let document: String
}
struct Observation: Codable {
    let binding: Binding
    let observedAt: Double
    let frontPID: Int32?
    let focused: Bool
    let source: String
    let nihaoCount: Int
}
enum Failure: Error { case stop(String) }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure.stop(message) }
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func textCount(_ element: AXUIElement, depth: Int = 0) -> Int? {
    guard depth < 12 else { return nil }
    if attribute(element, kAXRoleAttribute) as? String == kAXTextAreaRole,
       let text = attribute(element, kAXValueAttribute) as? String {
        return text.components(separatedBy: "你好").count - 1
    }
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(128) {
        if let count = textCount(child, depth: depth + 1) { return count }
    }
    return nil
}
func resolve(_ pid: Int32, _ title: String) throws -> (Binding, AXUIElement) {
    try require(AXIsProcessTrusted(), "Accessibility permission unavailable; no installation permitted")
    guard let app = NSRunningApplication(processIdentifier: pid),
          let launched = app.launchDate, let executable = app.executableURL?.path else {
        throw Failure.stop("Host is no longer running")
    }
    try require(executable == "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit", "Unexpected host executable")
    let element = AXUIElementCreateApplication(pid)
    let windows = attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? []
    let matches = windows.filter { attribute($0, kAXTitleAttribute) as? String == title }
    try require(matches.count == 1, "Expected exactly one named window in the bound PID")
    guard let document = attribute(matches[0], kAXDocumentAttribute) as? String,
          URL(string: document)?.isFileURL == true else { throw Failure.stop("Missing document URL") }
    let cg = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
    let owned = cg.filter {
        ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
        $0[kCGWindowName as String] as? String == title
    }
    try require(owned.count == 1, "Window ownership unavailable or ambiguous; check screen permission")
    guard let number = owned[0][kCGWindowNumber as String] as? Int else { throw Failure.stop("Missing window ID") }
    return (Binding(pid: pid, launched: launched.timeIntervalSince1970, executable: executable,
                    window: number, title: title, document: document), matches[0])
}
func observe(_ expected: Binding) throws -> Observation {
    let (actual, window) = try resolve(expected.pid, expected.title)
    try require(actual == expected, "Host/window identity changed; do not reopen or silently rebind")
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let focused = attribute(AXUIElementCreateApplication(expected.pid), kAXFocusedWindowAttribute)
    let input = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let value = TISGetInputSourceProperty(input, kTISPropertyInputSourceID)
    let source = value.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? ""
    guard let count = textCount(window) else { throw Failure.stop("Cannot read bound test window text") }
    return Observation(binding: actual, observedAt: Date().timeIntervalSince1970, frontPID: front,
                       focused: front == expected.pid && focused.map { CFEqual($0, window) } == true,
                       source: source, nihaoCount: count)
}
func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}
func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    try require(args.count >= 2, "Usage: bind PID TITLE | inspect BINDING.json | focus BINDING.json | new DOCUMENT")
    if args[0] == "bind" {
        try require(args.count == 3, "bind requires PID and exact title")
        guard let pid = Int32(args[1]) else { throw Failure.stop("Invalid PID") }
        try emit(resolve(pid, args[2]).0)
    } else if args[0] == "new" {
        let document = URL(fileURLWithPath: args[1]).standardizedFileURL
        try require(FileManager.default.fileExists(atPath: document.path), "Create a unique empty test file first")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        var opened: NSRunningApplication?
        var failure: Error?
        var done = false
        NSWorkspace.shared.open([document], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: config) { app, error in opened = app; failure = error; done = true }
        let deadline = Date().addingTimeInterval(10)
        while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard let app = opened else { throw failure ?? Failure.stop("New host launch timed out") }
        while Date() < deadline {
            if let result = try? resolve(app.processIdentifier, document.lastPathComponent) {
                try require(URL(string: result.0.document)?.standardizedFileURL == document, "Wrong new document")
                try emit(result.0); return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw Failure.stop("New host window unavailable; retain process for inspection")
    } else {
        let binding = try JSONDecoder().decode(Binding.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        if args[0] == "focus" {
            let (_, window) = try resolve(binding.pid, binding.title)
            _ = try observe(binding) // Verify all identities before changing focus.
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            NSRunningApplication(processIdentifier: binding.pid)?.activate(options: [])
            try require(AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success, "Cannot raise bound window")
            let deadline = Date().addingTimeInterval(3)
            repeat {
                let result = try observe(binding)
                if result.focused { try emit(result); return }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            } while Date() < deadline
            throw Failure.stop("Bound window did not become focused")
        }
        try require(args[0] == "inspect", "Unknown command")
        try emit(observe(binding))
    }
}
do { try run() } catch { fputs("STOP: \(error)\n", stderr); exit(1) }
