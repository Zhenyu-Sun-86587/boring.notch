import Foundation

@main enum InteractionDiagnosticsChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = InteractionDiagnosticWriter(directory: directory, limit: 1_024)
        writer.record("fixture", "off", ["reason": "disabled"])
        precondition(writer.snapshot().isEmpty && !FileManager.default.fileExists(atPath: directory.path))
        var evaluated = false
        func fields() -> [String: String] { evaluated = true; return [:] }
        InteractionDiagnostics.record("fixture", "off", fields())
        precondition(!evaluated, "Disabled tracing evaluated metadata")
        writer.setEnabled(true)
        writer.record("fixture", "privacy", ["key": "return", "clipboard": "PRIVATE-CONTENT", "secret": "PRIVATE-KEY"])
        let privacy = String(decoding: writer.snapshot(), as: UTF8.self)
        precondition(!privacy.contains("PRIVATE-") && privacy.contains("return"))
        let group = DispatchGroup()
        for index in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                writer.record("fixture", "concurrent", ["index": String(index), "detail": String(repeating: "x", count: 120)])
                group.leave()
            }
        }
        group.wait()
        let exported = writer.snapshot()
        precondition(exported.count <= 2_048 && !exported.isEmpty, "Rotation exceeded two bounded files")
        var previous: UInt64 = 0
        for line in exported.split(separator: 10) {
            let row = try JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
            let sequence = (row["sequence"] as! NSNumber).uint64Value
            precondition(sequence > previous); previous = sequence
        }
        let path = directory.appendingPathComponent("interactions.jsonl").path
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600)
        writer.setEnabled(false)
        writer.record("fixture", "after-stop", ["reason": "disabled"])
        precondition(writer.snapshot() == exported, "Disabled capture changed logs")
        writer.clear()
        precondition(writer.snapshot().isEmpty)
        print("PASS interaction diagnostics: disabled zero writes/lazy fields, metadata allowlist, concurrent JSONL ordering, two-file rotation, private mode, stop, consistent export and clear")
    }
}
