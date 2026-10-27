import AppKit
import IslandCore
import UniformTypeIdentifiers

/// Preserve local history and the system pasteboard; own only bounded temporary attachment files.
enum HermesClipboardContext {
    static func files(from payload: ClipboardPayload, maximumCount: Int) throws -> [StagedAttachment] {
        guard !payload.items.isEmpty, payload.items.count <= maximumCount else {
            throw IslandError.limit("剪贴板项目超出剩余附件数量，请减少附件。")
        }
        var result: [StagedAttachment] = []
        do {
            for item in payload.items {
                try Task.checkCancellation()
                let data: Data
                let suffix: String
                let name: String
                if let image = item.representations.first(where: { UTType($0.type)?.conforms(to: .image) == true }) {
                    guard image.data.count <= 16 * 1_024 * 1_024 else { throw IslandError.limit("剪贴板图片超过 16 MB。") }
                    data = image.data
                    suffix = UTType(image.type)?.preferredFilenameExtension ?? "png"
                    name = "剪贴板图片"
                } else {
                    let plain = item.representations.first { $0.type == UTType.utf8PlainText.identifier }
                        .flatMap { String(data: $0.data, encoding: .utf8) }
                    let utf16 = item.representations.first { $0.type == "public.utf16-external-plain-text" }
                        .flatMap { String(data: $0.data, encoding: .utf16) }
                    let rich = item.representations.first { $0.type == UTType.rtf.identifier }
                    guard let text = plain ?? utf16 ?? rich.flatMap({ NSAttributedString(rtf: $0.data, documentAttributes: nil)?.string }) else {
                        throw IslandError.configuration("这条剪贴板记录不包含可用的文本或图片。")
                    }
                    guard text.utf8.count <= 65_536 else { throw IslandError.limit("剪贴板文本超过 64 KB。") }
                    data = Data(text.utf8); suffix = "txt"; name = "剪贴板文本"
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-" + UUID().uuidString).appendingPathExtension(suffix)
                try data.write(to: url, options: .atomic)
                result.append(StagedAttachment(url: url, temporary: true, name: name))
            }
            return result
        } catch {
            for item in result { try? FileManager.default.removeItem(at: item.url) }
            throw error
        }
    }
}
