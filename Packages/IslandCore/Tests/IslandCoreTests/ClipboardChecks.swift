import Foundation
import IslandCore
import ImageIO
import UniformTypeIdentifiers

private struct ClipboardCheckError: Error { let detail: String }
private func clipboardAssert(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
    if !condition() { throw ClipboardCheckError(detail: detail) }
}

/// Called by the core check executable. Every file is isolated below a fresh temporary fixture.
func runClipboardHistoryChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-check-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let history = ClipboardHistory(directory: root)
    let now = Date()
    let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.clear(CGRect(x: 0, y: 0, width: 2, height: 2))
    let generated = NSMutableData()
    let destination = CGImageDestinationCreateWithData(generated, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    try clipboardAssert(CGImageDestinationFinalize(destination), "PNG fixture encoding")
    let png = generated as Data
    let payload = ClipboardPayload(items: [
        .init(representations: [.init(type: "public.png", data: png), .init(type: "public.tiff", data: Data([0x49, 0x49, 0x2a, 0]))]),
        .init(representations: [.init(type: "public.utf8-plain-text", data: Data("中文\nsecond item".utf8))])
    ])
    let first = try await history.insert(payload, title: "图片", searchableText: "中文", kind: .image,
                                        sourceBundleID: "test.fixture", sourceName: "Fixture", now: now)
    try clipboardAssert(first.count == 1 && first[0].itemCount == 2, "multi-item snapshot")
    let reloaded = ClipboardHistory(directory: root)
    let restored = try await reloaded.payload(id: first[0].id)
    try clipboardAssert(restored == payload, "image and rich representations persist byte-for-byte")
    let repeated = try await history.insert(payload, title: "same", searchableText: "中文", kind: .image,
                                           sourceBundleID: nil, sourceName: nil, now: now.addingTimeInterval(1))
    try clipboardAssert(repeated.count == 1 && repeated[0].copiedAt > now, "hash dedup updates recency")
    _ = try await history.setFavorite(id: first[0].id, value: true)
    let text = ClipboardPayload(items: [.init(representations: [.init(type: "public.utf8-plain-text", data: Data("other".utf8))])])
    _ = try await history.insert(text, title: "other", searchableText: "other", kind: .text,
                                 sourceBundleID: nil, sourceName: nil, now: now.addingTimeInterval(2))
    let pruned = try await history.load(limits: .init(count: 1), now: now.addingTimeInterval(3))
    try clipboardAssert(pruned.count == 1 && pruned[0].favorite, "count quota preserves favorites")
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    try clipboardAssert(files.filter { $0.pathExtension == "clipboard" }.count == 1, "pruned payload is removed")
    let aged = try await history.load(now: now.addingTimeInterval(30 * 86_400))
    try clipboardAssert(aged.count == 1, "favorites survive retention")
    let big = ClipboardPayload(items: [.init(representations: [.init(type: "public.png", data: Data(repeating: 0x7f, count: 8_192))])])
    do {
        _ = try await history.insert(big, title: "too large", searchableText: "", kind: .image,
                                     sourceBundleID: nil, sourceName: nil, limits: .init(itemBytes: 1_024))
        throw ClipboardCheckError(detail: "oversized input accepted")
    } catch ClipboardHistoryError.tooLarge {}
    let transparent = CGImageSourceCreateWithData(restored.items[0].representations[0].data as CFData, nil)!
    let decoded = CGImageSourceCreateImageAtIndex(transparent, 0, nil)!
    try clipboardAssert(decoded.width == 2 && decoded.height == 2 && decoded.alphaInfo != .none, "image dimensions and alpha retained")
    // Actor isolation serializes simultaneous writes without losing another captured item.
    let concurrentRoot = root.appendingPathComponent("concurrent")
    let concurrent = ClipboardHistory(directory: concurrentRoot)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<12 {
            group.addTask {
                let data = ClipboardPayload(items: [.init(representations: [.init(type: "public.utf8-plain-text", data: Data("entry-\(index)".utf8))])])
                _ = try await concurrent.insert(data, title: "entry", searchableText: "entry", kind: .text,
                                                 sourceBundleID: nil, sourceName: nil, now: now)
            }
        }
        try await group.waitForAll()
    }
    let concurrentRecords = try await concurrent.load(now: now)
    try clipboardAssert(concurrentRecords.count == 12, "concurrent snapshots are all retained")
    let expiring = try await concurrent.load(limits: .init(retention: 3_600), now: now.addingTimeInterval(3_601))
    try clipboardAssert(expiring.isEmpty, "unstarred items expire")
    // Favorite data is never silently deleted to satisfy disk quota.
    let quotaRoot = root.appendingPathComponent("quota")
    let quota = ClipboardHistory(directory: quotaRoot)
    let quotaEntry = try await quota.insert(big, title: "image", searchableText: "", kind: .image,
                                           sourceBundleID: nil, sourceName: nil, now: now)
    _ = try await quota.setFavorite(id: quotaEntry[0].id, value: true)
    do {
        _ = try await quota.load(limits: .init(diskBytes: 1_024), now: now)
        throw ClipboardCheckError(detail: "favorite disk quota was not surfaced")
    } catch ClipboardHistoryError.favoritesFillQuota {}
    let preserved = try await quota.payload(id: quotaEntry[0].id)
    try clipboardAssert(preserved == big, "quota failure preserves original payload")
    // Corrupt indexes are reported and left untouched instead of overwriting user history.
    let corruptRoot = root.appendingPathComponent("corrupt")
    try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
    let corruptBytes = Data("broken-index".utf8)
    try corruptBytes.write(to: corruptRoot.appendingPathComponent("history.json"))
    do {
        _ = try await ClipboardHistory(directory: corruptRoot).load()
        throw ClipboardCheckError(detail: "invalid index accepted")
    } catch ClipboardHistoryError.invalidIndex {}
    let unchangedCorrupt = try Data(contentsOf: corruptRoot.appendingPathComponent("history.json"))
    try clipboardAssert(unchangedCorrupt == corruptBytes, "corrupt data is preserved")
    let corruptHistory = ClipboardHistory(directory: corruptRoot)
    let orphan = corruptRoot.appendingPathComponent(String(repeating: "b", count: 64) + ".clipboard")
    try Data("orphaned payload".utf8).write(to: orphan)
    let unrelated = corruptRoot.appendingPathComponent("unrelated.txt")
    try Data("keep".utf8).write(to: unrelated)
    try await corruptHistory.clear()
    try clipboardAssert(!FileManager.default.fileExists(atPath: orphan.path) && FileManager.default.fileExists(atPath: unrelated.path), "confirmed clear deletes only owned payload files")
    let afterRecovery = try await corruptHistory.insert(text, title: "recovered", searchableText: "recovered", kind: .text,
                                                        sourceBundleID: nil, sourceName: nil, now: now)
    let recoveredPayload = try await ClipboardHistory(directory: corruptRoot).payload(id: afterRecovery[0].id)
    try clipboardAssert(recoveredPayload == text, "confirmed clear recovers corrupt index and accepts new captures")
    // Valid JSON containing extreme decoded integers must throw, never overflow quota arithmetic.
    let oversizedMetadataRoot = root.appendingPathComponent("oversized-metadata")
    try FileManager.default.createDirectory(at: oversizedMetadataRoot, withIntermediateDirectories: true)
    let validIndex = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("history.json"))) as! [String: Any]
    var damagedRecord = (validIndex["records"] as! [[String: Any]])[0]
    damagedRecord["storedBytes"] = Int.max
    var secondDamaged = damagedRecord
    secondDamaged["id"] = String(repeating: "a", count: 64)
    let oversizedMetadataBytes = try JSONSerialization.data(withJSONObject: ["version": 1, "records": [damagedRecord, secondDamaged]])
    let oversizedMetadataIndex = oversizedMetadataRoot.appendingPathComponent("history.json")
    try oversizedMetadataBytes.write(to: oversizedMetadataIndex)
    do {
        _ = try await ClipboardHistory(directory: oversizedMetadataRoot).load()
        throw ClipboardCheckError(detail: "extreme decoded metadata was accepted")
    } catch ClipboardHistoryError.invalidIndex {}
    let afterInvalidMetadata = try Data(contentsOf: oversizedMetadataIndex)
    try clipboardAssert(afterInvalidMetadata == oversizedMetadataBytes, "invalid integer metadata remains intact")
    // A replaced payload cannot be read beyond its persisted size limit.
    let boundedRoot = root.appendingPathComponent("bounded-payload")
    let boundedHistory = ClipboardHistory(directory: boundedRoot)
    let boundedRecord = try await boundedHistory.insert(text, title: "bounded", searchableText: "bounded", kind: .text,
                                                       sourceBundleID: nil, sourceName: nil, now: now)[0]
    let boundedURL = boundedRoot.appendingPathComponent(boundedRecord.id + ".clipboard")
    let grows = try FileHandle(forWritingTo: boundedURL)
    try grows.truncate(atOffset: UInt64(boundedRecord.storedBytes + 1_024))
    try grows.close()
    do {
        _ = try await boundedHistory.payload(id: boundedRecord.id)
        throw ClipboardCheckError(detail: "replaced payload size was accepted")
    } catch ClipboardHistoryError.missing {}
    try clipboardAssert(ClipboardPrivacy.shouldIgnore(types: ["org.nspasteboard.ConcealedType"], sourceBundleID: nil), "concealed content ignored")
    try clipboardAssert(ClipboardPrivacy.shouldIgnore(types: [], sourceBundleID: "com.apple.Passwords"), "password source ignored")
    try clipboardAssert(ClipboardPrivacy.shouldIgnore(types: [ClipboardPrivacy.ownMarker], sourceBundleID: nil), "own writes ignored")
    try await history.clear()
    let cleared = try await ClipboardHistory(directory: root).load()
    try clipboardAssert(cleared.isEmpty, "clear remains empty across restart")
    print("PASS clipboard persistence, original image bytes, multi-item order, dedup, quotas, corruption recovery and privacy")
}
