// Production provider resolution and Shelf state; isolated files only, no user shelf or pasteboard.
import AppKit
import Combine
import IslandCore
import UniformTypeIdentifiers
import os
import ImageIO

enum Log {
    static let general = Logger(subsystem: "fixture", category: "general")
    static let shelf = Logger(subsystem: "fixture", category: "shelf")
}
struct StagedAttachment {
    let id: UUID
    let url: URL
    let temporary: Bool
    let bookmark: Data?
}
@MainActor final class ShelfPersistenceService {
    static let shared = ShelfPersistenceService()
    func load() -> [ShelfItem] { [] }
    func save(_ items: [ShelfItem]) {}
    func saveAsync(_ items: [ShelfItem]) async {}
}
enum TempFileType { case data(Data, suggestedName: String?) }
final class TemporaryFileStorageService {
    static let shared = TemporaryFileStorageService()
    func createTempFile(for type: TempFileType) async -> URL? { nil }
    func removeTemporaryFileIfNeeded(at url: URL) { try? FileManager.default.removeItem(at: url) }
}
struct Failure: Error { let message: String }
func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
func provider(_ type: UTType, _ data: Data) -> NSItemProvider {
    let result = NSItemProvider()
    result.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
        completion(data, nil)
        return nil
    }
    return result
}
@main enum ShelfContextChecks {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-context-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("中文 空格.md")
        try Data("ISOLATED-SHELF-FILE".utf8).write(to: file)
        let fileProvider = provider(.fileURL, Data(file.absoluteString.utf8))
        let pathProvider = provider(.fileURL, Data(file.path.utf8))
        let staged = try await ShelfDropService.stagingFiles(from: [fileProvider, pathProvider])
        try check(staged.count == 2 && staged.allSatisfy { $0.url == file && !$0.temporary }, "File URL/path failed to resolve")
        // Minimal real PNG from ImageIO, provider vends only data (no file representation).
        let bitmap = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let imageData = NSMutableData()
        let destination = CGImageDestinationCreateWithData(imageData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
        try check(CGImageDestinationFinalize(destination), "PNG fixture creation failed")
        let imageProvider = provider(.png, imageData as Data)
        imageProvider.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { completion in
            completion(Data("https://fixture.invalid/image.png".utf8), nil)
            return nil
        }
        let image = try await ShelfDropService.stagingFiles(from: [imageProvider])
        defer { for item in image { try? FileManager.default.removeItem(at: item.url) } }
        try check(image.count == 1 && image[0].temporary, "Data-only image was not staged")
        try check(try !AttachmentImage.jpeg(at: image[0].url).isEmpty, "Staged image cannot be encoded")
        let shelf = ShelfStateViewModel.shared
        let items = try await ShelfDropService.items(from: [fileProvider, imageProvider])
        shelf.add(items)
        defer { for item in items { shelf.remove(item) } }
        let context = try shelf.hermesAttachments(excluding: [])
        try check(context.count == 2 && context.allSatisfy { !$0.temporary && $0.bookmark != nil }, "Shelf snapshot lost scoped bookmarks or source ownership")
        try check(try shelf.hermesAttachments(excluding: Set(items.map(\.id))).isEmpty, "Excluded Shelf files still attached")
        try check(FileManager.default.fileExists(atPath: file.path), "Snapshot consumed original source")
        let stale = ShelfItem(kind: .file(bookmark: Data([0xff])))
        shelf.add([stale])
        try check(try shelf.hermesAttachments(excluding: [stale.id]).count == 2, "Excluded stale file prevented submission")
        do { _ = try shelf.hermesAttachments(excluding: []); throw Failure(message: "Stale file silently omitted") }
        catch is Failure { throw Failure(message: "Stale file silently omitted") }
        catch {}
        shelf.remove(stale)
        do { _ = try await ShelfDropService.items(from: [NSItemProvider()]); throw Failure(message: "Failed drop silently succeeded") }
        catch is Failure { throw Failure(message: "Failed drop silently succeeded") }
        catch {}
        print("PASS: production Shelf provider files/UTF8 paths/data-only images; bookmark snapshots, explicit exclusions, preserved sources and surfaced failures")
    }
}
