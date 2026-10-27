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
    static let dropTypes: [UTType] = [.fileURL, .url, .image, .utf8PlainText, .plainText, .data]

    private static func imageFile(from provider: NSItemProvider, type: String) async throws -> URL {
        // Some sources (browser images/screenshots) vend only bytes, not a file representation.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-" + UUID().uuidString)
            .appendingPathExtension(UTType(type)?.preferredFilenameExtension ?? "png")
        let copied: Bool = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { continuation.resume(returning: false); return }
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: true)
                } catch { continuation.resume(returning: false) }
            }
        }
        if copied { return destination }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
            }
        }
        guard data.count <= 16 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Hermes uses the same provider resolution, but retains only URLs and never decodes a full bitmap.
    static func stagingFiles(from providers: [NSItemProvider]) async throws -> [(url: URL, temporary: Bool)] {
        var results: [(url: URL, temporary: Bool)] = []
        do {
            for provider in providers {
                if let url = await provider.extractFileURL(), url.isFileURL {
                    results.append((url, false))
                } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                    let url = try await imageFile(from: provider, type: type)
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

    static func items(from providers: [NSItemProvider]) async throws -> [ShelfItem] {
        // Process providers concurrently for better performance with large drops
        let results = await withTaskGroup(of: ShelfItem?.self) { group in
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
        guard results.count == providers.count else {
            for item in results { await item.cleanupStoredData() }
            throw CocoaError(.fileReadUnknown)
        }
        return results
    }

    private static func processProvider(_ provider: NSItemProvider) async -> ShelfItem? {
        if let actualFileURL = await provider.extractFileURL() {
            if let bookmark = createBookmark(for: actualFileURL) {
                return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
            }
            return nil
        }

        if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
            guard let url = try? await imageFile(from: provider, type: type) else { return nil }
            guard let bookmark = createBookmark(for: url) else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: true)
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
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? Bookmark(url: url))?.data
    }
}
