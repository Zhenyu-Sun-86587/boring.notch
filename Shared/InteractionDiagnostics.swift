import Foundation

/// Local metadata only. Off means no field evaluation, encoding or disk writes.
enum InteractionDiagnostics {
    static let preferenceKey = "island.interactionDebug"
    private static let writer = InteractionDiagnosticWriter(directory: FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("InteractionDiagnostics", isDirectory: true))
    static var enabled: Bool { writer.enabled }
    static var directory: URL { writer.directory }
    static func setEnabled(_ enabled: Bool) {
        writer.setEnabled(enabled)
        NotificationCenter.default.post(name: Notification.Name("InteractionDiagnosticsChanged"), object: nil)
    }
    static func record(_ area: String, _ event: String, _ fields: @autoclosure () -> [String: String] = [:]) {
        guard enabled else { return }
        writer.record(area, event, fields())
    }
    static func exportData() -> Data { writer.snapshot() }
    static func clear() { writer.clear() }
}

/// A serial bounded writer is shared by every interaction entry point in the host.
/// The helper returns request-scoped metadata through XPC, never a separate file.
final class InteractionDiagnosticWriter: @unchecked Sendable {
    let directory: URL
    private let limit: Int
    private let lock = NSLock()
    private var recording = false
    private var pending = 0
    private let queue = DispatchQueue(label: "BoringNotch.interaction-diagnostics", qos: .utility)
    private let runID = UUID().uuidString
    private var sequence: UInt64 = 0
    // Prevent accidental payload/credential/prefs dumps at future call sites.
    private static let allowed: Set<String> = [
        "direction", "clickCount", "region", "reason", "cause", "session", "request", "owner", "generation", "ticket", "activation",
        "window", "keyWindow", "windowKey", "visible", "canKey", "main", "active", "responder",
        "requestedResponder", "result", "enabled", "current", "handoff", "locked", "blocking",
        "ready", "wantsKeyboard", "attempted", "explicit", "allowed", "presented", "pending",
        "target", "foreground", "focused", "bundle", "helper", "ax", "post", "gui", "snapshot",
        "hasWindow", "hasElement", "owners", "screen", "mouseOwner", "keyboardSession",
        "key", "command", "composing", "repeating", "event", "eventNumber", "rowHit", "consumed",
        "selected", "index", "count", "busy", "pasting", "changeCount", "items", "bytes",
        "width", "height", "x", "y", "version", "build", "os", "errorDomain", "errorCode", "detail"
    ]
    init(directory: URL, limit: Int = 2 * 1_024 * 1_024) {
        self.directory = directory
        self.limit = max(1_024, limit)
    }
    var enabled: Bool { lock.lock(); defer { lock.unlock() }; return recording }
    func setEnabled(_ value: Bool) { lock.lock(); recording = value; lock.unlock() }
    func record(_ area: String, _ event: String, _ fields: [String: String]) {
        lock.lock()
        guard recording, pending < 128 else { lock.unlock(); return }
        pending += 1
        lock.unlock()
        let clean = fields.filter { Self.allowed.contains($0.key) }.mapValues { String($0.prefix(1_024)) }
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            guard enabled else { return }
            sequence &+= 1
            let row: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()),
                "uptime": ProcessInfo.processInfo.systemUptime, "sequence": sequence,
                "run": runID, "pid": ProcessInfo.processInfo.processIdentifier,
                "area": String(area.prefix(64)), "event": String(event.prefix(96)), "fields": clean]
            guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
            data.append(10)
            guard data.count <= limit else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let current = directory.appendingPathComponent("interactions.jsonl")
                if ((try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > limit - data.count {
                    let previous = directory.appendingPathComponent("interactions.previous.jsonl")
                    try? FileManager.default.removeItem(at: previous)
                    try FileManager.default.moveItem(at: current, to: previous)
                }
                if !FileManager.default.fileExists(atPath: current.path) {
                    FileManager.default.createFile(atPath: current.path, contents: nil,
                        attributes: [.posixPermissions: 0o600])
                }
                let file = try FileHandle(forWritingTo: current)
                defer { try? file.close() }
                try file.seekToEnd()
                try file.write(contentsOf: data)
            } catch { /* Diagnostics cannot alter interaction outcomes. */ }
        }
    }
    func snapshot() -> Data {
        queue.sync {
            var data = Data()
            for name in ["interactions.previous.jsonl", "interactions.jsonl"] {
                if let part = try? Data(contentsOf: directory.appendingPathComponent(name)) { data.append(part) }
            }
            return data
        }
    }
    func clear() {
        queue.sync {
            for name in ["interactions.previous.jsonl", "interactions.jsonl"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }
}
