import AppKit
import Combine
import ImageIO
import IslandCore
import UniformTypeIdentifiers

extension Notification.Name {
    static let clipboardPasteRequested = Notification.Name("ClipboardPasteRequested")
    static let clipboardDismissRequested = Notification.Name("ClipboardDismissRequested")
}

/// AppKit pasteboard access stays on the main actor; all persistence and image decoding are isolated.
@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()
    @Published private(set) var records: [ClipboardHistoryRecord] = []
    @Published var search = ""
    @Published var selectedID: String?
    @Published var keyboardSessionActive = false
    @Published private(set) var message: String?
    @Published private(set) var busy = false
    @Published private(set) var needsReadAccess = false
    @Published private(set) var readDenied = false
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "island.clipboardEnabled")
            if enabled { restartMonitor() } else { timer?.invalidate(); timer = nil }
        }
    }
    @Published var retentionDays: Int {
        didSet { UserDefaults.standard.set(retentionDays, forKey: "island.clipboardRetentionDays"); applyLimits() }
    }
    @Published var maximumCount: Int {
        didSet { UserDefaults.standard.set(maximumCount, forKey: "island.clipboardMaximumCount"); applyLimits() }
    }
    @Published var diskMegabytes: Int {
        didSet { UserDefaults.standard.set(diskMegabytes, forKey: "island.clipboardDiskMB"); applyLimits() }
    }
    @Published var excludedApps: String {
        didSet { UserDefaults.standard.set(excludedApps, forKey: "island.clipboardExcludedApps") }
    }
    private let history: ClipboardHistory
    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var changeCount: Int
    private var started = false
    private var locked = false
    private var loading = false
    private var capturing = false
    private var monitorTick = 0
    private var legacyReadAllowed = false
    private var sessionTarget: NSRunningApplication?
    private var sessionGeneration = UUID()
    private var copyTask: Task<Void, Never>?
    private var heldScopes: [URL] = []
    private var scopeReleaseTask: Task<Void, Never>?
    private var thumbnailCache = NSCache<NSString, NSImage>()
    private var thumbnailTasks: [String: Task<NSImage?, Never>] = [:]
    private static let bookmarkType = "theboringteam.boringnotch.file-bookmark"
    private let supportedTypes = Set(["public.utf8-plain-text", "public.utf16-external-plain-text", "public.rtf", "public.html",
                                     "public.url", "public.file-url", "public.png", "public.tiff", "public.jpeg", "com.compuserve.gif", "public.heic"])

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: "island.clipboardEnabled")
        retentionDays = max(1, defaults.object(forKey: "island.clipboardRetentionDays") as? Int ?? 7)
        maximumCount = max(20, defaults.object(forKey: "island.clipboardMaximumCount") as? Int ?? 200)
        diskMegabytes = max(32, defaults.object(forKey: "island.clipboardDiskMB") as? Int ?? 256)
        excludedApps = defaults.string(forKey: "island.clipboardExcludedApps") ?? ""
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        history = ClipboardHistory(directory: support.appendingPathComponent("boringNotch/Clipboard", isDirectory: true))
        changeCount = NSPasteboard.general.changeCount
        thumbnailCache.countLimit = 24
        thumbnailCache.totalCostLimit = 12 * 1_024 * 1_024
    }
    var filteredRecords: [ClipboardHistoryRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter {
            query.isEmpty || $0.searchableText.localizedStandardContains(query)
                || $0.sourceName?.localizedStandardContains(query) == true
                || $0.title.localizedStandardContains(query)
        }.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            return $0.copiedAt > $1.copiedAt
        }
    }
    var selectedRecord: ClipboardHistoryRecord? { filteredRecords.first { $0.id == selectedID } ?? filteredRecords.first }
    private var limits: ClipboardHistoryLimits {
        .init(count: maximumCount, retention: Double(retentionDays) * 86_400, diskBytes: diskMegabytes * 1_024 * 1_024)
    }
    func start() {
        guard !started else { return }; started = true
        applyLimits()
        if enabled { restartMonitor() }
    }
    func beginSession(target: NSRunningApplication?) {
        sessionGeneration = UUID()
        sessionTarget = nil
        start()
        if let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier, !target.isTerminated {
            sessionTarget = target
        }
        search = ""; selectedID = filteredRecords.first?.id
        applyLimits()
    }
    func endSession() {
        sessionGeneration = UUID()
        copyTask?.cancel(); copyTask = nil
        keyboardSessionActive = false
        search = ""
        sessionTarget = nil
        thumbnailTasks.values.forEach { $0.cancel() }; thumbnailTasks.removeAll()
        thumbnailCache.removeAllObjects()
    }
    func setScreenLocked(_ value: Bool) {
        locked = value
        if value {
            endSession(); timer?.invalidate(); timer = nil
        } else if enabled { changeCount = pasteboard.changeCount; restartMonitor() }
    }
    func reportPasteError(_ value: String) { message = value }
    func clearMessage() { message = nil }
    func requestReadAccess() {
        enabled = true
        needsReadAccess = false
        readDenied = false
        // A user action triggers exactly one attempt; monitoring never repeatedly requests permission.
        changeCount = pasteboard.changeCount - 1
        capture(allowPrompt: true)
    }
    func openReadSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") {
            NSWorkspace.shared.open(url)
        }
    }
    private func restartMonitor() {
        timer?.invalidate(); timer = nil
        guard enabled, !locked else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer?.tolerance = 0.15
        poll()
    }
    private func poll() {
        guard enabled, !locked else { return }
        let access = pasteboard.accessBehavior
        readDenied = access == .alwaysDeny
        needsReadAccess = access == .ask || (access == .default && !legacyReadAllowed)
        guard access == .alwaysAllow || (access == .default && legacyReadAllowed) else { return }
        monitorTick += 1
        if monitorTick % 120 == 0 { applyLimits() }
        guard !capturing, pasteboard.changeCount != changeCount else { return }
        capture(allowPrompt: false)
    }
    private func capture(allowPrompt: Bool) {
        guard enabled, !locked, !capturing else { return }
        guard allowPrompt || pasteboard.accessBehavior == .alwaysAllow || (pasteboard.accessBehavior == .default && legacyReadAllowed) else { return }
        let count = pasteboard.changeCount
        guard count != changeCount else { return }
        changeCount = count
        let source = NSWorkspace.shared.frontmostApplication
        let extraApps = Set(excludedApps.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) })
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard !ClipboardPrivacy.shouldIgnore(types: types, sourceBundleID: source?.bundleIdentifier, extraApps: extraApps) else { return }
        guard let boardItems = pasteboard.pasteboardItems else {
            needsReadAccess = pasteboard.accessBehavior != .alwaysAllow
            return
        }
        readDenied = pasteboard.accessBehavior == .alwaysDeny
        // Older systems may expose the API before enforcing pasteboard privacy. A successful
        // explicit user read in `.default` permits monitoring until the system reports ask/deny.
        if allowPrompt && pasteboard.accessBehavior == .default { legacyReadAllowed = true }
        needsReadAccess = pasteboard.accessBehavior == .ask || (pasteboard.accessBehavior == .default && !legacyReadAllowed)
        guard !readDenied, boardItems.count <= 64 else { return }
        var items: [ClipboardPayloadItem] = []
        var searchable = ""
        var kind: ClipboardHistoryRecord.Kind = .text
        var total = 0
        for item in boardItems {
            let itemTypes = Set(item.types.map(\.rawValue))
            if ClipboardPrivacy.shouldIgnore(types: itemTypes, sourceBundleID: source?.bundleIdentifier, extraApps: extraApps) { return }
            var representations: [ClipboardRepresentation] = []
            for type in item.types where supportedTypes.contains(type.rawValue) {
                guard let data = item.data(forType: type), !data.isEmpty else { continue }
                total += data.count
                guard total <= limits.itemBytes else { message = ClipboardHistoryError.tooLarge.localizedDescription; return }
                representations.append(.init(type: type.rawValue, data: data))
                if UTType(type.rawValue)?.conforms(to: .image) == true { kind = .image }
            }
            let plainText = item.string(forType: .string) ?? item.string(forType: .URL)
                ?? item.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil)?.string }
            if let text = plainText, !text.isEmpty {
                searchable += String(text.prefix(8_192)) + "\n"
            } else if let html = item.string(forType: .html) {
                // Metadata extraction never invokes HTML rendering or fetches remote resources.
                searchable += String(html.prefix(32_768)).replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&") + "\n"
            }
            if let path = item.string(forType: .fileURL), let url = URL(string: path), url.isFileURL {
                if kind != .image { kind = .file }
                searchable += url.lastPathComponent + "\n"
                // The pasteboard-granted file access is converted to a bookmark where possible.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    representations.append(.init(type: Self.bookmarkType, data: bookmark))
                }
            }
            if !representations.isEmpty { items.append(.init(representations: representations)) }
        }
        guard count == pasteboard.changeCount, !items.isEmpty else { return }
        let payload = ClipboardPayload(items: items)
        if kind == .text && searchable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard items.contains(where: { $0.representations.contains(where: { $0.type == "public.rtf" || $0.type == "public.html" }) }) else { return }
            searchable = "富文本"
        }
        let title: String
        switch kind {
        case .image: title = "图片"
        case .file: title = searchable.split(separator: "\n").first.map(String.init) ?? "文件"
        case .text: title = String(searchable.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        }
        capturing = true
        let currentLimits = limits
        Task {
            defer { capturing = false }
            do {
                let updated = try await history.insert(payload, title: title, searchableText: searchable, kind: kind,
                    sourceBundleID: source?.bundleIdentifier, sourceName: source?.localizedName, limits: currentLimits)
                records = updated
                if selectedID == nil { selectedID = filteredRecords.first?.id }
            } catch { message = error.localizedDescription }
        }
    }
    private func applyLimits() {
        guard !loading else { return }; loading = true
        let currentLimits = limits
        Task {
            defer { loading = false }
            do { records = try await history.load(limits: currentLimits) }
            catch { message = error.localizedDescription }
        }
    }
    func moveSelection(_ offset: Int) {
        let results = filteredRecords
        guard !results.isEmpty else { selectedID = nil; return }
        let index = results.firstIndex(where: { $0.id == selectedID }) ?? 0
        selectedID = results[min(max(0, index + offset), results.count - 1)].id
    }
    func copySelected(paste: Bool) {
        guard let record = selectedRecord, !busy else { return }
        copy(record, paste: paste)
    }
    func copy(_ record: ClipboardHistoryRecord, paste: Bool) {
        guard !busy, !locked else { return }
        busy = true
        let target = sessionTarget
        let generation = sessionGeneration
        copyTask = Task {
            defer { busy = false; copyTask = nil }
            do {
                let payload = try await history.payload(id: record.id)
                guard !Task.isCancelled, !locked, sessionGeneration == generation else { return }
                let objects = try payload.items.map { item -> NSPasteboardItem in
                    let object = NSPasteboardItem()
                    for representation in item.representations where representation.type != Self.bookmarkType {
                        if representation.type == NSPasteboard.PasteboardType.fileURL.rawValue,
                           let path = String(data: representation.data, encoding: .utf8),
                           let url = URL(string: path), url.isFileURL {
                            var reachable = FileManager.default.fileExists(atPath: url.path)
                            if let bookmark = item.representations.first(where: { $0.type == Self.bookmarkType }) {
                                var stale = false
                                if let resolved = try? URL(resolvingBookmarkData: bookmark.data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
                                   resolved.startAccessingSecurityScopedResource() {
                                    heldScopes.append(resolved)
                                    reachable = FileManager.default.fileExists(atPath: resolved.path)
                                    object.setString(resolved.absoluteString, forType: .fileURL)
                                    continue
                                }
                            }
                            guard reachable else { throw ClipboardHistoryError.missing }
                        }
                        object.setData(representation.data, forType: .init(representation.type))
                    }
                    object.setString("1", forType: .init(ClipboardPrivacy.ownMarker))
                    return object
                }
                // End the file scope after the receiving app has time to consume file references.
                scheduleScopeRelease()
                pasteboard.clearContents()
                guard pasteboard.writeObjects(objects) else { throw ClipboardHistoryError.missing }
                changeCount = pasteboard.changeCount
                message = nil
                if paste {
                    guard let target, !target.isTerminated else {
                        message = "已复制，请在目标应用中粘贴。"
                        NotificationCenter.default.post(name: .clipboardDismissRequested, object: nil)
                        return
                    }
                    NotificationCenter.default.post(name: .clipboardPasteRequested, object: nil,
                                                    userInfo: ["targetPID": Int(target.processIdentifier)])
                } else {
                    NotificationCenter.default.post(name: .clipboardDismissRequested, object: nil)
                }
            } catch { scheduleScopeRelease(); message = error.localizedDescription }
        }
    }
    private func scheduleScopeRelease() {
        scopeReleaseTask?.cancel()
        scopeReleaseTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self else { return }
            heldScopes.forEach { $0.stopAccessingSecurityScopedResource() }; heldScopes = []
        }
    }
    func favorite(_ record: ClipboardHistoryRecord) {
        Task { do { records = try await history.setFavorite(id: record.id, value: !record.favorite) } catch { message = error.localizedDescription } }
    }
    func delete(_ record: ClipboardHistoryRecord) {
        Task {
            do {
                records = try await history.delete(id: record.id)
                thumbnailCache.removeObject(forKey: record.id as NSString)
                if selectedID == record.id { selectedID = filteredRecords.first?.id }
            } catch { message = error.localizedDescription }
        }
    }
    func clear() {
        Task {
            do { try await history.clear(); records = []; selectedID = nil; thumbnailCache.removeAllObjects() }
            catch { message = error.localizedDescription }
        }
    }
    func thumbnail(for record: ClipboardHistoryRecord) async -> NSImage? {
        if let cached = thumbnailCache.object(forKey: record.id as NSString) { return cached }
        guard record.kind == .image else { return nil }
        if let task = thumbnailTasks[record.id] { return await task.value }
        let history = self.history
        let task = Task<NSImage?, Never> {
            let decoded = await ClipboardThumbnailRenderer.shared.render(history: history, id: record.id)
            guard !Task.isCancelled, let decoded, let image = NSImage(data: decoded) else { return nil }
            thumbnailCache.setObject(image, forKey: record.id as NSString, cost: 240 * 240 * 4)
            return image
        }
        thumbnailTasks[record.id] = task
        let result = await task.value
        thumbnailTasks.removeValue(forKey: record.id)
        return result
    }
}
