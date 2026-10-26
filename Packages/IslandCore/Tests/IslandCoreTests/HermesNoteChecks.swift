import Foundation
import IslandCore

/// A selected file can have any basename and survive atomic replacement by a sync tool.
func singleMarkdownFileReadsAtomicReplacements() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let selected = folder.appendingPathComponent("我的任意名称.md")
    let unrelated = folder.appendingPathComponent("Today.md")
    let untouched = Data("unrelated file\n".utf8)
    try untouched.write(to: unrelated)
    try Data("\u{feff}# First\r\n".utf8).write(to: selected)
    try expect(try SurfaceFiles.coordinatedRead(selected) == "# First\r\n")

    let replacement = Data("\u{feff}# Synced\r\n- [ ] Existing\r\n".utf8)
    try replacement.write(to: selected, options: .atomic)
    try expect(try SurfaceFiles.coordinatedRead(selected).contains("# Synced"))
    try SurfaceFiles.appendTask("Answer\nsecond line", to: selected)
    let result = try Data(contentsOf: selected)
    try expect(result.starts(with: replacement))
    try expect(String(decoding: result, as: UTF8.self).hasSuffix("- [ ] Answer\r\n  second line\r\n"))
    try expect(try Data(contentsOf: unrelated) == untouched)

    try Data(repeating: 65, count: 65_537).write(to: selected, options: .atomic)
    try expectThrows { try SurfaceFiles.coordinatedRead(selected) }
    let invalid = Data([0xFF, 0xFE, 0xFF])
    try invalid.write(to: selected, options: .atomic)
    try expectThrows { try SurfaceFiles.appendTask("Preserve invalid data", to: selected) }
    try expect(try Data(contentsOf: selected) == invalid)
}
