import AppKit
import Combine
import IslandCore
import UniformTypeIdentifiers

/// A file presenter follows coordinated edits/renames without requesting directory access.
private final class NoteFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "Hermes.NotePresenter"
        return queue
    }()
    private let changed: @Sendable (URL?) -> Void
    init(url: URL, changed: @escaping @Sendable (URL?) -> Void) {
        presentedItemURL = url
        self.changed = changed
    }
    func presentedItemDidChange() { changed(nil) }
    func presentedItemDidMove(to newURL: URL) { changed(newURL) }
    func accommodatePresentedItemDeletion(completionHandler: @escaping ((any Error)?) -> Void) {
        changed(nil)
        completionHandler(nil)
    }
}

struct NoteSelection: Sendable {
    let bookmark: Data
    let name: String
}

@MainActor
final class SurfaceAccess: ObservableObject {
    static let shared = SurfaceAccess()
    @Published private(set) var filePath: String
    @Published private(set) var revision = UUID()
    @Published private(set) var errorMessage: String?
    var hasFile: Bool { !filePath.isEmpty }
    var fileName: String { URL(fileURLWithPath: filePath).lastPathComponent }
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var presenter: NoteFilePresenter?
    private var scopedURL: URL?
    private var users = 0
    private var watchGeneration = UUID()
    init() { filePath = UserDefaults.standard.string(forKey: "island.surfaceFilePath") ?? "" }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 Markdown 文件"
        panel.prompt = "选择"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if hasFile { panel.directoryURL = URL(fileURLWithPath: filePath).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try saveSelection(url)
            errorMessage = nil
            restartWatching()
        } catch { errorMessage = error.localizedDescription }
    }

    func clearSelection() {
        stopWatching()
        UserDefaults.standard.removeObject(forKey: "island.surfaceFileBookmark")
        UserDefaults.standard.removeObject(forKey: "island.surfaceFilePath")
        filePath = ""
        errorMessage = nil
        revision = UUID()
    }

    private func saveSelection(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: "island.surfaceFileBookmark")
        UserDefaults.standard.set(url.path, forKey: "island.surfaceFilePath")
        filePath = url.path
        revision = UUID()
    }

    private func resolve() throws -> URL {
        guard let bookmark = UserDefaults.standard.data(forKey: "island.surfaceFileBookmark") else {
            throw IslandError.configuration("请先选择 Markdown 文件。")
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale || filePath != url.path { try saveSelection(url) }
        return url
    }

    /// Immutable identity captured before a request/save is queued.
    func snapshot() throws -> NoteSelection {
        guard let bookmark = UserDefaults.standard.data(forKey: "island.surfaceFileBookmark") else {
            throw IslandError.configuration("请先选择 Markdown 文件。")
        }
        return NoteSelection(bookmark: bookmark, name: fileName)
    }

    private func resolve(_ selection: NoteSelection) throws -> URL {
        var stale = false
        // An older in-flight selection must never overwrite a newly chosen bookmark.
        return try URL(resolvingBookmarkData: selection.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Resolve and read again for every submission, even if a sync tool replaced the file.
    func context(selection: NoteSelection) async throws -> String {
        let file = try resolve(selection)
        guard file.startAccessingSecurityScopedResource() else { throw IslandError.configuration("无法访问便签，请重新选择文件。") }
        defer { file.stopAccessingSecurityScopedResource() }
        return try await Task.detached(priority: .userInitiated) {
            let contents = try SurfaceFiles.coordinatedRead(file)
            return "\n\n--- 本地便签：\(file.lastPathComponent) ---\n" + contents
        }.value
    }

    func appendTask(_ text: String, selection: NoteSelection) async throws {
        let file = try resolve(selection)
        guard file.startAccessingSecurityScopedResource() else { throw IslandError.configuration("无法访问便签，请重新选择文件。") }
        defer { file.stopAccessingSecurityScopedResource() }
        try await Task.detached(priority: .userInitiated) {
            try SurfaceFiles.appendTask(text, to: file)
        }.value
        revision = UUID()
        restartWatching()
    }

    func acquire() { users += 1; if users == 1 { startWatching() } }
    func release() { users = max(0, users - 1); if users == 0 { stopWatching() } }
    private func restartWatching() {
        stopWatching()
        if users > 0 { startWatching() }
    }
    private func startWatching() {
        guard scopedURL == nil, let file = try? resolve(), file.startAccessingSecurityScopedResource() else { return }
        scopedURL = file
        let generation = watchGeneration
        let filePresenter = NoteFilePresenter(url: file) { [weak self] movedURL in
            Task { @MainActor in
                guard let self, self.watchGeneration == generation else { return }
                if let movedURL {
                    do { try self.saveSelection(movedURL); self.restartWatching() }
                    catch { self.errorMessage = error.localizedDescription }
                }
                self.revision = UUID()
            }
        }
        presenter = filePresenter
        NSFileCoordinator.addFilePresenter(filePresenter)

        // A parent-directory event survives sync tools' uncoordinated atomic replacement.
        // File-only sandbox grants can deny that descriptor; the selected file still gets
        // a vnode watcher and NSFilePresenter without broadening the user's authorization.
        addWatcher(file.deletingLastPathComponent(), isParent: true)
        addWatcher(file, isParent: false)
    }
    private func addWatcher(_ url: URL, isParent: Bool) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let generation = watchGeneration
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib, .revoke], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let events = source?.data ?? []
            Task { @MainActor in
                guard let self, self.watchGeneration == generation else { return }
                self.revision = UUID()
                if !isParent,
                   !events.intersection([.rename, .delete, .revoke]).isEmpty {
                    // Reads always use a fresh URL; directory events rebind the new vnode.
                    self.restartWatching()
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        watchers.append(source)
        source.resume()
    }
    private func stopWatching() {
        watchGeneration = UUID()
        for watcher in watchers { watcher.cancel() }
        watchers = []
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        presenter = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }
}
