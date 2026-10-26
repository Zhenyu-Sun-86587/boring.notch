import Foundation
import ImageIO
import IslandCore
import UniformTypeIdentifiers

/// A permit covers payload loading as well as decoding. Many visible rows never load large originals
/// simultaneously, and cancellation of a hidden row is checked before the next file read.
actor ClipboardThumbnailRenderer {
    static let shared = ClipboardThumbnailRenderer()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func render(history: ClipboardHistory, id: String) async -> Data? {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        guard !Task.isCancelled, let payload = try? await history.payload(id: id), !Task.isCancelled,
              let original = payload.items.flatMap(\.representations).first(where: {
                  UTType($0.type)?.conforms(to: .image) == true
              })?.data else { return nil }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithData(original as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 240,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }
    }
}
