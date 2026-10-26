//
//  ShelfDropService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-26.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

struct ShelfDropService {
    /// Hermes uses the same provider resolution, but retains only URLs and never decodes a full bitmap.
    static func stagingFiles(from providers: [NSItemProvider]) async throws -> [(url: URL, temporary: Bool)] {
        var results: [(url: URL, temporary: Bool)] = []
        do {
            for provider in providers {
                if let url = await provider.extractFileURL(), url.isFileURL {
                    results.append((url, false))
                } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                    let url: URL = try await withCheckedThrowingContinuation { continuation in
                        provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                            do {
                                if let error { throw error }
                                guard let url else { throw CocoaError(.fileReadUnknown) }
                                let destination = FileManager.default.temporaryDirectory
                                    .appendingPathComponent("hermes-" + UUID().uuidString)
                                    .appendingPathExtension(UTType(type)?.preferredFilenameExtension ?? "png")
                                try FileManager.default.copyItem(at: url, to: destination)
                                continuation.resume(returning: destination)
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                    results.append((url, true))
                } else if let text = await provider.extractText() {
                    guard text.utf8.count <= 65_536 else { throw CocoaError(.fileReadTooLarge) }
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-" + UUID().uuidString + ".txt")
                    try Data(text.utf8).write(to: url, options: .atomic)
                    results.append((url, true))
                } else { throw CocoaError(.fileReadUnsupportedScheme) }
            }
            return results
        } catch {
            for item in results where item.temporary { try? FileManager.default.removeItem(at: item.url) }
            throw error
        }
    }

    static func items(from providers: [NSItemProvider]) async -> [ShelfItem] {
        // Process providers concurrently for better performance with large drops
        await withTaskGroup(of: ShelfItem?.self) { group in
            for provider in providers {
                group.addTask {
                    await processProvider(provider)
                }
            }

            var results: [ShelfItem] = []
            results.reserveCapacity(providers.count)

            for await item in group {
                if let item = item {
                    results.append(item)
                }
            }

            return results
        }
    }

    private static func processProvider(_ provider: NSItemProvider) async -> ShelfItem? {
        if let actualFileURL = await provider.extractFileURL() {
            if let bookmark = createBookmark(for: actualFileURL) {
                return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
            }
            return nil
        }

        if let url = await provider.extractURL() {
            if url.isFileURL {
                if let bookmark = createBookmark(for: url) {
                    return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
                }
            } else {
                return await ShelfItem(kind: .link(url: url), isTemporary: false)
            }
            return nil
        }

        if let text = await provider.extractText() {
            return await ShelfItem(kind: .text(string: text), isTemporary: false)
        }

        if let data = await provider.loadData() {
            if let tempDataURL = await TemporaryFileStorageService.shared.createTempFile(for: .data(data, suggestedName: provider.suggestedName)),
               let bookmark = createBookmark(for: tempDataURL) {
                return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: true)
            }
            return nil
        }

        if let fileURL = await provider.extractItem() {
            if let bookmark = createBookmark(for: fileURL) {
                return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
            }
        }

        return nil
    }

    private static func createBookmark(for url: URL) -> Data? {
        return (try? Bookmark(url: url))?.data
    }
}
