import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum SurfaceFiles {
    public static func read(_ url: URL, limit: Int = 65_536) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw IslandError.limit("\(url.lastPathComponent) 超过 \(limit / 1_024) KB，请先缩小内容。") }
        guard let text = String(data: data, encoding: .utf8) else { throw IslandError.configuration("附件必须是 UTF-8 文本。") }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
    }

    public static func coordinatedRead(_ url: URL, limit: Int = 65_536) throws -> String {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<String, any Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try read(coordinatedURL, limit: limit) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw IslandError.changedFile }
        return try result.get()
    }

    /// Preserve the original byte prefix, BOM and line endings when appending one multi-line task.
    public static func appendingTask(_ text: String, to existing: Data) throws -> Data {
        guard let original = String(data: existing, encoding: .utf8) else { throw IslandError.configuration("便签必须是 UTF-8 文本。") }
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        guard let first = lines.first, !first.isEmpty else { throw IslandError.configuration("没有可保存的回答。") }
        guard text.utf8.count <= 131_072 else { throw IslandError.limit("保存内容超过 128 KB。") }
        let newline = original.contains("\r\n") ? "\r\n" : "\n"
        let task = (["- [ ] " + first] + lines.dropFirst().map { "  " + $0 }).joined(separator: newline) + newline
        var result = existing
        if !existing.isEmpty && !original.hasSuffix("\n") { result.append(Data(newline.utf8)) }
        result.append(Data(task.utf8))
        return result
    }

    public static func appendTask(_ text: String, to url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var failure: (any Error)?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { coordinatedURL in
            do {
                guard (try coordinatedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 2_097_152 else {
                    throw IslandError.limit("便签超过 2 MB，请先归档旧内容。")
                }
                for attempt in 0..<3 {
                    let before = try Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
                    let updated = try appendingTask(text, to: before)
                    guard try Data(contentsOf: coordinatedURL) == before else {
                        if attempt == 2 { throw IslandError.changedFile }
                        continue
                    }
                    try updated.write(to: coordinatedURL, options: .atomic)
                    return
                }
            } catch { failure = error }
        }
        if let coordinationError { throw coordinationError }
        if let failure { throw failure }
    }
}

public enum AttachmentImage {
    public static func jpeg(at url: URL, maxPixelSize: Int = 1_600) throws -> Data {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw IslandError.configuration("无法读取图片。") }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw IslandError.invalidResponse }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw IslandError.invalidResponse }
            return data as Data
        }
    }
}
