import AppKit
import Combine
import IslandCore

@MainActor
final class SurfaceAccess: ObservableObject {
    static let shared = SurfaceAccess()
    @Published private(set) var directoryPath: String
    @Published private(set) var revision = UUID()
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedURL: URL?
    private var users = 0
    init() { directoryPath = UserDefaults.standard.string(forKey: "island.surfacePath") ?? IslandSettings.surfaceDefault }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: directoryPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: "island.surfaceBookmark")
            UserDefaults.standard.set(url.path, forKey: "island.surfacePath")
            directoryPath = url.path
            stopWatching()
            if users > 0 { startWatching() }
            revision = UUID()
        } catch { NSAlert(error: error).runModal() }
    }
    private func resolve() throws -> URL {
        guard let bookmark = UserDefaults.standard.data(forKey: "island.surfaceBookmark") else {
            throw IslandError.configuration("请在 Hermes 设置中选择并授权便签目录。")
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale {
            guard url.startAccessingSecurityScopedResource() else { throw IslandError.configuration("便签目录授权已失效，请重新选择。") }
            defer { url.stopAccessingSecurityScopedResource() }
            UserDefaults.standard.set(try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "island.surfaceBookmark")
        }
        return url
    }
    func context(for prompt: String) async throws -> String {
        let files = SurfaceFiles.references(in: prompt)
        guard !files.isEmpty else { return "" }
        let directory = try resolve()
        guard directory.startAccessingSecurityScopedResource() else { throw IslandError.configuration("无法访问便签目录，请重新授权。") }
        defer { directory.stopAccessingSecurityScopedResource() }
        return try await Task.detached(priority: .userInitiated) {
            try files.map { name in "\n\n--- Local context: \(name) ---\n" + (try SurfaceFiles.read(directory.appendingPathComponent(name))) }.joined()
        }.value
    }
    func appendTask(_ text: String) async throws {
        let directory = try resolve()
        guard directory.startAccessingSecurityScopedResource() else { throw IslandError.configuration("无法访问便签目录，请重新授权。") }
        defer { directory.stopAccessingSecurityScopedResource() }
        try await Task.detached(priority: .userInitiated) {
            try SurfaceFiles.appendTask(text, to: directory.appendingPathComponent("Today.md"))
        }.value
        revision = UUID()
    }
    func acquire() { users += 1; if users == 1 { startWatching() } }
    func release() { users = max(0, users - 1); if users == 0 { stopWatching() } }
    private func startWatching() {
        guard let directory = try? resolve(), directory.startAccessingSecurityScopedResource() else { return }
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { directory.stopAccessingSecurityScopedResource(); return }
        watchedURL = directory
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in Task { @MainActor in self?.revision = UUID() } }
        source.setCancelHandler { close(descriptor); directory.stopAccessingSecurityScopedResource() }
        watcher = source; source.resume()
    }
    private func stopWatching() { watcher?.cancel(); watcher = nil; watchedURL = nil }
}
